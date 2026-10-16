/**
 * 账号级数据经工作机之间的同步链路（src/account-data/directory.ts、replication.ts）：两台本进程 kited 各有自己的数据目录
 * 和凭据密钥文件，用 harness 的 connect 互为组网对端，读 /machine 发现、长轮询拉增量都直接访问对方的监听地址。
 * 后一段是经同一链路交接的资源库与项目约束（src/library-sync.ts）：写入先进本机的账号级数据，再对缓存；别的工作机经同步
 * 拿到同一条，对完缓存后两边按同一内容算出同一版本，乐观锁才对得上。
 */
import { afterEach, expect, test } from 'bun:test';
import { Database } from 'bun:sqlite';
import { existsSync, readFileSync, rmSync } from 'node:fs';
import { join } from 'node:path';
import { startDaemon, type Daemon } from '../../src/daemon.ts';
import type { ContextDefinition } from '../../src/harness/context/types.ts';
import type { Json, ModelItem } from '../../src/harness/types.ts';
import type { Project, WorkspaceModel } from '../../src/model.ts';
import type { Role } from '../../src/roles.ts';
import { emblemTemplate } from '../../src/template-emblems.ts';
import { after, call, connect, type Kited, mark, openAgent, registerCheckout, startKited, synced } from '../harness.ts';
import { item, ManualModel } from '../harness-loop.ts';
import { git, makeTemp, newRepo, read, until } from '../util.ts';

const kiteds: Kited[] = [];
afterEach(async () => {
  for (const k of kiteds.splice(0)) await k.stop();
});

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

// 两台工作机没同步上时各自登记了同一远程（HTTPS 与 SSH 写法），各得一个项目；连上后登记表随同步合并，
// 先登记的保留、后登记的记为并入它，各机 syncProjects 时把本机检出与工作区改挂过去。
// 后登记的那个设了工具约束和执行约束、有一条项目专用的密钥，合并后都要归到保留的项目；约束取两份里更严的组合。
// 要登记表、同步、两边各自合并与本机 SQLite 改挂合起来才看得出。
// 真实 bug（旧实现）：合并只改挂检出，保留的项目读到默认的不限制约束，密钥还绑在并入的旧 ID 上，按保留的项目列不出、取不到。
// 真实 bug（后来的实现）：保留的项目没设执行约束时，合并直接换成并入项目的那份，把它的基础许可（沙箱外命令、额外可读目录）
// 带到保留的项目上；应当许可取交集（这里为空）、禁止取并集。
test('两台工作机没同步时各自登记同一远程，连上同步后两边都只剩先登记的项目，后登记那台的检出和工作区改挂过去，它禁用的 shell、执行禁止与项目密钥归到保留的项目，它的执行许可不带过去', async () => {
  const a = startKited();
  const b = startKited();
  kiteds.push(a, b);
  const path = `owner/${crypto.randomUUID()}`;
  const first = await registerCheckout(a, newRepo(a.root, 'project', { 'a.txt': 'A\n' }, `https://example.test/${path}.git`));
  const second = await registerCheckout(b, newRepo(b.root, 'project', { 'b.txt': 'B\n' }, `git@example.test:${path}.git`));
  expect(second.project.id).not.toBe(first.project.id);
  expect(second.project.remote).toBe(first.project.remote);
  expect(b.daemon.kite.registry.get(second.project.id)!.createdAt).toBeGreaterThan(a.daemon.kite.registry.get(first.project.id)!.createdAt);
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
    await synced(k, () => k.daemon.kite.registry.canonical(second.project.id) === first.project.id
      && k.daemon.kite.accountData.get('credential', secret.body.id), '后登记的项目并入先登记的，B 的密钥同步到');
  }
  await Promise.all([a.daemon.kite.syncProjects(), b.daemon.kite.syncProjects()]);
  for (const k of [a, b]) {
    const kept = await k.call('GET', `/project-registry/${first.project.id}/constraints`);
    expect(kept.status).toBe(200);
    expect(kept.body.tools).toEqual({ mode: 'deny', tools: ['shell'] });
    expect(kept.body.execution).toMatchObject({
      allow: { read: [], write: [], network: [], unsandboxed: [] },
      deny: { read: ['~/.ssh'], write: [], network: [], unsandboxed: ['sudo *'] },
    });
    const listed = await k.call('GET', `/credentials?type=secret&projectId=${first.project.id}`);
    expect(listed.body).toEqual([expect.objectContaining({ id: secret.body.id, name: 'DEPLOY_TOKEN' })]);
    expect(await k.daemon.kite.credentials.resolve(['{project.DEPLOY_TOKEN}'], first.project.id))
      .toEqual([{ reference: '{project.DEPLOY_TOKEN}', kind: 'text', value }]);
  }

  for (const k of [a, b]) {
    expect(k.daemon.kite.registry.list().filter((project) => project.remote === first.project.remote).map((project) => project.id))
      .toEqual([first.project.id]);
  }
  expect(((await b.call('GET', '/projects')).body as Project[]).map((project) => project.id)).toEqual([first.project.id]);
  expect((await b.call('GET', '/checkouts')).body).toEqual([expect.objectContaining({ id: second.checkout.id, projectId: first.project.id })]);
  const workspaces = (await b.call('GET', '/workspaces')).body as WorkspaceModel[];
  expect(workspaces.map((model) => [model.workspace.id, model.project.id])).toEqual([[second.workspace.id, first.project.id]]);
  expect(((await a.call('GET', '/projects')).body as Project[]).map((project) => project.id)).toEqual([first.project.id]);
  expect((await a.call('GET', '/checkouts')).body).toEqual([expect.objectContaining({ id: first.checkout.id, projectId: first.project.id })]);
}, 1000);

// 删除是账号级数据的一次写入（正文为空），随同步传到 B，B 的 syncProjects 认出「删过」才移除本机的检出，目录留在磁盘上。
// 账号级数据重建过的工作机从没收到过这条登记，分不出删过还是没收到；syncProjects 不能把它当成删了而移除检出（防误删）。
// 要同步链路、删除记录与各机本地移除合起来才看得出。
test('A 删除项目后 B 同步到删除、移除本机检出而目录还在；账号级数据重建过、从没收到过这条登记的工作机不移除', async () => {
  const a = startKited();
  const b = startKited();
  kiteds.push(a, b);
  await connect(a, b);
  const origin = `https://example.test/owner/${crypto.randomUUID()}.git`;
  const first = await registerCheckout(a, newRepo(a.root, 'project', { 'a.txt': 'A\n' }, origin));
  const projectId = first.project.id;
  await synced(b, () => b.daemon.kite.registry.get(projectId), 'B 同步到 A 登记的项目');
  const repoB = newRepo(b.root, 'project', { 'b.txt': 'B\n' }, origin);
  expect((await registerCheckout(b, repoB)).project.id).toBe(projectId);
  const headB = git(repoB, 'rev-parse', 'HEAD');

  await a.daemon.kite.deleteProject(projectId);
  await synced(b, () => b.daemon.kite.registry.deleted(projectId), 'B 同步到 A 删除项目');
  await b.daemon.kite.syncProjects();
  expect(b.daemon.kite.store.projects()).toEqual([]);
  expect(b.daemon.kite.store.checkouts()).toEqual([]);
  expect(b.daemon.kite.store.workspaces()).toEqual([]);
  expect(read(join(repoB, 'b.txt'))).toBe('B\n');
  expect(git(repoB, 'rev-parse', 'HEAD')).toBe(headB);

  const before = startKited();
  kiteds.push(before);
  const kept = await registerCheckout(before, newRepo(before.root, 'kept', { 'c.txt': 'C\n' }));
  await before.halt();
  for (const name of ['account.db', 'account.db-wal', 'account.db-shm']) rmSync(join(before.home, name), { force: true });
  const c = startKited(undefined, false, { root: before.root });
  kiteds.splice(kiteds.indexOf(before), 1, c);
  expect(c.daemon.kite.registry.get(kept.project.id)).toBeUndefined();
  await c.daemon.kite.syncProjects();
  expect(c.daemon.kite.store.checkouts()).toEqual([expect.objectContaining({ id: kept.checkout.id, projectId: kept.project.id })]);
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
const cached = (k: Kited, type: 'roles.changed' | 'context-templates.changed', check: () => boolean) =>
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

  const workspace = await registerCheckout(b, newRepo(b.root, 'project', { 'base.txt': '原始\n' }));
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
    expectedRevision: role.revision, role: { ...role.role, maxRequestsPerTurn: role.role.maxRequestsPerTurn + 1 },
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
    expectedRevision: changedRole.body.revision, role: { ...role.role, maxRequestsPerTurn: role.role.maxRequestsPerTurn + 2 },
  });
  expect(staleRole.status).toBe(409);
  const staleTemplate = await b.call('PUT', `/context-templates/${emblemTemplate.id}`, {
    expectedRevision: changedTemplate.body.revision, definition: edited, model: template.model,
  });
  expect(staleTemplate.status).toBe(409);
  expect(b.daemon.kite.accountData.get('role', 'kite.review')).toBeUndefined();
  expect(b.daemon.kite.accountData.get('template', emblemTemplate.id)).toBeUndefined();
}, 1000);

// 真实 bug：首次同步时本机还没有此项目，之后登记已有项目不会再收到约束变更，因而留下无限制缓存。
// 约束随账号级数据同步：B 先同步到 A 登记的项目和收紧的约束，之后才登记同一远程的检出，登记完开的代理就要受约束。
test('B 先同步到别的工作机已收紧约束的项目、再登记它的检出时，开的代理已禁用 shell', async () => {
  const a = startKited();
  const b = startKited();
  kiteds.push(a, b);
  await connect(a, b);
  const url = `https://example.test/library/${crypto.randomUUID()}.git`;
  const registered = await registerCheckout(a, newRepo(a.root, 'project', { 'base.txt': 'A\n' }, url));
  const projectId = registered.project.id;
  const current = await a.call('GET', `/project-registry/${projectId}/constraints`);
  expect(current.status).toBe(200);
  const saved = await a.call('PUT', `/project-registry/${projectId}/constraints`, {
    tools: { mode: 'deny', tools: ['shell'] }, expectedRevision: current.body.revision,
  });
  expect(saved.status).toBe(200);
  await synced(b, () => b.daemon.kite.registry.get(projectId) && b.daemon.kite.registry.constraints(projectId).revision === saved.body.revision,
    'B 同步到项目与收紧的约束');

  const other = await registerCheckout(b, newRepo(b.root, 'project', { 'base.txt': 'B\n' }, url));
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
  const workspace = await registerCheckout(k, newRepo(k.root, 'project', { 'base.txt': '原始\n' }));
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
  expect(second.request.allowedTools).toEqual(tools.filter((name) => name !== 'shell'));
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
  expect(third.request.allowedTools).toEqual(tools);
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
