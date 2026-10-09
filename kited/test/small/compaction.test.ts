/**
 * 自研 harness 的上下文压缩：手动与自动压缩、嵌套与撤销、停止压缩，以及显示投影。
 * 都是几个部分的配合：runner 运行中的历史、journal 重放、后台摘要请求与停止/插话的时序、投影把 seq 范围换成显示记录。
 */
import { expect, test } from 'bun:test';
import { assembleContext, literalContext } from '../../src/harness/context/assembler.ts';
import type {
  ContextItem, HarnessEvent, HarnessOptions, JsonObject, Model, ModelItem, ThreadNotification,
} from '../../src/harness/types.ts';
import { TranscriptFeed } from '../../src/transcript/feed.ts';
import { TranscriptProjection } from '../../src/transcript/projection.ts';
import type { ThreadContext } from '../../src/model.ts';
import { input, item, ManualModel, success, tool, useHarness, waitRecord } from '../harness-loop.ts';

const h = useHarness();

/** 订阅 Responses 格式的助手文字；摘要请求只取这种条目的正文。 */
const message = (id: string, text: string): ModelItem => ({
  id, raw: { type: 'message', role: 'assistant', content: [{ type: 'output_text', text }] },
});

const notice = (id: string, sequence: number, kind: string): ThreadNotification => ({
  id, sequence, kind, source: 'test', authority: 'instruction',
  context: assembleContext(literalContext(`通知正文 ${id}`)).snapshot,
});

/** 投递给定的通知列表，按游标只给未投递的部分。 */
function requests(model: Model, notices: ThreadNotification[] = [], extra: { autoCompactTokens?: number; maxRequestsPerTurn?: number } = {}) {
  const prepareRequest: HarnessOptions['prepareRequest'] = ({ afterNotification }) => ({
    model, tools: [tool('noop', async () => success('无事'))], instructions: '测试主循环',
    settings: { maxRequestsPerTurn: extra.maxRequestsPerTurn },
    autoCompactTokens: extra.autoCompactTokens,
    notifications: notices.filter((entry) => entry.sequence! > afterNotification),
  });
  return prepareRequest;
}

const summaries = ['第二轮摘要', '内层摘要', '外层摘要', '自动摘要'];
/** 把历史条目缩写成可读标签，便于整段比较。 */
function shape(history: ContextItem[]): string[] {
  return history.map((entry) => {
    switch (entry.type) {
      case 'input': return `人:${entry.input.id}`;
      case 'output': return `答:${entry.item.id}`;
      case 'tool_result': return `结果:${entry.callId}`;
      case 'feedback': return '反馈';
      case 'notification': {
        if (entry.notification.kind === 'context.summary') {
          return `摘要:${summaries.filter((text) => entry.text.includes(text)).join('+')}`;
        }
        if (entry.notification.kind === 'files.changed') return '文件变化';
        return `通知:${entry.notification.id}`;
      }
    }
  });
}

/** 把 runner 事件接进真实显示投影，读它给客户端的快照。 */
function projected() {
  const thread = { id: 'thread', status: 'open', runtime: 'harness', workspace: { status: 'open' } } as ThreadContext;
  const projection = new TranscriptProjection(thread, new TranscriptFeed());
  projection.finishReplay();
  return {
    projection,
    onEvent(event: HarnessEvent) { projection.accept({ type: 'harness', event, threadId: thread.id, at: Date.now() }); },
    record(predicate: (block: { type: string; [key: string]: unknown }) => boolean) {
      return projection.snapshot().records.find((record) => predicate(record.block as { type: string }));
    },
  };
}

/** 一轮完整对话：发输入、模型回一段文字、回合收尾。 */
async function round(runner: { send: (value: ReturnType<typeof input>) => Promise<void>; settled(): Promise<void> },
  model: ManualModel, number: number, id: string, usage?: JsonObject) {
  await runner.send(input(id));
  const call = await model.call(number);
  await call.response.emit({ type: 'item', item: message(`out-${id}`, `回答 ${id}`) });
  void call.response.emit({ type: 'completed', responseId: `response-${id}`, ...(usage ? { usage } : {}) });
  call.response.finish();
  await runner.settled();
  return call;
}

async function summarize(model: ManualModel, number: number, text: string) {
  const call = await model.call(number);
  await call.response.emit({ type: 'item', item: message(`summary-${number}`, text) });
  call.response.complete(`summary-response-${number}`);
  return call;
}

// 运行中的历史、摘要请求的截断、状态通知取舍、重放后的历史和投影的范围换算要一致；单看各部分都对，合起来才知道。
test('手动压缩中间一轮：前后原样、范围换成摘要与仍有效的状态通知，重开后历史相同，投影指向首尾显示记录', async () => {
  const root = h.root();
  const model = new ManualModel();
  const notices: ThreadNotification[] = [];
  const view = projected();
  let filesAsked = 0;
  const options = {
    prepareRequest: requests(model, notices),
    onEvent: view.onEvent,
    async compactionFiles() { filesAsked++; return '修改 a.txt (+1 -0)'; },
  };
  const { runner, events } = h.runner(root, options);

  notices.push(notice('A1', 1, 'agent.configuration.changed'));
  const first = await round(runner, model, 1, 'r1');
  notices.push(notice('P1', 2, 'execution.permissions.changed'), notice('A2', 3, 'agent.configuration.changed'),
    notice('P2', 4, 'execution.permissions.changed'));
  const second = await round(runner, model, 2, 'r2', { input_tokens: 1200, output_tokens: 30 });
  notices.push(notice('A3', 5, 'agent.configuration.changed'));
  const third = await round(runner, model, 3, 'r3', { input_tokens: 1500, output_tokens: 30 });
  expect(view.projection.state().context).toBeDefined();
  expect(view.projection.state().capabilities.compact).toBe(true);

  await runner.compact({ id: 'c1', from: 'r2', through: 'r2' });
  const summary = await model.call(4);
  // 摘要请求只带到范围末尾（第二轮的回答），再追加摘要指令；不许调用工具。
  expect(summary.request.history.slice(0, -1)).toEqual([...second.request.history, { type: 'output', item: message('out-r2', '回答 r2') }]);
  expect(summary.request.history.at(-1)?.type).toBe('feedback');
  expect(summary.request.allowedTools).toEqual([]);
  expect(runner.state).toMatchObject({ busy: true, compacting: true });
  expect(view.projection.state().capabilities.compact).toBe(false);
  await summary.response.emit({ type: 'item', item: message('summary', '第二轮摘要') });
  summary.response.complete('summary-response');
  await waitRecord(events, (record) => record.type === 'context.compacted' && record.id === 'c1');
  await runner.settled();
  expect(filesAsked).toBe(1);
  // 旧的实测用量包含被压缩的原文，投影须清除。
  expect(view.projection.state().context).toBeUndefined();

  await runner.send(input('r4'));
  const fourth = await model.call(5);
  // 第一轮（含其中的 A1）原样；第二轮换成摘要、净文件变化和范围内仍有效的状态通知：
  // A2 之后还有同类 A3 所以丢弃，执行授权只留范围内最新的 P2。第三轮原样。
  const prefix = first.request.history.length + 1;
  expect(fourth.request.history.slice(0, prefix)).toEqual(second.request.history.slice(0, prefix));
  expect(shape(fourth.request.history.slice(prefix))).toEqual([
    '摘要:第二轮摘要', '文件变化', '通知:P2',
    ...shape(third.request.history.slice(second.request.history.length + 1)), '答:out-r3', '人:r4',
  ]);
  expect(shape(first.request.history)).toEqual(['通知:A1', '人:r1']);
  fourth.response.complete();
  await runner.settled();

  // 投影：压缩块指向范围首尾的显示记录；空闲后又能压缩。
  const human = view.record((block) => block.type === 'human' && block.id === 'r2');
  const answer = view.record((block) => block.type === 'text' && block.text === '回答 r2');
  expect(human && answer).toBeTruthy();
  const compacted = view.projection.snapshot().records.find((record) => record.id === 'compaction:c1');
  expect(compacted?.block).toMatchObject({ type: 'compacted', from: human?.id, through: answer?.id, automatic: false });
  expect(compacted?.block.type === 'compacted' && compacted.block.reverted).toBeFalsy();
  expect(view.projection.state().capabilities.compact).toBe(true);

  // 重放：关闭后重开同一 journal，下一次请求看到的历史与运行中一致。
  await runner.shutdown();
  const reopenedModel = new ManualModel();
  const reopened = h.runner(root, { prepareRequest: requests(reopenedModel, notices) });
  await reopened.runner.send(input('r5'));
  const fifth = await reopenedModel.call(1);
  expect(fifth.request.history).toEqual([...fourth.request.history, { type: 'input', input: input('r5') }]);
  fifth.response.complete();
  await reopened.runner.settled();
}, 1000);

// 嵌套与撤销叠加之后，下一次真实请求的历史取决于 runner 对多条压缩/撤销记录的叠加；投影同一记录标记撤销。
test('外层压缩完整包含内层，部分重叠与撤销内层被拒绝，撤销外层后内层压缩重新生效', async () => {
  const model = new ManualModel();
  const view = projected();
  const { runner, events } = h.runner(h.root(), { prepareRequest: requests(model), onEvent: view.onEvent });
  for (const [index, id] of ['r1', 'r2', 'r3', 'r4'].entries()) await round(runner, model, index + 1, id);

  await runner.compact({ id: 'inner', from: 'r2', through: 'r3' });
  await summarize(model, 5, '内层摘要');
  await waitRecord(events, (record) => record.type === 'context.compacted' && record.id === 'inner');
  await runner.settled();
  await expect(runner.compact({ id: 'overlap', from: 'r3', through: 'r4' })).rejects.toThrow();

  await runner.compact({ id: 'outer', from: 'r1', through: 'r3' });
  // 外层摘要的材料里，内层范围已经是内层摘要。
  const outerSummary = await model.call(6);
  expect(shape(outerSummary.request.history)).toEqual(['人:r1', '答:out-r1', '摘要:内层摘要', '反馈']);
  await outerSummary.response.emit({ type: 'item', item: message('summary-outer', '外层摘要') });
  outerSummary.response.complete();
  await waitRecord(events, (record) => record.type === 'context.compacted' && record.id === 'outer');
  await runner.settled();
  await expect(runner.revertCompaction('inner')).rejects.toThrow();

  const fifth = await round(runner, model, 7, 'r5');
  expect(shape(fifth.request.history)).toEqual(['摘要:外层摘要', '人:r4', '答:out-r4', '人:r5']);

  await runner.revertCompaction('outer');
  await waitRecord(events, (record) => record.type === 'context.compaction.reverted' && record.id === 'outer');
  const sixth = await round(runner, model, 8, 'r6');
  expect(shape(sixth.request.history)).toEqual([
    '人:r1', '答:out-r1', '摘要:内层摘要', '人:r4', '答:out-r4', '人:r5', '答:out-r5', '人:r6',
  ]);
  const block = (id: string) => view.projection.snapshot().records.find((record) => record.id === `compaction:${id}`)?.block;
  expect(block('outer')).toMatchObject({ type: 'compacted', reverted: true });
  expect(block('inner')).toMatchObject({ type: 'compacted' });
  expect(block('inner')).not.toHaveProperty('reverted', true);
}, 1000);

// 自动压缩夹在回合内两次请求之间：估算、后台摘要、请求预算和「压缩后未有新实测用量不再触发」要一起对。
test('估算用量超过上限时回合内先自动压缩并保留人发原文，压缩不占请求预算，紧接的请求不再压缩', async () => {
  const model = new ManualModel();
  const { runner, journal, events } = h.runner(h.root(), {
    prepareRequest: requests(model, [], { autoCompactTokens: 1000, maxRequestsPerTurn: 2 }),
  });
  await runner.send({ id: 'k1', text: 'Kite 发的输入', source: 'kite' });
  const first = await model.call(1);
  first.response.complete();
  await runner.settled();
  await round(runner, model, 2, 'r1', { input_tokens: 5000, output_tokens: 100 });

  await runner.send(input('r2'));
  const summary = await model.call(3);
  expect(summary.request.allowedTools).toEqual([]);
  expect(shape(summary.request.history)).toEqual(['人:k1', '人:r1', '答:out-r1', '反馈']);
  await summary.response.emit({ type: 'item', item: message('summary-auto', '自动摘要') });
  summary.response.complete();
  const compacted = await waitRecord(events, (record) => record.type === 'context.compacted');
  expect(compacted.type === 'record' && compacted.record.type === 'context.compacted' && compacted.record.automatic).toBe(true);

  const next = await model.call(4);
  expect(next.request.turnId).toBe(summary.request.turnId);
  expect(shape(next.request.history)).toEqual(['人:r1', '摘要:自动摘要', '人:r2']);
  expect(next.request.history[0]).toEqual({ type: 'input', input: input('r1') });
  // 这次请求没有给出用量，估算仍沿用压缩前的实测值；不能因此再压缩一次。
  await next.response.emit({ type: 'item', item: item('call-1', 'noop') });
  next.response.complete();
  const after = await model.call(5);
  expect(after.request.allowedTools).not.toEqual([]);
  expect(shape(after.request.history)).toEqual(['人:r1', '摘要:自动摘要', '人:r2', '答:call-1', '结果:call-1']);
  after.response.complete();
  await runner.settled();
  expect(runner.state.lastOutcome).toEqual({ kind: 'completed' });
  expect(journal.records.filter((record) => record.type === 'context.compacted')).toHaveLength(1);
}, 1000);

// 停止与后台摘要请求的时序：压缩期间收到的输入按停止语义退回，取消的压缩不留记录也不报失败。
test('停止进行中的手动压缩：取消摘要请求、退回期间收到的输入，历史不变且不报错', async () => {
  const model = new ManualModel();
  const { runner, journal, events } = h.runner(h.root(), { prepareRequest: requests(model) });
  await round(runner, model, 1, 'r1');
  const second = await round(runner, model, 2, 'r2');

  await runner.compact({ id: 'stopped', from: 'r1', through: 'r1' });
  const summary = await model.call(3);
  await runner.send(input('during'));
  expect(model.calls.values).toHaveLength(3);
  expect(await runner.interrupt({ id: 'stop' })).toEqual([input('during')]);
  expect(summary.signal.aborted).toBe(true);
  await runner.settled();
  expect(runner.state).toMatchObject({ phase: 'idle', busy: false });
  expect(runner.state.compacting).toBeFalsy();
  expect(journal.records.some((record) => record.type === 'context.compacted')).toBe(false);
  expect(events.values.filter((event) => event.type === 'error')).toEqual([]);

  const third = await round(runner, model, 4, 'r3');
  expect(third.request.history).toEqual([...second.request.history,
    { type: 'output', item: message('out-r2', '回答 r2') }, { type: 'input', input: input('r3') }]);
}, 1000);
