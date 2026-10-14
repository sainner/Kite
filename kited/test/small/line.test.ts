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
import type { Json, ModelItem, ModelRequest, ToolResult } from '../../src/harness/types.ts';
import { monitorState } from '../../src/line/monitor.ts';
import type { WorkspaceModel } from '../../src/model.ts';
import { type FakeAccount, startFakeAccount } from '../fake-account.ts';
import { after, type Kited, mark, registerCheckout, startKited, waitIdle } from '../harness.ts';
import { diskRecords, item, ManualModel } from '../harness-loop.ts';
import { git, gitOk, makeTemp, newDir, newRepo, until, writeFiles } from '../util.ts';

let account: FakeAccount | undefined;
const kiteds: Kited[] = [];
const dirs: string[] = [];
/** 测试前的 HOME，测试结束时换回。 */
const homes: string[] = [];
afterEach(async () => {
  for (const k of kiteds.splice(0)) await k.stop();
  account?.stop();
  account = undefined;
  const home = homes.pop();
  if (home) process.env.HOME = home;
  for (const dir of dirs.splice(0)) rmSync(dir, { recursive: true, force: true });
});

const calledItem = (id: string, name: string, args: Json): ModelItem => ({ ...item(id, name), call: { id, name, arguments: args } });
const inputs = (request: ModelRequest) => request.history.flatMap((entry) => entry.type === 'input' ? [entry.input] : []);
const lineTools = ['line_status', 'line_reply', 'line_control', 'line_workspace'];

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
  const a = startKited((thread) => modelOf(thread.id), false, account, { peers: { directory: async () => directory } });
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
  return { a, b, modelOf, machineA: a.daemon.kite.store.machine.id, machineB, lineWorkspace, lineId, bare, workId };
}

async function send(k: Kited, threadId: string, id: string, text: string) {
  const sent = await k.call('POST', `/threads/${threadId}/messages`, { id, text });
  expect(sent.status).toBe(200);
}

/** 模型在第 number 次请求里调一个工具；返回挂着的下一次请求和这次调用的结果。 */
async function step(model: ManualModel, number: number, callId: string, name: string, args: Json) {
  const call = await model.call(number);
  await call.response.emit({ type: 'item', item: calledItem(callId, name, args) });
  call.response.complete();
  const next = await model.call(number + 1);
  const found = next.request.history.find((entry) => entry.type === 'tool_result' && entry.callId === callId);
  if (found?.type !== 'tool_result') throw new Error(`${name} 没有结果`);
  return { call, next, result: found.result as ToolResult };
}

const reportIdOf = (result: ToolResult) => (JSON.parse(result.output) as { reportId: string }).reportId;

/** 工作线程提一个 question 上报并结束回合，从第 number 次请求开始。 */
async function raise(k: Kited, model: ManualModel, threadId: string, number: number, text: string) {
  const since = mark(k);
  const asked = await step(model, number, `ask-${number}`, 'report', { kind: 'question', text });
  asked.next.response.complete();
  await waitIdle(k, threadId, since);
  return { asked, reportId: reportIdOf(asked.result) };
}

/*
 * 几个部分的配合：monitor 读两台工作机的汇总唤醒 Line，Line 的工具经跨机调用读状态、转达答复，目标机把答复
 * 作为人的输入落到线程并记下经 Line；同一转达重试时目标按输入 ID 去重。工具只声明给 Line 角色的实例。
 */
test('monitor 唤醒 Line 转达用户原文：目标线程收到来源为人且经 Line 的答复，重试不产生第二条输入，line_* 只给 Line', async () => {
  const s = await lineSetup();
  const work = s.modelOf(s.workId);
  const line = s.modelOf(s.lineId);
  await send(s.b, s.workId, 'kickoff', '开始');
  const { asked, reportId } = await raise(s.b, work, s.workId, 1, '用哪个存储方案？');
  expect(asked.call.request.allowedTools).toContain('report');
  expect((asked.call.request.allowedTools ?? []).filter((tool) => tool.startsWith('line_'))).toEqual([]);

  await s.a.daemon.kite.monitor.check();
  const status = await step(line, 1, 'status', 'line_status', {});
  expect(status.call.request.allowedTools).toEqual(expect.arrayContaining(lineTools));
  expect(inputs(status.call.request).at(-1)).toMatchObject({ source: 'kite', text: expect.stringContaining(reportId) });
  expect(status.result.status).toBe('success');
  expect(status.result.output).toContain(reportId);

  // Line 向用户上报，用户在 Line 的线程上答复。
  const toUser = await step(line, 2, 'to-user', 'report', { kind: 'question', text: 'B 上的线程问：用哪个存储方案？' });
  toUser.next.response.complete();
  const lineReport = reportIdOf(toUser.result);
  const answered = await s.a.call('POST', `/threads/${s.lineId}/reports/${lineReport}/answer`, { id: 'user-answer', text: '用 SQLite' });
  expect(answered.status).toBe(200);

  const relay = { machine: s.machineB, threadId: s.workId, reportId, from: lineReport };
  const replied = await step(line, 4, 'relay', 'line_reply', relay);
  expect(replied.result.status).toBe('success');
  const resumed = await work.call(3);
  expect(inputs(resumed.request)).toContainEqual(expect.objectContaining({
    text: '用 SQLite', source: 'human', via: { kind: 'line', machine: s.machineA, instance: s.lineId },
  }));
  const since = mark(s.b);
  const retried = await step(line, 5, 'relay-again', 'line_reply', relay);
  expect(retried.result.status).toBe('success');
  retried.next.response.complete();
  resumed.response.complete();
  await waitIdle(s.b, s.workId, since);
  expect(work.calls.values).toHaveLength(3);
  expect(inputs(resumed.request).filter((input) => input.text === '用 SQLite')).toHaveLength(1);
}, 1000);

/*
 * 几个部分的配合：确认核验在 Line 所在机器上读 Line 自己的上报与答复、记下用过的确认，再跨机停止目标线程；
 * 模型只能引用确认上报，不带、被拒绝或用过的都不能放行。
 */
test('Line 停止线程须引用用户同意且没用过的确认上报：不带、答复不同意、重复使用都被拒且目标不停，同意后停下', async () => {
  const s = await lineSetup();
  const work = s.modelOf(s.workId);
  const line = s.modelOf(s.lineId);
  await send(s.b, s.workId, 'kickoff', '一直跑');
  const running = await work.call(1);
  const stop = (confirmation?: string) => ({ action: 'stop', machine: s.machineB, threadId: s.workId, ...(confirmation ? { confirmation } : {}) });

  await send(s.a, s.lineId, 'manage', '看看要不要停');
  const bare = await step(line, 1, 'stop-bare', 'line_control', stop());
  expect(bare.result.status).toBe('error');
  const askNo = await step(line, 2, 'confirm-1', 'report', { kind: 'confirm', text: '停下 B 上的线程？' });
  askNo.next.response.complete();
  const refusal = reportIdOf(askNo.result);
  expect((await s.a.call('POST', `/threads/${s.lineId}/reports/${refusal}/answer`, { id: 'answer-no', decision: 'no' })).status).toBe(200);
  const denied = await step(line, 4, 'stop-no', 'line_control', stop(refusal));
  expect(denied.result.status).toBe('error');
  expect(running.signal.aborted).toBe(false);

  const askYes = await step(line, 5, 'confirm-2', 'report', { kind: 'confirm', text: '还是停下吧？' });
  askYes.next.response.complete();
  const consent = reportIdOf(askYes.result);
  expect((await s.a.call('POST', `/threads/${s.lineId}/reports/${consent}/answer`, { id: 'answer-yes', decision: 'yes' })).status).toBe(200);
  const stopped = await step(line, 7, 'stop-yes', 'line_control', stop(consent));
  expect(stopped.result.status).toBe('success');
  expect(running.signal.aborted).toBe(true);
  const reused = await step(line, 8, 'stop-again', 'line_control', stop(consent));
  expect(reused.result.status).toBe('error');
  const since = mark(s.a);
  reused.next.response.complete();
  await waitIdle(s.a, s.lineId, since);
}, 1000);

/*
 * 几个部分的配合：monitor 的待办派生、持久保存的状态、投递与 Line 线程的执行互斥，以及 Line 回合结束后宿主提交并推送现场。
 * 只有新增的待办唤醒 Line；投递失败时待投递项留在状态里，下一轮用同一输入 ID 补送且只送一次。
 */
test('monitor 只为新增待办唤醒 Line，投递失败留到下一轮用同一 ID 补送一次；Line 回合结束后现场推到托管远程', async () => {
  const s = await lineSetup();
  const work = s.modelOf(s.workId);
  const line = s.modelOf(s.lineId);
  const journal = join(s.a.home, 'sessions', s.lineId, 'journal.jsonl');
  const monitorInputs = () => diskRecords(journal).flatMap((record) =>
    record.type === 'input.received' && record.input.source === 'kite' ? [record.input.id] : []);
  const state = () => monitorState(s.a.daemon.kite.store.instance(s.lineId)!);

  await send(s.b, s.workId, 'kickoff', '开始');
  const first = await raise(s.b, work, s.workId, 1, '第一个问题');
  await s.a.daemon.kite.monitor.check();
  const woke = await line.call(1);
  writeFiles(s.lineWorkspace.workspace.cwd, { '.kite/memory/notes.md': 'Line 记下的事\n' });
  woke.response.complete();
  await waitIdle(s.a, s.lineId);
  await until(() => gitOk(s.bare, 'cat-file', '-e', 'HEAD:.kite/memory/notes.md'), 'Line 的现场推到托管远程', 900);
  expect(monitorInputs()).toHaveLength(1);

  // 同一个待办再读一轮不唤醒；用户在 B 上直接答复后事项消失，也不唤醒。
  await s.a.daemon.kite.monitor.check();
  expect(monitorInputs()).toHaveLength(1);
  expect(Object.keys(state().todo)).toEqual([`report:${first.reportId}`]);
  expect((await s.b.call('POST', `/threads/${s.workId}/reports/${first.reportId}/answer`, { id: 'direct', text: '直接答' })).status).toBe(200);
  await work.call(3);
  await s.a.daemon.kite.monitor.check();
  expect(monitorInputs()).toHaveLength(1);
  expect(state().todo).toEqual({});
  const workSince = mark(s.b);
  const asked = await step(work, 3, 'ask-again', 'report', { kind: 'question', text: '第二个问题' });
  asked.next.response.complete();
  await waitIdle(s.b, s.workId, workSince);
  const second = reportIdOf(asked.result);

  // Line 的工作区里另一个线程在跑，执行互斥让投递失败。
  const blocker = await s.a.call('POST', `/workspaces/${s.lineWorkspace.workspace.id}/operations/agent.start`, { operationId: 'blocker' });
  expect(blocker.status).toBe(200);
  const blockerId = blocker.body.instanceId as string;
  await send(s.a, blockerId, 'busy', '占着工作区');
  const busy = await s.modelOf(blockerId).call(1);
  await s.a.daemon.kite.monitor.check();
  const pending = state().pending;
  expect(pending?.text).toContain(second);
  expect(Object.keys(state().todo)).toEqual([`report:${second}`]);
  expect(monitorInputs()).toHaveLength(1);

  const since = mark(s.a);
  busy.response.complete();
  await waitIdle(s.a, blockerId, since);
  await s.a.daemon.kite.monitor.check();
  await s.a.daemon.kite.monitor.check();
  expect(monitorInputs()).toEqual([expect.any(String), pending!.id]);
  expect(state().pending).toBeUndefined();
  (await line.call(2)).response.complete();
  await s.a.waitEvent((e) => e.type === 'idle' && e.threadId === s.lineId && after(s.a, since)(e));
}, 1000);
