import { afterEach, expect, test } from 'bun:test';
import { chmodSync, rmSync } from 'node:fs';
import { join } from 'node:path';
import { startDaemon, type Daemon } from '../../src/daemon.ts';
import type { WorkspaceModel } from '../../src/model.ts';
import type { FakeAccount } from '../fake-account.ts';
import { call, createWorkspace, linkNewAccount, machine, registerCheckout, startKited, type Kited } from '../harness.ts';
import { item, ManualModel, Seen } from '../harness-loop.ts';
import { commitAll, makeTemp, newRepo } from '../util.ts';

type RecordView = { id: string; at: number; block: { type: string; [key: string]: unknown }; parent?: string;
  generation?: 'streaming' | 'complete' | 'interrupted' };
type DeltaView = { id: string; field: 'text' | 'arguments' | 'output'; text: string; part?: number;
  replace?: boolean; limit?: number; input?: unknown };
type PendingView = { id: string; text: string; source: string; midTurn: boolean };
type StateView = {
  phase: string;
  busy: boolean;
  waitingForResume: boolean;
  lastOutcome?: { kind: string };
  context?: { requestId: string; inputTokens: number; windowTokens?: number; measuredAt: number };
  [key: string]: unknown;
};
type WireEvent = {
  type: string;
  threadId?: string;
  workspaceId?: string;
  checkoutId?: string;
  status?: string;
  workspaces?: unknown[];
  cursor: string;
  at: number;
  version?: number;
  records?: RecordView[];
  record?: RecordView;
  delta?: DeltaView;
  pending?: PendingView[];
  state?: StateView;
};

const roots: string[] = [];
const streams: Array<{ close(): Promise<void> }> = [];
let kited: Kited | undefined;
let daemon: Daemon | undefined;
const accounts: FakeAccount[] = [];
afterEach(async () => {
  await Promise.all(streams.splice(0).map((stream) => stream.close()));
  await daemon?.stop();
  daemon = undefined;
  await kited?.stop();
  kited = undefined;
  for (const account of accounts.splice(0)) account.stop();
  for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true });
});

async function connect(url: string, threadId?: string) {
  const ctl = new AbortController();
  const response = await fetch(`${url}/events${threadId ? `?thread=${threadId}` : ''}`, {
    headers: { 'X-Kite-Machine': (await machine(url)).id }, signal: ctl.signal,
  });
  expect(response.status).toBe(200);
  const events = new Seen<WireEvent>();
  const reading = (async () => {
    const reader = response.body!.pipeThrough(new TextDecoderStream()).getReader();
    let buffer = '';
    try {
      while (true) {
        const { value, done } = await reader.read();
        if (done) return;
        buffer += value;
        let end: number;
        while ((end = buffer.indexOf('\n\n')) >= 0) {
          const frame = buffer.slice(0, end);
          buffer = buffer.slice(end + 2);
          const data = frame.split('\n').filter((line) => line.startsWith('data: ')).map((line) => line.slice(6)).join('\n');
          if (data) events.add(JSON.parse(data) as WireEvent);
        }
      }
    } catch (error) {
      if (!ctl.signal.aborted) throw error;
    }
  })();
  const stream = {
    events,
    async close() { ctl.abort(); await reading; },
  };
  streams.push(stream);
  return stream;
}

// HTTP 快照、异步工作区事件与 SSE 目录过滤交错；第二次检出登记作流内屏障，确认正文未漏入目录。
test('目录 SSE 快照和列表响应头同序，后续变化需要更新列表', async () => {
  kited = startKited();
  const kk = kited;
  const firstRepo = newRepo(kk.root, 'first', { 'base.txt': '一\n', '.kite/setup': '#!/bin/sh\necho 已准备\n' });
  chmodSync(join(firstRepo, '.kite/setup'), 0o755);
  commitAll(firstRepo, '加准备脚本');
  const first = await registerCheckout(kk, firstRepo);
  const stream = await connect(kk.url);
  const baseline = await stream.events.wait((event) => event.type === 'catalog.snapshot');
  expect(baseline.workspaces).toContainEqual(expect.objectContaining({
    checkout: expect.objectContaining({ id: first.checkout.id }),
  }));

  const created = await kk.call('POST', '/workspaces', { checkout: first.checkout.id });
  expect(created.status).toBe(200);
  const workspaceId = created.body.workspace.id as string;
  await kk.waitEvent((event) => event.type === 'workspace.changed' && event.workspaceId === workspaceId && event.status === 'open');
  expect(created.body.threads).toEqual([]);
  expect(kk.events).toContainEqual(expect.objectContaining({ type: 'workspace.setup', workspaceId, exit: 0 }));
  expect(kk.events).toContainEqual(expect.objectContaining({ type: 'workspace.snapshot', workspaceId, label: '工作区开始' }));
  const operations = kk.events.filter((event) => event.type === 'workspace.setup' || event.type === 'workspace.snapshot');
  expect(operations.every((event) => !('threadId' in event)
    && (!('originThreadId' in event) || event.originThreadId === undefined))).toBe(true);

  const opened = await stream.events.wait((event) => event.type === 'workspace.changed' && event.workspaceId === workspaceId
    && event.status === 'open');

  const machineId = (await machine(kk.url)).id;
  const readCatalog = async () => {
    const response = await fetch(`${kk.url}/workspaces`, { headers: { 'X-Kite-Machine': machineId } });
    expect(response.status).toBe(200);
    const cursor = response.headers.get('X-Kite-Cursor');
    expect(cursor).toMatch(/^[0-9a-f-]{36}:\d+$/i);
    return { cursor: cursor!, models: await response.json() as WorkspaceModel[] };
  };
  const before = await readCatalog();
  expect(before.models.find((entry) => entry.workspace.id === workspaceId)?.threads).toEqual([]);
  expect(opened.cursor.split(':')[0]).toBe(before.cursor.split(':')[0]);
  expect(Number(opened.cursor.split(':')[1])).toBeLessThanOrEqual(Number(before.cursor.split(':')[1]));

  const secondRepo = newRepo(kk.root, 'second', { 'base.txt': '二\n' });
  const second = await registerCheckout(kk, secondRepo);
  const later = await stream.events.wait((event) => event.type === 'checkout.changed' && event.checkoutId === second.checkout.id);
  expect(later.cursor.split(':')[0]).toBe(before.cursor.split(':')[0]);
  expect(Number(later.cursor.split(':')[1])).toBeGreaterThan(Number(before.cursor.split(':')[1]));
  const after = await readCatalog();
  expect(after.models.some((entry) => entry.workspace.id === second.workspace.id)).toBe(true);
  expect(Number(later.cursor.split(':')[1])).toBeLessThanOrEqual(Number(after.cursor.split(':')[1]));
  await stream.close();
}, 1000);

function apply(events: WireEvent[]) {
  let records = new Map<string, RecordView>();
  let pending: PendingView[] = [];
  for (const event of events) {
    if (event.type === 'thread.history') {
      records = new Map(event.records!.map((record) => [record.id, record]));
      pending = event.pending!;
    } else if (event.type === 'thread.record') records.set(event.record!.id, event.record!);
    else if (event.type === 'thread.pending') pending = event.pending!;
  }
  return { records: [...records.values()], pending };
}

// 模型分段、工具执行、journal 和 SSE 重连交错：快照累计增量，完整条目同 id 校正且调用只执行一次。
test('SSE 重连保留流式分段、排队输入及交错工具结果所属的模型请求批次', async () => {
  const model = new ManualModel();
  kited = startKited(() => model);
  const kk = kited;
  const repo = newRepo(kk.root, 'project', { 'base.txt': '初始\n' });
  const project = await registerCheckout(kk, repo);
  const thread = await createWorkspace(kk, project.checkout.id, '开始', 'harness');
  const id = thread.id;
  const first = await model.call(1);
  const stream = await connect(kk.url, id);
  await stream.events.wait((event) => event.type === 'thread.history');

  await first.response.emit({ type: 'item.started', itemId: 'answer-a', kind: 'text' });
  const startedText = await stream.events.wait((event) => event.type === 'thread.record'
    && event.record?.generation === 'streaming' && event.record.block.type === 'text' && event.record.block.text === '');
  await first.response.emit({ type: 'delta', itemId: 'answer-a', field: 'text', part: 0, text: '半' });
  await first.response.emit({ type: 'delta', itemId: 'answer-a', field: 'text', part: 1, text: '另' });
  await first.response.emit({ type: 'delta', itemId: 'answer-a', field: 'text', part: 0, text: '完整', replace: true });
  const corrected = await stream.events.wait((event) => event.type === 'thread.record.delta'
    && event.delta?.id === startedText.record?.id && event.delta?.part === 0 && event.delta?.replace === true);
  expect(corrected.delta?.text).toBe('完整');
  await stream.close();

  const resumed = await connect(kk.url, id);
  const reconnected = await resumed.events.wait((event) => event.type === 'thread.history');
  expect(reconnected.records?.find((record) => record.id === startedText.record?.id)).toMatchObject({
    generation: 'streaming', block: { type: 'text', text: '完整\n\n另', parts: ['完整', '另'] },
  });

  const queued = await kk.call('POST', `/threads/${id}/messages`, { id: 'queued-a', text: '接着做' });
  expect(queued.status).toBe(200);
  await resumed.events.wait((event) => event.type === 'thread.pending' && event.pending?.some((entry) => entry.id === 'queued-a') === true);
  await first.response.emit({ type: 'item', item: { id: 'answer-a', raw: { type: 'message', content: [
    { type: 'output_text', text: '完整' }, { type: 'output_text', text: '另' },
  ] } } });
  const complete = await resumed.events.wait((event) => event.type === 'thread.record'
    && event.record?.id === startedText.record?.id && event.record?.generation === 'complete');
  expect(complete.record?.block.type).toBe('text');
  expect(complete.record?.block.text).toBe('完整\n\n另');

  const firstShell = { ...item('shell-first', 'shell'), call: { id: 'shell-first', name: 'shell', arguments: { description: '输出第一段内容', command: 'printf first' } } };
  const patch = { ...item('patch-middle', 'patch'), call: { id: 'patch-middle', name: 'patch', arguments: {
    operations: [{ type: 'create_file', path: 'batch.txt', diff: '+同批次\n+' }],
  } } };
  await first.response.emit({ type: 'item.started', itemId: firstShell.id, kind: 'tool_use', callId: firstShell.id, name: 'shell' });
  const draftTool = await resumed.events.wait((event) => event.type === 'thread.record' && event.record?.id === `call:${firstShell.id}`
    && event.record.block.stage === 'generating');
  expect(draftTool.record?.block).toMatchObject({ type: 'tool_use', id: firstShell.id, name: 'shell' });
  await first.response.emit({ type: 'delta', itemId: firstShell.id, field: 'arguments',
    text: '{"description":"输出第一段内容","command":"printf' });
  const toolArguments = await resumed.events.wait((event) => event.type === 'thread.record.delta' && event.delta?.id === `call:${firstShell.id}`
    && event.delta.field === 'arguments');
  expect(toolArguments.delta?.input).toMatchObject({ description: '输出第一段内容' });
  const generatingTool = await kk.call('GET', `/threads/${id}/history`);
  expect(generatingTool.body.records.find((record: RecordView) => record.id === `call:${firstShell.id}`)?.block)
    .toMatchObject({ stage: 'generating', input: { description: '输出第一段内容' } });
  expect(kk.events.some((event) => event.type === 'harness' && event.threadId === id
    && event.event.type === 'record' && event.event.record.type === 'tool.started'
    && event.event.record.callId === firstShell.id)).toBe(false);
  await first.response.emit({ type: 'item', item: firstShell });
  const firstUse = (await resumed.events.wait((event) => event.type === 'thread.record'
    && event.record?.id === `call:${firstShell.id}` && event.record.block.stage === 'finished')).record!;
  await resumed.events.wait((event) => event.type === 'thread.record' && event.record?.block.type === 'tool_result' && event.record.block.call === firstShell.id);
  expect(firstUse.block.output).toContain('first');
  // 上游把大型 patch 的 diff 先发来，路径和操作类型后到；SSE 概要不能带出 diff，也不能把不同数组项串位。
  const patchArguments = `{"operations":[{"diff":"${'x'.repeat(8192)}","path":"batch.txt","type":"create_file"}]}`;
  await first.response.emit({ type: 'item.started', itemId: patch.id, kind: 'tool_use', callId: patch.id, name: 'patch' });
  await first.response.emit({ type: 'delta', itemId: patch.id, field: 'arguments',
    text: patchArguments.slice(0, patchArguments.indexOf(',"path"')) });
  const diffOnly = await resumed.events.wait((event) => event.type === 'thread.record.delta'
    && event.delta?.id === `call:${patch.id}` && event.delta.text.includes('xxxx'));
  expect(JSON.stringify(diffOnly.delta?.input ?? {})).not.toContain('xxxx');
  await first.response.emit({ type: 'delta', itemId: patch.id, field: 'arguments',
    text: patchArguments.slice(patchArguments.indexOf(',"path"')) });
  const patchSummary = await resumed.events.wait((event) => event.type === 'thread.record.delta'
    && event.delta?.id === `call:${patch.id}` && event.delta.text.includes('batch.txt'));
  expect(patchSummary.delta?.input).toEqual({ operations: [{ path: 'batch.txt', type: 'create_file' }] });
  await first.response.emit({ type: 'item', item: patch });
  const patchUse = (await resumed.events.wait((event) => event.type === 'thread.record' && event.record?.block.type === 'tool_use' && event.record.block.id === patch.id)).record!;
  await resumed.events.wait((event) => event.type === 'thread.record' && event.record?.block.type === 'tool_result' && event.record.block.call === patch.id);
  expect(patchUse.block.name).toBe('patch');
  expect(typeof firstUse.block.batch).toBe('string');
  expect(firstUse.block.batch).not.toBe('');
  expect(patchUse.block.batch).toBe(firstUse.block.batch);

  const beforeFirstCompletion = resumed.events.values.length;
  await first.response.emit({ type: 'completed', responseId: 'response-first', usage: { input_tokens: 123 } });
  first.response.finish();
  const completedRecord = await kk.waitEvent((event) => event.type === 'harness' && event.threadId === id
    && event.event.type === 'record' && event.event.record.type === 'request.completed'
    && event.event.record.requestId === first.request.id);
  if (completedRecord.type !== 'harness' || completedRecord.event.type !== 'record'
    || completedRecord.event.record.type !== 'request.completed') throw new Error('缺少首请求完成记录');
  expect(completedRecord.event.record.usage).toEqual({ input_tokens: 123 });
  // 实时状态与重放按 request.started 指向的请求快照使用实际窗口。
  const harnessRecords = kk.events.flatMap((event) => event.type === 'harness' && event.threadId === id
    && event.event.type === 'record' ? [event.event.record] : []);
  const started = harnessRecords.find((record) => record.type === 'request.started' && record.requestId === first.request.id);
  if (started?.type !== 'request.started') throw new Error('缺少首请求开始记录');
  const configured = harnessRecords.find((record) => record.type === 'request.configured'
    && record.snapshot.id === started.configurationId);
  if (configured?.type !== 'request.configured') throw new Error('缺少首请求配置记录');
  expect(configured.snapshot.settings.contextWindow).toBe(272_000);
  const measured = { requestId: first.request.id, inputTokens: 123, windowTokens: 272_000,
    measuredAt: completedRecord.event.record.at };
  await resumed.events.wait((event) => resumed.events.values.indexOf(event) >= beforeFirstCompletion
    && event.type === 'thread.state' && event.state?.context?.requestId === first.request.id);
  const second = await model.call(2);
  const secondInFlight = await kk.call('GET', `/threads/${id}/history`);
  expect(secondInFlight.body.state.phase).toBe('running');
  expect(secondInFlight.body.state.context).toEqual(measured);
  await resumed.events.wait((event) => event.type === 'thread.record' && event.record?.block.type === 'human' && event.record.block.id === 'queued-a');
  await resumed.events.wait((event) => event.type === 'thread.pending' && event.pending?.some((entry) => entry.id === 'queued-a') === false);

  const secondShell = { ...item('shell-second', 'shell'), call: { id: 'shell-second', name: 'shell', arguments: { description: '输出第二段内容', command: 'printf second' } } };
  await second.response.emit({ type: 'item', item: secondShell });
  const secondUse = (await resumed.events.wait((event) => event.type === 'thread.record' && event.record?.block.type === 'tool_use' && event.record.block.id === secondShell.id)).record!;
  await resumed.events.wait((event) => event.type === 'thread.record' && event.record?.block.type === 'tool_result' && event.record.block.call === secondShell.id);
  expect(secondUse.block.name).toBe(firstUse.block.name);
  expect(typeof secondUse.block.batch).toBe('string');
  expect(secondUse.block.batch).not.toBe('');
  expect(secondUse.block.batch).not.toBe(firstUse.block.batch);
  expect(resumed.events.values.every((event) => event.type.startsWith('thread.') && event.threadId === id)).toBe(true);

  await second.response.emit({ type: 'item.started', itemId: 'thinking-unfinished', kind: 'thinking' });
  await second.response.emit({ type: 'delta', itemId: 'thinking-unfinished', field: 'thinking', part: 0, text: '仍在思考' });
  await resumed.events.wait((event) => event.type === 'thread.record.delta' && event.delta?.field === 'text'
    && event.delta.text === '仍在思考');
  await second.response.emit({ type: 'item.started', itemId: 'tool-unfinished', kind: 'tool_use',
    callId: 'call-unfinished', name: 'shell' });
  await second.response.emit({ type: 'delta', itemId: 'tool-unfinished', field: 'arguments',
    text: '{"description":"带\\n换行","meta":{"paths":["目录/甲"]},"command":"printf ' });
  const nestedArguments = await resumed.events.wait((event) => event.type === 'thread.record.delta'
    && event.delta?.id === 'call:call-unfinished' && event.delta.field === 'arguments');
  expect(nestedArguments.delta?.input).toMatchObject({ description: '带\n换行' });
  expect((nestedArguments.delta?.input as Record<string, unknown>)?.meta).toBeUndefined();
  const nestedSnapshot = await kk.call('GET', `/threads/${id}/history`);
  const nestedTool = nestedSnapshot.body.records.find((record: RecordView) => record.id === 'call:call-unfinished')?.block;
  expect(nestedTool)
    .toMatchObject({ stage: 'generating', input: { description: '带\n换行' } });
  expect(nestedTool?.arguments).toContain('"meta":{"paths":["目录/甲"]}');
  // 半个 Unicode 代理不能进入显示 JSON；补齐配对后才展示真实 emoji，期间不生成可执行调用。
  await second.response.emit({ type: 'delta', itemId: 'tool-unfinished', field: 'arguments',
    text: '\\uD83D' });
  const halfUnicode = await resumed.events.wait((event) => event.type === 'thread.record.delta'
    && event.delta?.id === 'call:call-unfinished' && event.delta.text.includes('\\uD83D'));
  const halfSnapshot = await kk.call('GET', `/threads/${id}/history`);
  const halfTool = halfSnapshot.body.records.find((record: RecordView) => record.id === 'call:call-unfinished')?.block;
  expect(halfTool?.input).toMatchObject({ description: '带\n换行' });
  expect(JSON.stringify(halfTool?.input)).not.toMatch(/\\ud83d/i);
  expect(JSON.stringify(halfUnicode.delta?.input ?? {})).not.toMatch(/\\ud83d/i);
  await second.response.emit({ type: 'delta', itemId: 'tool-unfinished', field: 'arguments',
    text: '\\uDE00"}' });
  const fullUnicode = await resumed.events.wait((event) => event.type === 'thread.record.delta'
    && event.delta?.id === 'call:call-unfinished' && event.delta.text.includes('\\uDE00'));
  expect(fullUnicode.delta?.input).toEqual({ description: '带\n换行', command: 'printf 😀' });
  expect(kk.events.some((event) => event.type === 'harness' && event.threadId === id
    && event.event.type === 'record' && event.event.record.type === 'tool.started'
    && event.event.record.callId === 'call-unfinished')).toBe(false);

  const queuedBeforeStop = { id: 'queued-before-stop', text: '停止前排队', source: 'human' as const };
  const unconfirmed = { id: 'unconfirmed-stop', text: '尚未确认发送', source: 'human' as const };
  expect((await kk.call('POST', `/threads/${id}/messages`, queuedBeforeStop)).status).toBe(200);
  await resumed.events.wait((event) => event.type === 'thread.pending'
    && event.pending?.some((entry) => entry.id === queuedBeforeStop.id) === true);
  const fromStop = resumed.events.values.length;
  const stoppedByHttp = await kk.call('POST', `/threads/${id}/interrupt`, { id: 'stop-transcript', inputs: [unconfirmed] });
  expect(stoppedByHttp.status).toBe(200);
  expect(stoppedByHttp.body.returned).toEqual([queuedBeforeStop, unconfirmed]);
  const stopped = await resumed.events.wait((event) => resumed.events.values.indexOf(event) >= fromStop
    && event.type === 'thread.state' && event.state?.phase === 'idle' && event.state.busy === false
    && event.state.lastOutcome?.kind === 'interrupted');
  await resumed.events.wait((event) => resumed.events.values.indexOf(event) >= fromStop
    && event.type === 'thread.pending' && event.pending?.length === 0);
  expect(stopped.state?.waitingForResume).toBe(false);
  expect(stopped.state?.context).toEqual(measured);
  const interruptedHistory = await kk.call('GET', `/threads/${id}/history`);
  expect(interruptedHistory.body.records.find((record: RecordView) => record.block.type === 'thinking'
    && record.block.text === '仍在思考')?.generation).toBe('interrupted');
  expect(interruptedHistory.body.records.find((record: RecordView) => record.id === 'call:call-unfinished')?.block.stage)
    .toBe('not_executed');

  await resumed.close();
  const rebuilt = await connect(kk.url, id);
  const rebuiltHistory = await rebuilt.events.wait((event) => event.type === 'thread.history');
  const calls = rebuiltHistory.records!.filter((record) => record.block.type === 'tool_use');
  expect(calls.map((record) => [record.block.id, record.block.batch])).toEqual([
    [firstShell.id, firstUse.block.batch],
    [patch.id, patchUse.block.batch],
    [secondShell.id, secondUse.block.batch],
    ['call-unfinished', secondUse.block.batch],
  ]);

  const history = await kk.call('GET', `/threads/${id}/history`);
  expect(history.status).toBe(200);
  expect(stopped.state).toEqual(history.body.state);
  expect(rebuiltHistory.state).toEqual(history.body.state);
  const replayed = apply(rebuilt.events.values);
  expect(replayed.records).toEqual(history.body.records);
  expect(replayed.pending).toEqual(history.body.pending);
  expect(replayed.pending).toEqual([]);
  expect(replayed.records.filter((record) => record.block.type === 'human' && record.block.id === 'queued-a')).toHaveLength(1);
  expect(replayed.records.filter((record) => record.id === startedText.record?.id)).toHaveLength(1);
  expect(model.calls.values).toHaveLength(2);

  // 新请求缺少模型用量时清除上次测量；实时状态和之后的完整快照不能把旧值归给新请求。
  const beforeUnmeasured = rebuilt.events.values.length;
  expect((await kk.call('POST', `/threads/${id}/messages`, { id: 'after-stop', text: '重新开始' })).status).toBe(200);
  const third = await model.call(3);
  third.response.complete('response-without-usage');
  await rebuilt.events.wait((event) => rebuilt.events.values.indexOf(event) >= beforeUnmeasured
    && event.type === 'thread.state' && event.state?.phase === 'idle'
    && event.state.lastOutcome?.kind === 'completed' && event.state.context === undefined);
  const unmeasuredHistory = await kk.call('GET', `/threads/${id}/history`);
  expect(unmeasuredHistory.body.state.context).toBeUndefined();
  await rebuilt.close();
  const unmeasuredReconnect = await connect(kk.url, id);
  const unmeasuredSnapshot = await unmeasuredReconnect.events.wait((event) => event.type === 'thread.history');
  expect(unmeasuredSnapshot.state).toEqual(unmeasuredHistory.body.state);
  await unmeasuredReconnect.close();
}, 1000);

// SQLite 和 native journal 在 daemon 关闭重开后共同重建视图；只读历史不能启动模型或更改记录 id。
test('重启后只读历史保持记录 id 和排队输入，重复发送及取消不唤醒模型', async () => {
  const root = makeTemp('transcript-');
  roots.push(root);
  const home = join(root, 'kite');
  accounts.push(linkNewAccount(home));
  const repo = newRepo(root, 'project', { 'base.txt': '初始\n' });
  const firstModel = new ManualModel();
  daemon = startDaemon({ home, port: 0, lightTasks: false, model: () => firstModel });
  const project = await call(daemon.url, 'POST', '/checkouts', { path: repo });
  expect(project.status).toBe(200);
  const created = await call(daemon.url, 'POST', '/workspaces', { checkout: project.body.checkout.id, prompt: '保持挂起' });
  expect(created.status).toBe(200);
  const id = created.body.threads[0].instanceId as string;
  const active = await firstModel.call(1);
  const queued = await call(daemon.url, 'POST', `/threads/${id}/messages`, { id: 'queued-after-restart', text: '恢复后继续' });
  expect(queued.status).toBe(200);
  const before = await call(daemon.url, 'GET', `/threads/${id}/history`);
  expect(before.status).toBe(200);
  expect(before.body.pending).toContainEqual(expect.objectContaining({ id: 'queued-after-restart', text: '恢复后继续' }));
  await daemon.stop();
  daemon = undefined;
  expect(active.signal.aborted).toBe(true);

  const secondModel = new ManualModel();
  daemon = startDaemon({ home, port: 0, lightTasks: false, model: () => secondModel });
  const restored = await call(daemon.url, 'GET', `/threads/${id}/history`);
  expect(restored.status).toBe(200);
  expect(restored.body.records.slice(0, before.body.records.length)).toEqual(before.body.records);
  expect(restored.body.pending).toEqual(before.body.pending);
  expect(secondModel.calls.values).toHaveLength(0);

  const duplicate = await call(daemon.url, 'POST', `/threads/${id}/messages`, { id: 'queued-after-restart', text: '恢复后继续' });
  expect(duplicate.status).toBe(200);
  const afterDuplicate = await call(daemon.url, 'GET', `/threads/${id}/history`);
  expect(afterDuplicate.body.pending.filter((entry: PendingView) => entry.id === 'queued-after-restart')).toHaveLength(1);
  const cancelled = await call(daemon.url, 'POST', `/threads/${id}/messages/queued-after-restart/cancel`);
  expect(cancelled.status).toBe(200);
  const afterCancel = await call(daemon.url, 'GET', `/threads/${id}/history`);
  expect(afterCancel.body.pending).toEqual([]);
  expect(secondModel.calls.values).toHaveLength(0);
}, 1000);
