/**
 * 没有远程的项目在几台 kited 之间的接管（docs/Line与工作区流转.md「目标还原」「强制接管」）：几台本进程 kited 互为组网对端
 * （harness 的 connect），项目登记与目录摘要随账号级数据同步；各机检出互为远程，副本由跟进方的 kite.replicas.sync() 立即跟一轮。
 * 目标机的检出都显式建在它自己的临时根目录下，不 clone 到共用 HOME 的 ~/code。基本的交接、还原与强制接管在 transfer.test.ts，
 * 这里是 review 复现过的几处缺陷的回归。一次接管要起几十个 git 进程，单个在 0.5 到 0.9 秒，守小测试 1 秒的预算：
 * 不跑 .kite/setup（沙箱里起一次约 0.3 秒），两台同时来接时两次还原并行。
 */
import { afterEach, expect, test } from 'bun:test';
import { join } from 'node:path';
import type { Checkout, WorkspaceModel } from '../../src/model.ts';
import { after, chatgptLogin, connect, createWorkspace, type Kited, mark, registerCheckout, startKited, synced } from '../harness.ts';
import { deferred, ManualModel } from '../harness-loop.ts';
import { git, newRepo, read, writeFiles } from '../util.ts';

const kiteds: Kited[] = [];
const servers: Array<{ stop(force?: boolean): unknown }> = [];
afterEach(async () => {
  for (const k of kiteds.splice(0)) await k.stop();
  for (const server of servers.splice(0)) void server.stop(true);
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
