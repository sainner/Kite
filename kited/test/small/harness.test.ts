import { expect, test } from 'bun:test';
import { appendFileSync, readFileSync, readdirSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { assembleContext, literalContext } from '../../src/harness/context/assembler.ts';
import { FileJournal } from '../../src/harness/journal.ts';
import { requestSnapshot } from '../../src/harness/request-config.ts';
import { EXIT_LIMIT, exitOutcome } from '../../src/harness/runner.ts';
import type { Input, Journal, JournalEvent, JournalRecord, Tool } from '../../src/harness/types.ts';
import {
  aborted, deferred, diskRecords, input, item, ManualModel, Seen, success, tool,
  useHarness, waitRecord, withAbort,
} from '../harness-loop.ts';

const h = useHarness();

// 流消费、工具副作用、同步文件写入和宿主快照四方交接：不能靠各函数单独正确来保证。
test('工具调用先落盘并在流结束前启动，下一请求等待工具与快照', async () => {
  const root = h.root();
  const model = new ManualModel();
  const toolDone = h.gate(success('写入完成'));
  const snapshotDone = h.gate(undefined);
  const started = deferred<JournalRecord[]>();
  const snapshotStarted = deferred<string[]>();
  const path = join(root, 'journal.jsonl');
  const { runner, journal, events } = h.runner(root, {
    model,
    tools: [tool('write', async (_args, { signal }) => {
      started.resolve(diskRecords(path));
      return withAbort(toolDone.promise, signal);
    })],
    async afterTools(_turn, ids) { snapshotStarted.resolve(ids); await snapshotDone.promise; },
  });
  await runner.send(input('first'));
  const first = await model.call(1);
  await first.response.emit({ type: 'delta', text: '临时增量' });
  const call = item('write-1', 'write');
  await first.response.emit({ type: 'item', item: call });
  const atExecution = await started.promise;
  expect(atExecution.slice(-2).map((record) => record.type)).toEqual(['model.item', 'tool.started']);
  expect(atExecution.some((record) => record.type === 'request.completed')).toBe(false);
  expect(events.values.some((event) => event.type === 'delta' && event.text === '临时增量')).toBe(true);
  expect(readFileSync(path, 'utf8')).not.toContain('临时增量');
  first.response.complete();
  await waitRecord(events, (record) => record.type === 'request.completed');
  expect(model.calls.values).toHaveLength(1);
  toolDone.resolve(success('写入完成'));
  expect(await snapshotStarted.promise).toEqual(['write-1']);
  expect(runner.state.busy).toBe(true);
  expect(model.calls.values).toHaveLength(1);
  snapshotDone.resolve(undefined);
  const second = await model.call(2);
  expect(second.request.history).toEqual([
    { type: 'input', input: input('first') },
    { type: 'output', item: call },
    { type: 'tool_result', callId: 'write-1', result: success('写入完成') },
  ]);
  second.response.complete();
  await runner.settled();
  expect(runner.state).toMatchObject({ phase: 'idle', busy: false, waitingForResume: false });
  expect(runner.state.lastOutcome).toEqual({ kind: 'completed' });
  expect(journal.records.filter((record) => record.type === 'turn.finished')).toHaveLength(1);
}, 1000);

// 工具完成顺序故意与调用顺序不同，验证并发队列、排他屏障与上下文投影配合。
test('并发工具遵守排他屏障，历史保留调用顺序', async () => {
  const model = new ManualModel();
  const starts = new Seen<string>();
  const gates = new Map(['A', 'B', 'C', 'D'].map((id) => [id, h.gate(success(id))]));
  const execute = async (args: unknown, { signal }: { signal: AbortSignal }) => {
    const id = (args as { id: string }).id;
    starts.add(id);
    return withAbort(gates.get(id)!.promise, signal);
  };
  const { runner, events, journal } = h.runner(h.root(), {
    model, tools: [tool('read', execute, true), tool('write', execute)],
  });
  await runner.send(input('parallel'));
  const first = await model.call(1);
  const calls = [item('A', 'read'), item('B', 'read'), item('C', 'write'), item('D', 'read')];
  for (const call of calls) await first.response.emit({ type: 'item', item: call });
  first.response.complete();
  await starts.wait((id) => id === 'B');
  expect(starts.values).toEqual(['A', 'B']);
  gates.get('B')!.resolve(success('B'));
  await waitRecord(events, (record) => record.type === 'tool.finished' && record.callId === 'B');
  expect(starts.values).toEqual(['A', 'B']);
  gates.get('A')!.resolve(success('A'));
  await starts.wait((id) => id === 'C');
  expect(starts.values).toEqual(['A', 'B', 'C']);
  gates.get('C')!.resolve(success('C'));
  await starts.wait((id) => id === 'D');
  gates.get('D')!.resolve(success('D'));
  const second = await model.call(2);
  expect(journal.records.filter((record) => record.type === 'tool.finished').map((record) => record.callId)).toEqual(['B', 'A', 'C', 'D']);
  expect(second.request.history).toEqual([
    { type: 'input', input: input('parallel') },
    ...calls.map((call) => ({ type: 'output' as const, item: call })),
    ...['A', 'B', 'C', 'D'].map((id) => ({ type: 'tool_result' as const, callId: id, result: success(id) })),
  ]);
  second.response.complete();
  await runner.settled();
}, 1000);

// 最终文字、停止 hook、收尾之间都有 await；消息必须按实际边界归入回合。
test('最终文字后的插话和停止反馈继续同回合，收尾期间的消息另开回合', async () => {
  const model = new ManualModel();
  const finishing = deferred();
  const finish = h.gate(undefined);
  let stops = 0;
  let turns = 0;
  const { runner } = h.runner(h.root(), {
    model,
    async beforeStop() { return ++stops === 1 ? '请检查最后一步' : undefined; },
    async afterTurn() { if (++turns === 1) { finishing.resolve(); await finish.promise; } },
  });
  await runner.send(input('initial'));
  const first = await model.call(1);
  await first.response.emit({ type: 'item', item: item('final-text') });
  await runner.send(input('interjection'));
  first.response.complete();
  const second = await model.call(2);
  expect(second.request.turnId).toBe(first.request.turnId);
  expect(second.request.history.at(-1)).toEqual({ type: 'input', input: input('interjection') });
  second.response.complete();
  const third = await model.call(3);
  expect(third.request.turnId).toBe(first.request.turnId);
  expect(third.request.history.at(-1)).toEqual({ type: 'feedback', text: '请检查最后一步' });
  third.response.complete();
  await finishing.promise;
  await runner.send(input('during-finish'));
  expect(model.calls.values).toHaveLength(3);
  expect(runner.state.busy).toBe(true);
  finish.resolve(undefined);
  const fourth = await model.call(4);
  expect(fourth.request.turnId).not.toBe(first.request.turnId);
  expect(fourth.request.history.at(-1)).toEqual({ type: 'input', input: input('during-finish') });
  fourth.response.complete();
  await runner.settled();
}, 1000);

// 停止信号先到，受管工具、快照和回合收尾稍后确认；用户停止退还队列，shutdown 保留队列。
test('用户停止等收尾后退还输入，关闭重开保留未封定输入', async () => {
  const root = h.root();
  const model = new ManualModel();
  const toolStarted = deferred<AbortSignal>();
  const toolStopped = h.gate(success('取消前已完成'));
  const snapshotStarted = deferred();
  const snapshotDone = h.gate(undefined);
  const turnFinishing = deferred();
  const turnDone = h.gate(undefined);
  let turns = 0;
  const { runner, path } = h.runner(root, {
    model,
    tools: [tool('write', async (_args, { signal }) => {
      toolStarted.resolve(signal);
      await aborted(signal);
      return toolStopped.promise;
    })],
    async afterTools() { snapshotStarted.resolve(); await snapshotDone.promise; },
    async afterTurn() { if (++turns === 1) { turnFinishing.resolve(); await turnDone.promise; } },
  });
  await runner.send(input('initial'));
  const first = await model.call(1);
  await first.response.emit({ type: 'item', item: item('writing', 'write') });
  const signal = await toolStarted.promise;
  await runner.send(input('later'));
  let interrupted = false;
  const interruption = runner.interrupt({ id: 'stop-with-tool', inputs: [input('not-sent')] })
    .then((returned) => { interrupted = true; return returned; });
  await aborted(signal);
  await expect(runner.send(input('during-stop'))).rejects.toThrow();
  await expect(runner.resume()).rejects.toThrow();
  expect(interrupted).toBe(false);
  expect(runner.state.busy).toBe(true);
  toolStopped.resolve(success('取消前已完成'));
  await snapshotStarted.promise;
  expect(interrupted).toBe(false);
  expect(model.calls.values).toHaveLength(1);
  snapshotDone.resolve(undefined);
  await turnFinishing.promise;
  expect(interrupted).toBe(false);
  turnDone.resolve(undefined);
  expect(await interruption).toEqual([input('later'), input('not-sent')]);
  expect(model.calls.values).toHaveLength(1);
  expect(first.request.history).toEqual([{ type: 'input', input: input('initial') }]);
  expect(runner.state).toMatchObject({ phase: 'idle', busy: false, waitingForResume: false,
    lastOutcome: { kind: 'interrupted' } });
  expect(diskRecords(path).filter((record) => record.type === 'thread.stopped')).toEqual([
    expect.objectContaining({ id: 'stop-with-tool', returned: [input('later'), input('not-sent')] }),
  ]);
  await runner.shutdown();
  expect(runner.lifecycle).toBe('closed');
  const reopenedModel = new ManualModel();
  const reopened = h.runner(root, { model: reopenedModel });
  await reopened.runner.settled();
  expect(reopenedModel.calls.values).toHaveLength(0);
  expect(reopened.runner.state).toMatchObject({ phase: 'idle', busy: false, waitingForResume: false });

  // 实际缺口：刚建立 active turn、尚未封定第一次请求时关闭，不能按普通打断撤回输入。
  const earlyRoot = h.root();
  const earlyModel = new ManualModel();
  const closingStarted = deferred();
  let closing!: Promise<void>;
  const early = h.runner(earlyRoot, {
    model: earlyModel,
    onEvent(event) {
      if (event.type === 'state' && event.state.phase === 'running' && event.state.turnId) {
        closing = early.runner.shutdown();
        closingStarted.resolve();
      }
    },
  });
  await early.runner.send(input('before-first-request'));
  await closingStarted.promise;
  await closing;
  expect(early.runner.lifecycle).toBe('closed');
  expect(earlyModel.calls.values).toHaveLength(0);
  const earlyRecords = diskRecords(early.path);
  expect(earlyRecords.some((record) => record.type === 'input.received' && record.input.id === 'before-first-request')).toBe(true);
  expect(earlyRecords.some((record) => record.type === 'input.cancelled' || record.type === 'request.started')).toBe(false);
}, 1000);

// send 的接收、请求封定、停止记录和重开交错；同一停止 ID 必须重放原结果，迟到输入不能入模型。
// 实际 bug：停止把队列里 Kite 的通知和代理来信也放进 returned，App 把它们塞进了用户的输入框。
// 它们留在队列里：停止收据先落盘、回合随后以 interrupted 收尾，收尾后和重开后都得是 waitingForResume，不自己跑起来。
test('停止只退还人发的输入，通知和来信留到下一条输入，同 ID 重试与重开不重复执行', async () => {
  const root = h.root();
  const model = new ManualModel();
  const { runner, journal } = h.runner(root, { model });
  const notice: Input = { id: 'notice', text: '整理文档 做完了', source: 'kite',
    notice: { kind: 'agent.report', title: '整理文档 做完了', subject: '整理文档', instance: 'child' } };
  const letter: Input = { id: 'letter', text: '另一个代理的来信', source: 'agent',
    from: { kind: 'agent', instance: 'peer', title: '统筹' } };
  await runner.send(input('active'));
  const first = await model.call(1);
  await runner.send(input('queued-a'));
  await runner.send(input('queued-a'));
  await expect(runner.send({ ...input('queued-a'), text: '冲突内容' })).rejects.toThrow();
  await runner.send(notice);
  await runner.send(letter);
  const sending = runner.send(input('queued-b'));
  const request = { id: 'stop-race', inputs: [input('queued-b'), input('not-yet-received')] };
  const stopping = runner.interrupt(request);
  await sending.catch(() => {});
  const returned = await stopping;
  expect(returned).toEqual([input('queued-a'), input('queued-b'), input('not-yet-received')]);
  expect(runner.state).toMatchObject({ phase: 'idle', busy: false, waitingForResume: true,
    lastOutcome: { kind: 'interrupted' } });
  expect(first.signal.aborted).toBe(true);
  expect(model.calls.values).toHaveLength(1);
  expect(journal.records.filter((record) => record.type === 'input.received' && record.input.id === 'queued-a')).toHaveLength(1);
  expect(first.request.history).toEqual([{ type: 'input', input: input('active') }]);
  expect(await runner.interrupt(request)).toEqual(returned);
  expect(journal.records.filter((record) => record.type === 'thread.stopped')).toEqual([
    expect.objectContaining({ id: request.id, returned }),
  ]);
  await runner.shutdown();
  expect(model.calls.values).toHaveLength(1);
  const reopenedModel = new ManualModel();
  const reopened = h.runner(root, { model: reopenedModel });
  expect(await reopened.runner.interrupt(request)).toEqual(returned);
  await reopened.runner.send(input('not-yet-received')).catch(() => {});
  await reopened.runner.settled();
  expect(reopenedModel.calls.values).toHaveLength(0);
  expect(reopened.runner.state).toMatchObject({ phase: 'idle', busy: false, waitingForResume: true });
  await reopened.runner.send(input('fresh'));
  const fresh = await reopenedModel.call(1);
  expect(fresh.request.history.filter((entry) => entry.type === 'input').map((entry) => entry.input.id))
    .toEqual(['active', 'notice', 'letter', 'fresh']);
  expect(reopened.runner.state.busy).toBe(true);
  expect(await reopened.runner.interrupt(request)).toEqual(returned);
  expect(fresh.signal.aborted).toBe(false);
  expect(reopened.runner.state.busy).toBe(true);
  fresh.response.complete();
  await reopened.runner.settled();
  expect(reopenedModel.calls.values).toHaveLength(1);
  expect(reopened.runner.state).toMatchObject({ phase: 'idle', busy: false, waitingForResume: false,
    lastOutcome: { kind: 'completed' } });
  expect(reopened.journal.records.filter((record) => record.type === 'thread.stopped')).toHaveLength(1);
}, 1000);

// 流异常会与排队输入/持久化交错；失败必须停住，不能因为有文字或 completed 就误判成功。
test('异常流暂停请求，写盘失败阻塞恢复与副作用', async () => {
  for (const extraAfterCompleted of [false, true]) {
    const model = new ManualModel();
    let executed = 0;
    const { runner } = h.runner(h.root(), {
      model, tools: [tool('write', async () => { executed++; return success('不应执行'); })],
    });
    await runner.send(input('failed'));
    const first = await model.call(1);
    await first.response.emit({ type: 'item', item: item('partial') });
    await runner.send(input('queued'));
    if (extraAfterCompleted) {
      void first.response.emit({ type: 'completed', responseId: 'bad-response' });
      void first.response.emit({ type: 'item', item: item('illegal', 'write') });
    }
    first.response.finish();
    await runner.settled();
    expect(runner.state).toMatchObject({ phase: 'idle', busy: false, waitingForResume: true });
    expect(runner.state.lastOutcome?.kind).toBe('failed');
    expect(model.calls.values).toHaveLength(1);
    expect(executed).toBe(0);
    await runner.resume();
    const resumed = await model.call(2);
    expect(resumed.request.history).toContainEqual({ type: 'input', input: input('queued') });
    expect(resumed.request.history).toContainEqual({ type: 'output', item: item('partial') });
    expect(resumed.request.history.some((entry) => entry.type === 'feedback')).toBe(true);
    resumed.response.complete();
    await runner.settled();
    expect(runner.state).toMatchObject({ phase: 'idle', busy: false, waitingForResume: false });
    expect(runner.state.lastOutcome).toEqual({ kind: 'completed' });
  }
  for (const failAt of ['tool.started', 'tool.finished', 'turn.finished'] as const) {
    const root = h.root();
    const real = h.open(join(root, 'journal.jsonl'));
    let poisoned = false;
    const journal: Journal = {
      get records() { return real.records; },
      append(event: JournalEvent) {
        if (poisoned || event.type === failAt) { poisoned = true; throw new Error('模拟磁盘写满'); }
        return real.append(event);
      },
      close() { real.close(); },
    };
    const model = new ManualModel();
    const effectDone = h.gate(success('副作用已经发生'));
    const started = deferred();
    let executed = 0;
    const write = tool('write', async (_args, { signal }) => {
      executed++;
      started.resolve();
      return withAbort(effectDone.promise, signal);
    });
    const { runner } = h.runner(root, { model, journal, tools: [write] });
    await runner.send(input('disk-full'));
    const first = await model.call(1);
    if (failAt !== 'turn.finished') await first.response.emit({ type: 'item', item: item('first-write', 'write') });
    if (failAt === 'tool.finished') {
      await started.promise;
      await first.response.emit({ type: 'item', item: item('blocked-write', 'write') });
    }
    first.response.complete();
    effectDone.resolve(success('副作用已经发生'));
    await runner.settled();
    expect(executed).toBe(failAt === 'tool.finished' ? 1 : 0);
    expect(runner.state).toMatchObject({ phase: 'idle', busy: false, waitingForResume: true,
      lastOutcome: { kind: 'failed' } });
    expect(model.calls.values).toHaveLength(1);
    if (failAt === 'tool.finished') {
      await runner.shutdown();
      const reopenedModel = new ManualModel();
      const reopened = h.runner(root, { model: reopenedModel, tools: [write] });
      expect(executed).toBe(1);
      expect(reopened.journal.records.filter((record) => record.type === 'tool.finished').map((record) => [record.callId, record.result.status])).toEqual([
        ['first-write', 'unknown'], ['blocked-write', 'not_executed'],
      ]);
    }
  }
}, 1000);

// 通过公开 append 写入真实崩溃事实，验证重新读盘、补结果与上下文重建，绝不启动旧副作用。
test('崩溃后补齐工具结果，不重跑副作用', async () => {
  const root = h.root();
  const path = join(root, 'journal.jsonl');
  const journal = h.open(path);
  const saved = item('saved', 'write');
  const waiting = item('waiting', 'write');
  const uncertain = item('uncertain', 'write');
  const ids = { turnId: 'crashed-turn', requestId: 'crashed-request' };
  journal.append({ type: 'input.received', input: input('before-crash') });
  journal.append({ type: 'turn.started', turnId: ids.turnId });
  const context = assembleContext(literalContext('测试主循环')).snapshot;
  const configuration = requestSnapshot({}, [{ name: 'write', description: '测试工具', parameters: { type: 'object' } }]);
  journal.append({ type: 'context.prepared', snapshot: context });
  journal.append({ type: 'request.configured', snapshot: configuration });
  journal.append({ type: 'request.started', ...ids, inputIds: ['before-crash'],
    contextId: context.id, configurationId: configuration.id });
  journal.append({ type: 'model.item', ...ids, item: saved });
  journal.append({ type: 'tool.started', ...ids, callId: saved.id });
  journal.append({ type: 'tool.finished', ...ids, callId: saved.id, result: success('磁盘中的结果') });
  journal.append({ type: 'model.item', ...ids, item: waiting });
  journal.append({ type: 'model.item', ...ids, item: uncertain });
  journal.append({ type: 'tool.started', ...ids, callId: uncertain.id });
  journal.close();
  const model = new ManualModel();
  let executed = 0;
  const recovered = h.runner(root, {
    model, tools: [tool('write', async () => { executed++; return success('不应重跑'); })],
  });
  expect(executed).toBe(0);
  const results = recovered.journal.records.filter((record) => record.type === 'tool.finished');
  expect(results.find((record) => record.callId === 'saved')?.result).toEqual(success('磁盘中的结果'));
  expect(results.find((record) => record.callId === 'waiting')?.result.status).toBe('not_executed');
  expect(results.find((record) => record.callId === 'uncertain')?.result.status).toBe('unknown');
}, 1000);

/**
 * 在 root 的记录上打开会话，像 kited 启动时那样。crash() 模拟 kited 崩溃：这个实例之后写的记录都不落盘（进程已经没了），
 * 挂着的模型请求和工具也不再有下文；下一次 openSession 从硬盘上的记录重新打开。
 */
function openSession(root: string, tools: Tool[]) {
  const disk = h.open(join(root, 'journal.jsonl'));
  let dead = false;
  const journal: Journal = {
    get records() { return disk.records; },
    append(event: JournalEvent) {
      return dead ? { ...event, version: 1, seq: -1, at: Date.now() } as JournalRecord : disk.append(event);
    },
    close() { disk.close(); },
  };
  const model = new ManualModel();
  const { runner, events } = h.runner(root, { journal, model, tools });
  return { runner, model, events, journal, crash() { dead = true; } };
}
type Session = ReturnType<typeof openSession>;

const CHECKED = '检查过了，状态正常';
const checkTool = () => tool('check', async () => success(CHECKED));

/** 这一回合里模型先调一次检查工具；工具成功、下一次模型请求挂着时 kited 崩溃。 */
async function checkThenCrash(session: Session): Promise<void> {
  const id = `check-${crypto.randomUUID()}`;
  const first = await session.model.call(1);
  await first.response.emit({ type: 'item', item: item(id, 'check') });
  first.response.complete();
  const second = await session.model.call(2);
  expect(second.request.history).toContainEqual({ type: 'tool_result', callId: id, result: success(CHECKED) });
  session.crash();
}

/** 等这次推进停下；要是起了回合、请求了模型，也立刻返回，交给调用方断言，不白等到超时。 */
async function idleOrRequested(session: Session): Promise<void> {
  await Promise.race([session.runner.settled(), session.model.call(1)]);
}

const lastTurn = (session: Session) => session.journal.records
  .filter((record): record is Extract<JournalRecord, { type: 'turn.finished' }> => record.type === 'turn.finished').at(-1);

/*
 * 跨重启的状态流转：连续崩溃的次数每次打开都从硬盘上的记录重算，要经过几轮「崩溃→重放记录→打开→接着做」才看得出对不对。
 * 实际 bug：接着做时模型总是先跑一个检查实际状态的工具，检查总会成功；旧代码在工具成功时把计数清零，崩溃循环永远停不下来。
 */
test('每次接着做都先成功跑完检查工具再崩溃，连续第 3 次后停在等待继续；之后 monitor 事件和代理来信只排队，人发的消息才起回合并重新计数', async () => {
  const root = h.root();
  const tools = [checkTool()];
  let session = openSession(root, tools);
  await session.runner.send(input('task'));
  await checkThenCrash(session);
  for (let crashes = 1; crashes < EXIT_LIMIT; crashes++) {
    session = openSession(root, tools);
    expect(session.runner.running).toBe(true);
    await session.runner.continueInterrupted();
    await checkThenCrash(session);
  }

  session = openSession(root, tools);
  expect(session.runner.running).toBe(false);
  expect(session.runner.state).toMatchObject({ phase: 'idle', busy: false, waitingForResume: true,
    lastOutcome: exitOutcome(EXIT_LIMIT) });
  await session.runner.continueInterrupted();
  await idleOrRequested(session);
  expect(session.model.calls.values).toHaveLength(0);
  const monitor: Input = { id: 'monitor', text: '构建失败了', source: 'kite',
    notice: { kind: 'monitor.events', title: '构建 有新事件', subject: '构建' } };
  const letter: Input = { id: 'letter', text: '另一个代理的来信', source: 'agent',
    from: { kind: 'agent', instance: 'peer', title: '统筹' } };
  for (const queued of [monitor, letter]) {
    expect(await session.runner.send(queued)).toBe(true);
    await idleOrRequested(session);
    expect(session.model.calls.values).toHaveLength(0);
    expect(session.runner.state).toMatchObject({ phase: 'idle', busy: false, waitingForResume: true });
  }

  await session.runner.send(input('human'));
  await idleOrRequested(session);
  expect(session.model.calls.values).toHaveLength(1);
  const delivered = (await session.model.call(1)).request.history
    .flatMap((entry) => entry.type === 'input' ? [entry.input.id] : []);
  expect(delivered).toEqual(expect.arrayContaining(['monitor', 'letter', 'human']));
  // 人发的消息清了零：这一回合再崩溃只算第 1 次，重开后照常接着做。
  await checkThenCrash(session);
  expect(openSession(root, tools).runner.running).toBe(true);
}, 1000);

/*
 * 跨重启的状态流转：停止收据已经落盘、在跑的工具还没停下时 kited 崩溃。重开补齐结果时要认出这是被停下的回合，
 * 按停止收尾，不当成又一次被崩溃打断：不接着做，也不算进连续崩溃。
 */
test('停止收据已落盘、回合还没收尾时崩溃：重开后回合按停止收尾，不标被退出打断、不接着做，也不计入连续崩溃', async () => {
  const root = h.root();
  const stopping = h.gate(success('停下之前做完了'));
  const tools = [checkTool(), tool('slow', async () => stopping.promise)];
  let session = openSession(root, tools);
  await session.runner.send(input('task'));
  await checkThenCrash(session);

  // 接着做的回合停在一个不理会取消的工具上，用户停下：收据先落盘，回合等工具停下才收尾，这时 kited 崩溃。
  session = openSession(root, tools);
  await session.runner.continueInterrupted();
  const first = await session.model.call(1);
  await first.response.emit({ type: 'item', item: item('slow', 'slow') });
  await waitRecord(session.events, (record) => record.type === 'tool.started' && record.callId === 'slow');
  void session.runner.interrupt({ id: 'stop' }).catch(() => {});
  await waitRecord(session.events, (record) => record.type === 'thread.stopped');
  session.crash();

  session = openSession(root, tools);
  const stopped = lastTurn(session);
  expect(stopped?.outcome).toEqual({ kind: 'interrupted' });
  expect(stopped?.exited).toBeUndefined();
  expect(session.runner.running).toBe(false);
  expect(session.runner.state).toMatchObject({ phase: 'idle', busy: false, lastOutcome: { kind: 'interrupted' } });
  await session.runner.continueInterrupted();
  await idleOrRequested(session);
  expect(session.model.calls.values).toHaveLength(0);

  // 不计入：之后代理来信开的回合再崩溃，连上第一次一共 2 次，重开后照常接着做；算进去就到了 3 次、停下等人。
  await session.runner.send({ id: 'letter', text: '另一个代理的来信', source: 'agent',
    from: { kind: 'agent', instance: 'peer', title: '统筹' } });
  await checkThenCrash(session);
  expect(openSession(root, tools).runner.running).toBe(true);
}, 1000);

// Bun/Node 文件 IO 的真实截断、复制与重新追加语义，验证故障文件不会悄悄丢中间记录。
test('JSONL 尾部半行先保留诊断副本再修复，中间损坏则拒绝且原文件不变', () => {
  const root = h.root();
  const path = join(root, 'journal.jsonl');
  const original = h.open(path);
  original.append({ type: 'input.received', input: input('one') });
  original.close();
  const intact = readFileSync(path, 'utf8');
  const tail = '{"version":1,"seq":2,"type":"input.received","input":';
  appendFileSync(path, tail);
  const before = new Set(readdirSync(root));
  const repaired = h.open(path);
  expect(repaired.records).toHaveLength(1);
  expect(readFileSync(path, 'utf8')).toBe(intact);
  const copies = readdirSync(root).filter((name) => !before.has(name));
  expect(copies.some((name) => readFileSync(join(root, name), 'utf8') === tail)).toBe(true);
  expect(repaired.append({ type: 'input.received', input: input('two') }).seq).toBe(2);
  repaired.close();
  const lines = readFileSync(path, 'utf8').trimEnd().split('\n');
  for (const broken of ['不是 JSON', JSON.stringify({ version: 9, seq: 2, at: 0, type: 'recovery.confirmed' })]) {
    const contents = `${lines[0]}\n${broken}\n${lines[1]}\n`;
    writeFileSync(path, contents);
    expect(() => new FileJournal(path)).toThrow();
    expect(readFileSync(path, 'utf8')).toBe(contents);
  }
});

