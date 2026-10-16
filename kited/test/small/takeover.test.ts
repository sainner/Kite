/**
 * 工作区执行权与接管（docs/Line与工作区流转.md「工作区的稳定身份与执行权」「目标还原」「强制接管」），分两段：
 * 一、没有远程的项目在几台 kited 之间的接管：几台本进程 kited 互为组网对端（harness 的 connect），项目登记与目录摘要随账号级数据
 *    同步；各机检出互为远程，副本由跟进方的 kite.replicas.sync() 立即跟一轮。目标机的检出都显式建在它自己的临时根目录下，
 *    不 clone 到共用 HOME 的 ~/code。基本的交接、还原与强制接管在 transfer.test.ts，这里是 review 复现过的几处缺陷的回归，
 *    以及工作机睡眠前的自动换机（「工作区流转」的睡眠前换机；kite-net 的系统睡眠预告在测试里起不来，直接调 kite.leaving，
 *    目标机没有检出时 clone 到 HOME 下的 ~/code/<项目名>，测试结束时删掉）。
 *    一次接管要起几十个 git 进程，单个在 0.5 到 0.9 秒，守小测试 1 秒的预算：不跑 .kite/setup（沙箱里起一次约 0.3 秒），
 *    两台同时来接时两次还原并行。
 * 二、远程 lease 的比较后更新、联网核对后的冻结，以及工作区表加上 epoch 与 transferred 的旧库迁移。
 */
import { Database } from 'bun:sqlite';
import { afterEach, expect, test } from 'bun:test';
import { randomUUID } from 'node:crypto';
import { rmSync } from 'node:fs';
import { join } from 'node:path';
import type { Input, ModelRequest } from '../../src/harness/types.ts';
import type { Checkout, Workspace, WorkspaceModel } from '../../src/model.ts';
import { Store } from '../../src/store.ts';
import type { History } from '../../src/transcript/protocol.ts';
import { readLease, remoteLeases, writeLease } from '../../src/workspace/lease.ts';
import { type FakeGit, startFakeGit } from '../fake-git.ts';
import {
  after, chatgptLogin, connect, createWorkspace, type Kited, listSnapshots, mark, registerCheckout, startKited, synced,
} from '../harness.ts';
import { deferred, ManualModel } from '../harness-loop.ts';
import { git, gitOk, newDir, newRepo, read, useTemp, writeFiles } from '../util.ts';

const kiteds: Kited[] = [];
const servers: Array<{ stop(force?: boolean): unknown }> = [];
const dirs: string[] = [];
/** lease 一段：单台 kited 与 Git 平台替身。 */
let kited: Kited | undefined;
let remotes: FakeGit | undefined;
afterEach(async () => {
  for (const k of kiteds.splice(0)) await k.stop();
  for (const server of servers.splice(0)) void server.stop(true);
  for (const dir of dirs.splice(0)) rmSync(dir, { recursive: true, force: true });
  await kited?.stop();
  kited = undefined;
  remotes?.stop();
  remotes = undefined;
});

/** 一台 kited：手动模型、目录摘要不合批（别的工作机马上看到检出与工作区的变化）、已登录 ChatGPT。 */
function machine(model: ManualModel): Kited {
  const k = startKited(() => model, false, { catalogDelayMs: 0 });
  kiteds.push(k);
  chatgptLogin(k.home);
  return k;
}

/**
 * A 上登记一个没有远程的项目，等 others 同步到这条登记和 A 有检出的目录摘要，再在 others 各自的根目录下从 A 的检出 clone 一份。
 * withCheckout 为 false 的不 clone。
 */
async function project(a: Kited, files: Record<string, string>, others: Kited[], withCheckout = true) {
  const name = `takeover-${crypto.randomUUID().slice(0, 8)}`;
  const repo = newRepo(a.root, name, files, null);
  const registered = await registerCheckout(a, repo);
  const projectId = registered.project.id;
  const machineA = a.daemon.kite.store.machine.id;
  const checkouts = new Map<Kited, Checkout>();
  await Promise.all(others.map(async (k) => {
    await synced(k, () => k.daemon.kite.registry.get(projectId) && k.daemon.kite.directory.entries()
      .some((entry) => entry.id === machineA && entry.snapshot?.checkouts.some((checkout) => checkout.projectId === projectId)),
    '同步到 A 登记的项目与检出');
    if (withCheckout) checkouts.set(k, await clone(k, projectId, name));
  }));
  return { repo, name, registered, projectId, checkouts };
}

/** 在 k 的根目录下从有检出的工作机 clone 这个没有远程的项目。 */
async function clone(k: Kited, projectId: string, name: string): Promise<Checkout> {
  const cloned = await k.call('POST', '/checkouts', { project: projectId, path: join(k.root, name) });
  if (cloned.status !== 200) throw new Error(`clone 失败：${cloned.status} ${JSON.stringify(cloned.body)}`);
  return (cloned.body as WorkspaceModel).checkout;
}

/** k 上的线程跑完一个回合：发消息，模型第 number 次调用期间往 cwd 写 files，结束后等这个工作区存好快照、线程回到空闲。 */
async function turnWriting(k: Kited, model: ManualModel, workspace: { id: string; cwd: string }, threadId: string, number: number,
  text: string | undefined, files: Record<string, string>) {
  const since = mark(k);
  if (text !== undefined) {
    const sent = await k.call('POST', `/threads/${threadId}/messages`, { id: crypto.randomUUID(), text });
    if (sent.status !== 200) throw new Error(`发消息失败：${sent.status} ${JSON.stringify(sent.body)}`);
  }
  const call = await model.call(number);
  writeFiles(workspace.cwd, files);
  call.response.complete();
  await k.waitEvent((e) => e.type === 'workspace.snapshot' && e.workspaceId === workspace.id && after(k, since)(e));
  await k.waitEvent((e) => e.type === 'idle' && e.threadId === threadId && after(k, since)(e));
}

const restore = (k: Kited, body: { project: string; workspaceId: string; from?: string; force?: boolean }) =>
  k.call('POST', '/workspaces/restore', { operationId: crypto.randomUUID(), ...body });
const statusOf = async (k: Kited, workspaceId: string) => ((await k.call('GET', `/workspaces/${workspaceId}`)).body as WorkspaceModel).workspace.status;

/**
 * 原样转发到 target 的代理（请求与回应按字节转发，Git 的拉取也能经过它），只扣住交出通知（POST /workspaces/:id/handover/complete）：
 * 按通知里写的接收方分开，arrived(machine) 在那台的通知第一次到达时兑现；release(machine) 之前它的通知都等着，之后直接转发。
 */
function holdingProxy(target: string) {
  const gates = new Map<string, { arrived: ReturnType<typeof deferred<void>>; released: ReturnType<typeof deferred<void>> }>();
  const gate = (machine: string) => {
    let found = gates.get(machine);
    if (!found) gates.set(machine, found = { arrived: deferred(), released: deferred() });
    return found;
  };
  const server = Bun.serve({
    hostname: '127.0.0.1', port: 0,
    async fetch(request) {
      const url = new URL(request.url);
      const body = request.method === 'GET' || request.method === 'HEAD' ? undefined : await request.arrayBuffer();
      if (body && request.method === 'POST' && /^\/workspaces\/[^/]+\/handover\/complete$/.test(url.pathname)) {
        const held = gate(JSON.parse(new TextDecoder().decode(body)).machine);
        held.arrived.resolve();
        await held.released.promise;
      }
      let response: Response;
      try { response = await fetch(target + url.pathname + url.search, { method: request.method, headers: request.headers, body, decompress: false }); }
      catch { return new Response('连不上', { status: 502 }); }
      const headers = new Headers(response.headers);
      headers.delete('content-length');
      return new Response(await response.arrayBuffer(), { status: response.status, headers });
    },
  });
  servers.push(server);
  return {
    url: `http://127.0.0.1:${server.port}`,
    arrived: (machine: string) => gate(machine).arrived.promise,
    release: (machine: string) => gate(machine).released.resolve(),
  };
}

/*
 * 两台目标机同时接同一次交接的时序，与源机冻结的配合。真实 bug（旧实现）：没有远程的项目交出时源机只核对 epoch，
 * 已交出的再收到通知照样成功，B、C 都拿着 A 交接中的副本来接时两边都返回 200，同一工作区在两台上同时以 epoch 2 开放。
 * 要两台都过了「源机仍在交接中」的核对才看得出：B、C 经一个代理访问 A，同时来接；代理扣住两边的交出通知
 * （这时两边都已核对、导入、存好快照），先放 C 的过去，C 接管后再放 B 的。只认一台与工作区种类无关，交的是 A 检出的根工作区，
 * 不用先建工作树、跑回合；B 回滚后本机检出原来的根工作区还在。
 */
test('没有远程的项目交给两台：B、C 都过了核对，先通知到的 C 以 epoch 2 接管根工作区，B 通知被拒、回滚后本机不留这个工作区，A 冻结；A 只认 C 重发的交出通知', async () => {
  const models = { a: new ManualModel(), b: new ManualModel(), c: new ManualModel() };
  const a = machine(models.a);
  const b = machine(models.b);
  const c = machine(models.c);
  const proxy = holdingProxy(a.url);
  a.candidates.push({ address: b.url, online: true }, { address: c.url, online: true });
  b.candidates.push({ address: proxy.url, online: true }, { address: c.url, online: true });
  c.candidates.push({ address: proxy.url, online: true }, { address: b.url, online: true });
  await Promise.all([a, b, c].map((k) => k.daemon.kite.directory.refresh()));
  const machineA = a.daemon.kite.store.machine.id;
  const machineB = b.daemon.kite.store.machine.id;
  const machineC = c.daemon.kite.store.machine.id;
  const { registered, projectId, checkouts } = await project(a, { 'a.txt': '一\n' }, [b, c]);
  const workspaceId = registered.workspace.id;
  expect((await a.call('POST', `/workspaces/${workspaceId}/handover`, {})).status).toBe(200);

  const late = restore(b, { project: projectId, workspaceId, from: machineA });
  const early = restore(c, { project: projectId, workspaceId, from: machineA });
  await Promise.all([proxy.arrived(machineB), proxy.arrived(machineC)]);
  for (const k of [b, c]) expect(k.daemon.kite.store.workspace(workspaceId)?.status).toBe('preparing');
  proxy.release(machineC);
  const taken = await early;
  expect(taken.status).toBe(200);
  expect((taken.body as WorkspaceModel).workspace).toMatchObject({ id: workspaceId, kind: 'root', epoch: 2, status: 'open', cwd: checkouts.get(c)!.path });
  proxy.release(machineB);
  const refused = await late;
  expect(refused.status).toBe(409);
  expect(b.daemon.kite.store.workspace(workspaceId)).toBeNull();
  expect(b.daemon.kite.store.rootWorkspaceModel(checkouts.get(b)!.id)?.workspace).toMatchObject({ status: 'open', epoch: 1 });
  expect(c.daemon.kite.store.workspace(workspaceId)).toMatchObject({ epoch: 2, status: 'open' });
  expect(await statusOf(a, workspaceId)).toBe('transferred');

  // 目标的回应丢失时会再通知一次：交给的那台重发照样成功，换一台来发拒绝。
  const complete = (to: string) => a.call('POST', `/workspaces/${workspaceId}/handover/complete`, { epoch: 1, machine: to });
  expect((await complete(machineC)).status).toBe(200);
  expect((await complete(machineB)).status).toBe(409);
}, 5_000);

/*
 * git 的实际效果与副本跟进的配合：根工作区的快照链经副本跟进取到 B 的检出，强制接管时用最后一个快照的树还原源机没提交的现场。
 * 真实 bug（旧实现）：强制接管根工作区只把 B 的检出快进到源机的 HEAD，不看快照，返回成功但 A 回合里改的文件回到原样、新加的文件不在。
 */
test('强制接管根工作区：A 回合里改了已有文件、新加了文件没提交，A 停掉后 B 用副本接管，检出里改动和新文件都在、HEAD 不变', async () => {
  const models = { a: new ManualModel(), b: new ManualModel() };
  const a = machine(models.a);
  const b = machine(models.b);
  await connect(a, b);
  const { repo, registered, projectId, checkouts } = await project(a, { 'a.txt': '一\n' }, [b]);
  const target = checkouts.get(b)!;
  const head = git(target.path, 'rev-parse', 'HEAD');
  expect(git(repo, 'rev-parse', 'HEAD')).toBe(head);

  const root = registered.workspace;
  const started = await a.call('POST', `/workspaces/${root.id}/operations/agent.start`, { operationId: 'worker' });
  expect(started.status).toBe(200);
  const threadId = started.body.instanceId as string;
  await turnWriting(a, models.a, root, threadId, 1, '在根工作区的回合', { 'a.txt': '二\n', 'new.txt': '新增未跟踪\n' });
  await b.daemon.kite.replicas.sync();
  expect(b.daemon.kite.replicas.store.state(root.id)?.complete).toBe(true);
  await a.halt();

  const taken = await restore(b, { project: projectId, workspaceId: root.id, force: true });
  expect(taken.status).toBe(200);
  expect((taken.body as WorkspaceModel).workspace).toMatchObject({ id: root.id, kind: 'root', epoch: 2, status: 'open', cwd: target.path });
  expect(read(join(target.path, 'a.txt'))).toBe('二\n');
  expect(read(join(target.path, 'new.txt'))).toBe('新增未跟踪\n');
  expect(git(target.path, 'rev-parse', 'HEAD')).toBe(head);
  expect(git(target.path, 'status', '--porcelain').split('\n').sort()).toEqual([' M a.txt', '?? new.txt']);
}, 5_000);

/*
 * 副本跟进与之后才建的检出的配合：副本的文件跟完时 B 还没有检出，快照链与工作区分支没处放；B 后来 clone 了检出，
 * 下一轮跟进时 A 上的工作区没变（摘要相同），也要补取这些引用。
 * 真实 bug（旧实现）：摘要没变就不再拉，B 始终没有工作区分支，A 丢失后强制接管 409「副本里没有这个工作区的分支」。
 */
test('副本跟完后 B 才 clone 检出：下一轮跟进补取工作区分支与快照链，A 停掉后 B 能强制接管独立工作区、有 A 回合里的改动', async () => {
  const models = { a: new ManualModel(), b: new ManualModel() };
  const a = machine(models.a);
  const b = machine(models.b);
  await connect(a, b);
  const { name, registered, projectId } = await project(a, { 'a.txt': '一\n' }, [b], false);

  const thread = await createWorkspace(a, registered.checkout.id, '第一回合', 'harness');
  const workspaceId = thread.workspace.id;
  await turnWriting(a, models.a, thread.workspace, thread.id, 1, undefined, { 'work.txt': 'A 回合里写的\n' });
  const replicas = b.daemon.kite.replicas;
  await replicas.sync();
  expect(replicas.store.state(workspaceId)?.complete).toBe(true);
  expect(b.daemon.kite.store.checkouts(projectId)).toEqual([]);

  await clone(b, projectId, name);
  await replicas.sync();
  await a.halt();

  const taken = await restore(b, { project: projectId, workspaceId, force: true });
  expect(taken.status).toBe(200);
  const onB = (taken.body as WorkspaceModel).workspace;
  expect(onB).toMatchObject({ id: workspaceId, kind: 'worktree', epoch: 2, status: 'open' });
  expect(read(join(onB.cwd, 'work.txt'))).toBe('A 回合里写的\n');
}, 5_000);

const inputs = (request: ModelRequest) => request.history.flatMap((entry) => entry.type === 'input' ? [entry.input] : []);

/*
 * 几个部分的配合：按目标机的 /environment 选机器、打断正在工作的线程并收回排队的输入、交接、目标机还原（没有远程的项目，
 * 目标机从源机的检出 clone）、源机收到通知后冻结；接管后在目标机上先补一条 kite 来源的说明接着做被打断的回合，
 * 再把排队的输入按原来的正文、来源与经由重发。排队的输入在源机的 journal 里已记为收到（随后被打断收回），副本把它带到了目标机；
 * harness 按输入 ID 永久去重，原 ID 重发会被吞，所以重发换新 ID，这里只认正文与来源。
 */
test('睡眠前自动换机：打开自动换机的项目里正在工作的工作区交给 B，B 上的线程先收到 kite 来源的继续说明，再收到正文与来源相同的排队输入且只一次，A 的记录冻结', async () => {
  const models = { a: new ManualModel(), b: new ManualModel() };
  const [a, b] = [models.a, models.b].map((model) => {
    const k = startKited(() => model, false, { catalogDelayMs: 0 });
    kiteds.push(k);
    chatgptLogin(k.home);
    return k;
  }) as [Kited, Kited];
  await connect(a, b);
  const name = `leaving-${crypto.randomUUID().slice(0, 8)}`;
  // B 没有检出，还原时 clone 到 HOME 下的 ~/code/<项目名>。
  dirs.push(join(process.env.HOME!, 'code', name));
  const registered = await registerCheckout(a, newRepo(a.root, name, { 'a.txt': '一\n' }, null));
  const projectId = registered.project.id;
  const machineA = a.daemon.kite.store.machine.id;
  await synced(b, () => b.daemon.kite.registry.get(projectId) && b.daemon.kite.directory.entries()
    .some((entry) => entry.id === machineA && entry.snapshot?.checkouts.some((checkout) => checkout.projectId === projectId)),
  'B 同步到 A 登记的项目与检出');
  expect((await a.call('PUT', `/project-registry/${projectId}/settings`, { autoHandover: true })).status).toBe(200);
  const thread = await createWorkspace(a, registered.checkout.id, '第一回合', 'harness');
  const workspaceId = thread.workspace.id;
  const working = await models.a.call(1);
  const queued: Input = { id: 'queued-input', text: '排队等着的输入', source: 'human' };
  expect((await a.call('POST', `/threads/${thread.id}/messages`, { id: queued.id, text: queued.text })).status).toBe(200);

  await a.daemon.kite.leaving(Date.now() + 10_000);
  expect(working.signal.aborted).toBe(true);
  expect(((await a.call('GET', `/workspaces/${workspaceId}`)).body as WorkspaceModel).workspace.status).toBe('transferred');
  expect(b.daemon.kite.store.workspace(workspaceId)).toMatchObject({ epoch: 2, status: 'open' });

  const resumed = await models.b.call(1);
  const first = inputs(resumed.request);
  const note = first.findIndex((input) => input.source === 'kite');
  expect(note).toBeGreaterThan(first.findIndex((input) => input.text === '第一回合'));
  const same = (input: Input) => input.text === queued.text && input.source === queued.source;
  // 还原返回前说明与排队的输入都已发出：排队的输入要么赶上了这次请求，要么等在这个还没结束的回合后面。
  const included = first.filter(same);
  const waiting = ((await b.call('GET', `/threads/${thread.id}/history`)).body as History).pending.filter(same);
  expect(included.length + waiting.length).toBe(1);
  let delivered = resumed;
  if (!included.length) {
    resumed.response.complete();
    delivered = await models.b.call(2);
  }
  const deliveredInputs = inputs(delivered.request);
  expect(deliveredInputs.filter(same)).toHaveLength(1);
  expect(deliveredInputs.findIndex(same)).toBeGreaterThan(deliveredInputs.findIndex((input) => input.source === 'kite'));
  expect(models.a.calls.values).toHaveLength(1);
}, 1_000);

// ---- 远程 lease 与旧库迁移 ----

const temp = useTemp();

/** 只用来写对象和推送的空仓库，代表另一台工作机上的检出。 */
function emptyRepo(parent: string, name: string): string {
  const dir = newDir(parent, name);
  git(dir, 'init', '-q');
  return dir;
}

/*
 * 几条 git 命令合起来的效果：lease 提交经 push --force-with-lease 写到远程，远程按预期的旧值比较后更新。
 * 两处同时创建、拿过期的值接管、源机在被接管后撤回交接，都只能有符合预期的一方成功。
 */
test('lease 比较后更新：同时创建只有一方成功，拿过期的值接管被拒，拿当前值接管成功后旧持有者撤回被拒', async () => {
  const root = temp('lease-');
  const remote = join(root, 'remote.git');
  git(root, 'init', '-q', '--bare', remote);
  const access = { url: remote, env: {} };
  const repos = { source: emptyRepo(root, 'source'), target: emptyRepo(root, 'target') };
  const workspaceId = randomUUID();

  const created = await Promise.all((['source', 'target'] as const).map(async (machine) =>
    ({ machine, result: await writeLease(repos[machine], workspaceId, { machine, epoch: 1, state: 'active' }, null, access) })));
  expect(created.map((entry) => entry.result.status).sort()).toEqual(['conflict', 'written']);
  const winner = created.find((entry) => entry.result.status === 'written')!;
  const holder = winner.machine;
  const taker = holder === 'source' ? 'target' : 'source';
  const first = (winner.result as { commit: string }).commit;
  expect((await remoteLeases(repos[taker], access)).get(workspaceId)).toBe(first);
  expect(await readLease(repos[taker], workspaceId, first, access)).toEqual({ machine: holder, epoch: 1, state: 'active' });

  const handing = await writeLease(repos[holder], workspaceId, { machine: holder, epoch: 1, state: 'handing_off' }, first, access);
  expect(handing.status).toBe('written');
  const takeover = { machine: taker, epoch: 2, state: 'active' } as const;
  expect((await writeLease(repos[taker], workspaceId, takeover, first, access)).status).toBe('conflict');
  const current = (await remoteLeases(repos[taker], access)).get(workspaceId)!;
  expect(current).toBe((handing as { commit: string }).commit);
  const taken = await writeLease(repos[taker], workspaceId, takeover, current, access);
  expect(taken.status).toBe('written');

  expect((await writeLease(repos[holder], workspaceId, { machine: holder, epoch: 1, state: 'active' }, current, access)).status)
    .toBe('conflict');
  const final = (await remoteLeases(repos[holder], access)).get(workspaceId)!;
  expect(final).toBe((taken as { commit: string }).commit);
  expect(await readLease(repos[holder], workspaceId, final, access)).toEqual(takeover);
}, 1000);

/*
 * 几个部分的配合：项目远程上的 lease（ls-remote 与经 http-backend 取回）、线程停止、快照、插件关闭与工作区登记。
 * 别的机器以更高 epoch 接管后，本机核对要停下运行中的线程、把本机多出的改动存成快照、冻结记录；
 * 根工作区冻结后同一检出目录要另有一个可用的根工作区。独立工作区走同一条冻结路径，只少了另建根工作区。
 */
test('别的机器以更高 epoch 接管根工作区后核对执行权：运行中的线程停下、发送 409、本机改动存成快照，检出另得一个 open 的根工作区', async () => {
  const model = new ManualModel();
  kited = startKited(() => model);
  const kk = kited;
  remotes = startFakeGit();
  const remote = remotes.create('project');
  const repo = newRepo(kk.root, 'project', { 'base.txt': '原始\n' }, remote.url);
  const registered = await registerCheckout(kk, repo);
  const root = registered.workspace;
  const started = await kk.call('POST', `/workspaces/${root.id}/operations/agent.start`, { operationId: 'worker' });
  expect(started.status).toBe(200);
  const threadId = started.body.instanceId as string;
  expect((await kk.call('POST', `/threads/${threadId}/messages`, { id: 'kickoff', text: '保持运行' })).status).toBe(200);
  const running = await model.call(1);
  writeFiles(repo, { 'local.txt': '只在本机\n' });

  // 另一台工作机接管：直接推到远程的裸仓库。
  const other = emptyRepo(kk.root, 'other-machine');
  const access = { url: remote.bare, env: {} };
  const written = await writeLease(other, root.id, { machine: 'other-machine', epoch: 2, state: 'active' }, null, access);
  expect(written.status).toBe('written');
  // 启动时的那一轮核对若还没结束，第一次调用会并入它；第二次保证有一轮在 lease 写好之后开始。
  await kk.daemon.kite.syncLeases();
  await kk.daemon.kite.syncLeases();

  expect(((await kk.call('GET', `/workspaces/${root.id}`)).body as WorkspaceModel).workspace.status).toBe('transferred');
  expect(running.signal.aborted).toBe(true);
  const sent = await kk.call('POST', `/threads/${threadId}/messages`, { id: 'after-transfer', text: '继续' });
  expect(sent.status).toBe(409);
  expect(model.calls.values).toHaveLength(1);

  const snapshots = await listSnapshots(kk, root.id);
  expect(snapshots.some((snapshot) => gitOk(repo, 'cat-file', '-e', `${snapshot.commit}:local.txt`)
    && git(repo, 'show', `${snapshot.commit}:local.txt`) === '只在本机')).toBe(true);

  const listed = (await kk.call('GET', '/workspaces')).body as WorkspaceModel[];
  const roots = listed.filter((entry) => entry.checkout.id === registered.checkout.id && entry.workspace.kind === 'root'
    && entry.workspace.status === 'open');
  expect(roots).toHaveLength(1);
  expect(roots[0]!.workspace.id).not.toBe(root.id);
  expect(roots[0]!.workspace.cwd).toBe(root.cwd);
}, 1000);

/*
 * 依赖 SQLite 的改表行为：状态的 check 约束只能随表重建。旧表有引用它的实例、窗口和窗口请求，
 * 重建后外键要仍然成立，旧的唯一索引（根工作区、cwd）要换成允许冻结记录与新根工作区并存的新索引。
 */
test('旧库的工作区表迁移后数据与外键保留、epoch 为 1，可以冻结根工作区并为同一目录另建根工作区', () => {
  const root = temp('store-migration-');
  const path = join(root, 'kite.db');
  const old = new Database(path, { create: true, strict: true });
  old.exec(`
create table machine (
  slot integer primary key check (slot = 1), id text not null unique, name text not null, created_at integer not null
);
create table projects (id text primary key, name text not null, remote text not null, created_at integer not null);
create table checkouts (
  id text primary key, project_id text not null references projects(id), machine_id text not null references machine(id),
  path text not null, remote text not null, created_at integer not null,
  unique(machine_id, path)
);
create table workspaces (
  id text primary key, checkout_id text not null references checkouts(id), name text not null, cwd text not null unique,
  kind text not null check (kind in ('root', 'worktree')), branch text, base text,
  status text not null check (status in ('preparing', 'open', 'failed', 'archived')), created_at integer not null,
  check ((kind = 'root' and branch is null and base is null) or (kind = 'worktree' and branch is not null and base is not null))
);
create unique index root_workspace on workspaces(checkout_id) where kind = 'root';
create table plugin_instances (
  id text primary key, workspace_id text not null references workspaces(id), definition_id text not null, title text not null,
  config text not null, state text not null, presentation text not null check (presentation in ('window', 'inline', 'background')),
  status text not null check (status in ('open', 'archived')), created_at integer not null, origin text
);
create table workspace_windows (
  id text primary key, workspace_id text not null references workspaces(id),
  instance_id text not null, view_id text not null,
  state text not null check (state in ('open', 'closed')), created_at integer not null
);
create table window_requests (
  id text primary key, workspace_id text not null references workspaces(id),
  window_id text not null references workspace_windows(id), content text not null
);
insert into machine values (1, 'machine-1', '旧工作机', 1);
insert into projects values ('project-1', 'demo', 'example.test/demo', 1);
insert into checkouts values ('checkout-1', 'project-1', 'machine-1', '/work/demo', 'example.test/demo', 1);
insert into workspaces values ('root-1', 'checkout-1', '', '/work/demo', 'root', null, null, 'open', 1);
insert into workspaces values ('tree-1', 'checkout-1', '功能', '/kite/worktrees/tree-1', 'worktree', 'kite/tree-1', 'abc', 'open', 2);
insert into plugin_instances values ('instance-1', 'tree-1', 'kite.todo', '待办', '{}', '{}', 'window', 'open', 3, null);
insert into workspace_windows values ('window-1', 'tree-1', 'instance-1', 'main', 'open', 4);
insert into window_requests values ('request-1', 'tree-1', 'window-1', '{}');
`);
  old.close();

  let store = new Store(path);
  try {
    expect(store.machine.id).toBe('machine-1');
    expect(store.workspaces().map((w) => [w.id, w.epoch, w.status]).sort())
      .toEqual([['root-1', 1, 'open'], ['tree-1', 1, 'open']]);
    expect(store.instances('tree-1').map((instance) => instance.id)).toEqual(['instance-1']);
    expect(store.windows('tree-1').map((window) => window.id)).toEqual(['window-1']);
    expect(store.windowRequest('request-1')).toMatchObject({ workspaceId: 'tree-1', windowId: 'window-1' });

    const replacement: Workspace = { id: 'root-2', epoch: 1, checkoutId: 'checkout-1', name: '', cwd: '/work/demo', kind: 'root',
      branch: null, base: null, status: 'open', createdAt: 5 };
    store.freezeWorkspace('root-1', replacement);
    store.freezeWorkspace('tree-1');
    store.close();
    store = new Store(path);
    expect(store.workspaces().map((w) => [w.id, w.status]).sort())
      .toEqual([['root-1', 'transferred'], ['root-2', 'open'], ['tree-1', 'transferred']]);
    expect(store.rootWorkspaceModel('checkout-1')?.workspace.id).toBe('root-2');
    expect(store.instances('tree-1').map((instance) => instance.id)).toEqual(['instance-1']);
  } finally { store.close(); }
  const check = new Database(path);
  try { expect(check.query('pragma foreign_key_check').all()).toEqual([]); } finally { check.close(); }
});
