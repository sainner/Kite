/**
 * 工作区跨机流转（docs/Line与工作区流转.md「工作区流转」）：两台本进程 kited 共用一个账号替身。
 * 每个测试换一个 HOME：目标机还原时 clone 到 HOME 下的 ~/code，远程地址的改写也写在这个 HOME 的 git 全局配置里。
 * 一次交接加还原要起一百来个 git 进程：前两个测试各要 1 到 1.5 秒，流转回原机那个有两次交接、三次还原，约 2.5 秒，
 * 都超过小测试 1 秒的预算。
 */
import { afterEach, expect, test } from 'bun:test';
import { chmodSync, existsSync, readdirSync, rmSync } from 'node:fs';
import { join } from 'node:path';
import type { WorkspaceModel } from '../../src/model.ts';
import type { History } from '../../src/transcript/protocol.ts';
import { transferRef } from '../../src/transfer/materials.ts';
import { leaseRef, writeLease } from '../../src/workspace/lease.ts';
import { type FakeAccount, startFakeAccount } from '../fake-account.ts';
import { after, createWorkspace, type Kited, mark, registerCheckout, startKited } from '../harness.ts';
import { item, ManualModel } from '../harness-loop.ts';
import { git, makeTemp, newDir, newRepo, read, writeFiles } from '../util.ts';

let account: FakeAccount | undefined;
const kiteds: Kited[] = [];
const dirs: string[] = [];
const homes: string[] = [];
afterEach(async () => {
  for (const k of kiteds.splice(0)) await k.stop();
  account?.stop();
  account = undefined;
  const home = homes.pop();
  if (home) process.env.HOME = home;
  for (const dir of dirs.splice(0)) rmSync(dir, { recursive: true, force: true });
});

/** 未过期的 ChatGPT 订阅登录：还原时检查目标机对线程所用厂商的登录。 */
function chatgptLogin(home: string): void {
  const encoded = (value: unknown) => Buffer.from(JSON.stringify(value)).toString('base64url');
  const accessToken = `${encoded({ alg: 'RS256', typ: 'JWT' })}.${encoded({ exp: Math.floor(Date.now() / 1000) + 3600 })}.${encoded('仅测试')}`;
  writeFiles(home, { 'auth/chatgpt/auth.json': JSON.stringify({ auth_mode: 'chatgpt', tokens: { access_token: accessToken, account_id: 'test-account' } }) });
}

/** 新的临时根目录、HOME 与账号替身。 */
function fresh(prefix: string): string {
  const root = makeTemp(prefix);
  dirs.push(root);
  homes.push(process.env.HOME!);
  process.env.HOME = newDir(root, 'home');
  account = startFakeAccount(join(root, 'account'));
  return root;
}

/** 源机 A 与目标机 B，各有自己的手动模型；B 已登录 ChatGPT。 */
function machines() {
  const root = fresh('transfer-');
  const models = { a: new ManualModel(), b: new ManualModel() };
  const a = startKited(() => models.a, false, account);
  const b = startKited(() => models.b, false, account);
  kiteds.push(a, b);
  chatgptLogin(b.home);
  return { root, a, b, models };
}

/**
 * A 上登记一个托管项目。登记照常经 http 推到托管仓库；之后两台 kited 对这个远程的 git 操作经 HOME 的 url.insteadOf
 * 直接走裸仓库路径：一次交接加还原有十几次远程操作，经 http-backend 时每个测试要多出几百毫秒。
 * 经 http 读 lease 见 lease.test.ts；交接材料经 http 推到托管仓库是普通的 git 推送，没有单独测。
 */
async function hostedProject(root: string, a: Kited, files: Record<string, string>) {
  const repo = newRepo(a.root, 'project', files, null);
  const registered = await registerCheckout(a, repo);
  const bare = join(account!.repos, `${registered.project.id}.git`);
  git(root, 'config', '--global', `url.${bare}.insteadOf`, account!.projects.get(registered.project.id)!.url);
  return { repo, registered, bare };
}

const handover = (a: Kited, workspaceId: string) => a.call('POST', `/workspaces/${workspaceId}/handover`, {});
const restore = (b: Kited, project: string, workspaceId: string, operationId: string) =>
  b.call('POST', '/workspaces/restore', { project, workspaceId, operationId });
const leaseOf = (bare: string, workspaceId: string) => JSON.parse(git(bare, 'show', `${leaseRef(workspaceId)}:lease.json`));

/*
 * 几个部分的配合：git（快照、未提交改动打成的 commit、材料 ref 的推送与取回、工作树还原）、SQLite 记录的导出与导入、
 * 通知游标与重新编号、目标机上会话的续接，以及 lease 的比较后更新。源机被接管后的冻结见最后一个测试。
 */
test('独立工作区流转：未提交的改、增、删都还原成未提交状态，目标机续接历史且未交接的通知只到一次，交接前归档的线程历史也带过去', async () => {
  const { root, a, b, models } = machines();
  const { registered } = await hostedProject(root, a, { 'tracked.txt': '原始\n', 'gone.txt': '要删掉\n' });
  const thread = await createWorkspace(a, registered.checkout.id, '第一回合', 'harness');
  const workspaceId = thread.workspace.id;
  const first = await models.a.call(1);
  const reply = item('a-reply');
  await first.response.emit({ type: 'item', item: reply });
  first.response.complete();
  await a.waitEvent((e) => e.type === 'idle' && e.threadId === thread.id);
  // 真实 bug：交接只导出未归档线程的会话文件，交接前归档的线程到了目标机没有历史。
  const started = await a.call('POST', `/workspaces/${workspaceId}/operations/agent.start`, { operationId: 'side' });
  expect(started.status).toBe(200);
  const side = started.body.instanceId as string;
  expect((await a.call('POST', `/threads/${side}/messages`, { id: 'side-turn', text: '旁支回合' })).status).toBe(200);
  (await models.a.call(2)).response.complete();
  await a.waitEvent((e) => e.type === 'idle' && e.threadId === side);
  expect((await a.call('POST', `/instances/${side}/archive`)).status).toBe(200);
  const sideHistory = (await a.call('GET', `/threads/${side}/history`)).body;
  expect(sideHistory.records.length).toBeGreaterThan(0);
  writeFiles(thread.workspace.cwd, { 'tracked.txt': '本机改过\n', 'new.txt': '新增未跟踪\n' });
  rmSync(join(thread.workspace.cwd, 'gone.txt'));
  const config = await a.call('GET', `/instances/${thread.id}/agent-config`);
  const changed = await a.call('PUT', `/instances/${thread.id}/agent-config`, {
    expectedRevision: config.body.revision, agent: { ...config.body.instance.config.agent, maxRequestsPerTurn: 7 },
  });
  expect(changed.status).toBe(200);
  const notice = a.daemon.kite.store.instanceNotifications(thread.id, 0).find((n) => n.kind === 'agent.configuration.changed');
  if (!notice) throw new Error('改配置没有产生通知');

  expect((await handover(a, workspaceId)).status).toBe(200);
  expect((await a.call('POST', `/threads/${thread.id}/messages`, { id: 'on-source', text: '交接后不该执行' })).status).toBe(409);

  const restored = await restore(b, registered.project.id, workspaceId, 'restore-1');
  expect(restored.status).toBe(200);
  const model = restored.body as WorkspaceModel;
  expect(model.workspace).toMatchObject({ id: workspaceId, epoch: 2, status: 'open' });
  expect(model.workspace.cwd.startsWith(b.home + '/')).toBe(true);
  const cwd = model.workspace.cwd;
  expect(read(join(cwd, 'tracked.txt'))).toBe('本机改过\n');
  expect(read(join(cwd, 'new.txt'))).toBe('新增未跟踪\n');
  expect(existsSync(join(cwd, 'gone.txt'))).toBe(false);
  expect(git(cwd, 'status', '--porcelain').split('\n').sort()).toEqual([' D gone.txt', ' M tracked.txt', '?? new.txt']);
  expect((await b.call('GET', `/threads/${side}/history`)).body.records).toHaveLength(sideHistory.records.length);

  expect((await b.call('POST', `/threads/${thread.id}/messages`, { id: 'on-target', text: '在 B 上继续' })).status).toBe(200);
  const continued = await models.b.call(1);
  const history = continued.request.history;
  expect(history).toContainEqual({ type: 'input', input: expect.objectContaining({ text: '第一回合', source: 'human' }) });
  expect(history).toContainEqual({ type: 'output', item: reply });
  expect(history.filter((entry) => entry.type === 'notification' && entry.notification.id === notice.id)).toHaveLength(1);
  continued.response.complete();
  await b.waitEvent((e) => e.type === 'idle' && e.threadId === thread.id);
  expect(models.a.calls.values).toHaveLength(2);
}, 3000);

/*
 * 几个部分的配合：目标机在 CAS 接管之前失败（setup 退出非 0）时，已建的工作树、导入的记录与会话目录都要清掉，
 * lease 不动；源机撤回时 lease 改回 active、材料 ref 从远程删掉，工作区回到 open。
 */
test('目标机 setup 失败时还原清掉工作树、记录与会话目录且 lease 仍是源机的交接中，源机撤回后材料删除并回到 open', async () => {
  const { root, a, b, models } = machines();
  const { registered, bare } = await hostedProject(root, a, { 'base.txt': '原始\n' });
  const thread = await createWorkspace(a, registered.checkout.id, '第一回合', 'harness');
  const workspaceId = thread.workspace.id;
  (await models.a.call(1)).response.complete();
  await a.waitEvent((e) => e.type === 'idle' && e.threadId === thread.id);
  // 未提交的 setup 随材料过去，只在目标机上跑。
  writeFiles(thread.workspace.cwd, { '.kite/setup': '#!/bin/sh\necho 目标机缺依赖\nexit 4\n' });
  chmodSync(join(thread.workspace.cwd, '.kite/setup'), 0o755);
  expect((await handover(a, workspaceId)).status).toBe(200);
  const handing = leaseOf(bare, workspaceId);
  expect(handing).toEqual({ machine: a.daemon.kite.store.machine.id, epoch: 1, state: 'handing_off' });

  const failed = await restore(b, registered.project.id, workspaceId, 'restore-fails');
  expect(failed.status).toBeGreaterThanOrEqual(400);
  expect((await b.call('GET', `/workspaces/${workspaceId}`)).status).toBe(404);
  expect(b.daemon.kite.store.workspace(workspaceId)).toBeNull();
  expect(b.daemon.kite.store.thread(thread.id)).toBeNull();
  expect(existsSync(join(b.home, 'sessions', thread.id))).toBe(false);
  const clone = b.daemon.kite.store.checkouts()[0]!.path;
  expect(git(clone, 'worktree', 'list', '--porcelain').split('\n').filter((line) => line.startsWith('worktree '))).toEqual([`worktree ${clone}`]);
  expect(leaseOf(bare, workspaceId)).toEqual(handing);

  const cancelled = await a.call('POST', `/workspaces/${workspaceId}/handover/cancel`);
  expect(cancelled.status).toBe(200);
  expect((cancelled.body as WorkspaceModel).workspace.status).toBe('open');
  expect(git(bare, 'for-each-ref', `refs/kite/transfer/${workspaceId}/`)).toBe('');
  expect(leaseOf(bare, workspaceId)).toMatchObject({ epoch: 1, state: 'active' });
}, 3000);

/*
 * 流转回原机，几个部分的配合：源机核对执行权冻结、强制归档，目标机交回，源机还原时替换本机已有的同 ID 记录。
 * 真实 bug：还原失败时原有的归档记录被删掉了；成功还原后工作树在同一路径重建，快照模块按路径缓存的私有索引失效，
 * 回合收尾报 kite/index.lock 不存在；会话历史按线程缓存显示投影，还原换上 B 带回来的记录后原机仍返回离开前的投影
 * （下面 before 那次读历史时缓存住），看不到在 B 上的回合，要等 kited 重启。
 */
test('流转回原机：还原失败时原机已有的归档记录原样保留且不留备份，再还原成功后读到的历史有在 B 上的回合，epoch 3 能发送并存快照', async () => {
  const { root, a, b, models } = machines();
  chatgptLogin(a.home);
  const { repo, registered } = await hostedProject(root, a, { 'base.txt': '原始\n' });
  const thread = await createWorkspace(a, registered.checkout.id, '第一回合', 'harness');
  const workspaceId = thread.workspace.id;
  (await models.a.call(1)).response.complete();
  await a.waitEvent((e) => e.type === 'idle' && e.threadId === thread.id);
  // 未提交的 setup 随材料走：原机检出里有 .fail-setup 时失败。
  writeFiles(thread.workspace.cwd, { '.kite/setup': '#!/bin/sh\nif [ -e "$KITE_MAIN_DIR/.fail-setup" ]; then echo 缺依赖; exit 3; fi\n' });
  chmodSync(join(thread.workspace.cwd, '.kite/setup'), 0o755);

  expect((await handover(a, workspaceId)).status).toBe(200);
  expect((await restore(b, registered.project.id, workspaceId, 'to-b')).status).toBe(200);
  expect((await b.call('POST', `/threads/${thread.id}/messages`, { id: 'on-b', text: '在 B 上的回合' })).status).toBe(200);
  (await models.b.call(1)).response.complete();
  await b.waitEvent((e) => e.type === 'idle' && e.threadId === thread.id);
  expect(((await a.call('POST', `/workspaces/${workspaceId}/lease/check`)).body as WorkspaceModel).workspace.status).toBe('transferred');
  expect((await a.call('POST', `/workspaces/${workspaceId}/archive`, { force: true })).status).toBe(200);
  expect((await handover(b, workspaceId)).status).toBe(200);
  // cursor 是事件流的位置，随本机任何事件前进，不算记录内容。
  const local = async () => {
    const [workspace, history, snapshots] = await Promise.all([`/workspaces/${workspaceId}`, `/threads/${thread.id}/history`,
      `/workspaces/${workspaceId}/snapshots`].map((path) => a.call('GET', path)));
    expect([workspace!.status, history!.status, snapshots!.status]).toEqual([200, 200, 200]);
    const { cursor: _, ...records } = history!.body;
    return { workspace: workspace!.body, history: records, snapshots: snapshots!.body };
  };
  const before = await local();
  expect(before.workspace.workspace.status).toBe('archived');

  writeFiles(repo, { '.fail-setup': '' });
  expect((await restore(a, registered.project.id, workspaceId, 'back-fails')).status).toBeGreaterThanOrEqual(400);
  expect(await local()).toEqual(before);
  expect(existsSync(join(a.home, 'transfers')) ? readdirSync(join(a.home, 'transfers')) : []).toEqual([]);

  rmSync(join(repo, '.fail-setup'));
  const back = await restore(a, registered.project.id, workspaceId, 'back');
  expect(back.status).toBe(200);
  expect((back.body as WorkspaceModel).workspace).toMatchObject({ epoch: 3, status: 'open' });
  const humans = ((await a.call('GET', `/threads/${thread.id}/history`)).body as History).records
    .flatMap((record) => record.block.type === 'human' ? [record.block.text] : []);
  expect(humans).toEqual(['第一回合', '在 B 上的回合']);
  const since = mark(a);
  expect((await a.call('POST', `/threads/${thread.id}/messages`, { id: 'back-home', text: '回到原机继续' })).status).toBe(200);
  const resumed = await models.a.call(2);
  writeFiles(join(a.home, 'worktrees', registered.project.id, workspaceId), { 'after.txt': '回来以后的改动\n' });
  resumed.response.complete();
  await a.waitEvent((e) => e.type === 'workspace.snapshot' && e.workspaceId === workspaceId && after(a, since)(e));
  const finished = await a.waitEvent((e) => e.type === 'harness' && e.threadId === thread.id && e.event.type === 'record'
    && e.event.record.type === 'turn.finished' && after(a, since)(e));
  expect(finished.type === 'harness' && finished.event.type === 'record' && finished.event.record.type === 'turn.finished'
    && finished.event.record.outcome).toEqual({ kind: 'completed' });
}, 5000);

/*
 * 几个部分的配合：交接把四个材料 ref 与交接中的 lease 推到远程；目标机以更高 epoch 接管之后源机再撤回，
 * 读到的 lease 已不是自己的，撤回 409 并冻结本地记录，lease 保持目标机的。
 */
test('交接推上四个材料 ref，目标机接管后源机撤回返回 409 并冻结', async () => {
  const root = fresh('transfer-cancel-');
  const a = startKited(undefined, false, account);
  kiteds.push(a);
  const { registered, bare } = await hostedProject(root, a, { 'base.txt': '原始\n' });
  const created = await a.call('POST', '/workspaces', { checkout: registered.checkout.id });
  expect(created.status).toBe(200);
  const workspaceId = (created.body as WorkspaceModel).workspace.id;
  await a.waitEvent((e) => e.type === 'workspace.changed' && e.workspaceId === workspaceId && e.status === 'open');
  writeFiles((created.body as WorkspaceModel).workspace.cwd, { 'local.txt': '交接前的改动\n' });

  expect((await a.call('POST', `/workspaces/${workspaceId}/handover`, {})).status).toBe(200);
  const pushed = git(bare, 'for-each-ref', '--format=%(refname)', `refs/kite/transfer/${workspaceId}/`).split('\n').sort();
  expect(pushed).toEqual((['branch', 'records', 'snapshots', 'worktree'] as const).map((name) => transferRef(workspaceId, name)));
  expect(git(bare, 'show', `${transferRef(workspaceId, 'worktree')}:local.txt`)).toBe('交接前的改动');
  const handing = git(bare, 'rev-parse', leaseRef(workspaceId));

  // 目标机接管：以交接中的 lease 为预期值写入自己的 active 与 epoch 2。
  const target = newDir(root, 'target');
  git(target, 'init', '-q');
  const taken = await writeLease(target, workspaceId, { machine: 'target-machine', epoch: 2, state: 'active' }, handing,
    { url: bare, env: {} });
  expect(taken.status).toBe('written');
  const late = await a.call('POST', `/workspaces/${workspaceId}/handover/cancel`);
  expect(late.status).toBe(409);
  expect(((await a.call('GET', `/workspaces/${workspaceId}`)).body as WorkspaceModel).workspace.status).toBe('transferred');
  expect(leaseOf(bare, workspaceId)).toEqual({ machine: 'target-machine', epoch: 2, state: 'active' });
}, 1000);
