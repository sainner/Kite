import { afterEach, expect, test } from 'bun:test';
import type { Envelope } from '../../src/events.ts';
import type { Json, ModelItem, ModelRequest } from '../../src/harness/types.ts';
import type { Report, ReportStatus } from '../../src/model.ts';
import { reportAnswerRequest, type ReportAnswerRequest } from '../../src/reports.ts';
import { after, type Kited, mark, registerCheckout, startKited, waitIdle } from '../harness.ts';
import { item, ManualModel } from '../harness-loop.ts';
import { newRepo } from '../util.ts';

let kited: Kited | undefined;
afterEach(async () => { await kited?.stop(); kited = undefined; });

/** 每个线程一个手动模型，调用序号按线程分开数。 */
function startWithModels() {
  const models = new Map<string, ManualModel>();
  const modelOf = (threadId: string) => {
    let model = models.get(threadId);
    if (!model) { model = new ManualModel(); models.set(threadId, model); }
    return model;
  };
  const k = startKited((thread) => modelOf(thread.id));
  return { k, modelOf };
}

/** 登记一个检出，在它的根工作区里起代理线程；不建工作树，git 调用最少。 */
async function rootWorkspace(k: Kited): Promise<string> {
  const repo = newRepo(k.root, 'project', { 'base.txt': '原始\n' });
  return (await registerCheckout(k, repo)).workspace.id;
}

async function startAgent(k: Kited, workspaceId: string, operationId: string): Promise<string> {
  const started = await k.call('POST', `/workspaces/${workspaceId}/operations/agent.start`, { operationId });
  if (started.status !== 200) throw new Error(`起代理失败：${started.status} ${JSON.stringify(started.body)}`);
  return started.body.instanceId as string;
}

async function send(k: Kited, threadId: string, id: string, text: string): Promise<void> {
  const sent = await k.call('POST', `/threads/${threadId}/messages`, { id, text });
  if (sent.status !== 200) throw new Error(`发消息失败：${sent.status} ${JSON.stringify(sent.body)}`);
}

const answer = (k: Kited, threadId: string, reportId: string, body: ReportAnswerRequest) =>
  k.call('POST', `/threads/${threadId}/reports/${reportId}/answer`, reportAnswerRequest.parse(body));

async function reports(k: Kited, threadId: string): Promise<Report[]> {
  const listed = await k.call('GET', `/threads/${threadId}/reports`);
  if (listed.status !== 200) throw new Error(`取上报失败：${listed.status} ${JSON.stringify(listed.body)}`);
  return listed.body as Report[];
}

const reportCall = (id: string, args: Json): ModelItem => ({ ...item(id, 'report'), call: { id, name: 'report', arguments: args } });

const inputs = (request: ModelRequest) => request.history.flatMap((entry) => entry.type === 'input' ? [entry.input] : []);

/** 模型在第 number 次请求里调 report，返回下一次请求（已带工具结果、仍挂着）与工具返回的上报 ID。 */
async function raiseReport(model: ManualModel, number: number, callId: string, args: Json) {
  const call = await model.call(number);
  expect(call.request.allowedTools).toContain('report');
  await call.response.emit({ type: 'item', item: reportCall(callId, args) });
  call.response.complete();
  const next = await model.call(number + 1);
  const result = next.request.history.find((entry) => entry.type === 'tool_result' && entry.callId === callId);
  if (result?.type !== 'tool_result') throw new Error('report 调用没有结果');
  expect(result.result.status).toBe('success');
  const output = JSON.parse(result.result.output) as { reportId: string; status: string };
  expect(output.status).toBe('open');
  return { next, reportId: output.reportId };
}

const reportEvent = (reportId: string, status: ReportStatus, since = 0) => (k: Kited) =>
  k.waitEvent((event) => event.type === 'report.changed' && event.report.id === reportId
    && event.report.status === status && after(k, since)(event));

/** 事件流里这个上报依次经过的状态，相邻重复的只算一次。 */
function statusTrail(events: Envelope[], reportId: string): ReportStatus[] {
  const trail: ReportStatus[] = [];
  for (const event of events) {
    if (event.type !== 'report.changed' || event.report.id !== reportId) continue;
    if (trail.at(-1) !== event.report.status) trail.push(event.report.status);
  }
  return trail;
}

const chain: ReportStatus[] = ['open', 'answered', 'delivered', 'incorporated', 'closed'];
/**
 * 状态只沿交接链前进，从 open 起到 closed 止，不回退。线程空闲时纳入可能先于投递收尾，
 * delivered 允许被 incorporated 越过；越过之后不能再退回 delivered。
 */
function expectForward(trail: ReportStatus[]) {
  expect(trail).toEqual(chain.filter((status) => trail.includes(status)));
  expect(trail).toEqual(expect.arrayContaining(['open', 'answered', 'incorporated', 'closed']));
}

// 几个部分的配合：HTTP 保存答复、Kite.send 把答复落成 human 输入、harness 的 request.started 记下纳入的输入、回合结束收口，
// 各推进一步。输入落盘后下一次请求可能在投递收尾之前就开始，晚到的 delivered 会把 incorporated 盖回去；
// 答复本身也是 human 输入，不能把自己的上报判成 superseded。这些要跑起来看事件顺序。
test('question 上报答复后状态沿交接链前进不回退，纳入请求的回合结束才 closed，模型拿到用户原文', async () => {
  const { k, modelOf } = startWithModels();
  kited = k;
  const workspaceId = await rootWorkspace(k);
  const threadId = await startAgent(k, workspaceId, 'asker');
  const model = modelOf(threadId);
  await send(k, threadId, 'kickoff', '开始');
  const { next, reportId } = await raiseReport(model, 1, 'ask', {
    kind: 'question', text: '用哪种存储？', refs: ['src/store.ts:10-20'],
  });
  next.response.complete();
  await waitIdle(k, threadId);

  expect(await reports(k, threadId)).toEqual([expect.objectContaining({
    id: reportId, threadId, workspaceId, kind: 'question', text: '用哪种存储？', refs: ['src/store.ts:10-20'], status: 'open',
  })]);

  const since = mark(k);
  const answered = await answer(k, threadId, reportId, { id: 'reply', text: '用 SQLite' });
  expect(answered.status).toBe(200);
  expect(answered.body).toMatchObject({ id: reportId, answer: { inputId: 'reply', text: '用 SQLite' } });

  const consumed = await model.call(3);
  expect(inputs(consumed.request)).toContainEqual({ id: 'reply', text: '用 SQLite', source: 'human' });
  await reportEvent(reportId, 'incorporated', since)(k);
  expect((await reports(k, threadId))[0]!.status).toBe('incorporated');

  consumed.response.complete();
  await reportEvent(reportId, 'closed', since)(k);
  await waitIdle(k, threadId, since);
  expectForward(statusTrail(k.events, reportId));
  expect((await reports(k, threadId))[0]!.status).toBe('closed');
  expect(model.calls.values).toHaveLength(3);
}, 1000);

// 几个部分的配合：普通消息走 agent.send 进线程，上报要从这条输入得知自己被取代；之后的答复要被拒绝，且不能再作为输入送进线程。
test('上报 open 时用户发了别的消息即 superseded，之后的答复返回 409 带当前上报，也不进线程', async () => {
  const { k, modelOf } = startWithModels();
  kited = k;
  const workspaceId = await rootWorkspace(k);
  const threadId = await startAgent(k, workspaceId, 'asker');
  const model = modelOf(threadId);
  await send(k, threadId, 'kickoff', '开始');
  const { next, reportId } = await raiseReport(model, 1, 'ask', { kind: 'question', text: '要不要删旧接口？' });
  next.response.complete();
  await waitIdle(k, threadId);

  const since = mark(k);
  await send(k, threadId, 'unrelated', '先别管那个，改 README');
  await reportEvent(reportId, 'superseded', since)(k);
  const running = await model.call(3);

  const late = await answer(k, threadId, reportId, { id: 'late-reply', text: '删掉' });
  expect(late.status).toBe(409);
  expect(late.body.report).toMatchObject({ id: reportId, status: 'superseded' });

  running.response.complete();
  await waitIdle(k, threadId, since);
  // 回合只在没有排队输入时结束；被拒的答复若仍送进了线程，这里会多一次请求。
  expect(model.calls.values).toHaveLength(3);
  expect(inputs(running.request).map((input) => input.id)).not.toContain('late-reply');
  expect((await reports(k, threadId))[0]!.status).toBe('superseded');
}, 1000);

// 几个部分的配合：答复投递撞上同一 cwd 的执行互斥（send 409）停在 answered；另一线程回到 idle 时由 idle 事件触发补送，
// 补送时另一线程必须已真正放开工作区，否则补送又撞 409 而丢掉。确认类答复的正文由宿主拼成「同意。」加另起一段的附言。
test('同工作区另一线程在跑时答复停在 answered，那个线程回到 idle 后自动补送并推进到 closed', async () => {
  const { k, modelOf } = startWithModels();
  kited = k;
  const workspaceId = await rootWorkspace(k);
  const asker = await startAgent(k, workspaceId, 'asker');
  const busy = await startAgent(k, workspaceId, 'busy');
  const askerModel = modelOf(asker);
  const busyModel = modelOf(busy);
  await send(k, asker, 'kickoff', '开始');
  const { next, reportId } = await raiseReport(askerModel, 1, 'confirm-call', { kind: 'confirm', text: '可以改公共接口吗？' });
  next.response.complete();
  await waitIdle(k, asker);

  await send(k, busy, 'busy-work', '跑一会');
  const busyCall = await busyModel.call(1);
  const since = mark(k);
  const answered = await answer(k, asker, reportId, { id: 'confirm-reply', decision: 'yes', note: '保留旧名字做别名' });
  expect(answered.status).toBe(200);
  expect(answered.body.status).toBe('answered');
  expect((await reports(k, asker))[0]).toMatchObject({ status: 'answered', answer: { inputId: 'confirm-reply', decision: 'yes' } });
  expect(askerModel.calls.values).toHaveLength(2);

  busyCall.response.complete();
  await waitIdle(k, busy, since);
  const consumed = await askerModel.call(3);
  const delivered = inputs(consumed.request).find((input) => input.id === 'confirm-reply');
  expect(delivered?.source).toBe('human');
  expect(delivered?.text).toMatch(/^同意。\n\s*\n保留旧名字做别名$/);
  await reportEvent(reportId, 'incorporated', since)(k);
  consumed.response.complete();
  await reportEvent(reportId, 'closed', since)(k);
  expectForward(statusTrail(k.events, reportId));
}, 1000);

// 几个部分的配合：答复送到时线程还在跑，输入排在队里尚未纳入；停止把排队输入退回，上报要跟着回到 open、清掉答复，
// 重新答复要被接受。归档时先停线程再关上报：idle 事件到达时回合是被打断的，已纳入的上报不能借这次 idle 记成 closed；
// 未纳入的答复正文退回到 closure.returned，已纳入的不退。
test('答复排队未纳入时停止会退回答复且上报回到 open，归档时上报都记 archived，只有未纳入的答复正文写进 closure.returned', async () => {
  const { k, modelOf } = startWithModels();
  kited = k;
  const workspaceId = await rootWorkspace(k);
  const threadId = await startAgent(k, workspaceId, 'asker');
  const model = modelOf(threadId);
  await send(k, threadId, 'kickoff', '开始');
  const first = await raiseReport(model, 1, 'ask', { kind: 'question', text: '方案甲还是乙？' });

  // 第 2 次请求挂着，线程仍在跑：答复只能排队。
  let since = mark(k);
  expect((await answer(k, threadId, first.reportId, { id: 'reply-1', text: '用方案甲' })).status).toBe(200);
  await reportEvent(first.reportId, 'delivered', since)(k);
  since = mark(k);
  const stopped = await k.call('POST', `/threads/${threadId}/interrupt`, { id: 'stop-1' });
  expect(stopped.status).toBe(200);
  expect(first.next.signal.aborted).toBe(true);
  expect(stopped.body.returned).toContainEqual({ id: 'reply-1', text: '用方案甲', source: 'human' });
  await reportEvent(first.reportId, 'open', since)(k);
  const reopened = (await reports(k, threadId))[0]!;
  expect(reopened.status).toBe('open');
  expect(reopened.answer).toBeUndefined();
  expect(model.calls.values).toHaveLength(2);

  // 回到 open 后可以重新答复；线程空闲，答复开始新回合并被纳入。模型在这个回合里再提一个上报，并挂着下一次请求。
  since = mark(k);
  expect((await answer(k, threadId, first.reportId, { id: 'reply-2', text: '用方案乙' })).status).toBe(200);
  const second = await raiseReport(model, 3, 'ask-again', { kind: 'question', text: '乙方案的表名用什么？' });
  expect(inputs((await model.call(3)).request)).toContainEqual({ id: 'reply-2', text: '用方案乙', source: 'human' });
  await reportEvent(first.reportId, 'incorporated', since)(k);
  expect((await answer(k, threadId, second.reportId, { id: 'reply-3', text: '叫 records' })).status).toBe(200);
  await reportEvent(second.reportId, 'delivered', since)(k);

  since = mark(k);
  expect((await k.call('POST', `/instances/${threadId}/archive`)).status).toBe(200);
  await reportEvent(second.reportId, 'archived', since)(k);
  const archived = await reports(k, threadId);
  expect(archived.find((report) => report.id === second.reportId)).toMatchObject({
    status: 'archived', closure: { returned: '叫 records' },
  });
  // 归档先停下线程，回合以 interrupted 结束；纳入后的回合没有正常完成，上报不算 closed，由归档关闭。
  // 已纳入的答复模型已经看过，不退回。
  const settled = archived.find((report) => report.id === first.reportId)!;
  expect(settled.status).toBe('archived');
  expect(settled.closure?.returned).toBeUndefined();
}, 1000);
