/**
 * 等你回应（docs/工具审批与提问.md）：自研后端线程调 question 挂起，或 shell 连名单外主机时停下来问，
 * 回合停在工具调用上，用户经 HTTP 回应或停止会话。模型用 ManualModel，不起 Claude Code；命令在真实沙箱里跑。
 */
import { afterEach, expect, test } from 'bun:test';
// 询问模式的沙箱宿主按路径起子进程，不在 import 链上；按文本引入，宿主改动时 .kite/check 才会选中这里。
import '../../src/execution/sandbox-callback-host.ts' with { type: 'text' };
import type { Envelope } from '../../src/events.ts';
import type { Json, ModelItem, ModelRequest, ToolResult } from '../../src/harness/types.ts';
import type { DisplayState } from '../../src/transcript/protocol.ts';
import type { Question } from '../../src/waiting.ts';
import { addProject, after, createWorkspace, type Kited, mark, startKited, waitIdle } from '../harness.ts';
import { item, ManualModel } from '../harness-loop.ts';
import { newDir } from '../util.ts';

let kited: Kited | undefined;
afterEach(async () => {
  await kited?.stop();
  kited = undefined;
});

const calledItem = (id: string, name: string, args: Json): ModelItem => ({ ...item(id, name), call: { id, name, arguments: args } });
const resultOf = (request: ModelRequest, callId: string): ToolResult | undefined => {
  const found = request.history.find((entry) => entry.type === 'tool_result' && entry.callId === callId);
  return found?.type === 'tool_result' ? found.result : undefined;
};

const questions: Question[] = [
  { question: '用哪个存储方案？', multiSelect: false, options: [
    { label: 'SQLite（推荐）', description: '单文件，随工作区走' },
    { label: 'Postgres', description: '要另起服务' },
  ] },
  { question: '先支持哪些平台？', multiSelect: true, options: [
    { label: 'macOS', description: 'Mac App' },
    { label: 'iOS', description: 'iPhone 与 iPad' },
    { label: 'Linux', description: '只跑 kited' },
  ] },
];

/** 建一个自研后端线程，模型在第一次请求里调 question；返回线程 ID、挂起的等待和那次请求。 */
async function ask() {
  const model = new ManualModel();
  const k = kited = startKited(() => model);
  const registered = await addProject(k, { path: newDir(k.root, 'project', { 'a.txt': 'a\n' }) });
  const thread = await createWorkspace(k, registered.id, '先问清楚再做', 'harness');
  const first = await model.call(1);
  expect(first.request.allowedTools).toContain('question');
  const since = mark(k);
  await first.response.emit({ type: 'item', item: calledItem('ask', 'question', { questions } as unknown as Json) });
  first.response.complete();
  const event = await k.waitEvent((e) => e.type === 'waiting' && e.threadId === thread.id && !!e.waiting && after(k, since)(e));
  const waiting = (event as Extract<Envelope, { type: 'waiting' }>).waiting!;
  return { k, model, threadId: thread.id, waiting };
}

const state = async (k: Kited, threadId: string) => {
  const r = await k.call('GET', `/threads/${threadId}/state`);
  expect(r.status).toBe(200);
  return r.body as DisplayState;
};

/*
 * 几个部分的配合：question 工具的 promise 挂在回合里，HTTP 回应把它放行，显示投影的状态随等待出现和消失，
 * 回答作为这次调用的结果出现在模型下一次请求的历史里；回应过的等待不能再回应。
 */
test('线程提问时回合停在 running 并在状态里挂出等待，回应后回答按问题顺序作为调用结果交回模型、等待消失，再回应同一个等待得 409', async () => {
  const { k, model, threadId, waiting } = await ask();
  expect(waiting.kind === 'question' && waiting.questions).toEqual(questions);
  const before = await state(k, threadId);
  expect(before.phase).toBe('running');
  expect(before.busy).toBe(true);
  expect(before.waiting).toEqual(waiting);
  expect(model.calls.values).toHaveLength(1);

  const answers = { answers: [{ other: '先用内存，以后再说' }, { selected: ['macOS', 'iOS'] }] };
  const responded = await k.call('POST', `/threads/${threadId}/waiting/${waiting.id}`, answers);
  expect(responded).toEqual({ status: 200, body: { ok: true } });
  const second = await model.call(2);
  const result = resultOf(second.request, 'ask');
  expect(result?.status).toBe('success');
  expect(JSON.parse(result!.output)).toEqual({ answers: [
    { question: '用哪个存储方案？', other: '先用内存，以后再说' },
    { question: '先支持哪些平台？', selected: ['macOS', 'iOS'] },
  ] });
  const resumed = await state(k, threadId);
  expect(resumed.phase).toBe('running');
  expect(resumed.waiting).toBeUndefined();

  const again = await k.call('POST', `/threads/${threadId}/waiting/${waiting.id}`, answers);
  expect(again.status).toBe(409);
  expect(again.body.waiting).toBeNull();
  const since = mark(k);
  second.response.complete();
  await waitIdle(k, threadId, since);
}, 1000);

/*
 * 几个部分的配合：停止要等挂着的工具收尾，等待须在这之前作废并让工具按未回答返回；
 * 停止完成后线程回到 idle、等待从状态里消失，下一回合的历史里这次调用是 error。
 */
test('提问挂起时停止会话：停止能完成、线程回到 idle 且等待消失，这次调用按未回答记为 error，之后回应原等待得 409', async () => {
  const { k, model, threadId, waiting } = await ask();
  const since = mark(k);
  const stopped = await k.call('POST', `/threads/${threadId}/interrupt`, { id: 'stop' });
  expect(stopped.status).toBe(200);
  await waitIdle(k, threadId, since);
  const idle = await state(k, threadId);
  expect(idle.phase).toBe('idle');
  expect(idle.waiting).toBeUndefined();

  const late = await k.call('POST', `/threads/${threadId}/waiting/${waiting.id}`, { answers: [{ selected: ['SQLite（推荐）'] }, { selected: ['Linux'] }] });
  expect(late.status).toBe(409);
  expect(late.body.waiting).toBeNull();

  const sent = await k.call('POST', `/threads/${threadId}/messages`, { id: 'next', text: '接着做' });
  expect(sent.status).toBe(200);
  const next = await model.call(2);
  expect(resultOf(next.request, 'ask')?.status).toBe('error');
  const nextSince = mark(k);
  next.response.complete();
  await waitIdle(k, threadId, nextSince);
}, 1000);

/*
 * 几个部分的配合：带 skipWaiting 的消息先经 agent.send 排进 runner 的待处理输入，再由 Waits.skip 放行挂着的 question 工具；
 * 工具返回后 runner 发下一次请求时要同时带上跳过的结果和这条消息，不能先发一次只带工具结果的请求。
 * 工具返回到下一次请求之间 runner 还要做工具后的收尾（afterTools），这段空当足够让晚到的消息也赶上，
 * 光看请求内容分不出先后；所以同时按 runner 的记录核对：消息的 input.received 在这次调用的 tool.finished 之前。
 */
test('提问挂起时用户不回答、直接发带 skipWaiting 的消息：等待撤下，模型下一次请求里这次调用是跳过说明、紧跟着这条人发的消息，中间没有只带工具结果的请求', async () => {
  const { k, model, threadId, waiting } = await ask();
  const since = mark(k);
  const text = '先不选了，存储用 SQLite，平台只做 macOS';
  const sent = await k.call('POST', `/threads/${threadId}/messages`, { id: 'skip', text, skipWaiting: waiting.id });
  expect(sent.status).toBe(200);
  await k.waitEvent((e) => e.type === 'waiting' && e.threadId === threadId && !e.waiting && after(k, since)(e));

  const second = await model.call(2);
  const records = k.events.flatMap((e) => e.type === 'harness' && e.threadId === threadId && e.event.type === 'record' ? [e.event.record] : []);
  const received = records.findIndex((record) => record.type === 'input.received' && record.input.id === 'skip');
  expect(received).toBeGreaterThanOrEqual(0);
  expect(received).toBeLessThan(records.findIndex((record) => record.type === 'tool.finished' && record.callId === 'ask'));
  const result = resultOf(second.request, 'ask');
  expect(result?.status).toBe('success');
  expect(result?.output).toBe('用户没有回答，跳过了这些问题，直接发了一条新消息，见随后的输入。');
  const message = second.request.history.findIndex((entry) => entry.type === 'input' && entry.input.id === 'skip');
  expect(second.request.history[message]).toEqual({ type: 'input', input: { id: 'skip', text, source: 'human' } });
  expect(message).toBeGreaterThan(second.request.history.findIndex((entry) => entry.type === 'tool_result' && entry.callId === 'ask'));
  expect((await state(k, threadId)).waiting).toBeUndefined();

  const idle = mark(k);
  second.response.complete();
  await waitIdle(k, threadId, idle);
}, 1000);

/*
 * 几个部分的配合：沙箱宿主进程把名单外主机经控制目录里的 socket 交回 kited，kited 在线程上挂审批等待、命令挂着；
 * HTTP 回应「允许并记住」放行这次连接，同时把 host:port 追加进实例的执行授权（要拿工作区锁）并通知模型，
 * 同一回合里下一条命令的沙箱要带上新授权、不再问。审批模式在回合进行中改，下一次越界请求就生效。
 * 依赖上游 sandbox-runtime 的 HTTP 代理：名单外主机在 DNS 解析前交给宿主决定，拒绝回 403，
 * 放行后 .invalid 解析失败回 502，不靠外网也能分清放行与拒绝。
 */
test('审批模式改成越界询问后，shell 连名单外主机时线程挂出审批等待、命令挂着；允许并记住后命令放行、执行授权多了这台主机，再连不再问', async () => {
  const model = new ManualModel();
  const k = kited = startKited(() => model);
  const registered = await addProject(k, { path: newDir(k.root, 'project', { 'a.txt': 'a\n' }) });
  const thread = await createWorkspace(k, registered.id, '连一下外部服务', 'harness');
  const target = 'kite-approval.invalid:8080';
  const curl = (id: string) => calledItem(id, 'shell', {
    description: '连名单外主机',
    command: `curl --silent --output /dev/null --max-time 2 --write-out 'status=%{http_code}' http://${target}/`,
  });
  const asked = (since: number) => k.events.filter((e) => e.type === 'waiting' && e.threadId === thread.id && !!e.waiting && after(k, since)(e));
  const initial = await k.call('GET', `/instances/${thread.id}/execution-grants`);
  expect(initial.status).toBe(200);
  expect(initial.body.effective.network).not.toContain(target);

  // 回合已经开始（首条请求在途）时改审批模式。
  expect(await k.call('PUT', `/instances/${thread.id}/approval-mode`, { mode: 'ask' })).toMatchObject({ status: 200, body: { mode: 'ask', effective: 'ask' } });
  const first = await model.call(1);
  const since = mark(k);
  await first.response.emit({ type: 'item', item: curl('ask') });
  first.response.complete();
  const event = await k.waitEvent((e) => e.type === 'waiting' && e.threadId === thread.id && !!e.waiting && after(k, since)(e));
  const waiting = (event as Extract<Envelope, { type: 'waiting' }>).waiting!;
  expect(waiting).toMatchObject({ kind: 'approval', tool: 'shell', target, mustAsk: false });
  const pending = await state(k, thread.id);
  expect(pending.phase).toBe('running');
  expect(pending.waiting).toEqual(waiting);
  expect(model.calls.values).toHaveLength(1);

  expect(await k.call('POST', `/threads/${thread.id}/waiting/${waiting.id}`, { decision: 'remember' })).toEqual({ status: 200, body: { ok: true } });
  const second = await model.call(2);
  expect(resultOf(second.request, 'ask')?.output).toContain('status=502');
  expect((await state(k, thread.id)).waiting).toBeUndefined();
  const remembered = await k.call('GET', `/instances/${thread.id}/execution-grants`);
  expect(remembered.body.grants.add.network).toEqual([...initial.body.grants.add.network, target]);
  expect(remembered.body.effective.network).toContain(target);
  expect(second.request.history.filter((entry) => entry.type === 'notification'
    && entry.notification.kind === 'execution.permissions.changed')).toHaveLength(1);

  const again = mark(k);
  await second.response.emit({ type: 'item', item: curl('remembered') });
  second.response.complete();
  const third = await model.call(3);
  expect(resultOf(third.request, 'remembered')?.output).toContain('status=502');
  expect(asked(again)).toEqual([]);
  const idle = mark(k);
  third.response.complete();
  await waitIdle(k, thread.id, idle);
}, 1000);
