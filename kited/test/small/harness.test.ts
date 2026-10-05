import { expect, test } from 'bun:test';
import { appendFileSync, readFileSync, readdirSync, renameSync, statSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { assembleContext, literalContext } from '../../src/harness/context/assembler.ts';
import { FileJournal, JournalIndex } from '../../src/harness/journal.ts';
import { requestSnapshot } from '../../src/harness/request-config.ts';
import type { Journal, JournalEvent, JournalRecord } from '../../src/harness/types.ts';
import {
  aborted, deferred, diskRecords, input, item, ManualModel, Seen, success, tool,
  useHarness, waitRecord, withAbort,
} from '../harness-loop.ts';

const h = useHarness();

const configurationRecord = (model: string, seq = 1): Extract<JournalRecord, { type: 'request.configured' }> => ({
  version: 1, seq, at: 1, type: 'request.configured',
  snapshot: requestSnapshot({ model: { model, reasoning: 'medium' } }, []),
});

// 流消费、工具副作用、同步文件写入和宿主快照四方交接：不能靠各函数单独正确来保证。
test('完整调用先落盘再执行，流未结束就启动，工具和快照结束后才请求下一轮', async () => {
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
test('连续并发工具一起启动但不能越过排他调用，历史始终按调用顺序排列', async () => {
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
test('用户停止等待工具与收尾后退还排队输入，shutdown 重开仍保留未封定输入', async () => {
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
  const restartedModel = new ManualModel();
  const restarted = h.runner(earlyRoot, { model: restartedModel });
  const pending = await restartedModel.call(1);
  expect(pending.request.history.filter((entry) => entry.type === 'input')).toEqual([
    { type: 'input', input: input('before-first-request') },
  ]);
  pending.response.complete();
  await restarted.runner.settled();
  expect(restartedModel.calls.values).toHaveLength(1);
}, 1000);

// send 的接收、请求封定、停止记录和重开交错；同一停止 ID 必须重放原结果，迟到输入不能入模型。
test('停止按顺序退还未封定及未确认输入，同 ID 重试与重开不重复执行', async () => {
  const root = h.root();
  const model = new ManualModel();
  const { runner, journal } = h.runner(root, { model });
  await runner.send(input('active'));
  const first = await model.call(1);
  await runner.send(input('queued-a'));
  await runner.send(input('queued-a'));
  await expect(runner.send({ ...input('queued-a'), text: '冲突内容' })).rejects.toThrow();
  const sending = runner.send(input('queued-b'));
  const request = { id: 'stop-race', inputs: [input('queued-b'), input('not-yet-received')] };
  const stopping = runner.interrupt(request);
  await sending.catch(() => {});
  const returned = await stopping;
  expect(returned).toEqual([input('queued-a'), input('queued-b'), input('not-yet-received')]);
  expect(first.signal.aborted).toBe(true);
  expect(model.calls.values).toHaveLength(1);
  expect(journal.records.filter((record) => record.type === 'input.received' && record.input.id === 'queued-a')).toHaveLength(1);
  expect(first.request.history).toEqual([{ type: 'input', input: input('active') }]);
  expect(await runner.interrupt(request)).toEqual(returned);
  expect(journal.records.filter((record) => record.type === 'thread.stopped')).toEqual([
    expect.objectContaining({ id: request.id, returned }),
  ]);
  await runner.shutdown();
  const reopenedModel = new ManualModel();
  const reopened = h.runner(root, { model: reopenedModel });
  expect(await reopened.runner.interrupt(request)).toEqual(returned);
  await reopened.runner.send(input('not-yet-received')).catch(() => {});
  await reopened.runner.settled();
  expect(reopenedModel.calls.values).toHaveLength(0);
  await reopened.runner.send(input('fresh'));
  const fresh = await reopenedModel.call(1);
  expect(fresh.request.history.filter((entry) => entry.type === 'input').map((entry) => entry.input.id))
    .toEqual(['active', 'fresh']);
  expect(reopened.runner.state.busy).toBe(true);
  expect(await reopened.runner.interrupt(request)).toEqual(returned);
  expect(fresh.signal.aborted).toBe(false);
  expect(reopened.runner.state.busy).toBe(true);
  fresh.response.complete();
  await reopened.runner.settled();
  expect(reopened.journal.records.filter((record) => record.type === 'thread.stopped')).toHaveLength(1);
}, 1000);

// 流异常会与排队输入/持久化交错；失败必须停住，不能因为有文字或 completed 就误判成功。
test('断流和完成后多余事件都会暂停，工具或回合记录写失败就进入恢复阻塞', async () => {
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
      lastOutcome: { kind: 'failed' }, recovery: { message: expect.any(String) } });
    expect(model.calls.values).toHaveLength(1);
    await expect(runner.confirmRecovery()).rejects.toThrow();
    if (failAt === 'tool.finished') {
      await runner.shutdown();
      const reopenedModel = new ManualModel();
      const reopened = h.runner(root, { model: reopenedModel, tools: [write] });
      await reopened.runner.settled();
      expect(reopened.runner.state).toMatchObject({ phase: 'idle', busy: false, waitingForResume: true,
        lastOutcome: { kind: 'failed' }, recovery: { message: expect.any(String) } });
      expect(reopenedModel.calls.values).toHaveLength(0);
      expect(executed).toBe(1);
      expect(reopened.journal.records.filter((record) => record.type === 'tool.finished').map((record) => [record.callId, record.result.status])).toEqual([
        ['first-write', 'unknown'], ['blocked-write', 'not_executed'],
      ]);
    }
  }
}, 1000);

// 通过公开 append 写入真实崩溃事实，验证重新读盘、补结果与上下文重建，绝不启动旧副作用。
test('恢复复用已保存结果并补未知和未执行，宿主确认后仍须显式继续且不重跑工具', async () => {
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
  await recovered.runner.settled();
  expect(recovered.runner.state).toMatchObject({ phase: 'idle', busy: false, waitingForResume: true,
    lastOutcome: { kind: 'failed' }, recovery: { message: expect.any(String) } });
  expect(executed).toBe(0);
  expect(model.calls.values).toHaveLength(0);
  const results = recovered.journal.records.filter((record) => record.type === 'tool.finished');
  expect(results.find((record) => record.callId === 'saved')?.result).toEqual(success('磁盘中的结果'));
  expect(results.find((record) => record.callId === 'waiting')?.result.status).toBe('not_executed');
  expect(results.find((record) => record.callId === 'uncertain')?.result.status).toBe('unknown');
  await recovered.runner.confirmRecovery();
  await recovered.runner.settled();
  expect(recovered.runner.state).toMatchObject({ phase: 'idle', busy: false, waitingForResume: true });
  expect(recovered.runner.state.recovery).toBeUndefined();
  expect(model.calls.values).toHaveLength(0);
  await recovered.runner.send(input('after-crash'));
  const resumed = await model.call(1);
  expect(resumed.request.history.filter((entry) => entry.type === 'output')).toEqual([saved, waiting, uncertain].map((entry) => ({ type: 'output', item: entry })));
  expect(resumed.request.history.filter((entry) => entry.type === 'tool_result').map((entry) => [entry.callId, entry.result.status])).toEqual([
    ['saved', 'success'], ['waiting', 'not_executed'], ['uncertain', 'unknown'],
  ]);
  expect(resumed.request.history).toContainEqual({ type: 'tool_result', callId: 'saved', result: success('磁盘中的结果') });
  expect(resumed.request.history.at(-1)).toEqual({ type: 'input', input: input('after-crash') });
  expect(executed).toBe(0);
  resumed.response.complete();
  await recovered.runner.settled();

  const legacyRoot = h.root();
  const legacyPath = join(legacyRoot, 'journal.jsonl');
  const oldBytes = [
    { version: 1, seq: 1, at: 1, type: 'turn.started', turnId: 'old-recovery-turn' },
    { version: 1, seq: 2, at: 2, type: 'turn.finished', turnId: 'old-recovery-turn',
      outcome: { kind: 'needs_recovery', message: '旧版恢复提示' } },
  ].map((record) => JSON.stringify(record)).join('\n') + '\n';
  writeFileSync(legacyPath, oldBytes);
  expect(() => new FileJournal(legacyPath)).toThrow();
  expect(readFileSync(legacyPath, 'utf8')).toBe(oldBytes);
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

// 文件尾行可能尚未写完，且写入器已持锁；只读查询必须保留字节，首次配置后的正文交给恢复读取校验。
test('首次配置查询忽略未换行尾行且不争写锁，后续损坏留到 journal 恢复时校验', () => {
  const root = h.root();
  const path = join(root, 'query.jsonl');
  const index = new JournalIndex();
  const emptyDirectory = readdirSync(root);
  expect(index.firstConfiguration(path)).toBeUndefined();
  expect(readdirSync(root)).toEqual(emptyDirectory);
  writeFileSync(path, '');
  expect(index.firstConfiguration(path)).toBeUndefined();
  expect(readFileSync(path, 'utf8')).toBe('');

  const partial = JSON.stringify(configurationRecord('completed-on-newline'));
  writeFileSync(path, partial);
  const before = readdirSync(root);
  expect(index.firstConfiguration(path)).toBeUndefined();
  expect(index.firstConfiguration(path)).toBeUndefined();
  expect(readFileSync(path, 'utf8')).toBe(partial);
  expect(readdirSync(root)).toEqual(before);
  appendFileSync(path, '\n');
  expect(index.firstConfiguration(path)).toBe(configurationRecord('completed-on-newline').snapshot.id);

  for (const malformed of [
    '不是 JSON',
    JSON.stringify(configurationRecord('sequence-gap', 2)),
    JSON.stringify({ ...configurationRecord('invalid-schema'), snapshot: { id: 'invalid-schema' } }),
  ]) {
    writeFileSync(path, malformed + '\n');
    expect(() => index.firstConfiguration(path)).toThrow();
    expect(readFileSync(path, 'utf8')).toBe(malformed + '\n');
  }

  const lockedPath = join(root, 'locked.jsonl');
  const writer = h.open(lockedPath);
  writer.append({ type: 'input.received', input: input('before-configuration') });
  writer.append({ type: 'request.configured', snapshot: configurationRecord('first-configuration').snapshot });
  // 大输出和后续损坏都在首条配置之后；查询不会解析它们，恢复读取仍必须拒绝损坏。
  writer.append({ type: 'tool.finished', turnId: 'turn', requestId: 'request', callId: 'large-output',
    result: success('工具输出'.repeat(100_000)) });
  appendFileSync(lockedPath, '损坏的后续记录\n');
  const lockedBytes = readFileSync(lockedPath, 'utf8');
  const lockedFiles = readdirSync(root);
  expect(index.firstConfiguration(lockedPath)).toBe(configurationRecord('first-configuration').snapshot.id);
  expect(readFileSync(lockedPath, 'utf8')).toBe(lockedBytes);
  expect(readdirSync(root)).toEqual(lockedFiles);
  writer.close();
  expect(() => new FileJournal(lockedPath)).toThrow();
  expect(readFileSync(lockedPath, 'utf8')).toBe(lockedBytes);

  const splitPath = join(root, 'split-block.jsonl');
  const prefix: JournalRecord = { version: 1, seq: 1, at: 1, type: 'input.received',
    input: { ...input('split-block'), text: '' } };
  const template = JSON.stringify(prefix);
  const textAt = Buffer.byteLength(template.slice(0, template.indexOf('"text":""') + '"text":"'.length));
  const firstPadding = 'a'.repeat(65_535 - textAt) + '风筝';
  const lineLength = Buffer.byteLength(JSON.stringify({ ...prefix, input: { ...prefix.input, text: firstPadding } })) + 1;
  prefix.input.text = firstPadding + 'a'.repeat(131_072 - 50 - lineLength);
  // 「风」的三个 UTF-8 字节跨 64 KiB 边界；配置行从 128 KiB 边界前 50 字节开始。
  const configuration = configurationRecord('cross-block', 2);
  writeFileSync(splitPath, JSON.stringify(prefix) + '\n' + JSON.stringify(configuration) + '\n');
  expect(index.firstConfiguration(splitPath)).toBe(configuration.snapshot.id);
}, 1000);

// 真实文件追加、同 inode 改写与原子替换会改变 stat 版本；缓存中的 undefined 和已找到的 ID 都须重验。
test('首次配置缓存随补齐尾行、同 inode 改写截断和原子换文件更新，重启可重建', () => {
  const root = h.root();
  const path = join(root, 'changing.jsonl');
  const index = new JournalIndex();
  const prefix: JournalRecord = { version: 1, seq: 1, at: 1, type: 'input.received', input: input('prefix') };
  writeFileSync(path, JSON.stringify(prefix) + '\n');
  expect(index.firstConfiguration(path)).toBeUndefined();
  appendFileSync(path, JSON.stringify(configurationRecord('first-one', 2)));
  expect(index.firstConfiguration(path)).toBeUndefined();
  appendFileSync(path, '\n');
  expect(index.firstConfiguration(path)).toBe(configurationRecord('first-one', 2).snapshot.id);
  expect(index.firstConfiguration(path)).toBe(configurationRecord('first-one', 2).snapshot.id);
  appendFileSync(path, JSON.stringify(configurationRecord('later-one', 3)) + '\n');
  expect(index.firstConfiguration(path)).toBe(configurationRecord('first-one', 2).snapshot.id);

  const original = statSync(path);
  const rewritten = [prefix, configurationRecord('first-two', 2), configurationRecord('later-one', 3)]
    .map((record) => JSON.stringify(record)).join('\n') + '\n';
  writeFileSync(path, rewritten);
  expect(statSync(path).ino).toBe(original.ino);
  expect(statSync(path).size).toBe(original.size);
  expect(index.firstConfiguration(path)).toBe(configurationRecord('first-two', 2).snapshot.id);
  writeFileSync(path, '');
  expect(statSync(path).ino).toBe(original.ino);
  expect(index.firstConfiguration(path)).toBeUndefined();
  appendFileSync(path, JSON.stringify(configurationRecord('third-one')));
  expect(index.firstConfiguration(path)).toBeUndefined();
  appendFileSync(path, '\n');
  expect(index.firstConfiguration(path)).toBe(configurationRecord('third-one').snapshot.id);

  const replacement = join(root, 'replacement.jsonl');
  writeFileSync(replacement, JSON.stringify(configurationRecord('fourth-id')) + '\n');
  renameSync(replacement, path);
  expect(statSync(path).ino).not.toBe(original.ino);
  expect(index.firstConfiguration(path)).toBe(configurationRecord('fourth-id').snapshot.id);
  expect(new JournalIndex().firstConfiguration(path)).toBe(configurationRecord('fourth-id').snapshot.id);
}, 1000);
