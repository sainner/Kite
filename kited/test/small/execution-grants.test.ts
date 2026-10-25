/**
 * 实例执行授权（docs/实例操作.md「实例执行授权」）：经 HTTP 改授权、通知快照与缓存实例的交接，
 * 以及三层合成（docs/Agent与插件契约.md §3.2）与沙箱外命令（docs/工具审批与提问.md「审批」）。
 * 三层合成一段里，前两个测试直接调合成与沙箱策略，路径落在临时目录里；第三个直接调 localTools 的 shell，宿主的沙箱外判断换成测试替身，
 * 命令在真实的 macOS Seatbelt 沙箱里跑；最后一个在本进程起 kited，模型换成 ManualModel。
 */
import { afterEach, expect, test } from 'bun:test';
import { randomUUID } from 'node:crypto';
import { existsSync, mkdirSync, readFileSync, realpathSync, rmSync, symlinkSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
// 沙箱宿主按路径起子进程，不在 import 链上；按文本引入，宿主改动时 .kite/check 才会选中这里。
import '../../src/execution/sandbox-callback-host.ts' with { type: 'text' };
import {
  applyExecutionGrants, effectiveExecution, normalizeExecutionChanges, parseProjectExecution, unsandboxedVerdict,
  type ExecutionChanges, type ExecutionGrants, type ExecutionScope,
} from '../../src/execution/grants.ts';
import { runCommand } from '../../src/execution/command.ts';
import { localTools, type ShellBackground, type ShellOutside } from '../../src/execution/local-tools.ts';
import { harnessPolicy } from '../../src/execution/policy.ts';
import type { Envelope } from '../../src/events.ts';
import type { Json, ModelItem, ModelRequest, ToolResult } from '../../src/harness/types.ts';
import type { Waiting } from '../../src/waiting.ts';
import { after, folderWorkspace, mark, startKited, waitIdle, type Kited } from '../harness.ts';
import { diskRecords, item, ManualModel } from '../harness-loop.ts';
import { editNotificationTemplate } from '../notification-templates.ts';
import { ENV, newDir, until, useTemp } from '../util.ts';

let kited: Kited | undefined;
afterEach(async () => { await kited?.stop(); kited = undefined; });

const grantsPath = (id: string) => `/instances/${id}/execution-grants`;
const scope = (values: Partial<ExecutionScope> = {}): ExecutionScope => ({ read: [], write: [], network: [], unsandboxed: [], ...values });
/** 实例在项目基础上的增减（PUT 的 grants）；没有项目许可时生效的就是它加上的。 */
const changes = (workspace: 'read' | 'write', add: Partial<ExecutionScope> = {}): ExecutionChanges => ({ workspace, add: scope(add), remove: scope() });
const effective = (workspace: 'read' | 'write', add: Partial<ExecutionScope> = {}): ExecutionGrants => ({ workspace, ...scope(add) });

async function codingInstance(k: Kited) {
  const registered = await folderWorkspace(k, newDir(k.root, 'project', { 'base.txt': '原始内容\n' }));
  const opened = await k.call('POST', `/workspaces/${registered.workspace.id}/instances`, { id: randomUUID(), definitionId: 'kite.agent' });
  expect(opened.status).toBe(200);
  return { id: opened.body.id as string, cwd: registered.workspace.cwd };
}

function calledItem(id: string, name: string, args: Json): ModelItem {
  return { ...item(id, name), call: { id, name, arguments: args } };
}

function result(history: Awaited<ReturnType<ManualModel['call']>>['request']['history'], callId: string) {
  const entry = history.find((item) => item.type === 'tool_result' && item.callId === callId);
  if (entry?.type !== 'tool_result') throw new Error(`缺少工具结果：${callId}`);
  return entry.result;
}

// HTTP 授权提交与 SQLite 通知快照交接；排队后编辑目录不得重渲染旧通知或改变执行权限。
test('空闲时授权保留通知快照，重试不重复投递或改动历史', async () => {
  const model = new ManualModel();
  kited = startKited(() => model);
  const k = kited;
  const { id } = await codingInstance(k);
  const initial = await k.call('GET', grantsPath(id));
  expect(initial.status).toBe(200);
  const readOnly = changes('read');
  const readOnlyEffective = effective('read');
  const oldTemplate = await editNotificationTemplate(k.call,
    'kite.execution-permissions', '权限通知旧模板', 'execution.grants');

  expect((await k.call('POST', `/threads/${id}/messages`, { id: randomUUID(), text: '先执行' })).status).toBe(200);
  const first = await model.call(1);
  expect((await k.call('PUT', grantsPath(id), {
    expectedRevision: initial.body.revision, grants: readOnly,
  })).status).toBe(409);
  first.response.complete();
  await k.waitEvent((event) => event.type === 'idle' && event.threadId === id);

  // 本机地址的各种写法都不能写进授权：依赖运行时 URL 对数字 IPv4、IPv4 映射 IPv6 的规范化和 BlockList 对映射地址按 IPv4 网段的判断。
  for (const endpoint of ['localhost:8080', '127.0.0.1:8080', '[::1]:8080', '[::ffff:127.0.0.1]:8080', '2130706433:8080',
    '169.254.169.254:80', '[fe80::1]:80', '[::ffff:169.254.1.1]:80']) {
    const localhost = changes('read', { network: [endpoint] });
    expect((await k.call('PUT', grantsPath(id), {
      expectedRevision: initial.body.revision, grants: localhost,
    })).status).not.toBe(200);
    expect((await k.call('GET', grantsPath(id))).body).toEqual(initial.body);
  }
  const updated = await k.call('PUT', grantsPath(id), { expectedRevision: initial.body.revision, grants: readOnly });
  expect(updated.status).toBe(200);
  expect(updated.body.grants).toEqual(readOnly);
  expect(updated.body.effective).toEqual(readOnlyEffective);
  expect(updated.body.revision).not.toBe(initial.body.revision);
  expect((await k.call('PUT', grantsPath(id), {
    expectedRevision: initial.body.revision, grants: initial.body.grants,
  })).status).toBe(409);
  const repeated = await k.call('PUT', grantsPath(id), { expectedRevision: updated.body.revision, grants: readOnly });
  expect(repeated.status).toBe(200);
  expect(repeated.body).toEqual(updated.body);
  expect((await k.call('GET', grantsPath(id))).body).toEqual(updated.body);
  expect(model.calls.values).toHaveLength(1);
  const pending = structuredClone(k.daemon.kite.store.instanceNotifications(id, 0));
  const permissionsNotice = pending.find((notice) => notice.context.definition.scene === 'thread.execution_permissions_changed');
  if (!permissionsNotice) throw new Error('缺少排队中的执行授权通知');
  expect(permissionsNotice.context.definition).toEqual(oldTemplate.definition);
  expect(JSON.parse(permissionsNotice.context.bindings['execution.grants']!.text)).toEqual(readOnlyEffective);
  await editNotificationTemplate(k.call, 'kite.execution-permissions', '权限通知新模板', 'execution.grants');
  expect(k.daemon.kite.store.instanceNotifications(id, 0)).toEqual(pending);
  expect((await k.call('GET', grantsPath(id))).body).toEqual(updated.body);
  expect(model.calls.values).toHaveLength(1);

  const since = mark(k);
  expect((await k.call('POST', `/threads/${id}/messages`, { id: randomUUID(), text: '继续执行' })).status).toBe(200);
  const second = await model.call(2);
  expect(second.request.instructions).toBe(first.request.instructions);
  expect(second.request.history.slice(0, first.request.history.length)).toEqual(first.request.history);
  const permissionUpdates = second.request.history.filter((entry) => entry.type === 'notification')
    .filter((entry) => entry.notification.kind === 'execution.permissions.changed');
  expect(permissionUpdates).toHaveLength(1);
  expect(permissionUpdates[0]!.text).toContain('权限通知旧模板');
  expect(permissionUpdates[0]!.text).toContain(permissionsNotice.context.bindings['execution.grants']!.text);
  expect(permissionUpdates[0]!.text).not.toContain('权限通知新模板');
  const configured = diskRecords(join(k.home, 'sessions', id, 'journal.jsonl'))
    .filter((record) => record.type === 'request.configured');
  expect(configured.at(-1)!.snapshot.settings.execution?.grants).toEqual(readOnlyEffective);
  second.response.complete();
  await k.waitEvent((event) => event.type === 'idle' && event.threadId === id && after(k, since)(event));
}, 1000);

// 缓存 Runner、OS 沙箱与模型创建子实例跨请求交接；额外目录许可不能提升受管工具或子实例权限。
test('缓存实例采用新授权，额外目录不提升受管工具和子实例权限', async () => {
  const model = new ManualModel();
  kited = startKited(() => model);
  const k = kited;
  const { id, cwd } = await codingInstance(k);
  const outside = join(k.root, 'allowed-outside');
  const hostAuth = join(k.home, 'auth');
  mkdirSync(outside);
  mkdirSync(hostAuth, { recursive: true });
  writeFileSync(join(outside, 'outside.txt'), '工作区外内容\n');
  const initial = await k.call('GET', grantsPath(id));
  expect(initial.status).toBe(200);

  expect((await k.call('POST', `/threads/${id}/messages`, { id: randomUUID(), text: '建立运行时' })).status).toBe(200);
  const first = await model.call(1);
  first.response.complete();
  await k.waitEvent((event) => event.type === 'idle' && event.threadId === id);

  for (const protectedGrant of [changes('read', { read: [k.root] }), changes('read', { read: [k.home] }), changes('read', { write: [hostAuth] })]) {
    expect((await k.call('PUT', grantsPath(id), {
      expectedRevision: initial.body.revision, grants: protectedGrant,
    })).status).not.toBe(200);
    expect((await k.call('GET', grantsPath(id))).body).toEqual(initial.body);
  }
  const narrowed = changes('read', { write: [outside] });
  expect((await k.call('PUT', grantsPath(id), { expectedRevision: initial.body.revision, grants: narrowed })).status).toBe(200);

  const since = mark(k);
  expect((await k.call('POST', `/threads/${id}/messages`, { id: randomUUID(), text: '检查新授权' })).status).toBe(200);
  const second = await model.call(2);
  await second.response.emit({ type: 'item', item: calledItem('read-workspace', 'read', { path: 'base.txt' }) });
  await second.response.emit({ type: 'item', item: calledItem('read-outside', 'read', { path: join(outside, 'outside.txt') }) });
  await second.response.emit({ type: 'item', item: calledItem('patch-workspace', 'patch', {
    operations: [{ type: 'create_file', path: 'blocked-patch.txt', diff: '+不应写入\n+' }],
  }) });
  await second.response.emit({ type: 'item', item: calledItem('shell-paths', 'shell', {
    description: '验证撤权和额外目录',
    command: `printf denied > '${join(cwd, 'blocked-shell.txt')}' 2>/dev/null; printf allowed > '${join(outside, 'allowed.txt')}'`,
  }) });
  await second.response.emit({ type: 'item', item: calledItem('create-child', 'agent_start', { role: 'kite.work' }) });
  second.response.complete();

  const third = await model.call(3);
  expect(result(third.request.history, 'read-workspace')).toMatchObject({ status: 'success', output: expect.stringContaining('原始内容') });
  expect(result(third.request.history, 'read-outside').status).not.toBe('success');
  expect(result(third.request.history, 'patch-workspace').status).not.toBe('success');
  expect(result(third.request.history, 'shell-paths').status).toBe('success');
  expect(result(third.request.history, 'create-child').status).toBe('success');
  expect(existsSync(join(cwd, 'blocked-patch.txt'))).toBe(false);
  expect(existsSync(join(cwd, 'blocked-shell.txt'))).toBe(false);
  expect(readFileSync(join(outside, 'allowed.txt'), 'utf8')).toBe('allowed');
  const aggregate = await k.call('GET', '/workspaces');
  const child = aggregate.body.flatMap((workspace: { instances: Array<{ id: string; origin?: { callId: string } }> }) => workspace.instances)
    .find((instance: { origin?: { callId: string } }) => instance.origin?.callId === 'create-child');
  if (!child) throw new Error('模型没有创建工作角色的子实例');
  expect((await k.call('GET', grantsPath(child.id))).body.effective).toEqual(effective('read'));
  third.response.complete();
  await k.waitEvent((event) => event.type === 'idle' && event.threadId === id && after(k, since)(event));
}, 1000);

// ---- 三层合成与沙箱外命令 ----

const temp = useTemp();

/**
 * 在 root 下建用户主目录，返回它的真实位置和一条经系统链接的写法：macOS 的 /var 是指向 /private/var 的链接
 * （和 /tmp → /private/tmp 同类），临时目录的真实位置在 /private/var 下，去掉 /private 就是经链接的路径。
 */
function linkedHome(root: string): { real: string; home: string } {
  const real = join(root, 'home');
  mkdirSync(real);
  const home = real.startsWith('/private/') ? real.slice('/private'.length) : join(root, 'home-link');
  if (home === join(root, 'home-link')) symlinkSync(real, home);
  expect(home).not.toBe(real);
  expect(realpathSync(home)).toBe(real);
  return { real, home };
}

/*
 * 代码之外的东西：~/ 的展开与真实位置要经文件系统解析（系统链接 /var → /private/var、主目录里用户自建的链接），
 * 本机不存在的许可要按此刻的文件系统略过；再与项目禁止、实例增减、宿主的基础策略合成，交给 macOS Seatbelt 真跑一条命令，
 * 才知道禁止的路径在经链接给出的主目录下也拦得住。
 */
test('项目里 ~/ 开头的路径按给的主目录解析到真实位置、本机没有的略过，沙箱里读得到链接的目标；项目禁止的路径在沙箱里读写不了，落在禁止目录里的许可被去掉；*.example.com 禁止从网络许可里去掉并进禁止名单；实例 remove 去掉项目给的许可；项目只读时实例要可写也只读', async () => {
  const root = temp('layers-paths-');
  const { real, home } = linkedHome(root);
  for (const dir of ['ref', 'cache/locked', 'data/secret/notes', '.kite/auth']) mkdirSync(join(real, dir), { recursive: true });
  writeFileSync(join(real, 'data', 'ok.txt'), '可读内容');
  writeFileSync(join(real, 'data', 'secret', 'key.txt'), '禁止读的内容');
  writeFileSync(join(real, 'data', 'secret', 'notes', 'n.txt'), '禁止目录里的许可');
  const elsewhere = join(root, 'elsewhere');
  mkdirSync(elsewhere);
  writeFileSync(join(elsewhere, 'e.txt'), '链接目标的内容');
  symlinkSync(elsewhere, join(real, 'linked'));
  const extra = join(root, 'extra');
  mkdirSync(extra);
  const cwd = join(root, 'workspace');
  mkdirSync(cwd);

  const project = parseProjectExecution({
    workspace: 'read',
    allow: {
      read: ['~/ref', '~/linked', '~/missing', '~/data', '~/data/secret/notes'], write: ['~/cache'],
      network: ['registry.npmjs.org', 'api.example.com:443', 'pypi.org'], unsandboxed: [],
    },
    deny: { read: ['~/data/secret'], write: ['~/cache/locked'], network: ['*.example.com'], unsandboxed: [] },
  });
  const changes = await normalizeExecutionChanges({
    workspace: 'write',
    add: { read: [extra], write: [], network: ['cdn.example.com'], unsandboxed: [] },
    remove: { read: [], write: [], network: ['registry.npmjs.org'], unsandboxed: [] },
  });
  const effective = effectiveExecution(changes, project, home);
  expect(effective.grants.workspace).toBe('read');
  expect(effective.grants.read).toEqual(expect.arrayContaining([join(real, 'ref'), elsewhere, join(real, 'data'), extra]));
  expect(effective.grants.read).not.toContain(join(real, 'data', 'secret', 'notes'));
  expect(effective.grants.read.filter((path) => path.endsWith('missing') || path.startsWith('~') || path.startsWith(home + '/'))).toEqual([]);
  expect(effective.grants.write).toEqual([join(real, 'cache')]);
  expect(effective.grants.network).toEqual(['pypi.org']);

  const policy = applyExecutionGrants(await harnessPolicy({ cwd, env: ENV(), home: join(real, '.kite') }), cwd, effective);
  expect(policy.network).toEqual(['pypi.org']);
  expect(policy.deniedNetwork).toContain('*.example.com');
  const command = [
    `cat ${join(elsewhere, 'e.txt')}`, `cat ${join(real, 'data', 'ok.txt')}`,
    `cat ${join(real, 'data', 'secret', 'key.txt')}`, `cat ${join(real, 'data', 'secret', 'notes', 'n.txt')}`,
    `printf w > ${join(real, 'cache', 'ok.txt')}`, `printf w > ${join(real, 'cache', 'locked', 'x.txt')}`,
    `printf w > ${join(cwd, 'ws.txt')}`, 'printf done',
  ].join('; ');
  const result = await runCommand(command, 3000, new AbortController().signal,
    { cwd, logDir: join(root, 'logs'), env: { PATH: process.env.PATH, HOME: cwd, TMPDIR: cwd }, policy });
  expect(result.output).toContain('done');
  expect(result.output).toContain('链接目标的内容');
  expect(result.output).toContain('可读内容');
  expect(result.output).not.toContain('禁止读的内容');
  expect(result.output).not.toContain('禁止目录里的许可');
  expect(existsSync(join(real, 'cache', 'ok.txt'))).toBe(true);
  expect(existsSync(join(real, 'cache', 'locked', 'x.txt'))).toBe(false);
  expect(existsSync(join(cwd, 'ws.txt'))).toBe(false);
}, 1000);

/*
 * 代码之外的东西：实例的路径在授权时解析成真实位置，执行前要按此刻的文件系统核对——目录被删、被换成指向别处的链接都要拒绝；
 * 与宿主保护目录（kite 数据目录）重叠时，实例写的绝对路径拒绝执行，项目里来自 ~/ 的只略过，其余许可照常生效。
 */
test('实例授权的路径消失或被换成指向别处的链接后拒绝执行；与宿主保护目录重叠时实例的绝对路径拒绝执行，项目里来自 ~/ 的只略过', async () => {
  const root = temp('layers-strict-');
  const { real, home } = linkedHome(root);
  const kiteHome = join(real, '.kite');
  mkdirSync(join(kiteHome, 'auth'), { recursive: true });
  mkdirSync(join(real, 'ref'));
  const cwd = join(root, 'workspace');
  mkdirSync(cwd);
  const base = await harnessPolicy({ cwd, env: ENV(), home: kiteHome });
  const empty = { read: [], write: [], network: [], unsandboxed: [] };

  const lenient = effectiveExecution(await normalizeExecutionChanges({}),
    parseProjectExecution({ allow: { ...empty, read: ['~/.kite', '~/ref'], write: ['~/.kite/auth'] } }), home);
  const skipped = applyExecutionGrants(base, cwd, lenient);
  expect(skipped.read).toContain(join(real, 'ref'));
  expect([...skipped.read, ...skipped.write].filter((path) => path === kiteHome || path.startsWith(kiteHome + '/'))).toEqual([]);

  const strict = effectiveExecution(await normalizeExecutionChanges({ add: { ...empty, read: [kiteHome] } }), undefined, home);
  expect(() => applyExecutionGrants(base, cwd, strict)).toThrow();

  const gone = join(root, 'gone');
  mkdirSync(gone);
  const vanishing = effectiveExecution(await normalizeExecutionChanges({ add: { ...empty, read: [gone] } }), undefined, home);
  expect(() => applyExecutionGrants(base, cwd, vanishing)).not.toThrow();
  rmSync(gone, { recursive: true });
  expect(() => applyExecutionGrants(base, cwd, vanishing)).toThrow();

  const swapped = join(root, 'swapped');
  mkdirSync(swapped);
  const relinked = effectiveExecution(await normalizeExecutionChanges({ add: { ...empty, write: [swapped] } }), undefined, home);
  rmSync(swapped, { recursive: true });
  symlinkSync(join(real, 'ref'), swapped);
  expect(() => applyExecutionGrants(base, cwd, relinked)).toThrow();
}, 1000);

/*
 * 真实 bug：项目里写的绝对路径和实例加的一样按严格方式核对，本机不存在的、经过符号链接的（含 macOS 的系统链接 /var → /private/var）
 * 都让 applyExecutionGrants 抛「授权路径已消失或改变位置」，整个项目的代理都不能执行。项目约束随账号级数据到各工作机，
 * 本机没有的要略过，经链接的按真实位置授权。
 * 关联 bug：实例按项目里的原文 remove 经链接的路径，normalizeExecutionChanges 把 remove 也解析成真实位置，和项目原文对不上而去不掉；
 * 本机不存在的 remove 直接报错。
 * 代码之外的东西：路径的真实位置要经文件系统解析（realpath、用户建的链接、系统链接），结果要合成到基础策略上才看得出。
 */
test('项目里的绝对路径本机没有时略过、经链接的按真实位置授权，照常能执行；实例按项目原文 remove 去得掉经链接的和本机没有的路径', async () => {
  const root = temp('layers-absolute-');
  const { real, home } = linkedHome(root);
  const kiteHome = join(real, '.kite');
  mkdirSync(kiteHome);
  mkdirSync(join(real, 'ref'));
  const elsewhere = join(root, 'elsewhere');
  const dropped = join(root, 'dropped');
  mkdirSync(elsewhere);
  mkdirSync(dropped);
  symlinkSync(elsewhere, join(real, 'linked'));
  symlinkSync(dropped, join(real, 'dropped-link'));
  const absent = join(root, 'absent');
  const absentRemoved = join(root, 'absent-removed');
  const cwd = join(root, 'workspace');
  mkdirSync(cwd);
  const empty = { read: [], write: [], network: [], unsandboxed: [] };

  // home 是经链接的写法：join(home, …) 都要经过 /var（或测试建的链接）才到真实位置，linked、dropped-link 再多经一层。
  const project = parseProjectExecution({ allow: { ...empty, read: [
    join(home, 'ref'), join(home, 'linked'), join(home, 'dropped-link'), absent, absentRemoved,
  ] } });
  const changes = await normalizeExecutionChanges({ remove: { ...empty, read: [join(home, 'dropped-link'), absentRemoved] } });
  const effective = effectiveExecution(changes, project, home);
  expect(effective.grants.read).toEqual(expect.arrayContaining([join(real, 'ref'), elsewhere]));
  const gone = [dropped, join(real, 'dropped-link'), join(home, 'dropped-link'), absent, absentRemoved];
  for (const path of gone) expect(effective.grants.read).not.toContain(path);

  const policy = applyExecutionGrants(await harnessPolicy({ cwd, env: ENV(), home: kiteHome }), cwd, effective);
  expect(policy.read).toEqual(expect.arrayContaining([join(real, 'ref'), elsewhere]));
  for (const path of gone) expect(policy.read).not.toContain(path);
}, 1000);

/*
 * 真实 bug（沙箱外命令的安全边界被绕过）：
 * 一、单个 & 没被当成分隔符：允许 `npm run dev *` 时 `npm run dev & rm -rf ~/x` 整条判为允许，后一条跟着出了沙箱；
 *    禁止 `sudo *` 时 `ls & sudo rm -rf /` 不判为禁止。
 * 二、项目禁止只按字面前缀比对：`env sudo …`、`/usr/bin/sudo …`、`FOO=1 sudo …`、`sh -c "sudo …"` 都不算禁止。
 * 依赖 sh 的语法：& 把前一条放到后台、接着跑下一条；env、变量赋值前缀、程序的完整路径、sh -c 都会真的运行后面的 sudo。
 */
test('沙箱外命令里单个 & 后面的那条另算，不沾前一条的允许、碰到禁止就整条禁止；项目禁止的程序经 env、完整路径、变量前缀或 sh -c 运行也判为禁止', () => {
  // 对照：允许的写法本身生效，下面的 unlisted 只能是因为 & 后面那条。
  expect(unsandboxedVerdict('npm run dev --port 3000', ['npm run dev *'], [])).toBe('allowed');
  expect(unsandboxedVerdict('npm run dev & rm -rf ~/x', ['npm run dev *'], [])).toBe('unlisted');
  expect(unsandboxedVerdict('ls & sudo rm -rf /', ['ls *'], ['sudo *'])).toBe('denied');
  expect(unsandboxedVerdict('ls & sudo rm -rf /', [], ['sudo *'])).toBe('denied');
  for (const command of ['env sudo launchctl list', '/usr/bin/sudo ls', 'FOO=1 sudo ls', 'sh -c "sudo ls"']) {
    expect([command, unsandboxedVerdict(command, [], ['sudo *'])]).toEqual([command, 'denied']);
  }
});

type Tools = ReturnType<typeof localTools>;

/** 宿主的沙箱外判断替身：verdicts 按命令原文给结果，没列的是 unlisted；ask 记下每次申请，按 answers 依次回答。 */
function outsideHost(verdicts: Record<string, ReturnType<ShellOutside['verdict']>>, answers: boolean[] = []) {
  const asked: Array<{ command: string; description: string }> = [];
  const outside: ShellOutside = {
    verdict: (command) => verdicts[command] ?? 'unlisted',
    async ask(command, description) {
      asked.push({ command, description });
      const answer = answers.shift();
      if (answer === undefined) throw new Error(`没准备回答：${command}`);
      return answer;
    },
  };
  return { outside, asked };
}

async function shell(tools: Tools, cwd: string, args: Json): Promise<ToolResult> {
  const tool = tools.find((candidate) => candidate.name === 'shell');
  if (!tool) throw new Error('缺少 shell 工具');
  // 参数不收（比如不认 outside_sandbox）是测试本身的问题，照样抛出；执行时拒绝才算这次调用的结果。
  tool.validate(args);
  try {
    return await tool.execute(args, { cwd, signal: new AbortController().signal });
  } catch (error) {
    return { status: 'error', output: String(error) };
  }
}

/** 一台只在本机回环上的 HTTP 服务：沙箱里的命令连不上回环地址，沙箱外能连上。 */
function loopback() {
  const server = Bun.serve({ hostname: '127.0.0.1', port: 0, fetch: () => new Response('pong') });
  return {
    server,
    /** 写一个文件，再连一次本机端口，输出 net=HTTP 状态码（连不上是 000）。写不了时命令接着跑。 */
    probe: (file: string) => `printf ran > ${file}; curl --noproxy '*' --silent --max-time 1 --output /dev/null --write-out 'net=%{http_code}' http://127.0.0.1:${server.port}/`,
  };
}

/** 这几条命令都很快结束，不会转后台；给了后台接管方，shell 才收 outside_sandbox 参数。 */
const noBackground: ShellBackground = {
  interjected: () => () => {},
  adopt() { throw new Error('命令不应转到后台'); },
};

function workspace(prefix: string) {
  const root = temp(prefix);
  const cwd = join(root, 'workspace');
  const outside = join(root, 'outside');
  mkdirSync(cwd);
  mkdirSync(outside);
  return { root, cwd, outside };
}

/*
 * 几个部分的配合：outside_sandbox 的申请先过宿主判断再决定问不问；问的回答决定命令跑不跑、在哪跑。
 * 代码之外的东西：放行后命令真的不在 Seatbelt 沙箱里（写得了工作区外、连得上本机端口，依赖 /usr/bin/curl）。
 */
test('申请出沙箱时项目禁止的直接拒绝、不问也不执行；没登记的交给 ask，拒绝时命令没执行，放行时在沙箱外执行', async () => {
  const { root, cwd, outside } = workspace('layers-ask-');
  const { server, probe } = loopback();
  try {
    const denied = probe(join(outside, 'denied.txt'));
    const refused = probe(join(outside, 'refused.txt'));
    const approved = probe(join(outside, 'approved.txt'));
    const { outside: host, asked } = outsideHost({ [denied]: 'denied' }, [false, true]);
    const tools = localTools({
      cwd, logDir: join(root, 'logs'), env: ENV(), outside: host, background: noBackground,
    });

    const rejected = await shell(tools, cwd, { description: '项目禁止', command: denied, outside_sandbox: true });
    expect(rejected.status).not.toBe('success');
    expect(asked).toEqual([]);
    expect(existsSync(join(outside, 'denied.txt'))).toBe(false);

    const declined = await shell(tools, cwd, { description: '用户会拒绝', command: refused, outside_sandbox: true });
    expect(declined.status).not.toBe('success');
    expect(declined.output).not.toContain('net=');
    expect(existsSync(join(outside, 'refused.txt'))).toBe(false);

    const allowed = await shell(tools, cwd, { description: '用户会放行', command: approved, outside_sandbox: true });
    expect(allowed.output).toContain('net=200');
    expect(existsSync(join(outside, 'approved.txt'))).toBe(true);
    expect(asked).toEqual([{ command: refused, description: '用户会拒绝' }, { command: approved, description: '用户会放行' }]);
  } finally {
    await server.stop(true);
  }
}, 1000);

const resultOf = (request: ModelRequest, callId: string): ToolResult => {
  const found = request.history.find((entry) => entry.type === 'tool_result' && entry.callId === callId);
  if (found?.type !== 'tool_result') throw new Error(`缺少工具结果：${callId}`);
  return found.result;
};

/*
 * 几个部分的配合：项目约束经账号级数据对进本机缓存，审批模式按项目上限收紧；shell 调用前按三层合成的沙箱外命令与项目禁止判断；
 * 申请出沙箱时线程挂出审批等待，经 HTTP 回应「允许并记住」后命令在沙箱外跑，同时把命令原文写进运行中实例的执行授权，
 * 同一回合后面的同一条命令按新授权直接出沙箱、不再问。命令是否在沙箱外以能否写工作区外的目录判断（依赖 Seatbelt）。
 */
test('项目允许的沙箱外命令直接出沙箱；实例全放行而项目上限越界询问时申请出沙箱挂出审批，允许并记住后在沙箱外执行并记进实例授权，同一条再跑不再问；项目禁止的申请直接拒绝不挂等待', async () => {
  const model = new ManualModel();
  const k = kited = startKited(() => model);
  const registered = await folderWorkspace(k, newDir(k.root, 'project', { 'a.txt': 'a\n' }));
  const projectId = registered.project.id;
  const outside = join(k.root, 'outside');
  mkdirSync(outside);
  const direct = `touch ${join(outside, 'direct')}`;
  const denied = `mkdir -p ${join(outside, 'denied')}`;
  const requested = `mkdir -p ${join(outside, 'requested')}`;
  const empty = { read: [], write: [], network: [], unsandboxed: [] };

  const current = await k.call('GET', `/project-registry/${projectId}/constraints`);
  expect(current.status).toBe(200);
  const saved = await k.call('PUT', `/project-registry/${projectId}/constraints`, {
    tools: { mode: 'deny', tools: [] }, expectedRevision: current.body.revision,
    execution: { allow: { ...empty, unsandboxed: ['touch *'] }, deny: { ...empty, unsandboxed: [denied] }, approval: 'ask' },
  });
  expect(saved.status).toBe(200);
  await until(() => k.daemon.kite.store.projectConstraints(projectId)?.execution?.approval === 'ask', '项目约束对进本机缓存', 900);

  const started = await k.call('POST', `/workspaces/${registered.workspace.id}/operations/agent.start`, { operationId: 'agent' });
  expect(started.status).toBe(200);
  const id = started.body.instanceId as string;
  expect((await k.call('PUT', `/instances/${id}/approval-mode`, { mode: 'allow_all' })).status).toBe(200);
  expect((await k.call('GET', `/instances/${id}/approval-mode`)).body).toEqual({ mode: 'allow_all', effective: 'ask', max: 'ask' });
  const waits = (since: number) => k.events.filter((e): e is Extract<Envelope, { type: 'waiting' }> =>
    e.type === 'waiting' && e.threadId === id && !!e.waiting && after(k, since)(e));

  let since = mark(k);
  expect((await k.call('POST', `/threads/${id}/messages`, { id: 'run', text: '跑几条命令' })).status).toBe(200);
  const first = await model.call(1);
  await first.response.emit({ type: 'item', item: calledItem('direct', 'shell', { description: '项目允许', command: direct }) });
  await first.response.emit({ type: 'item', item: calledItem('denied', 'shell', { description: '项目禁止', command: denied, outside_sandbox: true }) });
  await first.response.emit({ type: 'item', item: calledItem('requested', 'shell', { description: '要出沙箱', command: requested, outside_sandbox: true }) });
  first.response.complete();
  const event = await k.waitEvent((e) => e.type === 'waiting' && e.threadId === id && !!e.waiting && after(k, since)(e));
  const waiting = (event as Extract<Envelope, { type: 'waiting' }>).waiting as Extract<Waiting, { kind: 'approval' }>;
  expect(waiting).toMatchObject({ kind: 'approval', tool: 'shell', target: requested, outside: true, mustAsk: false });
  expect(waiting.reason).toContain('要出沙箱');
  expect(existsSync(join(outside, 'requested'))).toBe(false);

  expect(await k.call('POST', `/threads/${id}/waiting/${waiting.id}`, { decision: 'remember' })).toEqual({ status: 200, body: { ok: true } });
  const second = await model.call(2);
  expect(resultOf(second.request, 'direct').status).toBe('success');
  expect(existsSync(join(outside, 'direct'))).toBe(true);
  expect(resultOf(second.request, 'denied').status).not.toBe('success');
  expect(existsSync(join(outside, 'denied'))).toBe(false);
  expect(resultOf(second.request, 'requested').status).toBe('success');
  expect(existsSync(join(outside, 'requested'))).toBe(true);
  expect(waits(since).map((e) => e.waiting!.id)).toEqual([waiting.id]);
  expect((await k.call('GET', `/instances/${id}/execution-grants`)).body.grants.add.unsandboxed).toContain(requested);

  rmSync(join(outside, 'requested'), { recursive: true });
  since = mark(k);
  await second.response.emit({ type: 'item', item: calledItem('again', 'shell', { description: '再跑一次', command: requested, outside_sandbox: true }) });
  second.response.complete();
  const third = await model.call(3);
  expect(resultOf(third.request, 'again').status).toBe('success');
  expect(existsSync(join(outside, 'requested'))).toBe(true);
  expect(waits(since)).toEqual([]);
  const idle = mark(k);
  third.response.complete();
  await waitIdle(k, id, idle);
}, 1000);
