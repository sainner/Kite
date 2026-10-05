import { expect, test } from 'bun:test';
import { mkdirSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { restoreContext } from '../../src/harness/context/assembler.ts';
import { projectContext } from '../../src/harness/context/project.ts';
import type { ContextSnapshot, ContextSource } from '../../src/harness/context/types.ts';
import { diskRecords, input, item, ManualModel, success, tool, useHarness } from '../harness-loop.ts';

const h = useHarness();

// 工厂、同步落盘、模型请求和工具续接跨越多个状态边界；旧指令须保持在历史前缀里，新值只追加一次通知。
test('首次指令固定，后续上下文变化落盘并作为通知追加到历史', async () => {
  const source: ContextSource = {
    definition: {
      version: 2, id: 'editable', title: '可编辑上下文', scene: 'thread.create',
      blocks: [{
        type: 'paragraph', id: 'rules', title: '规则',
        parts: [{ type: 'text', text: '旧段落：' }, { type: 'variable', name: 'project.documents' }],
      }],
    },
    bindings: { 'project.documents': { text: '旧材料', sources: [{ path: 'AGENTS.md', sha256: 'a'.repeat(64) }] } },
  };
  const root = h.root();
  const model = new ManualModel();
  let factoryCalls = 0;
  const { runner, path } = h.runner(root, {
    model,
    instructions: () => { factoryCalls++; return source; },
    tools: [tool('next', async () => success('继续'))],
  });

  await runner.send(input('context'));
  const first = await model.call(1);
  const firstRecords = diskRecords(path);
  const firstSnapshot = firstRecords.find((record) => record.type === 'context.prepared');
  const firstStart = firstRecords.find((record) => record.type === 'request.started');
  expect(firstSnapshot?.type).toBe('context.prepared');
  expect(firstStart?.type).toBe('request.started');
  if (firstSnapshot?.type !== 'context.prepared' || firstStart?.type !== 'request.started') throw new Error('缺少首请求上下文记录');
  expect(firstSnapshot.seq).toBeLessThan(firstStart.seq);
  expect(firstStart.contextId).toBe(firstSnapshot.snapshot.id);
  expect(first.request.instructions).toBe(restoreContext(firstSnapshot.snapshot).instructions);
  expect(first.request.instructions).toContain('旧段落：');
  expect(first.request.instructions).toContain('旧材料');
  expect(factoryCalls).toBe(1);

  source.definition.blocks[0] = {
    type: 'paragraph', id: 'rules', title: '规则',
    parts: [{ type: 'text', text: '新段落：' }, { type: 'variable', name: 'project.documents' }],
  };
  source.bindings['project.documents']!.text = '新材料';
  source.bindings['project.documents']!.sources![0]!.sha256 = 'b'.repeat(64);
  await first.response.emit({ type: 'item', item: item('continue', 'next') });
  first.response.complete();

  const second = await model.call(2);
  const records = diskRecords(path);
  const snapshots = records.filter((record) => record.type === 'context.prepared');
  const starts = records.filter((record) => record.type === 'request.started');
  expect(snapshots).toHaveLength(2);
  expect(starts).toHaveLength(2);
  for (let index = 0; index < 2; index++) {
    expect(snapshots[index]!.seq).toBeLessThan(starts[index]!.seq);
    expect(starts[index]!.contextId).toBe(snapshots[index]!.snapshot.id);
  }
  expect(snapshots[0]!.snapshot.bindings['project.documents']!.text).toBe('旧材料');
  expect(snapshots[0]!.snapshot.definition.blocks[0]).toMatchObject({
    parts: [{ type: 'text', text: '旧段落：' }, { type: 'variable', name: 'project.documents' }],
  });
  expect(snapshots[1]!.snapshot.bindings['project.documents']!.text).toBe('新材料');
  expect(snapshots[0]!.snapshot.id).not.toBe(snapshots[1]!.snapshot.id);
  expect(second.request.instructions).toBe(first.request.instructions);
  const updates = second.request.history.filter((entry) => entry.type === 'notification');
  expect(updates).toHaveLength(1);
  expect(updates[0]!.notification.authority).toBe('instruction');
  const delivered = starts[1]!.notifications?.[0];
  if (!delivered) throw new Error('缺少已投递上下文快照');
  const { context, ...metadata } = delivered;
  expect(updates[0]!.notification).toEqual(metadata);
  expect(updates[0]!.text).toBe(restoreContext(context).instructions);
  expect(updates[0]!.text).toContain('新段落：');
  expect(updates[0]!.text).toContain('新材料');
  expect(starts[1]!.notifications).toHaveLength(1);
  expect(second.request.history).toContainEqual({ type: 'output', item: item('continue', 'next') });
  expect(second.request.history).toContainEqual({ type: 'tool_result', callId: 'continue', result: success('继续') });
  expect(factoryCalls).toBe(2);
  second.response.complete();
  await runner.settled();
  source.bindings['project.documents']!.sources![0]!.sha256 = 'c'.repeat(64);
  await runner.send(input('same-context'));
  const third = await model.call(3);
  const reusedRecords = diskRecords(path);
  const reusedSnapshots = reusedRecords.filter((record) => record.type === 'context.prepared');
  const reusedStarts = reusedRecords.filter((record) => record.type === 'request.started');
  expect(reusedSnapshots).toHaveLength(3);
  expect(reusedStarts).toHaveLength(3);
  expect(reusedStarts[2]!.contextId).toBe(reusedSnapshots[2]!.snapshot.id);
  expect(third.request.instructions).toBe(second.request.instructions);
  expect(third.request.history.filter((entry) => entry.type === 'notification')).toEqual(updates);
  expect(reusedStarts[2]!.notifications ?? []).toEqual([]);
  expect(factoryCalls).toBe(3);
  third.response.complete();
  await runner.settled();
  await runner.shutdown();
  const reopenedModel = new ManualModel();
  const reopened = h.runner(root, { model: reopenedModel, instructions: () => source });
  await reopened.runner.send(input('after-reopen'));
  const fourth = await reopenedModel.call(1);
  expect(fourth.request.instructions).toBe(first.request.instructions);
  expect(fourth.request.history.filter((entry) => entry.type === 'notification')).toEqual(updates);
  const reopenedRecords = diskRecords(path);
  expect(reopenedRecords.filter((record) => record.type === 'context.prepared')).toHaveLength(3);
  expect(reopenedRecords.filter((record) => record.type === 'request.started').at(-1)!.notifications ?? []).toEqual([]);
  fourth.response.complete();
  await reopened.runner.settled();
}, 1000);

// 已实测的跨模块 bug：未引用的 AGENTS 变化仍改变摘要、追加同正文通知；隐藏分支也不得读取过大材料。
test('固定文字和隐藏分支不读取未使用项目材料，也不向模型重复通知', async () => {
  const root = h.root();
  mkdirSync(join(root, '.git'));
  const agents = join(root, 'AGENTS.md');
  writeFileSync(agents, '最初的项目规则');
  const source: ContextSource = {
    definition: {
      version: 2, id: 'fixed', title: '固定规则', scene: 'thread.create',
      blocks: [{ type: 'paragraph', id: 'fixed', title: '固定规则',
        parts: [{ type: 'text', text: '仅遵守这一段固定文字。' }] }],
    },
    bindings: {},
  };
  const model = new ManualModel();
  const { runner, path } = h.runner(root, {
    model, instructions: () => projectContext(root, source.definition),
  });
  await runner.send(input('fixed-first'));
  const first = await model.call(1);
  expect(first.request.instructions).toBe('仅遵守这一段固定文字。');
  expect(diskRecords(path).find((record) => record.type === 'context.prepared')!.snapshot.bindings).toEqual({});
  first.response.complete();
  await runner.settled();

  writeFileSync(agents, '改变后且过大的项目规则'.repeat(200_000));
  await runner.send(input('unused-material-changed'));
  const second = await Promise.race([
    model.call(2),
    runner.settled().then(() => { throw new Error('未引用项目材料导致请求未启动'); }),
  ]);
  expect(second.request.instructions).toBe(first.request.instructions);
  expect(second.request.history.filter((entry) => entry.type === 'notification')).toEqual([]);
  expect(diskRecords(path).filter((record) => record.type === 'context.prepared')).toHaveLength(1);
  second.response.complete();
  await runner.settled();

  source.definition.blocks = [{
    type: 'condition', id: 'selected', title: '实际路径', variable: 'environment.cwd',
    cases: [{ id: 'hidden', title: '隐藏材料', equals: '另一个项目',
      blocks: [{ type: 'paragraph', id: 'documents', title: '项目材料',
        parts: [{ type: 'variable', name: 'project.documents' }] }] }],
    otherwise: { id: 'fixed-branch', title: '固定规则', blocks: [{ type: 'paragraph', id: 'fixed', title: '固定规则',
      parts: [{ type: 'text', text: '仅遵守这一段固定文字。' }] }] },
  }];
  expect(Object.keys(projectContext(root, source.definition).bindings)).toEqual(['environment.cwd']);
  await runner.send(input('hidden-material'));
  const third = await model.call(3);
  expect(third.request.instructions).toBe(first.request.instructions);
  expect(third.request.history.filter((entry) => entry.type === 'notification')).toEqual([]);
  expect(diskRecords(path).filter((record) => record.type === 'request.started').at(-1)!.notifications ?? []).toEqual([]);
  third.response.complete();
  await runner.settled();
}, 1000);

// 组装异常发生在输入封定之前；恢复时必须原样重试同一条 pending 输入。
test('选中分支缺少绑定时暂停而不消费输入，补齐后恢复并保存条件快照', async () => {
  const source: ContextSource = {
    definition: {
      version: 2, id: 'conditional', title: '条件上下文', scene: 'thread.create',
      blocks: [{
        type: 'condition', id: 'project-rule', title: '项目规则', variable: 'environment.cwd',
        cases: [{
          id: 'with-project', title: '带项目', equals: 'project',
          blocks: [{ type: 'paragraph', id: 'documents', title: '材料', parts: [{ type: 'variable', name: 'project.documents' }] }],
        }],
        otherwise: { id: 'without-project', title: '无项目', blocks: [] },
      }],
    },
    bindings: { 'environment.cwd': { text: 'project' } },
  };
  const model = new ManualModel();
  const { runner, path } = h.runner(h.root(), { model, instructions: () => source });
  await runner.send(input('retry-me'));
  await runner.settled();
  expect(runner.state).toMatchObject({ phase: 'idle', busy: false, waitingForResume: true,
    lastOutcome: { kind: 'failed' } });
  expect(model.calls.values).toHaveLength(0);
  let records = diskRecords(path);
  expect(records.filter((record) => record.type === 'input.received')).toHaveLength(1);
  expect(records.some((record) => record.type === 'request.started' || record.type === 'context.prepared')).toBe(false);

  source.bindings['project.documents'] = { text: '恢复后的项目规则' };
  await runner.resume();
  const call = await model.call(1);
  records = diskRecords(path);
  const snapshot = records.find((record) => record.type === 'context.prepared');
  const started = records.find((record) => record.type === 'request.started');
  expect(snapshot?.type).toBe('context.prepared');
  expect(started?.type).toBe('request.started');
  if (snapshot?.type !== 'context.prepared' || started?.type !== 'request.started') throw new Error('恢复后未封定上下文');
  expect(started.contextId).toBe(snapshot.snapshot.id);
  expect(started.inputIds).toEqual(['retry-me']);
  expect(call.request.history.filter((entry) => entry.type === 'input')).toEqual([{ type: 'input', input: input('retry-me') }]);
  const restored = restoreContext(JSON.parse(JSON.stringify(snapshot.snapshot)) as ContextSnapshot);
  expect(restored.blocks[0]).toMatchObject({ type: 'condition', id: 'project-rule', branchId: 'with-project' });
  expect(call.request.instructions).toBe(restored.instructions);
  expect(call.request.instructions).toContain('恢复后的项目规则');
  call.response.complete();
  await runner.settled();
  expect(runner.state).toMatchObject({ phase: 'idle', busy: false, waitingForResume: false });
  expect(runner.state.lastOutcome).toEqual({ kind: 'completed' });
}, 1000);
