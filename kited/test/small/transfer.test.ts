/**
 * 工作区跨机流转（docs/Line与工作区流转.md「工作区流转」）：几台本进程 kited 互为组网对端（harness 的 connect），
 * 项目登记与目录摘要随账号级数据同步；工作区副本由跟进方的 kite.replicas.sync() 立即跟一轮，不等 15 秒一次的定时。
 * 有远程的项目用 fake-git.ts 的 Git 平台替身，lease 记在那里的裸仓库；没有远程的项目以各工作机的检出互为远程。
 * 目标机没有检出时还原会 clone 到 HOME 下的 ~/code/<项目名>，项目名各测试不同，测试结束时删掉。
 * 一次交接加还原要起几十个 git 进程；有远程的那个测试经 http 的 Git 平台替身来回流转两次，约 2 秒，超过小测试 1 秒的预算，
 * 这个文件单个上限 5 秒（scripts/check.ts 的 FILE_LIMITS）。睡眠前自动换机在 leaving.test.ts，守 1 秒。
 */
import { afterEach, expect, test } from 'bun:test';
import { chmodSync, existsSync, rmSync } from 'node:fs';
import { join } from 'node:path';
import type { ModelRequest } from '../../src/harness/types.ts';
import type { WorkspaceModel } from '../../src/model.ts';
import type { ReplicaEntry, ReplicaPage } from '../../src/transfer/replica.ts';
import type { History } from '../../src/transcript/protocol.ts';
import { leaseRef } from '../../src/workspace/lease.ts';
import { type FakeGit, startFakeGit } from '../fake-git.ts';
import { after, chatgptLogin, connect, createWorkspace, type Kited, mark, registerCheckout, startKited, synced } from '../harness.ts';
import { item, ManualModel } from '../harness-loop.ts';
import { commitAll, git, newRepo, read, until, writeFiles } from '../util.ts';

const kiteds: Kited[] = [];
const dirs: string[] = [];
const servers: Array<{ stop(force?: boolean): unknown }> = [];
let remotes: FakeGit | undefined;
afterEach(async () => {
  for (const k of kiteds.splice(0)) await k.stop();
  for (const server of servers.splice(0)) void server.stop(true);
  remotes?.stop();
  remotes = undefined;
  for (const dir of dirs.splice(0)) rmSync(dir, { recursive: true, force: true });
});

/** 一台 kited：手动模型、目录摘要不合批（别的工作机马上看到检出与工作区的变化）、已登录 ChatGPT。 */
function machine(model: ManualModel, root?: string): Kited {
  const k = startKited(() => model, false, { catalogDelayMs: 0, ...(root ? { root } : {}) });
  kiteds.push(k);
  chatgptLogin(k.home);
  return k;
}

/** 停掉 k 再在同一数据目录上起来（之后由新的那台负责删目录）。 */
async function restart(k: Kited, model: ManualModel): Promise<Kited> {
  await k.halt();
  kiteds.splice(kiteds.indexOf(k), 1);
  return machine(model, k.root);
}

/** 项目名各测试不同：目标机 clone 到 ~/code/<项目名>，结束时删掉。 */
function projectName(): string {
  const name = `transfer-${crypto.randomUUID().slice(0, 8)}`;
  dirs.push(join(process.env.HOME!, 'code', name));
  return name;
}

/** A 上登记一个项目（有 remote 时先把 main 推上去），等 others 同步到这条登记和 A 有检出的目录摘要。带 .kite/setup 时设成可执行再提交。 */
async function project(a: Kited, files: Record<string, string>, others: Kited[], remote?: { url: string; bare: string }) {
  const name = remote ? new URL(remote.url).pathname.slice(1, -'.git'.length) : projectName();
  const repo = newRepo(a.root, name, files, remote?.url ?? null);
  if (files['.kite/setup'] !== undefined) {
    chmodSync(join(repo, '.kite/setup'), 0o755);
    commitAll(repo, 'setup 可执行');
  }
  // 直接推到裸仓库路径：util 的 git 是同步调用，经 http 推会卡住本进程里的替身。
  if (remote) git(repo, 'push', '-q', remote.bare, 'main');
  const registered = await registerCheckout(a, repo);
  const projectId = registered.project.id;
  const machineA = a.daemon.kite.store.machine.id;
  for (const k of others) {
    await synced(k, () => k.daemon.kite.registry.get(projectId) && k.daemon.kite.directory.entries()
      .some((entry) => entry.id === machineA && entry.snapshot?.checkouts.some((checkout) => checkout.projectId === projectId)),
    '同步到 A 登记的项目与检出');
  }
  return { repo, registered, projectId };
}

/** k 上的线程跑完一个回合：发消息、等模型第 number 次调用、给出 reply（有的话）再结束，等回到空闲。 */
async function turn(k: Kited, model: ManualModel, threadId: string, number: number, text: string, reply?: string) {
  const since = mark(k);
  const sent = await k.call('POST', `/threads/${threadId}/messages`, { id: crypto.randomUUID(), text });
  if (sent.status !== 200) throw new Error(`发消息失败：${sent.status} ${JSON.stringify(sent.body)}`);
  const call = await model.call(number);
  if (reply) await call.response.emit({ type: 'item', item: item(reply) });
  call.response.complete();
  await k.waitEvent((e) => e.type === 'idle' && e.threadId === threadId && after(k, since)(e));
  return call;
}

const handover = (k: Kited, workspaceId: string) => k.call('POST', `/workspaces/${workspaceId}/handover`, {});
const restore = (k: Kited, body: { project: string; workspaceId: string; from?: string; force?: boolean }) =>
  k.call('POST', '/workspaces/restore', { operationId: crypto.randomUUID(), ...body });
const statusOf = async (k: Kited, workspaceId: string) => ((await k.call('GET', `/workspaces/${workspaceId}`)).body as WorkspaceModel).workspace.status;
const leaseOf = (bare: string, workspaceId: string) => JSON.parse(git(bare, 'show', `${leaseRef(workspaceId)}:lease.json`));
const humans = async (k: Kited, threadId: string) => ((await k.call('GET', `/threads/${threadId}/history`)).body as History).records
  .flatMap((record) => record.block.type === 'human' ? [record.block.text] : []);
const inputs = (request: ModelRequest) => request.history.flatMap((entry) => entry.type === 'input' ? [entry.input] : []);

/*
 * 几个部分的配合：副本（数据库行、journal、通知游标）的跟进与导入、执行设备检出上的快照链与工作区分支经对端取到目标检出、
 * 用最后一个快照还原未提交的改动、lease 在 Git 平台上的比较后更新、源机核对后冻结，以及副本随执行设备换人：
 * 目标机接管后原来的副本删掉，冻结的源机改跟新的执行设备。
 * 真实 bug（旧实现）：交接只带未归档线程的会话文件，交接前归档的线程到了目标机没有历史；
 * 流转回原机时工作树在同一路径重建，快照模块按路径缓存的私有索引失效，回合收尾报 kite/index.lock 不存在；
 * 会话历史按线程缓存显示投影，还原换上带回来的记录后原机仍返回离开前的投影（下面先读一次历史把它缓存住），看不到在 B 上的回合。
 */
test('有远程的项目：独立工作区交给 B 后未提交的改增删、会话历史、交接前归档的线程都在，通知只到一次，lease 是 B 的 epoch 2，A 核对后冻结；B 交回 A 替换冻结记录，epoch 3 续接并存快照', async () => {
  const models = { a: new ManualModel(), b: new ManualModel() };
  const a = machine(models.a);
  const b = machine(models.b);
  await connect(a, b);
  const [machineA, machineB] = [a, b].map((k) => k.daemon.kite.store.machine.id);
  remotes = startFakeGit();
  const remote = remotes.create(projectName());
  const bare = remote.bare;
  const { registered, projectId } = await project(a, { 'tracked.txt': '原始\n', 'gone.txt': '要删掉\n' }, [b], remote);

  const thread = await createWorkspace(a, registered.checkout.id, '第一回合', 'harness');
  const workspaceId = thread.workspace.id;
  const first = await models.a.call(1);
  await first.response.emit({ type: 'item', item: item('a-reply') });
  first.response.complete();
  await a.waitEvent((e) => e.type === 'idle' && e.threadId === thread.id);
  const started = await a.call('POST', `/workspaces/${workspaceId}/operations/agent.start`, { operationId: 'side' });
  expect(started.status).toBe(200);
  const side = started.body.instanceId as string;
  await turn(a, models.a, side, 2, '旁支回合');
  expect((await a.call('POST', `/instances/${side}/archive`)).status).toBe(200);
  const sideRecords = ((await a.call('GET', `/threads/${side}/history`)).body as History).records.length;
  expect(sideRecords).toBeGreaterThan(0);
  writeFiles(thread.workspace.cwd, { 'tracked.txt': '本机改过\n', 'new.txt': '新增未跟踪\n' });
  rmSync(join(thread.workspace.cwd, 'gone.txt'));
  const config = await a.call('GET', `/instances/${thread.id}/agent-config`);
  expect((await a.call('PUT', `/instances/${thread.id}/agent-config`, {
    expectedRevision: config.body.revision, agent: { ...config.body.instance.config.agent, maxRequestsPerTurn: 7 },
  })).status).toBe(200);
  const notice = a.daemon.kite.store.instanceNotifications(thread.id, 0).find((n) => n.kind === 'agent.configuration.changed');
  if (!notice) throw new Error('改配置没有产生通知');

  expect((await handover(a, workspaceId)).status).toBe(200);
  expect(leaseOf(bare, workspaceId)).toEqual({ machine: machineA, epoch: 1, state: 'handing_off' });
  const taken = await restore(b, { project: projectId, workspaceId, from: machineA });
  expect(taken.status).toBe(200);
  const onB = (taken.body as WorkspaceModel).workspace;
  expect(onB).toMatchObject({ id: workspaceId, epoch: 2, status: 'open' });
  expect(onB.cwd.startsWith(b.root + '/')).toBe(true);
  expect(read(join(onB.cwd, 'tracked.txt'))).toBe('本机改过\n');
  expect(read(join(onB.cwd, 'new.txt'))).toBe('新增未跟踪\n');
  expect(git(onB.cwd, 'status', '--porcelain').split('\n').sort()).toEqual([' D gone.txt', ' M tracked.txt', '?? new.txt']);
  expect(leaseOf(bare, workspaceId)).toEqual({ machine: machineB, epoch: 2, state: 'active' });
  expect(((await b.call('GET', `/threads/${side}/history`)).body as History).records).toHaveLength(sideRecords);

  const continued = await turn(b, models.b, thread.id, 1, '在 B 上的回合');
  const history = continued.request.history;
  expect(inputs(continued.request)).toContainEqual(expect.objectContaining({ text: '第一回合', source: 'human' }));
  expect(history).toContainEqual({ type: 'output', item: item('a-reply') });
  expect(history.filter((entry) => entry.type === 'notification' && entry.notification.id === notice.id)).toHaveLength(1);

  expect(((await a.call('POST', `/workspaces/${workspaceId}/lease/check`)).body as WorkspaceModel).workspace.status).toBe('transferred');
  expect((await a.call('POST', `/threads/${thread.id}/messages`, { id: 'on-frozen', text: '冻结后不该执行' })).status).toBe(409);
  // 本机还留着旧工作树时，流转回来之前要先归档旧记录。
  expect((await a.call('POST', `/workspaces/${workspaceId}/archive`, { force: true })).status).toBe(200);
  await Promise.all([a, b].map((k) => k.daemon.kite.replicas.sync()));
  expect(existsSync(join(b.home, 'replicas', workspaceId))).toBe(false);
  expect(JSON.parse(read(join(a.home, 'replicas', workspaceId, 'manifest.json')))).toMatchObject({ epoch: 2, machine: machineB });

  expect(await humans(a, thread.id)).toEqual(['第一回合']);
  expect((await handover(b, workspaceId)).status).toBe(200);
  const back = await restore(a, { project: projectId, workspaceId, from: machineB });
  expect(back.status).toBe(200);
  const home = (back.body as WorkspaceModel).workspace;
  expect(home).toMatchObject({ id: workspaceId, epoch: 3, status: 'open' });
  expect(leaseOf(bare, workspaceId)).toEqual({ machine: machineA, epoch: 3, state: 'active' });
  expect(await humans(a, thread.id)).toEqual(['第一回合', '在 B 上的回合']);
  const since = mark(a);
  expect((await a.call('POST', `/threads/${thread.id}/messages`, { id: 'back-home', text: '回到原机继续' })).status).toBe(200);
  const resumed = await models.a.call(3);
  writeFiles(home.cwd, { 'after.txt': '回来以后的改动\n' });
  resumed.response.complete();
  await a.waitEvent((e) => e.type === 'workspace.snapshot' && e.workspaceId === workspaceId && after(a, since)(e));
  const finished = await a.waitEvent((e) => e.type === 'harness' && e.threadId === thread.id && e.event.type === 'record'
    && e.event.record.type === 'turn.finished' && after(a, since)(e));
  expect(finished.type === 'harness' && finished.event.type === 'record' && finished.event.record.type === 'turn.finished'
    && finished.event.record.outcome).toEqual({ kind: 'completed' });
}, 5_000);

/*
 * 几个部分的配合：手动流转（POST /workspaces/:id/transfer）在源机上一步做完交接、目标还原、源机核对，跨两台 kited、
 * 经 Git 平台上 lease 的比较后更新。目标还原被拒（B 没登录线程所用的 ChatGPT）时源机撤回交接：工作区回到 open、lease 改回 A 的 active；
 * B 登录后的第二次流转能成功，说明撤回留下的状态让下一次交接、目标接管都走得通（lease 不归 A 时交接会被拒）。
 * 成功返回时 A 已核对并冻结，直接读本机记录，不经 lease/check。
 */
test('手动流转：目标没登录模型厂商时还原被拒，A 撤回交接、工作区回到 open、lease 回到 A；B 登录后再流转成功，返回时 A 已冻结、B 以 epoch 2 持有', async () => {
  const models = { a: new ManualModel(), b: new ManualModel() };
  const a = machine(models.a);
  const b = startKited(() => models.b, false, { catalogDelayMs: 0 });
  kiteds.push(b);
  await connect(a, b);
  const machineA = a.daemon.kite.store.machine.id;
  const machineB = b.daemon.kite.store.machine.id;
  remotes = startFakeGit();
  const remote = remotes.create(projectName());
  const { registered } = await project(a, { 'a.txt': '一\n' }, [b], remote);

  const thread = await createWorkspace(a, registered.checkout.id, '第一回合', 'harness');
  const workspaceId = thread.workspace.id;
  const first = await models.a.call(1);
  first.response.complete();
  await a.waitEvent((e) => e.type === 'idle' && e.threadId === thread.id);
  const transfer = () => a.call('POST', `/workspaces/${workspaceId}/transfer`, { to: machineB, operationId: crypto.randomUUID() });

  const refused = await transfer();
  expect(refused.status).toBeGreaterThanOrEqual(400);
  expect(await statusOf(a, workspaceId)).toBe('open');
  expect(leaseOf(remote.bare, workspaceId)).toEqual({ machine: machineA, epoch: 1, state: 'active' });

  chatgptLogin(b.home);
  const moved = await transfer();
  expect(moved.status).toBe(200);
  expect(moved.body).toMatchObject({ workspaceId, machine: machineB, epoch: 2 });
  expect(a.daemon.kite.store.workspace(workspaceId)?.status).toBe('transferred');
  expect(b.daemon.kite.store.workspace(workspaceId)).toMatchObject({ status: 'open', epoch: 2 });
}, 5_000);

/*
 * 几个部分的配合与 git：没有远程的根工作区交接，目标检出从源机的检出快进到源机现场的提交，沿用流转来的工作区 ID；
 * 目标装好后经 /handover/complete 通知源机，源机冻结记录、检出另得一个新的根工作区（目录不动）。
 * 撤回交接：交接停下了线程，撤回后工作区重新开放，线程能再起回合。
 */
test('没有远程的项目：A 现场提交后交出根工作区，B 的检出快进到这个提交并以同一 ID 接管，A 收到通知后冻结、检出另得新的根工作区；撤回交接后工作区重新开放能继续', async () => {
  const models = { a: new ManualModel(), b: new ManualModel() };
  const a = machine(models.a);
  const b = machine(models.b);
  await connect(a, b);
  const machineA = a.daemon.kite.store.machine.id;
  const { repo, registered, projectId } = await project(a, { 'a.txt': '一\n' }, [b]);
  const name = registered.checkout.path.split('/').pop()!;
  const cloned = await b.call('POST', '/checkouts', { project: projectId, path: join(b.root, name) });
  expect(cloned.status).toBe(200);
  const target = (cloned.body as WorkspaceModel).checkout;

  const root = registered.workspace;
  const started = await a.call('POST', `/workspaces/${root.id}/operations/agent.start`, { operationId: 'worker' });
  expect(started.status).toBe(200);
  const threadId = started.body.instanceId as string;
  await turn(a, models.a, threadId, 1, '在根工作区的回合');
  writeFiles(repo, { 'a.txt': '二\n' });
  const head = commitAll(repo, 'A 现场的提交');

  expect((await handover(a, root.id)).status).toBe(200);
  const taken = await restore(b, { project: projectId, workspaceId: root.id, from: machineA });
  expect(taken.status).toBe(200);
  expect((taken.body as WorkspaceModel).workspace).toMatchObject({ id: root.id, kind: 'root', epoch: 2, status: 'open', cwd: target.path });
  expect(git(target.path, 'rev-parse', 'HEAD')).toBe(head);
  expect(read(join(target.path, 'a.txt'))).toBe('二\n');
  expect(git(target.path, 'status', '--porcelain')).toBe('');
  expect(b.daemon.kite.store.rootWorkspaceModel(target.id)?.workspace.id).toBe(root.id);
  expect(await humans(b, threadId)).toEqual(['在根工作区的回合']);

  expect(await statusOf(a, root.id)).toBe('transferred');
  const fresh = a.daemon.kite.store.rootWorkspaceModel(registered.checkout.id)?.workspace;
  expect(fresh).toMatchObject({ kind: 'root', status: 'open', cwd: repo });
  expect(fresh?.id).not.toBe(root.id);

  expect((await handover(b, root.id)).status).toBe(200);
  expect(await statusOf(b, root.id)).toBe('handing_off');
  const cancelled = await b.call('POST', `/workspaces/${root.id}/handover/cancel`);
  expect(cancelled.status).toBe(200);
  expect((cancelled.body as WorkspaceModel).workspace.status).toBe('open');
  const resumed = await turn(b, models.b, threadId, 1, '撤回以后继续');
  expect(inputs(resumed.request).map((input) => input.text)).toEqual(['在根工作区的回合', '撤回以后继续']);
}, 5_000);

/**
 * 转发到 target 的代理，记下经过的副本增量页（POST /replica/:id 的回应）和各页所属的工作区，以及副本清单（GET /replica 的回应）。
 * holdPagesUntilListed 之后，副本页的回应扣住，等下一份清单答复出去才一起放行。
 */
function recordingProxy(target: string) {
  const pages: Array<{ workspaceId: string; page: ReplicaPage }> = [];
  const listings: ReplicaEntry[][] = [];
  let gate: Promise<void> | undefined;
  let open: (() => void) | undefined;
  const server = Bun.serve({
    hostname: '127.0.0.1', port: 0,
    async fetch(request) {
      const url = new URL(request.url);
      const body = request.method === 'GET' || request.method === 'HEAD' ? undefined : await request.arrayBuffer();
      let response: Response;
      try { response = await fetch(target + url.pathname + url.search, { method: request.method, headers: request.headers, body }); }
      catch { return new Response('连不上', { status: 502 }); }
      const text = await response.text();
      if (request.method === 'GET' && url.pathname === '/replica' && response.status === 200) {
        listings.push(JSON.parse(text) as ReplicaEntry[]);
        open?.();
      }
      if (request.method === 'POST' && url.pathname.startsWith('/replica/') && response.status === 200) {
        pages.push({ workspaceId: decodeURIComponent(url.pathname.slice('/replica/'.length)), page: JSON.parse(text) as ReplicaPage });
        await gate;
      }
      return new Response(text, { status: response.status, headers: { 'content-type': response.headers.get('content-type') ?? 'application/json' } });
    },
  });
  servers.push(server);
  return {
    url: `http://127.0.0.1:${server.port}`, pages, listings,
    holdPagesUntilListed() { gate = new Promise((resolve) => { open = resolve; }); },
  };
}

/*
 * 跟进方与执行设备的配合：跟进方按手上各文件的 {size, mtime, hash} 要增量，执行设备认出只长不改的 journal 是在原来末尾追加的，
 * 只发新增部分，跟进方写在原来的末尾；两边各自算的状态对不上时会退回整份重发，结果一样但每轮都传整份。
 * B 访问 A 都经一个记录代理，看 B 实际拿到的增量页。第一轮走定期跟进的入口（看清单上的摘要）；执行设备上清单的摘要
 * 几秒才重算一次，紧接着的第二轮可能还看不出变化，所以第二轮用交接时「补到末尾」的入口，不看摘要直接要增量。
 */
test('副本增量：A 上线程的 journal 增长后，B 补到末尾时只拿到从原来末尾开始的新增部分，副本里的 journal 与 A 的一致', async () => {
  const models = { a: new ManualModel(), b: new ManualModel() };
  const a = machine(models.a);
  const b = machine(models.b);
  const proxy = recordingProxy(a.url);
  a.candidates.push({ address: b.url, online: true });
  b.candidates.push({ address: proxy.url, online: true });
  await Promise.all([a, b].map((k) => k.daemon.kite.directory.refresh()));
  const { registered } = await project(a, { 'a.txt': '一\n' }, []);
  const thread = await createWorkspace(a, registered.checkout.id, '第一回合', 'harness');
  const workspaceId = thread.workspace.id;
  const first = await models.a.call(1);
  first.response.complete();
  await a.waitEvent((e) => e.type === 'idle' && e.threadId === thread.id);
  const journal = `sessions/${thread.id}/journal.jsonl`;
  const source = join(a.home, journal);
  const copy = join(b.home, 'replicas', workspaceId, journal);

  await b.daemon.kite.replicas.sync();
  const before = read(source);
  expect(read(copy)).toBe(before);
  const known = Buffer.byteLength(before);
  proxy.pages.splice(0);

  await turn(a, models.a, thread.id, 2, '第二回合', 'a-reply');
  const grown = read(source);
  expect(grown.startsWith(before)).toBe(true);
  expect(Buffer.byteLength(grown)).toBeGreaterThan(known);
  await b.daemon.kite.replicas.catchUp({ id: a.daemon.kite.store.machine.id, address: proxy.url }, workspaceId);
  const sent = proxy.pages.filter((entry) => entry.workspaceId === workspaceId).flatMap((entry) => entry.page.files)
    .filter((file) => file.path === journal);
  expect(sent.map((file) => file.offset)).toEqual([known]);
  expect(read(copy)).toBe(grown);
}, 5_000);

/*
 * 两条异步路径的并发。真实 bug（旧实现）：交接时的补到末尾（catchUp）与定期跟进的一轮各自拉同一工作区，按同一份本地情况
 * 要到同一段增量，按偏移追加的 journal 被追加了两次。代理扣住副本页的回应，等这一轮的清单答复出去才放行，让两条路径确实重叠。
 * 起初的副本经 catchUp 取，不经清单：执行设备上清单的摘要缓存几秒，先跟过一轮的话，紧接着的一轮看不出变化，不会去拉。
 */
test('定期跟进与补到末尾同时拉同一工作区：A 上的 journal 增长后两条一起跑完，副本里的 journal 与 A 的逐字节一致', async () => {
  const models = { a: new ManualModel(), b: new ManualModel() };
  const a = machine(models.a);
  const b = machine(models.b);
  const proxy = recordingProxy(a.url);
  a.candidates.push({ address: b.url, online: true });
  b.candidates.push({ address: proxy.url, online: true });
  await Promise.all([a, b].map((k) => k.daemon.kite.directory.refresh()));
  const { registered } = await project(a, { 'a.txt': '一\n' }, []);
  const thread = await createWorkspace(a, registered.checkout.id, '第一回合', 'harness');
  const workspaceId = thread.workspace.id;
  const first = await models.a.call(1);
  first.response.complete();
  await a.waitEvent((e) => e.type === 'idle' && e.threadId === thread.id);
  const journal = `sessions/${thread.id}/journal.jsonl`;
  const source = join(a.home, journal);
  const copy = join(b.home, 'replicas', workspaceId, journal);
  const holder = { id: a.daemon.kite.store.machine.id, address: proxy.url };
  const replicas = b.daemon.kite.replicas;

  await replicas.catchUp(holder, workspaceId);
  expect(read(copy)).toBe(read(source));
  const digest = replicas.store.state(workspaceId)?.digest;
  expect(digest).toEqual(expect.any(String));

  await turn(a, models.a, thread.id, 2, '第二回合', 'a-reply');
  const grown = read(source);
  expect(Buffer.byteLength(grown)).toBeGreaterThan(Buffer.byteLength(read(copy)));
  proxy.listings.splice(0);
  proxy.holdPagesUntilListed();
  await Promise.all([replicas.sync(), replicas.catchUp(holder, workspaceId)]);
  // 这一轮从清单上看到了变化，确实会去拉，不是只有 catchUp 在拉。
  const listed = proxy.listings.flat().find((entry) => entry.workspaceId === workspaceId);
  expect(listed?.digest).toEqual(expect.any(String));
  expect(listed?.digest).not.toBe(digest);
  expect(read(copy)).toBe(grown);
}, 5_000);

/*
 * 几个部分的配合：B 有这个项目的检出时，副本跟进顺带从 A 的检出取快照链与工作区分支；A 停掉后 B 不联系 A，
 * 只用手上的副本强制接管（epoch 2）。没有远程的项目没有 lease，A 重启后从目录摘要里看到 B 以更高 epoch 持有，核对后冻结本地记录。
 */
test('强制接管：A 停掉后 B 用手上的副本接管，工作树有 A 回合里的改动、历史在；A 重启后核对，从 B 的目录摘要看到更高 epoch，冻结本地记录', async () => {
  const models = { a: new ManualModel(), b: new ManualModel(), restarted: new ManualModel() };
  let a = machine(models.a);
  const b = machine(models.b);
  await connect(a, b);
  const machineB = b.daemon.kite.store.machine.id;
  const { registered, projectId } = await project(a, { 'a.txt': '一\n' }, [b]);
  const name = registered.checkout.path.split('/').pop()!;
  expect((await b.call('POST', '/checkouts', { project: projectId, path: join(b.root, name) })).status).toBe(200);

  const thread = await createWorkspace(a, registered.checkout.id, '第一回合', 'harness');
  const workspaceId = thread.workspace.id;
  const since = mark(a);
  const first = await models.a.call(1);
  writeFiles(thread.workspace.cwd, { 'work.txt': 'A 回合里写的\n' });
  first.response.complete();
  await a.waitEvent((e) => e.type === 'workspace.snapshot' && e.workspaceId === workspaceId && after(a, since)(e));
  await a.waitEvent((e) => e.type === 'idle' && e.threadId === thread.id);
  await b.daemon.kite.replicas.sync();
  await a.halt();

  const taken = await restore(b, { project: projectId, workspaceId, force: true });
  expect(taken.status).toBe(200);
  const onB = (taken.body as WorkspaceModel).workspace;
  expect(onB).toMatchObject({ id: workspaceId, epoch: 2, status: 'open' });
  expect(read(join(onB.cwd, 'work.txt'))).toBe('A 回合里写的\n');
  expect(await humans(b, thread.id)).toEqual(['第一回合']);

  a = await restart(a, models.restarted);
  await connect(a, b);
  await synced(a, () => a.daemon.kite.directory.entries().some((entry) => entry.id === machineB
    && entry.snapshot?.workspaces.some((w) => w.id === workspaceId && w.epoch === 2 && w.status === 'open')), 'A 看到 B 以 epoch 2 持有');
  expect(((await a.call('POST', `/workspaces/${workspaceId}/lease/check`)).body as WorkspaceModel).workspace.status).toBe('transferred');
  expect(await statusOf(b, workspaceId)).toBe('open');
}, 5_000);

/** B 的检出里有 fail 标记时，等到放行文件 go 出现后失败退出；没有标记时直接成功。 */
const FAILING_SETUP = [
  '#!/bin/sh',
  '[ -e "$KITE_MAIN_DIR/fail" ] || exit 0',
  'i=0; while [ ! -e "$KITE_MAIN_DIR/go" ] && [ $i -lt 300 ]; do sleep 0.01; i=$((i+1)); done',
  'exit 1',
  '',
].join('\n');

/*
 * 还原与后台轮询两个流程的交错。真实 bug（旧实现）：还原中工作区记录已以 preparing 导入本机，这时跟一轮副本，
 * 轮询把它当成本机已持有而删掉副本；之后 setup 失败、还原回滚，副本没了，源机丢失后强制接管时会话记录永久丢失。
 * 第一次从在线的 A 还原，这一轮照常向 A 要清单；setup 在 B 上等放行文件，测试在它结束之前（记录已导入）跟一轮副本，再放行让它失败。
 */
test('还原中 setup 失败回滚后副本还在：还原期间跟一轮副本不删它；A 停掉后去掉失败原因，B 用这份副本强制接管，历史在', async () => {
  const models = { a: new ManualModel(), b: new ManualModel() };
  const a = machine(models.a);
  const b = machine(models.b);
  await connect(a, b);
  const machineA = a.daemon.kite.store.machine.id;
  const { registered, projectId } = await project(a, { 'a.txt': '一\n', '.kite/setup': FAILING_SETUP }, [b]);
  const checkoutB = join(b.root, registered.checkout.path.split('/').pop()!);
  expect((await b.call('POST', '/checkouts', { project: projectId, path: checkoutB })).status).toBe(200);

  const thread = await createWorkspace(a, registered.checkout.id, '第一回合', 'harness');
  const workspaceId = thread.workspace.id;
  const first = await models.a.call(1);
  first.response.complete();
  await a.waitEvent((e) => e.type === 'idle' && e.threadId === thread.id);
  const replicas = b.daemon.kite.replicas;
  await replicas.sync();
  expect(replicas.store.state(workspaceId)?.complete).toBe(true);
  expect((await handover(a, workspaceId)).status).toBe(200);

  writeFiles(checkoutB, { fail: '' });
  expect(b.daemon.kite.store.workspace(workspaceId)).toBeNull();
  const failing = restore(b, { project: projectId, workspaceId, from: machineA });
  await until(() => b.daemon.kite.store.workspace(workspaceId), 'B 导入工作区记录');
  await replicas.sync();
  writeFiles(checkoutB, { go: '' });
  const failed = await failing;
  expect(failed.status).toBeGreaterThanOrEqual(400);
  expect(b.daemon.kite.store.workspace(workspaceId)).toBeNull();
  expect(existsSync(join(b.home, 'replicas', workspaceId, 'state.json'))).toBe(true);
  expect(replicas.store.state(workspaceId)?.complete).toBe(true);

  await a.halt();
  rmSync(join(checkoutB, 'fail'));
  const taken = await restore(b, { project: projectId, workspaceId, force: true });
  expect(taken.status).toBe(200);
  expect((taken.body as WorkspaceModel).workspace).toMatchObject({ id: workspaceId, epoch: 2, status: 'open' });
  expect(await humans(b, thread.id)).toEqual(['第一回合']);
}, 5_000);
