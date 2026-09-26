import { expect, test } from 'bun:test';
import { appendFileSync, readFileSync, readdirSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { FileJournal } from '../../src/harness/journal.ts';
import type { Journal, JournalEvent, JournalRecord } from '../../src/harness/types.ts';
import {
  aborted, deferred, diskRecords, input, item, ManualModel, Seen, success, tool,
  useHarness, waitRecord, withAbort,
} from '../harness-loop.ts';

const h = useHarness();

// 流消费、工具副作用、同步文件写入和宿主快照四方交接：不能靠各函数单独正确来保证。
test('完整调用先落盘再执行，流未结束就启动，工具和快照结束后才请求下一轮', async () => {
  const root = h.root();
  const model = new ManualModel();
  const toolDone = h.gate(success('写入完成'));
  const snapshotDone = h.gate(undefined);
  const started = deferred<JournalRecord[]>();
  const snapshotStarted = deferred<string[]>();
  const path = join(root, 'journal.jsonl');
  const { session, journal, events } = h.session(root, {
    model,
    tools: [tool('write', async (_args, { signal }) => {
      started.resolve(diskRecords(path));
      return withAbort(toolDone.promise, signal);
    })],
    async afterTools(_turn, ids) { snapshotStarted.resolve(ids); await snapshotDone.promise; },
  });
  await session.send(input('first'));
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
  expect(session.state.busy).toBe(true);
  expect(model.calls.values).toHaveLength(1);
  snapshotDone.resolve(undefined);
  const second = await model.call(2);
  expect(second.request.history).toEqual([
    { type: 'input', input: input('first') },
    { type: 'output', item: call },
    { type: 'tool_result', callId: 'write-1', result: success('写入完成') },
  ]);
  second.response.complete();
  await session.settled();
  expect(session.state.lastOutcome).toEqual({ kind: 'completed' });
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
  const { session, events, journal } = h.session(h.root(), {
    model, tools: [tool('read', execute, true), tool('write', execute)],
  });
  await session.send(input('parallel'));
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
  await session.settled();
}, 1000);

// 最终文字、停止 hook、收尾之间都有 await；消息必须按实际边界归入回合。
test('最终文字后的插话和停止反馈继续同回合，收尾期间的消息另开回合', async () => {
  const model = new ManualModel();
  const finishing = deferred();
  const finish = h.gate(undefined);
  let stops = 0;
  let turns = 0;
  const { session } = h.session(h.root(), {
    model,
    async beforeStop() { return ++stops === 1 ? '请检查最后一步' : undefined; },
    async afterTurn() { if (++turns === 1) { finishing.resolve(); await finish.promise; } },
  });
  await session.send(input('initial'));
  const first = await model.call(1);
  await first.response.emit({ type: 'item', item: item('final-text') });
  await session.send(input('interjection'));
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
  await session.send(input('during-finish'));
  expect(model.calls.values).toHaveLength(3);
  expect(session.state.busy).toBe(true);
  finish.resolve(undefined);
  const fourth = await model.call(4);
  expect(fourth.request.turnId).not.toBe(first.request.turnId);
  expect(fourth.request.history.at(-1)).toEqual({ type: 'input', input: input('during-finish') });
  fourth.response.complete();
  await session.settled();
}, 1000);

// 取消信号先到，受管工具与快照稍后确认停止；关闭和重开必须保存后来排队的消息。
test('打断等待工具与收尾但不等待后来回合，关闭留下的队列能在重开后继续', async () => {
  const root = h.root();
  const model = new ManualModel();
  const toolStarted = deferred<AbortSignal>();
  const toolStopped = h.gate(success('取消前已完成'));
  const snapshotStarted = deferred();
  const snapshotDone = h.gate(undefined);
  const turnFinishing = deferred();
  const turnDone = h.gate(undefined);
  let turns = 0;
  const { session, path } = h.session(root, {
    model,
    tools: [tool('write', async (_args, { signal }) => {
      toolStarted.resolve(signal);
      await aborted(signal);
      return toolStopped.promise;
    })],
    async afterTools() { snapshotStarted.resolve(); await snapshotDone.promise; },
    async afterTurn() { if (++turns === 1) { turnFinishing.resolve(); await turnDone.promise; } },
  });
  await session.send(input('initial'));
  const first = await model.call(1);
  await first.response.emit({ type: 'item', item: item('writing', 'write') });
  const signal = await toolStarted.promise;
  let interrupted = false;
  const interruption = session.interrupt().then(() => { interrupted = true; });
  await aborted(signal);
  await session.send(input('later'));
  expect(interrupted).toBe(false);
  expect(session.state.busy).toBe(true);
  toolStopped.resolve(success('取消前已完成'));
  await snapshotStarted.promise;
  expect(interrupted).toBe(false);
  expect(model.calls.values).toHaveLength(1);
  snapshotDone.resolve(undefined);
  await turnFinishing.promise;
  expect(interrupted).toBe(false);
  turnDone.resolve(undefined);
  await interruption;
  const second = await model.call(2);
  expect(second.request.turnId).not.toBe(first.request.turnId);
  expect(second.request.history.at(-1)).toEqual({ type: 'input', input: input('later') });
  await session.send(input('keep-on-close'));
  await session.shutdown();
  expect(session.state.phase).toBe('closed');
  expect(diskRecords(path).filter((record) => record.type === 'request.started').flatMap((record) => record.inputIds)).not.toContain('keep-on-close');
  const reopenedModel = new ManualModel();
  const reopened = h.session(root, { model: reopenedModel });
  const resumed = await reopenedModel.call(1);
  expect(resumed.request.history.at(-1)).toEqual({ type: 'input', input: input('keep-on-close') });
  resumed.response.complete();
  await reopened.session.settled();

  // 实际缺口：刚建立 active turn、尚未封定第一次请求时关闭，不能按普通打断撤回输入。
  const earlyRoot = h.root();
  const earlyModel = new ManualModel();
  const closingStarted = deferred();
  let closing!: Promise<void>;
  const early = h.session(earlyRoot, {
    model: earlyModel,
    onEvent(event) {
      if (event.type === 'state' && event.state.phase === 'running' && event.state.turnId) {
        closing = early.session.shutdown();
        closingStarted.resolve();
      }
    },
  });
  await early.session.send(input('before-first-request'));
  await closingStarted.promise;
  await closing;
  expect(earlyModel.calls.values).toHaveLength(0);
  const earlyRecords = diskRecords(early.path);
  expect(earlyRecords.some((record) => record.type === 'input.received' && record.input.id === 'before-first-request')).toBe(true);
  expect(earlyRecords.some((record) => record.type === 'input.cancelled' || record.type === 'request.started')).toBe(false);
  const restartedModel = new ManualModel();
  const restarted = h.session(earlyRoot, { model: restartedModel });
  const pending = await restartedModel.call(1);
  expect(pending.request.history.filter((entry) => entry.type === 'input')).toEqual([
    { type: 'input', input: input('before-first-request') },
  ]);
  pending.response.complete();
  await restarted.session.settled();
  expect(restartedModel.calls.values).toHaveLength(1);
}, 1000);

// send 的接收段、pump 封定输入和 interrupt 同处事件循环，最早一次打断容易丢撤回。
test('立即打断撤回尚未请求的输入，重试去重且撤回不影响已经封定的输入', async () => {
  const model = new ManualModel();
  const { session, journal } = h.session(h.root(), { model });
  const sending = session.send(input('too-soon'));
  const interrupting = session.interrupt();
  await Promise.all([sending, interrupting]);
  await session.settled();
  expect(model.calls.values).toHaveLength(0);
  expect(journal.records.some((record) => record.type === 'input.cancelled' && record.inputId === 'too-soon')).toBe(true);
  await session.send(input('active'));
  const first = await model.call(1);
  await session.send(input('pending'));
  await session.send(input('pending'));
  await expect(session.send({ ...input('pending'), text: '冲突内容' })).rejects.toThrow();
  // 契约允许拒绝撤回；关键是已封定输入不能从事实和上下文中消失。
  await session.cancel('active').catch(() => {});
  await session.cancel('pending');
  first.response.complete();
  await session.settled();
  expect(model.calls.values).toHaveLength(1);
  expect(journal.records.filter((record) => record.type === 'input.received' && record.input.id === 'pending')).toHaveLength(1);
  expect(journal.records.filter((record) => record.type === 'input.cancelled').map((record) => record.inputId)).toEqual(['too-soon', 'pending']);
  expect(first.request.history).toEqual([{ type: 'input', input: input('active') }]);
}, 1000);

// 流异常会与排队输入/持久化交错；失败必须停住，不能因为有文字或 completed 就误判成功。
test('断流和完成后多余事件都会暂停，工具或回合记录写失败就进入恢复阻塞', async () => {
  for (const extraAfterCompleted of [false, true]) {
    const model = new ManualModel();
    let executed = 0;
    const { session } = h.session(h.root(), {
      model, tools: [tool('write', async () => { executed++; return success('不应执行'); })],
    });
    await session.send(input('failed'));
    const first = await model.call(1);
    await first.response.emit({ type: 'item', item: item('partial') });
    await session.send(input('queued'));
    if (extraAfterCompleted) {
      void first.response.emit({ type: 'completed', responseId: 'bad-response' });
      void first.response.emit({ type: 'item', item: item('illegal', 'write') });
    }
    first.response.finish();
    await session.settled();
    expect(session.state.phase).toBe('paused');
    expect(session.state.lastOutcome?.kind).toBe('failed');
    expect(model.calls.values).toHaveLength(1);
    expect(executed).toBe(0);
    await session.resume();
    const resumed = await model.call(2);
    expect(resumed.request.history).toContainEqual({ type: 'input', input: input('queued') });
    expect(resumed.request.history).toContainEqual({ type: 'output', item: item('partial') });
    expect(resumed.request.history.some((entry) => entry.type === 'feedback')).toBe(true);
    resumed.response.complete();
    await session.settled();
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
    const { session } = h.session(root, { model, journal, tools: [write] });
    await session.send(input('disk-full'));
    const first = await model.call(1);
    if (failAt !== 'turn.finished') await first.response.emit({ type: 'item', item: item('first-write', 'write') });
    if (failAt === 'tool.finished') {
      await started.promise;
      await first.response.emit({ type: 'item', item: item('blocked-write', 'write') });
    }
    first.response.complete();
    effectDone.resolve(success('副作用已经发生'));
    await session.settled();
    expect(executed).toBe(failAt === 'tool.finished' ? 1 : 0);
    expect(session.state.phase).toBe('needs_recovery');
    expect(session.state.lastOutcome?.kind).toBe('needs_recovery');
    expect(model.calls.values).toHaveLength(1);
    await expect(session.confirmRecovery()).rejects.toThrow();
    if (failAt === 'tool.finished') {
      await session.shutdown();
      const reopenedModel = new ManualModel();
      const reopened = h.session(root, { model: reopenedModel, tools: [write] });
      await reopened.session.settled();
      expect(reopened.session.state.phase).toBe('needs_recovery');
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
  journal.append({ type: 'request.started', ...ids, inputIds: ['before-crash'] });
  journal.append({ type: 'model.item', ...ids, item: saved });
  journal.append({ type: 'tool.started', ...ids, callId: saved.id });
  journal.append({ type: 'tool.finished', ...ids, callId: saved.id, result: success('磁盘中的结果') });
  journal.append({ type: 'model.item', ...ids, item: waiting });
  journal.append({ type: 'model.item', ...ids, item: uncertain });
  journal.append({ type: 'tool.started', ...ids, callId: uncertain.id });
  journal.close();
  const model = new ManualModel();
  let executed = 0;
  const recovered = h.session(root, {
    model, tools: [tool('write', async () => { executed++; return success('不应重跑'); })],
  });
  await recovered.session.settled();
  expect(recovered.session.state.phase).toBe('needs_recovery');
  expect(executed).toBe(0);
  expect(model.calls.values).toHaveLength(0);
  const results = recovered.journal.records.filter((record) => record.type === 'tool.finished');
  expect(results.find((record) => record.callId === 'saved')?.result).toEqual(success('磁盘中的结果'));
  expect(results.find((record) => record.callId === 'waiting')?.result.status).toBe('not_executed');
  expect(results.find((record) => record.callId === 'uncertain')?.result.status).toBe('unknown');
  await recovered.session.send(input('after-crash'));
  await recovered.session.confirmRecovery();
  expect(recovered.session.state.phase).toBe('paused');
  expect(model.calls.values).toHaveLength(0);
  await recovered.session.resume();
  const resumed = await model.call(1);
  expect(resumed.request.history.filter((entry) => entry.type === 'output')).toEqual([saved, waiting, uncertain].map((entry) => ({ type: 'output', item: entry })));
  expect(resumed.request.history.filter((entry) => entry.type === 'tool_result').map((entry) => [entry.callId, entry.result.status])).toEqual([
    ['saved', 'success'], ['waiting', 'not_executed'], ['uncertain', 'unknown'],
  ]);
  expect(resumed.request.history).toContainEqual({ type: 'tool_result', callId: 'saved', result: success('磁盘中的结果') });
  expect(resumed.request.history.at(-1)).toEqual({ type: 'input', input: input('after-crash') });
  expect(executed).toBe(0);
  resumed.response.complete();
  await recovered.session.settled();
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
