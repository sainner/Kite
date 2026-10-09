import { afterEach, expect, test } from 'bun:test';
import { Database } from 'bun:sqlite';
import { existsSync, rmSync } from 'node:fs';
import { join } from 'node:path';
import { startDaemon, type Daemon } from '../../src/daemon.ts';
import type { Envelope } from '../../src/events.ts';
import type { ContextDefinition } from '../../src/harness/context/types.ts';
import type { Json, ModelItem } from '../../src/harness/types.ts';
import type { Role } from '../../src/roles.ts';
import { emblemTemplate } from '../../src/template-emblems.ts';
import { startFakeAccount, type FakeAccount } from '../fake-account.ts';
import { after, call, linkNewAccount, mark, openAgent, registerCheckout, startKited, type Kited } from '../harness.ts';
import { item, ManualModel, Seen } from '../harness-loop.ts';
import { makeTemp, newRepo, until } from '../util.ts';

let kiteds: Kited[] = [];
let shared: { account: FakeAccount; root: string } | undefined;
afterEach(async () => {
  for (const k of kiteds.splice(0)) await k.stop();
  if (shared) {
    shared.account.stop();
    rmSync(shared.root, { recursive: true, force: true });
    shared = undefined;
  }
});

function calledItem(id: string, name: string, args: Json): ModelItem {
  return { ...item(id, name), call: { id, name, arguments: args } };
}

function sharedRole(work: Role, text: string): Role {
  return { ...work, id: 'test.shared', title: '共享角色', context: { ...work.context, id: 'test.shared', title: '共享角色',
    blocks: [{ type: 'paragraph', id: 'rules', title: '规则', parts: [{ type: 'text', text }] }] } };
}

// 两台工作机经同一账号资源库交接：A 写入后账号服务经事件流推给 B，B 全量同步；账号按写入内容算版本，
// 工作机按本机缓存算版本，两边必须一致，乐观锁才对得上；版本冲突被拒后要追上账号；插件包在列表里只有元数据，
// 开窗口时才单独下载安装，装好后的版本须与另一台一致。
test('A 改的角色经推送同步到 B 后是同一版本，B 用过期版本改被拒后自动追上；A 导入的插件 B 能列出，开窗口时才下载安装', async () => {
  const root = makeTemp('library-sync-');
  shared = { account: startFakeAccount(join(root, 'account')), root };
  const a = startKited(undefined, false, shared.account);
  const b = startKited(undefined, false, shared.account);
  kiteds.push(a, b);
  const roleEntry = async (k: Kited) => {
    const catalog = await k.call('GET', '/roles');
    expect(catalog.status).toBe(200);
    return { work: catalog.body.roles.find((entry: { role: Role }) => entry.role.id === 'kite.work').role as Role,
      shared: catalog.body.roles.find((entry: { role: Role }) => entry.role.id === 'test.shared') as { role: Role; revision: string } | undefined };
  };

  const { work } = await roleEntry(a);
  const pushed = mark(b);
  const created = await a.call('POST', '/roles', { role: sharedRole(work, '第一版：先读需求。') });
  expect(created.status).toBe(200);
  await b.waitEvent((event) => event.type === 'roles.changed' && after(b, pushed)(event));
  expect((await roleEntry(b)).shared).toMatchObject({ revision: created.body.revision, role: created.body.role });

  // A 的修改也会推给 B，与 B 的过期写入谁先到不定；两条路都要让 B 追上，所以从 A 修改前开始等。
  const since = mark(b);
  const updated = await a.call('PUT', '/roles/test.shared', {
    expectedRevision: created.body.revision, role: sharedRole(work, '第二版：A 改过。'),
  });
  expect(updated.status).toBe(200);
  const stale = await b.call('PUT', '/roles/test.shared', {
    expectedRevision: created.body.revision, role: sharedRole(work, '第三版：B 基于过期版本改。'),
  });
  expect(stale.status).toBe(409);
  await b.waitEvent((event) => event.type === 'roles.changed' && after(b, since)(event));
  expect((await roleEntry(b)).shared).toMatchObject({ revision: updated.body.revision, role: updated.body.role });
  expect(shared.account.library.get('fake-user', 'role', 'test.shared')?.revision).toBe(updated.body.revision);

  const pack = { id: 'custom.shared', title: '共享插件', lifetime: 'persistent', bundle: 'export const marker = "共享插件代码";',
    views: [{ id: 'main', title: '主视图', resourceUri: 'ui://shared/main.html' }] };
  const installed = await a.call('POST', '/plugin-definitions', pack);
  expect(installed.status).toBe(200);
  const listed = await until(async () => {
    const definitions = await b.call('GET', '/plugin-definitions');
    return definitions.body.some((definition: { id: string }) => definition.id === pack.id) && definitions;
  }, 'B 经推送同步到 A 导入的插件');
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

// 项目约束是实时过滤：账号里改了约束、账号服务推送后工作机同步，正在跑的回合里已经发出的 shell 调用在执行前被拦下，
// 下一次请求不再放行 shell；只有有效工具真的变了的代理收到一条配置通知；放宽后实例配置里留着的 shell 恢复。
// 账号拉取、SQLite 缓存、配置通知与 harness 请求边界的执行检查要合起来才看得出。
test('项目约束禁用 shell 后在跑的回合里已发出的 shell 调用不执行，下一请求不再放行，只通知受影响的代理一次，放宽后恢复', async () => {
  const model = new ManualModel();
  const k = startKited(() => model);
  kiteds.push(k);
  const workspace = await registerCheckout(k, newRepo(k.root, 'project', { 'base.txt': '原始\n' }));
  const projectId = workspace.project.id;
  const workspaceId = workspace.workspace.id;
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
  k.account.constraints.set(projectId, { tools: { mode: 'deny', tools: ['shell'] } });
  await until(() => notices(id).length > 0, '收紧约束推送后受影响的代理收到配置通知');
  expect((await k.call('GET', `/instances/${id}/agent-capabilities`)).body).toMatchObject({ tools, blocked: ['shell'] });
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

  k.account.constraints.set(projectId, { tools: { mode: 'deny', tools: [] } });
  await until(() => notices(id).length > 1, '放宽约束推送后受影响的代理收到配置通知');
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
// kite.template-emblem.generate 旧副本（用户从没改过）和新默认对不上，加入账号后第一次同步被当成用户修改上传，
// 之后各工作机都拉到这份旧规则，新默认再也生效不了；预先写进去的内置角色也被整份上传。
// 要 daemon 启动、SQLite 缓存、事件流连上后的首次同步与账号服务合起来才看得出。
test('本机留着旧版内置模板和内置角色副本时加入空账号，首次同步不上传角色与模板，签名模板回到当前默认', async () => {
  const root = makeTemp('library-stale-');
  const home = join(root, 'kite');
  let daemon: Daemon | undefined;
  let account: FakeAccount | undefined;
  try {
    // 先在没加入账号时起一次建好本机库，停下后放进升级前的 kited 留下的副本。
    daemon = startDaemon({ home, port: 0, lightTasks: false });
    const builtins = ((await call(daemon.url, 'GET', '/roles')).body.roles as Array<{ role: Role }>)
      .map((entry) => entry.role).filter((role) => role.id === 'kite.work' || role.id === 'kite.review');
    expect(builtins).toHaveLength(2);
    await daemon.stop();
    daemon = undefined;
    const stale: ContextDefinition = { ...emblemTemplate, blocks: [{ type: 'paragraph', id: 'instructions', title: '设计规则',
      parts: [{ type: 'text', text: '旧版设计规则：签名是一行算式，结果在 0 到 1 之间。' }] }] };
    const db = new Database(join(home, 'kite.db'));
    try {
      db.query('insert into context_templates values (?, ?)').run(stale.id, JSON.stringify(stale));
      for (const role of builtins) db.query('insert or replace into roles values (?, ?)').run(role.id, JSON.stringify(role));
    } finally {
      db.close();
    }

    account = linkNewAccount(home);
    daemon = startDaemon({ home, port: 0, lightTasks: false });
    const events = new Seen<Envelope>();
    daemon.kite.bus.subscribe(undefined, (event) => events.add(event));
    const uploaded = () => account!.library.list('fake-user').filter((entry) => entry.kind === 'role' || entry.kind === 'template');
    // 首次同步去掉账号里没有的旧副本后通知客户端刷新模板；出错时则是账号里多出条目，两种情况都不再等。
    await until(() => events.values.some((event) => event.type === 'context-templates.changed') || uploaded().length > 0,
      '加入账号后的首次同步');
    expect(uploaded()).toEqual([]);
    const templates = (await call(daemon.url, 'GET', '/context-templates')).body.templates as Array<{ definition: ContextDefinition }>;
    expect(templates.find((template) => template.definition.id === emblemTemplate.id)?.definition).toEqual(emblemTemplate);
  } finally {
    await daemon?.stop();
    account?.stop();
    rmSync(root, { recursive: true, force: true });
  }
}, 1000);
