/**
 * 等人回应（docs/工具审批与提问.md）：自研后端线程用 question 提问不阻塞，工具立即返回请求 ID，请求存进库、挂在线程状态的 asks 里，
 * 用户经 HTTP 回应后结果作为一条来源为 kite 的输入交给线程；shell 连名单外主机时停下来问是审批，回合停在工具调用上。
 * 模型用 ManualModel，不起 Claude Code；命令在真实沙箱里跑。
 */
import { afterEach, expect, test } from 'bun:test';
// 询问模式的沙箱宿主按路径起子进程，不在 import 链上；按文本引入，宿主改动时 .kite/check 才会选中这里。
import '../../src/execution/sandbox-callback-host.ts' with { type: 'text' };
import type { Envelope } from '../../src/events.ts';
import type { Input, Json, ModelItem, ModelRequest, ToolResult } from '../../src/harness/types.ts';
import type { DisplayState } from '../../src/transcript/protocol.ts';
import type { Ask, Question } from '../../src/waiting.ts';
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
const inputs = (request: ModelRequest): Input[] => request.history.flatMap((entry) => entry.type === 'input' ? [entry.input] : []);

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

/**
 * 建一个自研后端线程，模型在第一次请求里调 question；等状态里挂出这项提问，再取同一回合的第二次请求（还没放行，线程在跑）。
 * 工具不等回答：第二次请求里这次调用已有成功结果，写明请求 ID。
 */
async function ask(model = new ManualModel()) {
  const k = kited = startKited(() => model);
  const registered = await addProject(k, { path: newDir(k.root, 'project', { 'a.txt': 'a\n' }) });
  const thread = await createWorkspace(k, registered.id, '先问清楚再做', 'harness');
  const first = await model.call(1);
  expect(first.request.allowedTools).toContain('question');
  const since = mark(k);
  await first.response.emit({ type: 'item', item: calledItem('ask', 'question', { questions } as unknown as Json) });
  first.response.complete();
  const event = await k.waitEvent((e) => e.type === 'asks' && e.threadId === thread.id && e.asks.length > 0 && after(k, since)(e));
  const asks = (event as Extract<Envelope, { type: 'asks' }>).asks;
  expect(asks).toHaveLength(1);
  const asked = asks[0]!;
  const second = await model.call(2);
  const result = resultOf(second.request, 'ask');
  expect(result?.status).toBe('success');
  expect(result?.output).toContain(`已向用户提问，请求 ID 是 ${asked.id}`);
  return { k, model, threadId: thread.id, asked, second };
}

const state = async (k: Kited, threadId: string) => {
  const r = await k.call('GET', `/threads/${threadId}/state`);
  expect(r.status).toBe(200);
  return r.body as DisplayState;
};
const respond = (k: Kited, threadId: string, ask: Ask, body: unknown) => k.call('POST', `/threads/${threadId}/waiting/${ask.id}`, body);

/*
 * 几个部分的配合：question 工具把请求存进库就返回，回合照常往下走、结束；提问留在显示投影的 asks 里（waiting 只放审批），
 * kited 重启后从库里读回来照常能回应。回应在线程空闲时开始新回合，回答按问题顺序写成一条来源为 kite 的输入出现在模型请求里，
 * 交上之后请求撤下；回应过的请求不能再回应。
 */
test('question 不等回答：工具立即返回请求 ID，提问挂在状态的 asks 里而不是 waiting，回合照常结束，kited 重启后提问还在；空闲时回应开始新回合，回答作为来源为 kite 的输入交给模型，提问撤下，再回应得 409', async () => {
  const model = new ManualModel();
  const { k, threadId, asked, second } = await ask(model);
  expect(asked.kind === 'question' && asked.questions).toEqual(questions);
  expect(asked.since).toBeGreaterThan(0);
  const running = await state(k, threadId);
  expect(running.phase).toBe('running');
  expect(running.waiting).toBeUndefined();
  expect(running.asks).toEqual([asked]);
  let since = mark(k);
  second.response.complete();
  await waitIdle(k, threadId, since);
  expect(model.calls.values).toHaveLength(2);

  await k.halt();
  const restarted = kited = startKited(() => model, false, { root: k.root });
  const idle = await state(restarted, threadId);
  expect(idle.phase).toBe('idle');
  expect(idle.waiting).toBeUndefined();
  expect(idle.asks).toEqual([asked]);

  const answers = { answers: [{ other: '先用内存，以后再说' }, { selected: ['macOS', 'iOS'] }] };
  expect(await respond(restarted, threadId, asked, answers)).toEqual({ status: 200, body: { ok: true } });
  expect((await state(restarted, threadId)).asks ?? []).toEqual([]);
  const third = await model.call(3);
  const answer = inputs(third.request).at(-1);
  expect(answer?.source).toBe('kite');
  expect(answer?.text.split('\n')).toEqual([
    `用户回答了你的提问（请求 ${asked.id}）：`,
    '- 用哪个存储方案？', '  回答：其他：先用内存，以后再说',
    '- 先支持哪些平台？', '  回答：「macOS」；「iOS」',
  ]);

  const again = await respond(restarted, threadId, asked, answers);
  expect(again.status).toBe(409);
  expect(again.body.waiting).toBeNull();
  since = mark(restarted);
  third.response.complete();
  await waitIdle(restarted, threadId, since);
}, 1000);

/*
 * 几个部分的配合：停止会话只停回合，不撤下没回应的提问。之后线程在跑时回应，结果排进 runner 的待处理输入，
 * 在同一回合的下一次模型请求里纳入，不另起回合；代理收回已回应过的请求，工具说明它可能已经回应或收回。
 */
test('提问后停止会话：停止能完成、线程回到 idle，提问仍在 asks 里；新回合在跑时用户不回答，这条说明在同一回合的下一次请求里交给模型并列出各题，提问撤下，代理再收回它得到可能已回应或收回的说明', async () => {
  const { k, model, threadId, asked } = await ask();
  let since = mark(k);
  expect((await k.call('POST', `/threads/${threadId}/interrupt`, { id: 'stop' })).status).toBe(200);
  await waitIdle(k, threadId, since);
  const stopped = await state(k, threadId);
  expect(stopped.phase).toBe('idle');
  expect(stopped.waiting).toBeUndefined();
  expect(stopped.asks).toEqual([asked]);

  expect((await k.call('POST', `/threads/${threadId}/messages`, { id: 'next', text: '先做别的' })).status).toBe(200);
  const third = await model.call(3);
  since = mark(k);
  expect(await respond(k, threadId, asked, { decision: 'deny' })).toEqual({ status: 200, body: { ok: true } });
  expect((await state(k, threadId)).asks ?? []).toEqual([]);
  await third.response.emit({ type: 'item', item: calledItem('late', 'question', { withdraw: asked.id }) });
  third.response.complete();
  const fourth = await model.call(4);
  expect(k.events.filter((e) => e.type === 'idle' && e.threadId === threadId && after(k, since)(e))).toEqual([]);
  const denied = inputs(fourth.request).filter((input) => input.source === 'kite' && input.text.includes(asked.id));
  expect(denied.map((input) => input.text.split('\n'))).toEqual([
    [`用户没有回答你的提问（请求 ${asked.id}），关掉了：`, '- 用哪个存储方案？', '- 先支持哪些平台？'],
  ]);
  expect(resultOf(fourth.request, 'late')?.output).toContain('已经回应或收回');
  since = mark(k);
  fourth.response.complete();
  await waitIdle(k, threadId, since);
}, 1000);

/*
 * 几个部分的配合：用户发消息（带 skipWaiting 也一样）只是一条新输入，不撤下没回应的提问；代理读到消息后用 withdraw 收回，
 * 提问从库与状态里撤下，之后回应得 409。
 */
test('提问留着时用户直接发带 skipWaiting 的消息不撤下提问，消息照常进下一次请求；代理用 withdraw 收回后提问撤下，回应收回的提问得 409', async () => {
  const { k, model, threadId, asked, second } = await ask();
  const text = '先不选了，存储用 SQLite，平台只做 macOS';
  expect((await k.call('POST', `/threads/${threadId}/messages`, { id: 'skip', text, skipWaiting: asked.id })).status).toBe(200);
  expect((await state(k, threadId)).asks).toEqual([asked]);

  let since = mark(k);
  await second.response.emit({ type: 'item', item: calledItem('withdraw', 'question', { withdraw: asked.id }) });
  second.response.complete();
  const third = await model.call(3);
  expect(inputs(third.request).find((input) => input.id === 'skip')).toEqual({ id: 'skip', text, source: 'human' });
  const withdrawn = resultOf(third.request, 'withdraw');
  expect([withdrawn?.status, withdrawn?.output]).toEqual(['success', '已收回。']);
  await k.waitEvent((e) => e.type === 'asks' && e.threadId === threadId && e.asks.length === 0 && after(k, since)(e));
  expect((await state(k, threadId)).asks ?? []).toEqual([]);
  const late = await respond(k, threadId, asked, { answers: [{ selected: ['SQLite（推荐）'] }, { selected: ['macOS'] }] });
  expect(late.status).toBe(409);
  expect(late.body.waiting).toBeNull();

  since = mark(k);
  third.response.complete();
  await waitIdle(k, threadId, since);
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
