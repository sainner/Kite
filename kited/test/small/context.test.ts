import { expect, test } from 'bun:test';
import { join } from 'node:path';
import { restoreContext } from '../../src/harness/context/assembler.ts';
import type { ContextSnapshot, ContextSource } from '../../src/harness/context/types.ts';
import { FileJournal } from '../../src/harness/journal.ts';
import { diskRecords, input, item, ManualModel, success, tool, useHarness } from '../harness-loop.ts';

const h = useHarness();

// 工厂、同步落盘、模型请求和工具续接跨越多个状态边界；修改原对象不能改写已发请求的快照。
test('每次模型请求封定当前定义和值，落盘快照与实际指令相同且后续请求读取新值', async () => {
  const source: ContextSource = {
    definition: {
      version: 2, id: 'editable', title: '可编辑上下文', scene: 'session.create',
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
  const { session, path } = h.session(root, {
    model,
    instructions: () => { factoryCalls++; return source; },
    tools: [tool('next', async () => success('继续'))],
  });

  await session.send(input('context'));
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
    expect(model.calls.values[index]!.request.instructions).toBe(restoreContext(snapshots[index]!.snapshot).instructions);
  }
  expect(snapshots[0]!.snapshot.bindings['project.documents']!.text).toBe('旧材料');
  expect(snapshots[0]!.snapshot.definition.blocks[0]).toMatchObject({
    parts: [{ type: 'text', text: '旧段落：' }, { type: 'variable', name: 'project.documents' }],
  });
  expect(snapshots[1]!.snapshot.bindings['project.documents']!.text).toBe('新材料');
  expect(snapshots[0]!.snapshot.id).not.toBe(snapshots[1]!.snapshot.id);
  expect(second.request.instructions).toContain('新段落：');
  expect(second.request.instructions).toContain('新材料');
  expect(second.request.history).toContainEqual({ type: 'output', item: item('continue', 'next') });
  expect(second.request.history).toContainEqual({ type: 'tool_result', callId: 'continue', result: success('继续') });
  expect(factoryCalls).toBe(2);
  second.response.complete();
  await session.settled();
  await session.send(input('same-context'));
  const third = await model.call(3);
  const reusedRecords = diskRecords(path);
  const reusedSnapshots = reusedRecords.filter((record) => record.type === 'context.prepared');
  const reusedStarts = reusedRecords.filter((record) => record.type === 'request.started');
  expect(reusedSnapshots).toHaveLength(2);
  expect(reusedStarts).toHaveLength(3);
  expect(reusedStarts[2]!.contextId).toBe(reusedSnapshots[1]!.snapshot.id);
  expect(third.request.instructions).toBe(second.request.instructions);
  expect(factoryCalls).toBe(3);
  third.response.complete();
  await session.settled();
}, 1000);

// 组装异常发生在输入封定之前；恢复时必须原样重试同一条 pending 输入。
test('选中分支缺少绑定时暂停而不消费输入，补齐后恢复并保存条件快照', async () => {
  const source: ContextSource = {
    definition: {
      version: 2, id: 'conditional', title: '条件上下文', scene: 'session.create',
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
  const { session, path } = h.session(h.root(), { model, instructions: () => source });
  await session.send(input('retry-me'));
  await session.settled();
  expect(session.state.phase).toBe('paused');
  expect(model.calls.values).toHaveLength(0);
  let records = diskRecords(path);
  expect(records.filter((record) => record.type === 'input.received')).toHaveLength(1);
  expect(records.some((record) => record.type === 'request.started' || record.type === 'context.prepared')).toBe(false);

  source.bindings['project.documents'] = { text: '恢复后的项目规则' };
  await session.resume();
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
  await session.settled();
  expect(session.state.lastOutcome).toEqual({ kind: 'completed' });
}, 1000);

// 旧 journal 的定义没有场景字段；反序列化、历史投影和新版本请求须在同一会话中衔接。
test('旧版上下文快照重开后仍能还原，下一请求改用场景定义并保留旧历史', async () => {
  // 由旧版 assembleContext 生成并冻结；升级后不可用新组装器重新生成旧数据。
  const legacySnapshot: ContextSnapshot = {
    id: '8525afbed3e952d61dc0f9cfc890ad2ded1d53008db01d8cd94842875f29d57d',
    definition: {
      version: 1, id: 'legacy', title: '旧场景',
      variables: [{ name: 'project.documents', title: '旧项目规则' }],
      blocks: [{
        type: 'paragraph', id: 'rules', title: '旧规则',
        parts: [{ type: 'text', text: '旧版前缀：' }, { type: 'variable', name: 'project.documents' }],
      }],
    },
    bindings: { 'project.documents': { text: '旧版材料' } },
  };
  const root = h.root();
  const path = join(root, 'journal.jsonl');
  const oldItem = item('old-opaque');
  const journal = new FileJournal(path);
  const ids = { turnId: 'old-turn', requestId: 'old-request' };
  journal.append({ type: 'input.received', input: input('old-input') });
  journal.append({ type: 'turn.started', turnId: ids.turnId });
  journal.append({ type: 'context.prepared', snapshot: legacySnapshot });
  journal.append({ type: 'request.started', ...ids, inputIds: ['old-input'], contextId: legacySnapshot.id });
  journal.append({ type: 'model.item', ...ids, item: oldItem });
  journal.append({ type: 'request.completed', ...ids, responseId: 'old-response', needsFollowUp: false });
  journal.append({ type: 'turn.finished', turnId: ids.turnId, outcome: { kind: 'completed' } });
  journal.close();

  const source: ContextSource = {
    definition: {
      version: 2, id: 'current', title: '新场景', scene: 'session.create',
      blocks: [{
        type: 'paragraph', id: 'current-rules', title: '新规则',
        parts: [{ type: 'text', text: '新版前缀：' }, { type: 'variable', name: 'project.documents' }],
      }],
    },
    bindings: { 'project.documents': { text: '新版材料' } },
  };
  const model = new ManualModel();
  const { session } = h.session(root, { model, instructions: source });
  await session.send(input('new-input'));
  const call = await model.call(1);
  const records = diskRecords(path);
  const snapshots = records.filter((record) => record.type === 'context.prepared');
  const starts = records.filter((record) => record.type === 'request.started');
  expect(snapshots).toHaveLength(2);
  expect(snapshots[0]!.snapshot).toEqual(legacySnapshot);
  expect(restoreContext(snapshots[0]!.snapshot).instructions).toBe('旧版前缀：旧版材料');
  expect(starts[0]!.contextId).toBe(legacySnapshot.id);
  expect(snapshots[1]!.snapshot.definition).toMatchObject({ version: 2, scene: 'session.create' });
  expect(starts[1]!.contextId).toBe(snapshots[1]!.snapshot.id);
  expect(call.request.instructions).toBe(restoreContext(snapshots[1]!.snapshot).instructions);
  expect(call.request.instructions).toContain('新版材料');
  expect(call.request.history).toContainEqual({ type: 'output', item: oldItem });
  expect(call.request.history).toContainEqual({ type: 'input', input: input('old-input') });
  call.response.complete();
  await session.settled();
}, 1000);
