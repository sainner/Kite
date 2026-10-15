/**
 * Line（docs/Line与工作区流转.md「Line」）：两台本进程 kited，A 启用 Line，B 上有工作线程。
 * 跨机调用经 startKited 的 peers.directory 直达 B 的监听地址。Line 的项目是没有远程的项目，回合结束只在本机提交现场。
 * 每个测试换一个 HOME：Line 的项目固定在 ~/code/kite-line，同一进程里前一个测试删掉再建的同路径仓库会碰上
 * 快照模块按路径记住的私有索引目录（src/workspace/snapshots.ts 的 indexes），回合收尾失败。
 */
import { afterEach, expect, jest, spyOn, test } from 'bun:test';
import { existsSync, rmSync } from 'node:fs';
import { join } from 'node:path';
import type { AccountMachine } from '../../src/account-data/directory.ts';
import type { Envelope } from '../../src/events.ts';
import type { Input, Json, ModelItem, ModelRequest, ToolResult } from '../../src/harness/types.ts';
import { type Delegation, type InboxItem, type InboxRecord, monitorState } from '../../src/line/monitor.ts';
import type { WorkspaceModel } from '../../src/model.ts';
import type { DisplayState } from '../../src/transcript/protocol.ts';
import { after, type Kited, mark, registerCheckout, startKited, waitIdle } from '../harness.ts';
import { deferred, diskRecords, item, ManualModel } from '../harness-loop.ts';
import { connectSse } from '../sse.ts';
import { gitOk, makeTemp, newDir, newRepo, until, writeFiles } from '../util.ts';

const kiteds: Kited[] = [];
const dirs: string[] = [];
/** 测试前的 HOME，测试结束时换回。 */
const homes: string[] = [];
/** 停住的账号目录读取；测试失败时也先放行，否则停 kited 时会一直等 monitor 这一轮。 */
const holds: Array<() => void> = [];
/** 打开着的事件流；先关掉再停 kited，免得留下打开的 HTTP 连接。 */
const streams: Array<{ close(): Promise<void> }> = [];
afterEach(async () => {
  for (const release of holds.splice(0)) release();
  for (const stream of streams.splice(0)) await stream.close().catch(() => {});
  for (const k of kiteds.splice(0)) await k.stop();
  const home = homes.pop();
  if (home) process.env.HOME = home;
  for (const dir of dirs.splice(0)) rmSync(dir, { recursive: true, force: true });
});

const calledItem = (id: string, name: string, args: Json): ModelItem => ({ ...item(id, name), call: { id, name, arguments: args } });
const inputs = (request: ModelRequest) => request.history.flatMap((entry) => entry.type === 'input' ? [entry.input] : []);
const lineTools = ['line_status', 'line_handle', 'line_relay', 'line_control', 'line_workspace'];
const resultOf = (request: ModelRequest, callId: string): ToolResult | undefined => {
  const found = request.history.find((entry) => entry.type === 'tool_result' && entry.callId === callId);
  return found?.type === 'tool_result' ? found.result : undefined;
};

/** A 启用 Line，B 的根工作区里有一个工作代理（还没发消息）。directory 是 A 读到的账号目录，测试可以往里加工作机。 */
async function lineSetup() {
  const root = makeTemp('line-');
  dirs.push(root);
  homes.push(process.env.HOME!);
  process.env.HOME = newDir(root, 'home');
  const models = new Map<string, ManualModel>();
  const modelOf = (threadId: string) => {
    let model = models.get(threadId);
    if (!model) { model = new ManualModel(); models.set(threadId, model); }
    return model;
  };
  const directory: AccountMachine[] = [];
  let hold: { reached: () => void; released: Promise<void> } | undefined;
  const a = startKited((thread) => modelOf(thread.id), false, { peers: { directory: async () => {
    const current = hold;
    hold = undefined;
    if (current) { current.reached(); await current.released; }
    return directory;
  } } });
  /** 下一次读账号目录时停住，直到放行：monitor 一轮已读到 Line 实例、还没投递时插进别的事。 */
  const holdDirectory = () => {
    const reached = deferred();
    const released = deferred();
    hold = { reached: reached.resolve, released: released.promise };
    holds.push(released.resolve);
    return { reached: reached.promise, release: released.resolve };
  };
  const b = startKited((thread) => modelOf(thread.id), false);
  kiteds.push(a, b);
  const machineB = b.daemon.kite.store.machine.id;
  directory.push({ id: machineB, name: '工作机 B', online: true, address: b.url });

  const enabled = await a.call('POST', '/line');
  expect(enabled.status).toBe(200);
  const lineWorkspace = enabled.body as WorkspaceModel;
  const lineId = lineWorkspace.threads[0]!.instanceId;

  const registered = await registerCheckout(b, newRepo(b.root, 'work', { 'a.txt': 'a\n' }));
  const started = await b.call('POST', `/workspaces/${registered.workspace.id}/operations/agent.start`, { operationId: 'worker' });
  expect(started.status).toBe(200);
  const workId = started.body.instanceId as string;
  return { a, b, modelOf, holdDirectory, directory, machineA: a.daemon.kite.store.machine.id, machineB, lineWorkspace, lineId, workId };
}

async function send(k: Kited, threadId: string, id: string, text: string) {
  const sent = await k.call('POST', `/threads/${threadId}/messages`, { id, text });
  expect(sent.status).toBe(200);
}

/** 模型在第 number 次请求里调一个会挂起的工具（question 或必问动作），等 threadId 上挂出等待。 */
async function hang(k: Kited, model: ManualModel, threadId: string, number: number, callId: string, name: string, args: Json) {
  const call = await model.call(number);
  const since = mark(k);
  await call.response.emit({ type: 'item', item: calledItem(callId, name, args) });
  call.response.complete();
  const event = await k.waitEvent((e) => e.type === 'waiting' && e.threadId === threadId && !!e.waiting && after(k, since)(e));
  return { call, waiting: (event as Extract<Envelope, { type: 'waiting' }>).waiting! };
}

/** 工作线程在第 number 次请求里提一个单选问题，回合挂在这次调用上。 */
const ask = (k: Kited, model: ManualModel, threadId: string, number: number, text: string) =>
  hang(k, model, threadId, number, `ask-${number}`, 'question', { questions: [{ header: '问题', question: text, multiSelect: false, options: [
    { label: '甲', description: '选甲' }, { label: '乙', description: '选乙' },
  ] }] });

async function waitingOf(k: Kited, threadId: string) {
  const r = await k.call('GET', `/threads/${threadId}/state`);
  expect(r.status).toBe(200);
  return (r.body as DisplayState).waiting;
}

/** Line 的收件箱：Line 工作区里的 monitor 实例。 */
function inboxInstance(k: Kited) {
  const inbox = k.daemon.kite.lineInbox();
  if (!inbox) throw new Error('启用 Line 后应有收件箱');
  return inbox;
}

/** 收件箱实例上的操作，经 Line 工作区的操作入口，调用方是界面。 */
function inboxOperation(k: Kited, operation: 'read' | 'delegate' | 'dismiss' | 'hosting', args: Record<string, unknown> = {}) {
  const inbox = inboxInstance(k);
  const operationId = operation === 'read' ? {} : { operationId: crypto.randomUUID() };
  return k.call('POST', `/workspaces/${inbox.workspaceId}/operations/monitor.${operation}`, { ...operationId, instanceId: inbox.id, ...args });
}

/** Line 所在工作机上的收件箱。 */
async function inboxOf(k: Kited) {
  const r = await inboxOperation(k, 'read');
  expect(r.status).toBe(200);
  return r.body as { items: InboxItem[]; period?: { since: number; until?: number }; records: InboxRecord[]; delegation: Delegation };
}
const delegate = (k: Kited, item: string) => inboxOperation(k, 'delegate', { item });

/** 线程日志里收到的输入，按到达顺序；线程还没跑过时没有日志。 */
function received(k: Kited, threadId: string): Input[] {
  const journal = join(k.home, 'sessions', threadId, 'journal.jsonl');
  if (!existsSync(journal)) return [];
  return diskRecords(journal).flatMap((record) => record.type === 'input.received' ? [record.input] : []);
}

/** monitor 投给 Line 的输入（Kite 来源）的 ID。 */
const wakesOf = (k: Kited, lineId: string) => received(k, lineId).filter((input) => input.source === 'kite').map((input) => input.id);

/** 打开 A 的目录事件流并声明这台设备在关注。 */
async function watch(k: Kited, device: string) {
  const stream = await connectSse<Envelope>(`${k.url}/events?device=${device}`, k.daemon.kite.store.machine.id);
  streams.push(stream);
  return stream;
}
const focus = async (k: Kited, device: string, focused: boolean) => {
  const r = await k.call('PUT', '/attention', { device, focused });
  expect(r.status).toBe(200);
};
const attentionOf = async (k: Kited) => (await k.call('GET', '/attention')).body as { focusedDevices: string[]; awaySince?: number };

/*
 * 几个部分的配合：必问动作的等待挂在 Line 自己的工具调用上，HTTP 回应放行工具的 promise，批准这一次后才经跨机调用
 * 停下 B 上的线程；拒绝时工具返回 error、不停目标。必问动作不接受「记住」，这样的回应被拒后等待仍在。
 * monitor 读本机汇总时把这个等待也放进收件箱，但标为 Line 自己的请求，代处理被拒、按时段托管也不交出，否则「必问」形同虚设。
 * 托管设置经 HTTP 的操作入口往返：省略的字段不变，null 关闭，JSON 里的 null 与省略要分得开。
 */
test('Line 停止线程须经用户逐次批准：等待挂在 Line 的线程上并以 Line 自己的请求进收件箱、不能代处理也不随托管交出，记住被拒且等待仍在，拒绝时工具出错且目标不停，批准这一次后目标停下', async () => {
  const s = await lineSetup();
  const work = s.modelOf(s.workId);
  const line = s.modelOf(s.lineId);
  await send(s.b, s.workId, 'kickoff', '一直跑');
  const running = await work.call(1);
  const stop = { action: 'stop', machine: s.machineB, threadId: s.workId };
  const respond = (id: string, decision: string) => s.a.call('POST', `/threads/${s.lineId}/waiting/${id}`, { decision });

  await send(s.a, s.lineId, 'manage', '看看要不要停');
  const first = await hang(s.a, line, s.lineId, 1, 'stop-1', 'line_control', stop);
  // 不用带 expect.any 的 toMatchObject：Bun 1.3 会把收到的对象里匹配上的值改写成匹配器。
  if (first.waiting.kind !== 'approval') throw new Error(`应是审批：${JSON.stringify(first.waiting)}`);
  expect(first.waiting.tool).toBe('line_control');
  expect(first.waiting.target).not.toBe('');
  expect(first.waiting.reason).not.toBe('');
  expect(await waitingOf(s.a, s.lineId)).toEqual(first.waiting);
  expect(running.signal.aborted).toBe(false);

  await s.a.daemon.kite.monitor.check();
  const own = `waiting:${first.waiting.id}`;
  expect((await inboxOf(s.a)).items.map((entry) => [entry.id, entry.kind, entry.own])).toEqual([[own, 'approval', true]]);
  expect((await delegate(s.a, own)).status).toBe(409);
  expect((await inboxOf(s.a)).items.find((entry) => entry.id === own)?.delegated).toBeUndefined();
  const until = Date.now() + 60 * 60_000;
  expect((await inboxOperation(s.a, 'hosting', { until, timeoutMinutes: 15 })).body).toEqual({ until, timeoutMinutes: 15 });
  await s.a.daemon.kite.monitor.check();
  expect((await inboxOf(s.a)).items.find((entry) => entry.id === own)?.delegated).toBeUndefined();
  expect((await inboxOperation(s.a, 'hosting', { timeoutMinutes: null })).body).toEqual({ until });
  expect((await inboxOf(s.a)).delegation).toEqual({ until });
  expect((await inboxOperation(s.a, 'hosting', { until: null })).body).toEqual({});

  expect((await respond(first.waiting.id, 'remember')).status).toBe(400);
  expect(await waitingOf(s.a, s.lineId)).toEqual(first.waiting);
  expect(await respond(first.waiting.id, 'deny')).toEqual({ status: 200, body: { ok: true } });
  const denied = await line.call(2);
  expect(resultOf(denied.request, 'stop-1')?.status).toBe('error');
  expect(running.signal.aborted).toBe(false);
  expect(await waitingOf(s.a, s.lineId)).toBeUndefined();

  const second = await hang(s.a, line, s.lineId, 2, 'stop-2', 'line_control', stop);
  expect(second.waiting.id).not.toBe(first.waiting.id);
  expect(running.signal.aborted).toBe(false);
  expect(await respond(second.waiting.id, 'once')).toEqual({ status: 200, body: { ok: true } });
  const approved = await line.call(3);
  expect(resultOf(approved.request, 'stop-2')?.status).toBe('success');
  expect(running.signal.aborted).toBe(true);
  const since = mark(s.a);
  approved.response.complete();
  await waitIdle(s.a, s.lineId, since);
}, 1000);

/*
 * 几个部分的配合：A 的 monitor 跨机读 B 的汇总，把 B 上的提问放进收件箱而不唤醒 Line；用户点代处理才投一条 Kite 来源的输入；
 * Line 的 line_handle 经跨机调用（带 X-Kite-Source）写回 B 上那个等待，B 的工具结果写明由 Line 代答及理由；了结后事项
 * 移出收件箱，没有设备关注时用户算离开，这一项记进离开期间的记录；Line 回合结束后宿主在本机提交现场（没有远程，不推送）。
 * 工作线程能用 question，line_* 只声明给 Line 角色的实例；Line 的角色工具与默认的操作授权合起来，它能用 monitor_*。
 */
test('B 上的提问进 Line 收件箱而不唤醒 Line，用户点代处理才唤醒；Line 用 line_handle 答复后 B 的线程拿到 Line 代答的结果，事项移出收件箱进处理记录，Line 的现场提交到本机', async () => {
  const s = await lineSetup();
  const work = s.modelOf(s.workId);
  const line = s.modelOf(s.lineId);

  await send(s.b, s.workId, 'kickoff', '开始');
  const asked = await ask(s.b, work, s.workId, 1, '第一个问题');
  expect(asked.call.request.allowedTools).toContain('question');
  expect((asked.call.request.allowedTools ?? []).filter((tool) => tool.startsWith('line_'))).toEqual([]);
  const itemId = `waiting:${asked.waiting.id}`;
  await s.a.daemon.kite.monitor.check();
  const inbox = await inboxOf(s.a);
  expect(inbox.items.map((entry) => [entry.id, entry.kind, entry.machine.id, entry.thread?.id, entry.delegated])).toEqual([
    [itemId, 'question', s.machineB, s.workId, undefined],
  ]);
  expect(inbox.items[0]!.waiting).toEqual(asked.waiting);
  expect(line.calls.values).toHaveLength(0);
  expect(wakesOf(s.a, s.lineId)).toEqual([]);

  expect((await delegate(s.a, itemId)).status).toBe(200);
  const woke = await line.call(1);
  expect(woke.request.allowedTools).toEqual(expect.arrayContaining([...lineTools, 'question', 'monitor_start', 'monitor_list', 'monitor_stop']));
  const wake = inputs(woke.request).at(-1)!;
  expect(wake.source).toBe('kite');
  expect(wake.text).toContain(itemId);
  const reason = '这类选择用户一向选乙';
  await woke.response.emit({ type: 'item', item: calledItem('handle-1', 'line_handle', { item: itemId, answers: [{ selected: ['乙'] }], reason }) });
  woke.response.complete();

  const resumed = await work.call(2);
  const answered = resultOf(resumed.request, 'ask-1');
  expect(answered?.status).toBe('success');
  const output = JSON.parse(answered!.output) as { answers: Array<{ selected?: string[] }>; answeredBy?: string; reason?: string };
  expect([output.answers.map((answer) => answer.selected), output.answeredBy, output.reason]).toEqual([[['乙']], 'Line', reason]);
  const handled = await line.call(2);
  expect(resultOf(handled.request, 'handle-1')?.status).toBe('success');
  const settled = await inboxOf(s.a);
  expect(settled.items).toEqual([]);
  // 没有设备关注，用户算离开：Line 了结的事项进离开期间的记录，带决定与理由。
  expect(settled.records.map((record) => [record.item.id, record.outcome, record.decision, record.reason])).toEqual([[itemId, 'handled', 'answered', reason]]);

  writeFiles(s.lineWorkspace.workspace.cwd, { '.kite/memory/notes.md': 'Line 记下的事\n' });
  const since = mark(s.a);
  handled.response.complete();
  await waitIdle(s.a, s.lineId, since);
  await until(() => gitOk(s.lineWorkspace.checkout.path, 'cat-file', '-e', 'HEAD:.kite/memory/notes.md'), 'Line 的现场提交到本机', 900);
  // 了结的事项不再回到收件箱，也不再唤醒 Line。
  await s.a.daemon.kite.monitor.check();
  expect((await inboxOf(s.a)).items).toEqual([]);
  expect(wakesOf(s.a, s.lineId)).toHaveLength(1);
}, 1000);

/*
 * 几个部分的配合：用户点代处理立即起一轮 monitor，这一轮读汇总的途中 Line 的工作区开始交接、本地不再接受执行；
 * 交给 Line 的事项不能因此丢掉或算作已投递，撤回交接后下一轮投给 Line 且只投一次。投给 Line 后它的回合结束了
 * 还没了结的事项，monitor 下一轮交回用户；用户在 B 上直接回应后，下一轮读到等待已解除，事项移出收件箱，
 * 在离开期间的记录里记为自己解除。
 */
test('代处理遇上 Line 工作区开始交接时不投递也不丢，撤回交接后下一轮只投一次；Line 回合结束仍没了结的事项下一轮交回用户，用户在 B 上直接回应后移出收件箱', async () => {
  const s = await lineSetup();
  const work = s.modelOf(s.workId);
  const line = s.modelOf(s.lineId);
  // 交接中的工作区里 lineInbox() 找不到 Line，直接按 ID 读收件箱实例。
  const inboxId = inboxInstance(s.a).id;
  const state = () => monitorState(s.a.daemon.kite.store.instance(inboxId)!);
  const check = () => s.a.daemon.kite.monitor.check();

  await send(s.b, s.workId, 'kickoff', '开始');
  const asked = await ask(s.b, work, s.workId, 1, '用哪个方案');
  const itemId = `waiting:${asked.waiting.id}`;
  await check();

  // 这一轮读账号目录时停住，此时 Line 的工作区开始交接：交接把工作区置为 handing_off，本地拒绝新的执行。
  // 真走一遍交接要推材料、停线程，太慢；这里只改交接和撤回改的同一个字段。
  const lineWorkspaceId = s.lineWorkspace.workspace.id;
  const held = s.holdDirectory();
  expect((await delegate(s.a, itemId)).status).toBe(200);
  await held.reached;
  s.a.daemon.kite.store.setWorkspaceStatus(lineWorkspaceId, 'handing_off');
  held.release();
  await check();
  expect(wakesOf(s.a, s.lineId)).toEqual([]);
  expect(state().items[itemId]?.delegated?.by).toBe('user');

  // 撤回交接，工作区重新开放：下一轮投给 Line，再下一轮不重复投。
  s.a.daemon.kite.store.setWorkspaceStatus(lineWorkspaceId, 'open');
  await check();
  await check();
  const wakes = wakesOf(s.a, s.lineId);
  expect(wakes).toHaveLength(1);
  expect(received(s.a, s.lineId).find((input) => input.id === wakes[0])?.text).toContain(itemId);
  expect(state().pending).toBeUndefined();

  // Line 这一回合没有处理就结束了：下一轮把事项交回用户，不再唤醒 Line。
  const since = mark(s.a);
  (await line.call(1)).response.complete();
  await waitIdle(s.a, s.lineId, since);
  await check();
  const left = (await inboxOf(s.a)).items;
  expect(left.map((entry) => [entry.id, entry.left, entry.note, entry.delegated])).toEqual([
    [itemId, true, 'Line 没有给出处理，留给你', undefined],
  ]);
  await check();
  expect(wakesOf(s.a, s.lineId)).toEqual(wakes);

  // 用户在 B 上直接回答，下一轮读到等待已解除，事项移出，也不算 Line 处理过。
  const answered = await s.b.call('POST', `/threads/${s.workId}/waiting/${asked.waiting.id}`, { answers: [{ selected: ['甲'] }] });
  expect(answered.status).toBe(200);
  await work.call(2);
  await check();
  // 离开期间在别处回应的事项记为自己解除；宿主把它交回用户不算 Line 的处理，不另记。
  const final = await inboxOf(s.a);
  expect(final.items).toEqual([]);
  expect(final.records.map((record) => [record.item.id, record.outcome])).toEqual([[itemId, 'resolved']]);
  expect(line.calls.values).toHaveLength(1);
}, 1000);

/*
 * 几个部分的配合：目录事件流（GET /events?device=）的连接与 PUT /attention 的声明取交集才算在关注；关注设备决定 monitor
 * 这一轮是否推系统通知、别人线程的回合结束是否进收件箱、了结的事项是否记进离开期间的那一段；最后一条事件流断开即离开，
 * 重连后不自动恢复关注。离开期间的那一段回来后留作简报，再离开时换成新的一段。
 */
test('事件流连着且声明关注才算在关注：在关注时提问进收件箱不推通知、回合结束不进收件箱；离开期间的回合结束进收件箱、点知道了移出，在别处回应的提问记进这一段，新提问推 line.notification 到目录事件流；回来后这一段收尾并留着，事件流断开即离开并换成新的一段，重连须再声明', async () => {
  const s = await lineSetup();
  const work = s.modelOf(s.workId);
  const check = () => s.a.daemon.kite.monitor.check();
  const notified = (since: number) => s.a.events.slice(since).flatMap((e) => e.type === 'line.notification' ? [e.notification] : []);
  const ids = async () => (await inboxOf(s.a)).items.map((entry) => entry.id);

  const stream = await watch(s.a, 'mac');
  await focus(s.a, 'phone', true);
  expect((await attentionOf(s.a)).focusedDevices).toEqual([]);
  await focus(s.a, 'mac', true);
  expect(await attentionOf(s.a)).toEqual({ focusedDevices: ['mac'] });

  // 有设备关注：别人线程的回合结束不进收件箱；提问照样进，但不推通知。
  await send(s.b, s.workId, 'first', '第一件事');
  let since = mark(s.b);
  (await work.call(1)).response.complete();
  await waitIdle(s.b, s.workId, since);
  await check();
  expect(await ids()).toEqual([]);
  await send(s.b, s.workId, 'second', '第二件事');
  const q1 = await ask(s.b, work, s.workId, 2, '先问一句');
  let at = mark(s.a);
  await check();
  expect(await ids()).toEqual([`waiting:${q1.waiting.id}`]);
  expect(notified(at)).toEqual([]);
  await stream.events.wait((e) => e.type === 'line.inbox');

  // 不再关注：记下离开时刻。离开期间回合结束进收件箱，不逐条推通知。
  await focus(s.a, 'mac', false);
  const away = await attentionOf(s.a);
  expect(away.focusedDevices).toEqual([]);
  expect(typeof away.awaySince).toBe('number');
  expect((await s.b.call('POST', `/threads/${s.workId}/waiting/${q1.waiting.id}`, { answers: [{ selected: ['甲'] }] })).status).toBe(200);
  since = mark(s.b);
  (await work.call(3)).response.complete();
  await waitIdle(s.b, s.workId, since);
  at = mark(s.a);
  await check();
  expect(await ids()).toEqual([`turn:${s.workId}`]);
  expect(notified(at)).toEqual([]);
  // 离开期间在 B 上回应的提问记进这一段；回合结束留在等你的那一段，点「知道了」才移出。
  const q1Record = [`waiting:${q1.waiting.id}`, 'resolved'];
  const leaving = await inboxOf(s.a);
  expect(leaving.period).toEqual({ since: away.awaySince! });
  expect(leaving.records.map((record) => [record.item.id, record.outcome])).toEqual([q1Record]);
  expect(await inboxOperation(s.a, 'dismiss', { item: `turn:${s.workId}` })).toEqual({ status: 200, body: { ok: true } });
  expect(await ids()).toEqual([]);

  // 离开期间的新提问立即推一条通知到目录事件流。
  await send(s.b, s.workId, 'third', '第三件事');
  const q2 = await ask(s.b, work, s.workId, 4, '再问一句');
  at = mark(s.a);
  await check();
  const q2Item = `waiting:${q2.waiting.id}`;
  expect(await ids()).toEqual([q2Item]);
  expect(notified(at).map((note) => note.item)).toEqual([q2Item]);
  const pushed = await stream.events.wait((e) => e.type === 'line.notification');
  if (pushed.type !== 'line.notification') throw new Error('应是通知');
  expect(pushed.notification.item).toBe(q2Item);
  expect(pushed.notification.title).not.toBe('');

  // 回来：离开的那一段收尾，记录留作简报。事件流断开即离开，换成新的一段，上一段的记录清掉；重连事件流不自动恢复关注，要再声明。
  await focus(s.a, 'mac', true);
  expect(await attentionOf(s.a)).toEqual({ focusedDevices: ['mac'] });
  const back = await inboxOf(s.a);
  expect(back.period?.since).toBe(away.awaySince!);
  expect(back.period?.until).toBeGreaterThanOrEqual(away.awaySince!);
  expect(back.records.map((record) => [record.item.id, record.outcome])).toEqual([q1Record]);
  await stream.close();
  const dropped = await until(async () => {
    const current = await attentionOf(s.a);
    return current.focusedDevices.length === 0 && current;
  }, '事件流断开后移出关注设备', 500);
  expect(typeof dropped.awaySince).toBe('number');
  const again = await inboxOf(s.a);
  expect(again.period).toEqual({ since: dropped.awaySince! });
  expect(again.records).toEqual([]);
  await watch(s.a, 'mac');
  expect((await attentionOf(s.a)).focusedDevices).toEqual([]);
  await focus(s.a, 'mac', true);
  expect((await attentionOf(s.a)).focusedDevices).toEqual(['mac']);
}, 1000);

/*
 * 几个部分的配合：line_relay 从 Line 线程里取用户的原话，经跨机调用写到 B：B 在等提问时作为每个问题的「其他」回答，
 * 没有等待时经 POST /threads/:id/messages {relay: true} 成为来源为人、带 via 的输入。转达记在 monitor 状态里，
 * 同一来源消息与目标的重试只去重：已答过提问的那句不会在 B 不再等待后变成一条消息，发过的消息也不会再发一遍。
 */
test('line_relay 照原文转达用户的话：B 在等提问时作为「其他」回答，没有等待时成为来源为人、经 Line 的输入；同一句重试只去重', async () => {
  const s = await lineSetup();
  const work = s.modelOf(s.workId);
  const line = s.modelOf(s.lineId);
  const relay = { machine: s.machineB, threadId: s.workId };

  await send(s.b, s.workId, 'kickoff', '开始');
  await ask(s.b, work, s.workId, 1, '用哪个方案');
  const first = '两个都不要，用第三种：先写测试再改';
  await send(s.a, s.lineId, 'user-1', first);
  const l1 = await line.call(1);
  await l1.response.emit({ type: 'item', item: calledItem('relay-1', 'line_relay', relay) });
  l1.response.complete();
  const resumed = await work.call(2);
  const answered = resultOf(resumed.request, 'ask-1');
  expect(answered?.status).toBe('success');
  expect((JSON.parse(answered!.output) as { answers: Array<{ selected?: string[]; other?: string }> }).answers
    .map((answer) => [answer.selected ?? [], answer.other])).toEqual([[[], first]]);
  const l2 = await line.call(2);
  expect(resultOf(l2.request, 'relay-1')?.status).toBe('success');
  let since = mark(s.a);
  l2.response.complete();
  await waitIdle(s.a, s.lineId, since);
  since = mark(s.b);
  resumed.response.complete();
  await waitIdle(s.b, s.workId, since);

  // B 不再等待：第二句发成一条消息；这一句按 ID 重试、第一句重试，都只去重。
  const second = '再补一个空输入的用例';
  await send(s.a, s.lineId, 'user-2', second);
  const l3 = await line.call(3);
  await l3.response.emit({ type: 'item', item: calledItem('relay-2', 'line_relay', relay) });
  await l3.response.emit({ type: 'item', item: calledItem('relay-2-again', 'line_relay', { ...relay, from: 'user-2' }) });
  await l3.response.emit({ type: 'item', item: calledItem('relay-1-again', 'line_relay', { ...relay, from: 'user-1' }) });
  l3.response.complete();
  const l4 = await line.call(4);
  expect(['relay-2', 'relay-2-again', 'relay-1-again'].map((id) => resultOf(l4.request, id)?.status)).toEqual(['success', 'success', 'success']);
  const relayed = received(s.b, s.workId).filter((input) => input.text === first || input.text === second);
  expect(relayed).toEqual([{ id: expect.any(String), text: second, source: 'human', via: { kind: 'line', machine: s.machineA, instance: s.lineId } }]);
  const next = await work.call(3);
  expect(inputs(next.request).at(-1)?.text).toBe(second);
}, 1000);

/*
 * 几个部分的配合：line_control send 经跨机调用给 B 的线程投 Line 的说明（来源 kite、带 via），B 的汇总据此把这一回合标为
 * Line 发起；monitor 读到它在离开期间结束回合时不放进用户的收件箱，改为唤醒 Line 告知结果。
 */
test('Line 用 line_control send 发起的工作在用户离开期间结束回合，不进用户的收件箱，改为唤醒 Line 告知结果', async () => {
  const s = await lineSetup();
  const work = s.modelOf(s.workId);
  const line = s.modelOf(s.lineId);
  // 先确立离开：这时别人发起的回合结束会进收件箱。
  await watch(s.a, 'mac');
  await focus(s.a, 'mac', true);
  await focus(s.a, 'mac', false);
  expect(typeof (await attentionOf(s.a)).awaySince).toBe('number');

  await send(s.a, s.lineId, 'ask-line', '让 B 上的代理把 a.txt 改成 b');
  const l1 = await line.call(1);
  await l1.response.emit({ type: 'item', item: calledItem('send-1', 'line_control', {
    action: 'send', machine: s.machineB, threadId: s.workId, text: '把 a.txt 的内容改成 b',
  }) });
  l1.response.complete();
  const working = await work.call(1);
  expect(inputs(working.request).at(-1)).toEqual({ id: expect.any(String), text: '把 a.txt 的内容改成 b', source: 'kite',
    via: { kind: 'line', machine: s.machineA, instance: s.lineId } });
  let since = mark(s.a);
  (await line.call(2)).response.complete();
  await waitIdle(s.a, s.lineId, since);
  since = mark(s.b);
  working.response.complete();
  await waitIdle(s.b, s.workId, since);

  await s.a.daemon.kite.monitor.check();
  const woke = await line.call(3);
  const wake = inputs(woke.request).at(-1)!;
  expect(wake.source).toBe('kite');
  expect(wake.text).toContain('发起的工作有了结果');
  expect(wake.text).toContain(s.workId);
  expect((await inboxOf(s.a)).items).toEqual([]);
  since = mark(s.a);
  woke.response.complete();
  await waitIdle(s.a, s.lineId, since);
  // 结果只交一次。
  await s.a.daemon.kite.monitor.check();
  expect(wakesOf(s.a, s.lineId)).toHaveLength(1);
}, 1000);

/*
 * 真实 bug：用户离开超过摘要间隔（10 分钟）后，收件箱里有交给 Line、还没通知过的回合结束时，摘要不收交给 Line 的事项，
 * 安排下一次读取的计时却照样拿它算到期时刻；到期时刻落在过去，monitor 按最短间隔反复读账号目录、对每台在线工作机读汇总，
 * 直到 Line 处理完或用户回来。摘要的筛选、代处理的投递和定时三处在真实计时器上合起来才看得出会不会空转。
 * 依赖运行时：Bun（1.4.2 上验证）的 jest.useFakeTimers 接管之后新建的 setTimeout 与 Date.now，advanceTimersByTime 同步推进两者并
 * 触发到点的计时器；之前建的计时器照旧是真的，daemon 起 monitor 时那个 60 秒的定时读在测试期间不会到点。
 * monitor.stop() 不另起一轮，只交出进行中的那一轮，用它等计时器触发的读取做完。
 */
test('用户离开超过摘要间隔、收件箱里只有交给 Line 还没了结的回合结束时，monitor 不按最短间隔反复读各工作机', async () => {
  const s = await lineSetup();
  const work = s.modelOf(s.workId);
  const line = s.modelOf(s.lineId);
  const monitor = s.a.daemon.kite.monitor;
  const inboxId = inboxInstance(s.a).id;
  await watch(s.a, 'mac');
  await focus(s.a, 'mac', true);
  await focus(s.a, 'mac', false);
  expect(typeof (await attentionOf(s.a)).awaySince).toBe('number');

  // 离开期间 B 上的回合结束进收件箱，用户交给 Line；Line 这一回合挂着不结束，事项一直是交出去、没了结。
  await send(s.b, s.workId, 'kickoff', '开始');
  const since = mark(s.b);
  (await work.call(1)).response.complete();
  await waitIdle(s.b, s.workId, since);
  await monitor.check();
  const turn = `turn:${s.workId}`;
  expect((await inboxOf(s.a)).items.map((entry) => entry.id)).toEqual([turn]);
  expect((await delegate(s.a, turn)).status).toBe(200);
  await line.call(1);
  // 等投递的那一轮做完，下面的 check 才是新起的一轮。
  await monitor.check();

  const reads = spyOn(s.a.daemon.kite.peers, 'machines');
  jest.useFakeTimers();
  try {
    // 时间推过摘要间隔后读一轮；之后 30 秒里不该再读。一轮读几次账号目录不归这里管，只比较前后。
    jest.advanceTimersByTime(11 * 60_000);
    await monitor.check();
    const perRound = reads.mock.calls.length;
    expect(perRound).toBeGreaterThan(0);
    jest.advanceTimersByTime(30_000);
    await monitor.stop();
    expect(reads).toHaveBeenCalledTimes(perRound);
  } finally {
    jest.useRealTimers();
    reads.mockRestore();
  }
  const item = monitorState(s.a.daemon.kite.store.instance(inboxId)!).items[turn];
  expect([item?.delegated?.by, item?.notified]).toEqual(['user', undefined]);
}, 1000);

/*
 * 几个部分的配合：Line 的工具经跨机调用等对端时，停止 Line 的线程要中止这次等待，停止很快完成，工具结果是错误。
 * 真实 bug：跨机调用只带超时（读回复 30 秒，建工作区、流转最长 30 分钟），对端收下请求却不回应时，停止 Line 要等到超时；
 * 这里靠测试的时限挡住。对端用一个只挂住读回复的服务替代，monitor 读汇总等其他请求照常答，免得停 kited 时等它这一轮。
 */
test('Line 等一台收下请求却不回应的工作机时，停止 Line 很快完成，这次工具调用以错误结束', async () => {
  const s = await lineSetup();
  const line = s.modelOf(s.lineId);
  const reached = deferred();
  const silent = Bun.serve({ hostname: '127.0.0.1', port: 0, fetch(request) {
    if (!new URL(request.url).pathname.endsWith('/reply')) return Response.json({ error: '没有这个接口' }, { status: 404 });
    reached.resolve();
    return new Promise<Response>(() => {});
  } });
  try {
    s.directory.push({ id: 'machine-silent', name: '不回应的工作机', online: true, address: `http://127.0.0.1:${silent.port}` });
    await send(s.a, s.lineId, 'read', '看看那台机器上线程的回复');
    const l1 = await line.call(1);
    await l1.response.emit({ type: 'item', item: calledItem('read-1', 'line_status', { machine: 'machine-silent', threadId: 'silent-thread' }) });
    l1.response.complete();
    await reached.promise;
    const since = mark(s.a);
    expect((await s.a.call('POST', `/threads/${s.lineId}/interrupt`)).status).toBe(200);
    const finished = await s.a.waitEvent((e) => e.type === 'harness' && e.threadId === s.lineId && e.event.type === 'record'
      && e.event.record.type === 'tool.finished' && e.event.record.callId === 'read-1');
    expect(finished.type === 'harness' && finished.event.type === 'record' && finished.event.record.type === 'tool.finished'
      && finished.event.record.result.status).toBe('error');
    await waitIdle(s.a, s.lineId, since);
  } finally {
    await silent.stop(true);
  }
}, 1000);
