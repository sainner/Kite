/**
 * 账号级数据经工作机之间的同步链路（src/account-data/directory.ts、replication.ts）：两台本进程 kited 各有自己的数据目录
 * 和凭据密钥文件，用 harness 的 connect 互为组网对端，读 /machine 发现、长轮询拉增量都直接访问对方的监听地址。
 * 后一段是经同一链路交接的资源库与项目约束（src/library-sync.ts）：写入先进本机的账号级数据，再对缓存；别的工作机经同步
 * 拿到同一条，对完缓存后两边按同一内容算出同一版本，乐观锁才对得上。
 */
import { afterEach, expect, test } from 'bun:test';
import { Database } from 'bun:sqlite';
import { existsSync, readdirSync, readFileSync, rmSync, statSync } from 'node:fs';
import { join } from 'node:path';
import { startDaemon, type Daemon } from '../../src/daemon.ts';
import { SYSTEM_SKILLS } from '../../src/harness/context/skills.ts';
import type { ContextDefinition } from '../../src/harness/context/types.ts';
import { TOOL_SEARCH } from '../../src/harness/tool-search.ts';
import type { Json, ModelItem } from '../../src/harness/types.ts';
import type { Project, WorkspaceModel } from '../../src/model.ts';
import type { Role } from '../../src/roles.ts';
import type { SkillPackage, SkillSnapshot } from '../../src/skills.ts';
import { emblemTemplate } from '../../src/template-emblems.ts';
import { type FakeGit, startFakeGit } from '../fake-git.ts';
import {
  addProject, after, call, connect, folderWorkspace, type Kited, mark, openAgent, openWorkspace, startKited, synced,
} from '../harness.ts';
import { item, ManualModel } from '../harness-loop.ts';
import { lexists, makeTemp, newDir, until } from '../util.ts';

const kiteds: Kited[] = [];
let remotes: FakeGit | undefined;
afterEach(async () => {
  for (const k of kiteds.splice(0)) await k.stop();
  remotes?.stop();
  remotes = undefined;
});

/** Git 平台替身上的一个空远程；登记远程要先确认访问得到。 */
const remoteUrl = (name: string) => (remotes ??= startFakeGit()).create(name).url;

/** 账号级数据落地的文件（含 WAL），按字节拼起来查有没有明文。 */
const stored = (k: Kited) => ['account.db', 'account.db-wal'].map((name) => join(k.home, name)).filter(existsSync)
  .map((path) => readFileSync(path).toString('latin1')).join('');

// 凭据的保密内容在 A 用 A 的密钥封装落地，传给 B 时解开成明文，B 要用自己的密钥重新封装：B 存成 A 的密文就解不开，
// 存成明文就泄露在磁盘上。目录摘要由 A 写进账号级数据，随同一条同步传到 B，B 读 /machine 判断 A 在线。
test('A 新建的 Git 凭据和共享密钥同步到 B 后 B 能取用、两边落地都不是明文，A 的目录摘要出现在 B 的工作机目录里且在线', async () => {
  const a = startKited();
  const b = startKited();
  kiteds.push(a, b);
  await connect(a, b);
  const machineA = a.daemon.kite.store.machine.id;
  const token = `git-token-${crypto.randomUUID()}`;
  const value = `secret-value-${crypto.randomUUID()}`;
  const git = await a.call('POST', '/credentials', { type: 'git', name: 'git.example.test', meta: { username: 'kite-bot' }, secret: { token } });
  expect(git.status).toBe(201);
  const secret = await a.call('POST', '/credentials', { type: 'secret', name: 'DEPLOY_TOKEN', meta: { kind: 'text' }, secret: { value } });
  expect(secret.status).toBe(201);

  await synced(b, () => b.daemon.kite.credentials.list('git').length > 0 && b.daemon.kite.credentials.list('secret').length > 0,
    'B 同步到 A 新建的凭据');
  expect(await b.daemon.kite.git.credential('https://git.example.test/owner/project.git')).toEqual({ username: 'kite-bot', password: token });
  expect(await b.daemon.kite.credentials.resolve(['{account.DEPLOY_TOKEN}']))
    .toEqual([{ reference: '{account.DEPLOY_TOKEN}', kind: 'text', value }]);
  for (const k of [a, b]) {
    expect(stored(k).includes(token)).toBe(false);
    expect(stored(k).includes(value)).toBe(false);
  }

  await synced(b, () => b.daemon.kite.directory.entries().some((entry) => entry.id === machineA && entry.snapshot), 'B 同步到 A 的目录摘要');
  const machines = await b.call('GET', '/machines');
  expect(machines.status).toBe(200);
  expect(machines.body).toContainEqual(expect.objectContaining({
    id: machineA, online: true, snapshot: expect.objectContaining({ machine: expect.objectContaining({ id: machineA }) }),
  }));
}, 1000);

// 两台工作机没同步上时各自登记了同一远程，各得一个项目；连上后登记表随同步合并，
// 先登记的保留、后登记的记为并入它，各机 syncProjects 时把本机检出与工作区改挂过去（后登记的那台建过工作区，有检出）。
// 后登记的那个设了工具约束和执行约束、有一条项目专用的密钥，合并后都要归到保留的项目；约束取两份里更严的组合。
// 要登记表、同步、两边各自合并与本机 SQLite 改挂合起来才看得出。
// 真实 bug（旧实现）：合并只改挂检出，保留的项目读到默认的不限制约束，密钥还绑在并入的旧 ID 上，按保留的项目列不出、取不到。
// 真实 bug（后来的实现）：保留的项目没设执行约束时，合并直接换成并入项目的那份，把它的基础许可（沙箱外命令、额外可读目录）
// 带到保留的项目上；应当许可取交集（这里为空）、禁止取并集。
test('两台工作机没同步时各自登记同一远程，连上同步后两边都只剩先登记的项目，后登记那台的检出和工作区改挂过去，它禁用的 shell、执行禁止与项目密钥归到保留的项目，它的执行许可不带过去', async () => {
  const a = startKited();
  const b = startKited();
  kiteds.push(a, b);
  const url = remoteUrl('project');
  const first = await addProject(a, { remote: url });
  const second = await openWorkspace(b, (await addProject(b, { remote: url })).id);
  expect(second.project.id).not.toBe(first.id);
  expect(second.project.remote).toBe(first.remote);
  expect(b.daemon.kite.registry.get(second.project.id)!.createdAt).toBeGreaterThan(a.daemon.kite.registry.get(first.id)!.createdAt);
  const constraints = await b.call('GET', `/project-registry/${second.project.id}/constraints`);
  expect((await b.call('PUT', `/project-registry/${second.project.id}/constraints`, {
    tools: { mode: 'deny', tools: ['shell'] }, expectedRevision: constraints.body.revision,
    execution: {
      allow: { read: ['~/.aws'], write: [], network: [], unsandboxed: ['docker compose *'] },
      deny: { read: ['~/.ssh'], write: [], network: [], unsandboxed: ['sudo *'] },
    },
  })).status).toBe(200);
  const value = `project-secret-${crypto.randomUUID()}`;
  const secret = await b.call('POST', '/credentials', {
    type: 'secret', name: 'DEPLOY_TOKEN', projectId: second.project.id, meta: { kind: 'text' }, secret: { value },
  });
  expect(secret.status).toBe(201);

  await connect(a, b);
  for (const k of [a, b]) {
    await synced(k, () => k.daemon.kite.registry.canonical(second.project.id) === first.id
      && k.daemon.kite.accountData.get('credential', secret.body.id), '后登记的项目并入先登记的，B 的密钥同步到');
  }
  await Promise.all([a.daemon.kite.syncProjects(), b.daemon.kite.syncProjects()]);
  for (const k of [a, b]) {
    const kept = await k.call('GET', `/project-registry/${first.id}/constraints`);
    expect(kept.status).toBe(200);
    expect(kept.body.tools).toEqual({ mode: 'deny', tools: ['shell'] });
    expect(kept.body.execution).toMatchObject({
      allow: { read: [], write: [], network: [], unsandboxed: [] },
      deny: { read: ['~/.ssh'], write: [], network: [], unsandboxed: ['sudo *'] },
    });
    const listed = await k.call('GET', `/credentials?type=secret&projectId=${first.id}`);
    expect(listed.body).toEqual([expect.objectContaining({ id: secret.body.id, name: 'DEPLOY_TOKEN' })]);
    expect(await k.daemon.kite.credentials.resolve(['{project.DEPLOY_TOKEN}'], first.id))
      .toEqual([{ reference: '{project.DEPLOY_TOKEN}', kind: 'text', value }]);
  }

  for (const k of [a, b]) {
    expect(k.daemon.kite.registry.list().filter((project) => project.remote === first.remote).map((project) => project.id))
      .toEqual([first.id]);
  }
  expect(((await b.call('GET', '/projects')).body as Project[]).map((project) => project.id)).toEqual([first.id]);
  expect((await b.call('GET', '/checkouts')).body).toEqual([expect.objectContaining({ id: second.checkout.id, projectId: first.id })]);
  const workspaces = (await b.call('GET', '/workspaces')).body as WorkspaceModel[];
  expect(workspaces.map((model) => [model.workspace.id, model.project.id])).toEqual([[second.workspace.id, first.id]]);
}, 1000);

// 删除是账号级数据的一次写入（正文为空），随同步传到 B，B 的 syncProjects 认出「删过」才移除本机的工作区、工作树与 Kite 的检出。
// 账号级数据重建过的工作机从没收到过这条登记，分不出删过还是没收到；syncProjects 不能把它当成删了而移除检出（防误删）。
// 要同步链路、删除记录与各机本地移除合起来才看得出。
test('A 删除项目后 B 同步到删除、移除本机的工作区、工作树与检出；账号级数据重建过、从没收到过这条登记的工作机不移除', async () => {
  const a = startKited();
  const b = startKited();
  kiteds.push(a, b);
  await connect(a, b);
  const projectId = (await addProject(a, { remote: remoteUrl('project') })).id;
  await synced(b, () => b.daemon.kite.registry.get(projectId), 'B 同步到 A 登记的项目');
  const onB = await openWorkspace(b, projectId);
  expect(lexists(onB.checkout.path)).toBe(true);

  await a.daemon.kite.deleteProject(projectId);
  await synced(b, () => b.daemon.kite.registry.deleted(projectId), 'B 同步到 A 删除项目');
  await b.daemon.kite.syncProjects();
  expect(b.daemon.kite.store.projects()).toEqual([]);
  expect(b.daemon.kite.store.checkouts()).toEqual([]);
  expect(b.daemon.kite.store.workspaces()).toEqual([]);
  expect(lexists(onB.workspace.cwd)).toBe(false);
  expect(lexists(onB.checkout.path)).toBe(false);

  const before = startKited();
  kiteds.push(before);
  const kept = await addProject(before, { path: newDir(before.root, 'kept', { 'c.txt': 'C\n' }) });
  const keptCheckout = before.daemon.kite.store.checkouts(kept.id)[0]!;
  await before.halt();
  for (const name of ['account.db', 'account.db-wal', 'account.db-shm']) rmSync(join(before.home, name), { force: true });
  const c = startKited(undefined, false, { root: before.root });
  kiteds.splice(kiteds.indexOf(before), 1, c);
  expect(c.daemon.kite.registry.get(kept.id)).toBeUndefined();
  await c.daemon.kite.syncProjects();
  expect(c.daemon.kite.store.checkouts()).toEqual([expect.objectContaining({ id: keptCheckout.id, projectId: kept.id })]);
  expect(lexists(keptCheckout.path)).toBe(true);
}, 1000);

// ---- 资源库与项目约束 ----

function calledItem(id: string, name: string, args: Json): ModelItem {
  return { ...item(id, name), call: { id, name, arguments: args } };
}

function sharedRole(work: Role, text: string): Role {
  return { ...work, id: 'test.shared', title: '共享角色', context: { ...work.context, id: 'test.shared', title: '共享角色',
    blocks: [{ type: 'paragraph', id: 'rules', title: '规则', parts: [{ type: 'text', text }] }] } };
}

const roleOn = (k: Kited, id: string) => k.daemon.kite.roles.list().find((entry) => entry.role.id === id);
const templateOn = (k: Kited, id: string) => k.daemon.kite.contextTemplates.list().templates.find((entry) => entry.definition.id === id);
/** 等 k 对完缓存并通知客户端：收到 type 事件时缓存已满足 check。 */
const cached = (k: Kited, type: 'roles.changed' | 'context-templates.changed' | 'skills.changed', check: () => boolean) =>
  k.waitEvent((event) => event.type === type && check());

// 两台工作机经账号级数据交接资源库：A 写入后 B 从 A 拉到这一条再对缓存；B 按缓存算的版本须与 A 给出的一致，
// B 用同步前的版本改才会被拒。插件包在 B 的列表里只有元数据，开窗口时才从账号级数据取出安装，装好后的版本须与 A 一致。
test('A 建、改的角色同步到 B 后是同一版本，B 用同步前的版本改被拒；A 导入的插件 B 能列出，开窗口时才安装', async () => {
  const a = startKited();
  const b = startKited();
  kiteds.push(a, b);
  await connect(a, b);
  const work = roleOn(a, 'kite.work')!.role;

  const created = await a.call('POST', '/roles', { role: sharedRole(work, '第一版：先读需求。') });
  expect(created.status).toBe(200);
  await cached(b, 'roles.changed', () => roleOn(b, 'test.shared')?.revision === created.body.revision);
  expect(roleOn(b, 'test.shared')!.role).toEqual(created.body.role);

  const updated = await a.call('PUT', '/roles/test.shared', {
    expectedRevision: created.body.revision, role: sharedRole(work, '第二版：A 改过。'),
  });
  expect(updated.status).toBe(200);
  await cached(b, 'roles.changed', () => roleOn(b, 'test.shared')?.revision === updated.body.revision);
  expect(roleOn(b, 'test.shared')!.role).toEqual(updated.body.role);
  const stale = await b.call('PUT', '/roles/test.shared', {
    expectedRevision: created.body.revision, role: sharedRole(work, '第三版：B 基于过期版本改。'),
  });
  expect(stale.status).toBe(409);
  expect(roleOn(b, 'test.shared')!.revision).toBe(updated.body.revision);

  const pack = { id: 'custom.shared', title: '共享插件', lifetime: 'persistent', bundle: 'export const marker = "共享插件代码";',
    views: [{ id: 'main', title: '主视图', resourceUri: 'ui://shared/main.html' }] };
  const installed = await a.call('POST', '/plugin-definitions', pack);
  expect(installed.status).toBe(200);
  const listed = await until(async () => {
    const definitions = await b.call('GET', '/plugin-definitions');
    return definitions.body.some((definition: { id: string }) => definition.id === pack.id) && definitions;
  }, 'B 同步到 A 导入的插件', 900);
  expect(listed.body).toContainEqual(expect.objectContaining({ id: pack.id, revision: installed.body.revision }));
  expect(b.daemon.kite.catalog.installed(pack.id)).toBe(false);

  const workspace = await folderWorkspace(b, newDir(b.root, 'project', { 'base.txt': '原始\n' }));
  const opened = await b.call('POST', `/workspaces/${workspace.workspace.id}/windows`, {
    id: crypto.randomUUID(), content: { kind: 'create', definitionId: pack.id },
  });
  expect(opened.status).toBe(200);
  expect(b.daemon.kite.catalog.installed(pack.id)).toBe(true);
  expect(b.daemon.kite.catalog.package(pack.id).bundle).toBe(pack.bundle);
  expect(b.daemon.kite.catalog.get(pack.id).revision).toBe(installed.body.revision);
  const instance = (await b.call('GET', `/workspaces/${workspace.workspace.id}`)).body.instances
    .find((entry: { id: string }) => entry.id === opened.body.target.instanceId);
  expect(instance.config.packageRevision).toBe(installed.body.revision);
}, 1000);

// 恢复默认在账号级数据里是删除：删除带的 expectedRevision 是按本机缓存算的版本，须与账号级数据里的对上才删得掉；
// 模板把内容原样改回默认也是删除，不留一份等于默认的副本。删除同步到 B 后，B 对缓存时发现没有这一条，
// 要从缓存去掉、退回内置默认；B 再用删掉前的版本保存要被拒，不能当新建写进去。
test('A 恢复内置角色默认、把模板原样改回默认后账号级数据不留这两条，B 同步后退回默认，再用删掉前的版本保存被拒', async () => {
  const a = startKited();
  const b = startKited();
  kiteds.push(a, b);
  await connect(a, b);
  const role = roleOn(a, 'kite.review')!;
  expect(role.revision).toBe(role.defaultRevision!);
  const template = templateOn(a, emblemTemplate.id)!;
  expect(template.revision).toBe(template.defaultRevision);
  const edited: ContextDefinition = { ...template.definition, blocks: [...template.definition.blocks,
    { type: 'paragraph', id: 'test-extra', title: '补充规则', parts: [{ type: 'text', text: 'A 加的规则。' }] }] };

  const changedRole = await a.call('PUT', '/roles/kite.review', {
    expectedRevision: role.revision, role: { ...role.role, approval: 'ask' },
  });
  expect(changedRole.status).toBe(200);
  const changedTemplate = await a.call('PUT', `/context-templates/${emblemTemplate.id}`, {
    expectedRevision: template.revision, definition: edited, model: template.model,
  });
  expect(changedTemplate.status).toBe(200);
  await cached(b, 'roles.changed', () => roleOn(b, 'kite.review')?.revision === changedRole.body.revision);
  await cached(b, 'context-templates.changed', () => templateOn(b, emblemTemplate.id)?.revision === changedTemplate.body.revision);

  const reset = await a.call('POST', '/roles/kite.review/reset', { expectedRevision: changedRole.body.revision });
  expect(reset.status).toBe(200);
  expect(reset.body).toMatchObject({ role: role.role, revision: role.defaultRevision });
  const reverted = await a.call('PUT', `/context-templates/${emblemTemplate.id}`, {
    expectedRevision: changedTemplate.body.revision, definition: template.definition, model: template.model,
  });
  expect(reverted.status).toBe(200);
  expect(reverted.body).toMatchObject({ definition: template.definition, revision: template.defaultRevision });
  expect(a.daemon.kite.accountData.get('role', 'kite.review')).toBeUndefined();
  expect(a.daemon.kite.accountData.get('template', emblemTemplate.id)).toBeUndefined();

  await cached(b, 'roles.changed', () => roleOn(b, 'kite.review')?.revision === role.defaultRevision);
  expect(roleOn(b, 'kite.review')!.role).toEqual(role.role);
  await cached(b, 'context-templates.changed', () => templateOn(b, emblemTemplate.id)?.revision === template.defaultRevision);
  expect(templateOn(b, emblemTemplate.id)!.definition).toEqual(template.definition);

  const staleRole = await b.call('PUT', '/roles/kite.review', {
    expectedRevision: changedRole.body.revision, role: { ...role.role, approval: 'allowlist' },
  });
  expect(staleRole.status).toBe(409);
  const staleTemplate = await b.call('PUT', `/context-templates/${emblemTemplate.id}`, {
    expectedRevision: changedTemplate.body.revision, definition: edited, model: template.model,
  });
  expect(staleTemplate.status).toBe(409);
  expect(b.daemon.kite.accountData.get('role', 'kite.review')).toBeUndefined();
  expect(b.daemon.kite.accountData.get('template', emblemTemplate.id)).toBeUndefined();
}, 1000);

// 用户层的 skill 是多文件包，经账号级数据同步后每台工作机写进数据目录的 skills/<名字>/，清单从磁盘重新读。
// 四部分各自都对，合起来才看得出：版本向量合并（AccountData.apply）、同步后对缓存的 microtask 合批（LibrarySync.refresh）、
// 先写临时目录再 rename 的落盘（Skills.materialize）、collectSkills 从磁盘读清单。要实际跑两台才知道：同步到了但对缓存还没跑时
// 清单不能列出半个文件夹；落盘后 #! 开头的脚本带可执行位（依赖 fs.chmodSync 在 APFS 上的效果）、SKILL.md 不带；
// 含零字节与非法 UTF-8 的附件要经 HTTP JSON、账号同步和落盘保留原字节，更新后两边也要换成新内容，不能把 base64 当文本写。
// 恢复默认与删除都只是账号级数据里的一条删除，同步到另一台后那台要把文件夹删干净、不留临时目录，清单退回系统层。
test('A 新建和更新的多文件 skill 同步到 B 后二进制附件字节一致、脚本带可执行位、清单列为用户层；B 改随 kited 带的 skill 后 A 盖过系统层；A 恢复默认、B 删除后另一台的文件夹删干净、清单退回；随 kited 带的不能删', async () => {
  const a = startKited();
  const b = startKited();
  kiteds.push(a, b);
  await connect(a, b);
  const [onA, onB] = await Promise.all([
    folderWorkspace(a, newDir(a.root, 'project-a', { 'a.txt': 'A\n' })),
    folderWorkspace(b, newDir(b.root, 'project-b', { 'b.txt': 'B\n' })),
  ]);
  const skillDir = (k: Kited, name: string) => join(k.home, 'skills', name);
  const skillsOn = async (k: Kited) => (await k.call('GET', '/skills')).body.skills as SkillSnapshot[];
  const available = async (k: Kited, workspaceId: string) => {
    const r = await k.call('GET', `/workspaces/${workspaceId}/skills`);
    expect(r.status).toBe(200);
    return r.body.skills as Array<{ name: string; description: string; layer: string }>;
  };
  /** 整包的每个文件都原样落在 k 的数据目录里。 */
  const written = (k: Kited, skill: SkillPackage) => {
    for (const file of skill.files) {
      expect(readFileSync(join(skillDir(k, skill.name), file.path)))
        .toEqual(Buffer.from(file.content, file.encoding === 'base64' ? 'base64' : 'utf8'));
    }
  };
  const [onboardName] = SYSTEM_SKILLS;
  const resourcePath = 'assets/logo.bin';
  const resource = Buffer.from([0x00, 0xff, 0xfe, 0x89, 0x50, 0x00, 0x80]);
  const changedResource = Buffer.from([0x00, 0x81, 0xfe, 0x01, 0x02]);

  // 1. A 新建 demo-skill：SKILL.md、#! 开头的脚本和二进制附件
  const demo: SkillPackage = { version: 1, name: 'demo-skill', files: [
    { path: 'SKILL.md', content: '---\nname: demo-skill\ndescription: 演示\n---\n# 演示\n\n跑 scripts/run.sh。\n' },
    { path: 'scripts/run.sh', content: '#!/bin/sh\necho demo\n' },
    { path: resourcePath, content: resource.toString('base64'), encoding: 'base64' },
  ] };
  const created = await a.call('POST', '/skills', { skill: demo });
  expect(created.status).toBe(200);
  expect(created.body).toEqual({ skill: demo, revision: expect.any(String) });

  // 2. B 同步到：文件夹落地、脚本可执行、列表同一版本、工作区清单列为用户层，随 kited 带的仍是系统层
  await cached(b, 'skills.changed', () => existsSync(join(skillDir(b, demo.name), 'SKILL.md')));
  for (const k of [a, b]) {
    written(k, demo);
    expect(statSync(join(skillDir(k, demo.name), 'scripts/run.sh')).mode & 0o111).not.toBe(0);
    expect(statSync(join(skillDir(k, demo.name), 'SKILL.md')).mode & 0o111).toBe(0);
  }
  const listedB = await skillsOn(b);
  expect(listedB).toContainEqual(expect.objectContaining({ skill: demo, revision: created.body.revision }));
  const onboard = listedB.find((entry) => entry.skill.name === onboardName)!;
  expect(onboard.revision).toBe(onboard.defaultRevision!);
  expect(await available(b, onB.workspace.id)).toEqual(expect.arrayContaining([
    { name: demo.name, description: '演示', layer: 'user' },
    expect.objectContaining({ name: onboardName, layer: 'system' }),
  ]));

  // 3. 只更新二进制附件：账号版本与两边的落盘字节都要改变，文本文件仍保留
  const changedDemo: SkillPackage = { ...demo, files: demo.files.map((file) => file.path === resourcePath
    ? { ...file, content: changedResource.toString('base64') } : file) };
  const changed = await a.call('PUT', `/skills/${demo.name}`, { expectedRevision: created.body.revision, skill: changedDemo });
  expect(changed.status).toBe(200);
  expect(changed.body.revision).not.toBe(created.body.revision);
  await cached(b, 'skills.changed', () => readFileSync(join(skillDir(b, demo.name), resourcePath)).equals(changedResource));
  for (const k of [a, b]) {
    written(k, changedDemo);
    expect(await skillsOn(k)).toContainEqual({ skill: changedDemo, revision: changed.body.revision });
  }

  // 4. B 改随 kited 带的 kite-onboard 正文并加附件；A 同步到后整包落地、清单里它的层变成用户层、版本不再是默认
  const edited: SkillPackage = { ...onboard.skill, files: [
    ...onboard.skill.files.map((file) => file.path === 'SKILL.md'
      ? { ...file, content: `${file.content}\n## B 加的规则\n\n改过的正文。\n` } : file),
    { path: resourcePath, content: resource.toString('base64'), encoding: 'base64' },
  ] };
  expect(edited.files.length).toBeGreaterThan(1);
  const updated = await b.call('PUT', `/skills/${onboardName}`, { expectedRevision: onboard.revision, skill: edited });
  expect(updated.status).toBe(200);
  expect(updated.body).toEqual({ skill: edited, revision: expect.any(String), defaultRevision: onboard.defaultRevision });
  expect(updated.body.revision).not.toBe(onboard.defaultRevision);
  await cached(a, 'skills.changed', () => existsSync(join(skillDir(a, onboardName), 'SKILL.md')));
  written(a, edited);
  expect(await skillsOn(a)).toContainEqual({ skill: edited, revision: updated.body.revision, defaultRevision: onboard.defaultRevision });
  expect(await available(a, onA.workspace.id)).toContainEqual(expect.objectContaining({ name: onboardName, layer: 'user' }));

  // 5. A 恢复默认：账号里那条删掉，两边的文件夹和附件都删掉，B 的清单退回系统层
  const reset = await a.call('POST', `/skills/${onboardName}/reset`, { expectedRevision: updated.body.revision });
  expect(reset.status).toBe(200);
  expect(reset.body).toEqual({ skill: onboard.skill, revision: onboard.defaultRevision, defaultRevision: onboard.defaultRevision });
  expect(a.daemon.kite.accountData.get('skill', onboardName)).toBeUndefined();
  await until(() => !existsSync(skillDir(a, onboardName)), 'A 恢复默认后本机文件夹删掉', 900);
  await cached(b, 'skills.changed', () => !existsSync(skillDir(b, onboardName)));
  expect(b.daemon.kite.accountData.get('skill', onboardName)).toBeUndefined();
  expect(await skillsOn(b)).toContainEqual(expect.objectContaining({ skill: onboard.skill, revision: onboard.defaultRevision }));
  expect(await available(b, onB.workspace.id)).toContainEqual(expect.objectContaining({ name: onboardName, layer: 'system' }));

  // 6. B 删除 demo-skill：A 同步到后文件夹与附件删干净（也不留落盘用的临时目录）、列表不再列它
  const removed = await b.call('DELETE', `/skills/${demo.name}?expectedRevision=${changed.body.revision}`);
  expect(removed.status).toBe(200);
  await cached(a, 'skills.changed', () => !existsSync(skillDir(a, demo.name)));
  await until(() => !existsSync(skillDir(b, demo.name)), 'B 删除后本机文件夹删掉', 900);
  for (const k of [a, b]) {
    expect((await skillsOn(k)).map((entry) => entry.skill.name)).toEqual([onboardName]);
    expect(existsSync(join(k.home, 'skills')) ? readdirSync(join(k.home, 'skills')) : []).toEqual([]);
    expect(k.daemon.kite.accountData.get('skill', demo.name)).toBeUndefined();
  }

  // 7. 随 kited 带的只能恢复默认，不能删
  const forbidden = await a.call('DELETE', `/skills/${onboardName}?expectedRevision=${onboard.defaultRevision}`);
  expect(forbidden.status).toBe(400);
  expect((await skillsOn(a)).map((entry) => entry.skill.name)).toEqual([onboardName]);
}, 1000);

// 真实 bug：首次同步时本机还没有此项目，之后登记已有项目不会再收到约束变更，因而留下无限制缓存。
// 约束随账号级数据同步：B 先同步到 A 登记的项目和收紧的约束，之后才在 B 上建工作区（clone 出检出、项目进本机库），开的代理就要受约束。
test('B 先同步到别的工作机已收紧约束的项目、再为它建工作区时，开的代理已禁用 shell', async () => {
  const a = startKited();
  const b = startKited();
  kiteds.push(a, b);
  await connect(a, b);
  const projectId = (await addProject(a, { remote: remoteUrl('library') })).id;
  const current = await a.call('GET', `/project-registry/${projectId}/constraints`);
  expect(current.status).toBe(200);
  const saved = await a.call('PUT', `/project-registry/${projectId}/constraints`, {
    tools: { mode: 'deny', tools: ['shell'] }, expectedRevision: current.body.revision,
  });
  expect(saved.status).toBe(200);
  await synced(b, () => b.daemon.kite.registry.get(projectId) && b.daemon.kite.registry.constraints(projectId).revision === saved.body.revision,
    'B 同步到项目与收紧的约束');

  const other = await openWorkspace(b, projectId);
  expect(other.project.id).toBe(projectId);
  expect(b.daemon.kite.store.projectConstraints(projectId)?.tools).toEqual({ mode: 'deny', tools: ['shell'] });
  const id = await openAgent(b.call, other.workspace.id);
  expect((await b.call('GET', `/instances/${id}/agent-capabilities`)).body.blocked).toContain('shell');
}, 1000);

// 项目约束是实时过滤：改了约束后对缓存，正在跑的回合里已经发出的 shell 调用在执行前被拦下，
// 下一次请求不再放行 shell；只有有效工具真的变了的代理收到一条配置通知；放宽后实例配置里留着的 shell 恢复。
// 账号级数据、SQLite 缓存、配置通知与 harness 请求边界的执行检查要合起来才看得出。
test('项目约束禁用 shell 后在跑的回合里已发出的 shell 调用不执行，下一请求不再放行，只通知受影响的代理一次，放宽后恢复', async () => {
  const model = new ManualModel();
  const k = startKited(() => model);
  kiteds.push(k);
  const workspace = await folderWorkspace(k, newDir(k.root, 'project', { 'base.txt': '原始\n' }));
  const projectId = workspace.project.id;
  const workspaceId = workspace.workspace.id;
  const constrain = async (tools: string[]) => {
    const current = await k.call('GET', `/project-registry/${projectId}/constraints`);
    const saved = await k.call('PUT', `/project-registry/${projectId}/constraints`, {
      tools: { mode: 'deny', tools }, expectedRevision: current.body.revision,
    });
    expect(saved.status).toBe(200);
  };
  const id = await openAgent(k.call, workspaceId);
  const readerId = await openAgent(k.call, workspaceId);
  const readerConfig = await k.call('GET', `/instances/${readerId}/agent-config`);
  expect((await k.call('PUT', `/instances/${readerId}/agent-config`, {
    expectedRevision: readerConfig.body.revision, agent: { ...readerConfig.body.instance.config.agent, tools: ['read'] },
  })).status).toBe(200);
  const notices = (instanceId: string) => k.daemon.kite.store.instanceNotifications(instanceId, 0)
    .filter((notification) => notification.kind === 'agent.configuration.changed');
  const readerNotices = notices(readerId).length;
  const tools = (await k.call('GET', `/instances/${id}/agent-config`)).body.instance.config.agent.tools as string[];
  expect(tools).toContain('shell');

  expect((await k.call('POST', `/threads/${id}/messages`, { id: 'run', text: '跑一个命令' })).status).toBe(200);
  const first = await model.call(1);
  expect(first.request.allowedTools).toContain('shell');
  await constrain(['shell']);
  await until(() => notices(id).length > 0, '收紧约束后受影响的代理收到配置通知', 900);
  expect((await k.call('GET', `/instances/${id}/agent-capabilities`)).body).toMatchObject({ defaults: tools, blocked: ['shell'] });
  expect(notices(id)).toHaveLength(1);
  expect(notices(readerId)).toHaveLength(readerNotices);

  await first.response.emit({ type: 'item', item: calledItem('blocked-shell', 'shell', {
    description: '约束收紧后不应执行', command: 'printf ran > blocked-shell.txt',
  }) });
  first.response.complete();
  const second = await model.call(2);
  const result = second.request.history.find((entry) => entry.type === 'tool_result' && entry.callId === 'blocked-shell');
  if (result?.type !== 'tool_result') throw new Error('被拦下的 shell 调用没有结果');
  expect(result.result.status).toBe('not_executed');
  expect(existsSync(join(workspace.workspace.cwd, 'blocked-shell.txt'))).toBe(false);
  expect(second.request.allowedTools).not.toContain('shell');
  expect(second.request.allowedTools).toEqual([...tools.filter((name) => name !== 'shell'), TOOL_SEARCH]);
  const delivered = second.request.history.filter((entry) => entry.type === 'notification'
    && entry.notification.kind === 'agent.configuration.changed');
  expect(delivered).toHaveLength(1);
  expect(delivered[0]!.type === 'notification' && delivered[0]!.text).toContain(tools.filter((name) => name !== 'shell').join('、'));
  second.response.complete();
  await k.waitEvent((event) => event.type === 'idle' && event.threadId === id);

  await constrain([]);
  await until(() => notices(id).length > 1, '放宽约束后受影响的代理收到配置通知', 900);
  expect(notices(id)).toHaveLength(2);
  expect((await k.call('GET', `/instances/${id}/agent-config`)).body.instance.config.agent.tools).toEqual(tools);
  const since = mark(k);
  expect((await k.call('POST', `/threads/${id}/messages`, { id: 'again', text: '再跑一次' })).status).toBe(200);
  const third = await model.call(3);
  expect(third.request.allowedTools).toEqual([...tools, TOOL_SEARCH]);
  third.response.complete();
  await k.waitEvent((event) => event.type === 'idle' && event.threadId === id && after(k, since)(event));
}, 1000);

// 真实出过的 bug：内置角色和模板曾预先写进本机库。kited 升级后默认的点阵签名规则变了，本机那份
// kite.template-emblem.generate 旧副本（用户从没改过）和新默认对不上，第一次同步时被当成用户修改写进账号，
// 之后各工作机都拿到这份旧规则，新默认再也生效不了；预先写进去的内置角色也被整份写进去。
// 升级到本机账号级数据时同样的副本还在缓存里：第一次对缓存不能把它们写进账号级数据，要从缓存去掉。
// 要 daemon 启动、SQLite 缓存与第一次对缓存合起来才看得出。
test('本机缓存留着旧版内置模板和内置角色副本时，第一次对缓存不把它们写进账号级数据，签名模板回到当前默认', async () => {
  const root = makeTemp('library-stale-');
  const home = join(root, 'kite');
  let daemon: Daemon | undefined;
  try {
    // 先起一次建好本机库，停下后放进升级前的 kited 留下的副本，并去掉账号级数据，相当于第一次有它。
    daemon = startDaemon({ home, port: 0, lightTasks: false });
    const builtins = ((await call(daemon.url, 'GET', '/roles')).body.roles as Array<{ role: Role }>)
      .map((entry) => entry.role).filter((role) => role.id === 'kite.work' || role.id === 'kite.review');
    expect(builtins).toHaveLength(2);
    await daemon.stop();
    daemon = undefined;
    for (const suffix of ['', '-wal', '-shm']) rmSync(join(home, `account.db${suffix}`), { force: true });
    const stale: ContextDefinition = { ...emblemTemplate, blocks: [{ type: 'paragraph', id: 'instructions', title: '设计规则',
      parts: [{ type: 'text', text: '旧版设计规则：签名是一行算式，结果在 0 到 1 之间。' }] }] };
    const db = new Database(join(home, 'kite.db'));
    try {
      db.query('insert into context_templates values (?, ?)').run(stale.id, JSON.stringify({ definition: stale }));
      for (const role of builtins) db.query('insert or replace into roles values (?, ?)').run(role.id, JSON.stringify(role));
    } finally {
      db.close();
    }

    daemon = startDaemon({ home, port: 0, lightTasks: false });
    const kite = daemon.kite;
    const written = () => [...kite.accountData.list('role'), ...kite.accountData.list('template')];
    const emblem = () => kite.contextTemplates.list().templates.find((template) => template.definition.id === emblemTemplate.id)?.definition;
    // 对完缓存时签名模板回到默认；出错时则是账号级数据里多出条目，两种情况都不再等。
    await until(() => Bun.deepEquals(emblem(), emblemTemplate) || written().length > 0, '启动后第一次对缓存', 900);
    expect(written()).toEqual([]);
    const templates = (await call(daemon.url, 'GET', '/context-templates')).body.templates as Array<{ definition: ContextDefinition }>;
    expect(templates.find((template) => template.definition.id === emblemTemplate.id)?.definition).toEqual(emblemTemplate);
  } finally {
    await daemon?.stop();
    rmSync(root, { recursive: true, force: true });
  }
}, 1000);
