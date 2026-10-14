/**
 * Line（docs/Line与工作区流转.md「Line」）：两台本进程 kited 共用一个账号替身，A 启用 Line，B 上有工作线程。
 * 跨机调用经 startKited 的 peers.directory 直达 B 的监听地址。Line 的项目是托管项目，启用时照常经 http 推送；
 * 之后的现场推送经 HOME 的 url.insteadOf 直接写托管裸仓库。
 * 每个测试换一个 HOME：Line 的项目固定在 ~/code/kite-line，同一进程里前一个测试删掉再建的同路径仓库会碰上
 * 快照模块按路径记住的私有索引目录（src/workspace/snapshots.ts 的 indexes），回合收尾失败。
 */
import { afterEach, expect, test } from 'bun:test';
import { rmSync } from 'node:fs';
import { join } from 'node:path';
import type { AccountMachine } from '../../src/account-client.ts';
import type { Envelope } from '../../src/events.ts';
import type { Json, ModelItem, ModelRequest, ToolResult } from '../../src/harness/types.ts';
import { monitorState } from '../../src/line/monitor.ts';
import type { WorkspaceModel } from '../../src/model.ts';
import type { DisplayState } from '../../src/transcript/protocol.ts';
import { type FakeAccount, startFakeAccount } from '../fake-account.ts';
import { after, type Kited, mark, registerCheckout, startKited, waitIdle } from '../harness.ts';
import { deferred, diskRecords, item, ManualModel } from '../harness-loop.ts';
import { git, gitOk, makeTemp, newDir, newRepo, until, writeFiles } from '../util.ts';

let account: FakeAccount | undefined;
const kiteds: Kited[] = [];
const dirs: string[] = [];
/** 测试前的 HOME，测试结束时换回。 */
const homes: string[] = [];
/** 停住的账号目录读取；测试失败时也先放行，否则停 kited 时会一直等 monitor 这一轮。 */
const holds: Array<() => void> = [];
afterEach(async () => {
  for (const release of holds.splice(0)) release();
  for (const k of kiteds.splice(0)) await k.stop();
  account?.stop();
  account = undefined;
  const home = homes.pop();
  if (home) process.env.HOME = home;
  for (const dir of dirs.splice(0)) rmSync(dir, { recursive: true, force: true });
});

const calledItem = (id: string, name: string, args: Json): ModelItem => ({ ...item(id, name), call: { id, name, arguments: args } });
const inputs = (request: ModelRequest) => request.history.flatMap((entry) => entry.type === 'input' ? [entry.input] : []);
const lineTools = ['line_status', 'line_control', 'line_workspace'];
const resultOf = (request: ModelRequest, callId: string): ToolResult | undefined => {
  const found = request.history.find((entry) => entry.type === 'tool_result' && entry.callId === callId);
  return found?.type === 'tool_result' ? found.result : undefined;
};

/** A 启用 Line，B 的根工作区里有一个工作代理（还没发消息）。 */
async function lineSetup() {
  const root = makeTemp('line-');
  dirs.push(root);
  homes.push(process.env.HOME!);
  process.env.HOME = newDir(root, 'home');
  account = startFakeAccount(join(root, 'account'));
  const models = new Map<string, ManualModel>();
  const modelOf = (threadId: string) => {
    let model = models.get(threadId);
    if (!model) { model = new ManualModel(); models.set(threadId, model); }
    return model;
  };
  const directory: AccountMachine[] = [];
  let hold: { reached: () => void; released: Promise<void> } | undefined;
  const a = startKited((thread) => modelOf(thread.id), false, account, { peers: { directory: async () => {
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
  const b = startKited((thread) => modelOf(thread.id), false, account);
  kiteds.push(a, b);
  const machineB = b.daemon.kite.store.machine.id;
  directory.push({ id: machineB, name: '工作机 B', online: true, address: b.url });

  const enabled = await a.call('POST', '/line');
  expect(enabled.status).toBe(200);
  const lineWorkspace = enabled.body as WorkspaceModel;
  const lineId = lineWorkspace.threads[0]!.instanceId;
  const bare = join(account.repos, `${lineWorkspace.project.id}.git`);
  git(root, 'config', '--global', `url.${bare}.insteadOf`, account.projects.get(lineWorkspace.project.id)!.url);

  const registered = await registerCheckout(b, newRepo(b.root, 'work', { 'a.txt': 'a\n' }));
  const started = await b.call('POST', `/workspaces/${registered.workspace.id}/operations/agent.start`, { operationId: 'worker' });
  expect(started.status).toBe(200);
  const workId = started.body.instanceId as string;
  return { a, b, modelOf, holdDirectory, machineA: a.daemon.kite.store.machine.id, machineB, lineWorkspace, lineId, bare, workId };
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

/*
 * 几个部分的配合：必问动作的等待挂在 Line 自己的工具调用上，HTTP 回应放行工具的 promise，批准这一次后才经跨机调用
 * 停下 B 上的线程；拒绝时工具返回 error、不停目标。必问动作不接受「记住」，这样的回应被拒后等待仍在。
 */
test('Line 停止线程须经用户逐次批准：等待挂在 Line 的线程上，记住被拒且等待仍在，拒绝时工具出错且目标不停，批准这一次后目标停下', async () => {
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
 * 几个部分的配合：monitor 跨机读汇总里的等待派生待办、先落盘再投递的状态、投递时 Line 的工作区正在交接，以及 Line 回合
 * 结束后宿主提交并推送现场。只有新增的待办唤醒 Line；投递失败时待投递项留在状态里，下一轮用同一输入 ID 补送且只送一次。
 * 工作线程能用 question，line_* 只声明给 Line 角色的实例。
 */
test('monitor 只为新增的等待唤醒 Line，回应后待办消失也不唤醒，投递失败留到下一轮用同一 ID 补送一次；Line 回合结束后现场推到托管远程', async () => {
  const s = await lineSetup();
  const work = s.modelOf(s.workId);
  const line = s.modelOf(s.lineId);
  const journal = join(s.a.home, 'sessions', s.lineId, 'journal.jsonl');
  const monitorInputs = () => diskRecords(journal).flatMap((record) =>
    record.type === 'input.received' && record.input.source === 'kite' ? [record.input.id] : []);
  const state = () => monitorState(s.a.daemon.kite.store.instance(s.lineId)!);

  await send(s.b, s.workId, 'kickoff', '开始');
  const first = await ask(s.b, work, s.workId, 1, '第一个问题');
  expect(first.call.request.allowedTools).toContain('question');
  expect((first.call.request.allowedTools ?? []).filter((tool) => tool.startsWith('line_'))).toEqual([]);
  await s.a.daemon.kite.monitor.check();
  const woke = await line.call(1);
  expect(woke.request.allowedTools).toEqual(expect.arrayContaining([...lineTools, 'question']));
  expect(inputs(woke.request).at(-1)?.source).toBe('kite');
  writeFiles(s.lineWorkspace.workspace.cwd, { '.kite/memory/notes.md': 'Line 记下的事\n' });
  woke.response.complete();
  await waitIdle(s.a, s.lineId);
  await until(() => gitOk(s.bare, 'cat-file', '-e', 'HEAD:.kite/memory/notes.md'), 'Line 的现场推到托管远程', 900);
  expect(monitorInputs()).toHaveLength(1);

  // 同一个等待再读一轮不唤醒；用户在 B 上直接回应后待办消失，也不唤醒，工作线程拿到回答接着走。
  await s.a.daemon.kite.monitor.check();
  expect(monitorInputs()).toHaveLength(1);
  expect(Object.keys(state().todo)).toEqual([`waiting:${first.waiting.id}`]);
  const answered = await s.b.call('POST', `/threads/${s.workId}/waiting/${first.waiting.id}`, { answers: [{ selected: ['乙'] }] });
  expect(answered.status).toBe(200);
  const resumed = await work.call(2);
  expect(resultOf(resumed.request, 'ask-1')?.status).toBe('success');
  await s.a.daemon.kite.monitor.check();
  expect(monitorInputs()).toHaveLength(1);
  expect(state().todo).toEqual({});
  const second = await ask(s.b, work, s.workId, 2, '第二个问题');

  // 这一轮读到 Line 实例之后、投递之前，Line 的工作区开始交接：交接把工作区置为 handing_off，本地拒绝新的执行，投递失败。
  // 真走一遍交接要推材料、停线程，太慢；这里只改工作区状态，与交接和撤回改的是同一个字段。
  const lineWorkspaceId = s.lineWorkspace.workspace.id;
  const held = s.holdDirectory();
  const failing = s.a.daemon.kite.monitor.check();
  await held.reached;
  s.a.daemon.kite.store.setWorkspaceStatus(lineWorkspaceId, 'handing_off');
  held.release();
  await failing;
  const pending = state().pending;
  expect(pending?.text).toContain('第二个问题');
  expect(Object.keys(state().todo)).toEqual([`waiting:${second.waiting.id}`]);
  expect(monitorInputs()).toHaveLength(1);

  // 撤回交接，工作区重新开放：下一轮补送同一 ID，再下一轮不重复送。
  s.a.daemon.kite.store.setWorkspaceStatus(lineWorkspaceId, 'open');
  const since = mark(s.a);
  await s.a.daemon.kite.monitor.check();
  await s.a.daemon.kite.monitor.check();
  expect(monitorInputs()).toEqual([expect.any(String), pending!.id]);
  expect(state().pending).toBeUndefined();
  (await line.call(2)).response.complete();
  await s.a.waitEvent((e) => e.type === 'idle' && e.threadId === s.lineId && after(s.a, since)(e));
}, 1000);
