import { afterEach, expect, test } from 'bun:test';
import { chmodSync, rmSync } from 'node:fs';
import { join } from 'node:path';
import { startDaemon, type Daemon } from '../../src/daemon.ts';
import type { WorkspaceModel } from '../../src/model.ts';
import type { ThreadActivity } from '../../src/transcript/protocol.ts';
import { addProject, call, chatgptLogin, createWorkspace, folderWorkspace, machine, startKited, type Kited } from '../harness.ts';
import { item, ManualModel } from '../harness-loop.ts';
import { connectSse } from '../sse.ts';
import { commitAll, makeTemp, newDir, newRepo } from '../util.ts';

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
  projectId?: string;
  status?: string;
  workspaces?: unknown[];
  cursor: string;
  since?: string;
  at: number;
  version?: number;
  records?: RecordView[];
  record?: RecordView;
  delta?: DeltaView;
  pending?: PendingView[];
  state?: StateView;
  activity?: ThreadActivity;
};

const roots: string[] = [];
const streams: Array<{ close(): Promise<void> }> = [];
let kited: Kited | undefined;
let daemon: Daemon | undefined;
afterEach(async () => {
  const closed = await Promise.allSettled(streams.splice(0).map((stream) => stream.close()));
  await daemon?.stop();
  daemon = undefined;
  await kited?.stop();
  kited = undefined;
  for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true });
  for (const result of closed) if (result.status === 'rejected') throw result.reason;
});

async function connect(url: string, threadId?: string, lastEventId?: string) {
  const stream = await connectSse<WireEvent>(`${url}/events${threadId ? `?thread=${threadId}` : ''}`, (await machine(url)).id,
    lastEventId === undefined ? {} : { 'Last-Event-ID': lastEventId });
  streams.push(stream);
  return stream;
}

// HTTP 快照、异步工作区事件与 SSE 目录过滤交错；第二个项目导入检出（checkout.changed）作流内屏障，确认正文未漏入目录。
test('目录 SSE 快照和列表响应头同序，后续变化需要更新列表', async () => {
  kited = startKited();
  const kk = kited;
  const firstRepo = newRepo(kk.root, 'first', { 'base.txt': '一\n', '.kite/setup': '#!/bin/sh\necho 已准备\n' }, null);
  chmodSync(join(firstRepo, '.kite/setup'), 0o755);
  commitAll(firstRepo, '加准备脚本');
  const first = await addProject(kk, { path: firstRepo });
  const stream = await connect(kk.url);
  const baseline = await stream.events.wait((event) => event.type === 'catalog.snapshot');
  expect(baseline.workspaces).toEqual([]);

  chatgptLogin(kk.home);
  const created = await kk.call('POST', '/workspaces', { project: first.id });
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

  const second = await addProject(kk, { path: newDir(kk.root, 'second', { 'base.txt': '二\n' }) });
  const later = await stream.events.wait((event) => event.type === 'checkout.changed' && event.projectId === second.id);
  expect(later.cursor.split(':')[0]).toBe(before.cursor.split(':')[0]);
  expect(Number(later.cursor.split(':')[1])).toBeGreaterThan(Number(before.cursor.split(':')[1]));
  const after = await readCatalog();
  expect(Number(later.cursor.split(':')[1])).toBeLessThanOrEqual(Number(after.cursor.split(':')[1]));
  await stream.close();
}, 1000);

/*
 * 执行进程、显示投影和两种 SSE 交接：摘要由投影推出的 thread.state 在同一次总线分发里重入发出，
 * 收尾时间只在实时看到 running 到 idle 的转换时记下，要真跑回合才知道时序对不对。
 * 第一回合不开线程流、不读历史，对应停靠栏里没人打开过的后台代理。
 */
test('后台代理跑完一回合，目录流先后收到运行中和带收尾时间的完成摘要并与列表一致，线程流收不到摘要', async () => {
  const model = new ManualModel();
  kited = startKited(() => model);
  const kk = kited;
  const registered = await folderWorkspace(kk, newDir(kk.root, 'project', { 'base.txt': '初始\n' }));
  const workspaceId = registered.workspace.id;
  const operationPath = (name: string) => `/workspaces/${workspaceId}/operations/${name}`;
  const created = await kk.call('POST', operationPath('agent.start'), { operationId: 'activity-agent' });
  expect(created.status).toBe(200);
  const id = created.body.instanceId as string;
  const catalog = await connect(kk.url);
  await catalog.events.wait((event) => event.type === 'catalog.snapshot');
  const isActivity = (event: WireEvent) => event.type === 'thread.activity' && event.threadId === id;
  const later = (stream: typeof catalog, index: number) => (event: WireEvent) => stream.events.values.indexOf(event) > index;

  expect((await kk.call('POST', operationPath('agent.send'), {
    operationId: 'first-turn', instanceId: id, text: '第一回合',
  })).status).toBe(200);
  const first = await model.call(1);
  const running = await catalog.events.wait((event) => isActivity(event) && event.activity?.phase !== 'idle');
  expect(running.workspaceId).toBe(workspaceId);
  first.response.complete();
  const runningAt = catalog.events.values.indexOf(running);
  const settled = await catalog.events.wait((event) => later(catalog, runningAt)(event) && isActivity(event)
    && event.activity?.phase === 'idle');
  expect(settled).toMatchObject({
    workspaceId, threadId: id, activity: { phase: 'idle', outcome: 'completed', settledAt: expect.any(Number) },
  });
  const listed = await kk.call('GET', '/workspaces');
  const listedThread = (listed.body as Array<{ workspace: { id: string }; threads: Array<{ instanceId: string; activity?: ThreadActivity }> }>)
    .find((entry) => entry.workspace.id === workspaceId)?.threads.find((thread) => thread.instanceId === id);
  expect(listedThread?.activity).toEqual(catalog.events.values.filter(isActivity).at(-1)?.activity);
  expect(listedThread?.activity).toEqual(settled.activity);

  // 第二回合开着线程流：运行中摘要与线程流的 running 状态同一次分发发出，之后的 idle 状态到达时，漏进线程流的摘要早该到了。
  const thread = await connect(kk.url, id);
  await thread.events.wait((event) => event.type === 'thread.history');
  const beforeSecond = catalog.events.values.length - 1;
  expect((await kk.call('POST', operationPath('agent.send'), {
    operationId: 'second-turn', instanceId: id, text: '第二回合',
  })).status).toBe(200);
  const second = await model.call(2);
  await catalog.events.wait((event) => later(catalog, beforeSecond)(event) && isActivity(event) && event.activity?.phase !== 'idle');
  second.response.complete();
  const threadRunning = await thread.events.wait((event) => event.type === 'thread.state' && event.state?.phase !== 'idle');
  await thread.events.wait((event) => later(thread, thread.events.values.indexOf(threadRunning))(event)
    && event.type === 'thread.state' && event.state?.phase === 'idle');
  await catalog.events.wait((event) => later(catalog, beforeSecond)(event) && isActivity(event) && event.activity?.phase === 'idle');
  expect(thread.events.values.filter((event) => event.type === 'thread.activity')).toEqual([]);
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
  const project = await addProject(kk, { path: newDir(kk.root, 'project', { 'base.txt': '初始\n' }) });
  const thread = await createWorkspace(kk, project.id, '开始', 'harness');
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

/** App 合并只补变化的首帧：按 id 原位替换，没有的按收到的顺序接在末尾。 */
function merge(copy: RecordView[], changed: RecordView[]) {
  const records = new Map(copy.map((record) => [record.id, record]));
  for (const record of changed) records.set(record.id, record);
  return [...records.values()];
}

/*
 * 几部分的配合：feed 的全局事件序号、投影里逐条记录的变化序号、SSE 首帧取的 cursor 要对得上，
 * 断线期间流式 delta、工具阶段变化、新记录有一处没记上，App 重连后就悄悄显示旧内容。
 * 第一次重连的 cursor 是断开前最后处理的线程事件；第二次用首帧自己的 cursor，之后只有一条 delta，
 * 记变化序号时差一位（记成上一个事件的序号）就补不到这条。
 */
test('线程流带 Last-Event-ID 重连只补断线期间变过的记录，旧副本按 id 合并后与完整快照相同', async () => {
  const model = new ManualModel();
  kited = startKited(() => model);
  const kk = kited;
  const project = await addProject(kk, { path: newDir(kk.root, 'project', { 'base.txt': '初始\n' }) });
  const { id } = await createWorkspace(kk, project.id, '开始', 'harness');
  const first = await model.call(1);
  // 另一台设备一直开着这个会话，用来等断线期间的变化落定。
  const watcher = await connect(kk.url, id);
  await watcher.events.wait((event) => event.type === 'thread.history');

  const phone = await connect(kk.url, id);
  const initial = await phone.events.wait((event) => event.type === 'thread.history');
  expect(initial.since).toBeUndefined();
  await first.response.emit({ type: 'item', item: { id: 'answer-pre', raw: { type: 'message', content: [
    { type: 'output_text', text: '先说一句' },
  ] } } });
  const said = (await phone.events.wait((event) => event.type === 'thread.record' && event.record?.block.type === 'text'
    && event.record.block.text === '先说一句')).record!;
  await first.response.emit({ type: 'item.started', itemId: 'answer-live', kind: 'text' });
  const live = (await phone.events.wait((event) => event.type === 'thread.record' && event.record?.block.type === 'text'
    && event.record.generation === 'streaming')).record!;
  await first.response.emit({ type: 'item.started', itemId: 'shell-gap', kind: 'tool_use', callId: 'shell-gap', name: 'shell' });
  const last = await phone.events.wait((event) => event.type === 'thread.record' && event.record?.id === 'call:shell-gap'
    && event.record.block.stage === 'generating');
  // 本地副本只由首帧和整条记录建成，这段里没有 delta，副本就是 last 这一刻的准确内容。
  const processed = phone.events.values.slice(0, phone.events.values.indexOf(last) + 1);
  expect(processed.some((event) => event.type === 'thread.record.delta')).toBe(false);
  const copy = merge(initial.records!, processed.flatMap((event) => event.type === 'thread.record' ? [event.record!] : []));
  const human = copy.find((record) => record.block.type === 'human' && record.block.text === '开始')!;
  expect(human).toBeDefined();
  await phone.close();

  // 断线期间：已有的流式正文只收 delta，生成中的工具整条换成执行完，出一条新的 tool_result，再排一条输入。
  await first.response.emit({ type: 'delta', itemId: 'answer-live', field: 'text', part: 0, text: '断线时写的' });
  await first.response.emit({ type: 'delta', itemId: 'shell-gap', field: 'arguments',
    text: '{"description":"断线时跑","command":"printf gap"}' });
  await first.response.emit({ type: 'item', item: { ...item('shell-gap', 'shell'), call: { id: 'shell-gap', name: 'shell',
    arguments: { description: '断线时跑', command: 'printf gap' } } } });
  const result = (await watcher.events.wait((event) => event.type === 'thread.record'
    && event.record?.block.type === 'tool_result' && event.record.block.call === 'shell-gap')).record!;
  expect((await kk.call('POST', `/threads/${id}/messages`, { id: 'queued-gap', text: '断线时排队' })).status).toBe(200);
  await watcher.events.wait((event) => event.type === 'thread.pending' && event.pending?.some((entry) => entry.id === 'queued-gap') === true);

  const resumed = await connect(kk.url, id, last.cursor);
  const partial = await resumed.events.wait((event) => event.type === 'thread.history');
  const fresh = await connect(kk.url, id);
  const full = await fresh.events.wait((event) => event.type === 'thread.history');
  expect(full.since).toBeUndefined();
  expect(partial.since).toBe(last.cursor);
  expect(full.records?.find((record) => record.id === live.id)?.block.text).toBe('断线时写的');
  expect(full.records?.find((record) => record.id === 'call:shell-gap')?.block.stage).toBe('finished');
  const changed = partial.records!.map((record) => record.id);
  expect(changed).not.toContain(human.id);
  expect(changed).not.toContain(said.id);
  expect(changed).toContain(result.id);
  const merged = merge(copy, partial.records!);
  expect(merged).toEqual(full.records!);
  expect(partial.pending).toEqual(full.pending!);
  expect(partial.pending).toContainEqual(expect.objectContaining({ id: 'queued-gap' }));
  expect(partial.state).toEqual(full.state!);
  await resumed.close();
  await fresh.close();

  // 首帧的 cursor 也能当 Last-Event-ID：之后只有一条 delta，再连只补这一条。
  await first.response.emit({ type: 'delta', itemId: 'answer-live', field: 'text', part: 0, text: '，又续一句' });
  await watcher.events.wait((event) => event.type === 'thread.record.delta' && event.delta?.text === '，又续一句');
  const again = await connect(kk.url, id, partial.cursor);
  const next = await again.events.wait((event) => event.type === 'thread.history');
  const latest = await connect(kk.url, id);
  const latestFull = await latest.events.wait((event) => event.type === 'thread.history');
  expect(next.since).toBe(partial.cursor);
  expect(next.records!.map((record) => record.id)).toEqual([live.id]);
  expect(merge(merged, next.records!)).toEqual(latestFull.records!);
}, 1000);

// SQLite 和 native journal 在 daemon 关闭重开后共同重建视图；重开后（会话接着做）已有记录的 id 不变。
test('重启后只读历史保持记录 id', async () => {
  const root = makeTemp('transcript-');
  roots.push(root);
  const home = join(root, 'kite');
  const repo = newDir(root, 'project', { 'base.txt': '初始\n' });
  const firstModel = new ManualModel();
  daemon = startDaemon({ home, port: 0, lightTasks: false, model: () => firstModel });
  const { id } = await createWorkspace(daemon, (await addProject(daemon, { path: repo })).id, '保持挂起', 'harness');
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
}, 1000);

/*
 * 真实出过的 bug：JSON.stringify 原样输出 U+0085、U+2028、U+2029，App 读事件流用的 Swift AsyncBytes.lines 把它们也当行尾，
 * data 行被切断、JSONDecoder 报格式不正确，App 每 2 秒重连一次，这个会话一直显示不出来（工具输出里的网页正文带 U+2028）。
 * 这里读真实 /events 流的原始字节，按 AsyncBytes.lines 的切行规则（\n、\r、\r\n 之外这三个也算）解析 data 行，
 * 快照里的人类消息和实时推送的模型回复都要能解出原文。
 */
test('线程事件流不含原样的 U+0085、U+2028、U+2029，按 App 的切行规则读 data 行仍能解出原文', async () => {
  const model = new ManualModel();
  kited = startKited(() => model);
  const kk = kited;
  const breaks = [0x85, 0x2028, 0x2029].map((code) => String.fromCharCode(code));
  const [nel, ls, ps] = breaks;
  const original = `Time to fly.${ls}${ls} The future of aviation${ps}下一段${nel}结尾`;
  const appLines = (text: string) => text.split(new RegExp(`\r\n|[\n\r${breaks.join('')}]`));

  const project = await addProject(kk, { path: newDir(kk.root, 'project', { 'base.txt': '初始\n' }) });
  const { id } = await createWorkspace(kk, project.id, original, 'harness');
  const first = await model.call(1);

  const controller = new AbortController();
  const response = await fetch(`${kk.url}/events?thread=${id}`, {
    headers: { 'X-Kite-Machine': (await machine(kk.url)).id }, signal: controller.signal,
  });
  expect(response.status).toBe(200);
  const reader = response.body!.pipeThrough(new TextDecoderStream()).getReader();
  streams.push({ close: async () => { controller.abort(); await reader.cancel().catch(() => {}); } });
  let raw = '';
  // 只解析已收完的帧：按 App 的切行规则切行，以 data: 开头的行整行交给 JSON.parse，被切断的行在这里抛错。
  const parsed = () => appLines(raw.slice(0, raw.lastIndexOf('\n\n') + 1))
    .filter((line) => line.startsWith('data: ')).map((line) => JSON.parse(line.slice(6)) as WireEvent);
  const readUntil = async (done: (events: WireEvent[]) => boolean) => {
    while (!done(parsed())) {
      const chunk = await reader.read();
      if (chunk.done) throw new Error('事件流在等到事件前关闭');
      raw += chunk.value;
    }
    return parsed();
  };

  const isReply = (event: WireEvent) => event.type === 'thread.record' && event.record?.block.type === 'text';
  await readUntil((events) => events.some((event) => event.type === 'thread.history'));
  await first.response.emit({ type: 'item', item: { id: 'answer-a', raw: { type: 'message', content: [
    { type: 'output_text', text: original },
  ] } } });
  const events = await readUntil((all) => all.some(isReply));

  expect([...raw].filter((char) => breaks.includes(char))).toEqual([]);
  const history = events.find((event) => event.type === 'thread.history')!;
  expect(history.records?.find((record) => record.block.type === 'human')?.block.text).toBe(original);
  expect(events.filter(isReply).at(-1)?.record?.block.text).toBe(original);
}, 1000);
