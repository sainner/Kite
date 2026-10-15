import { expect, test } from 'bun:test';
import { createHash } from 'node:crypto';
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { assembleContext, bindContext, restoreContext } from '../../src/harness/context/assembler.ts';
import { directoryVariables, projectContext } from '../../src/harness/context/project.ts';
import type { ContextDefinition, ContextSource } from '../../src/harness/context/types.ts';
import { diskRecords, input, item, ManualModel, success, tool, useHarness } from '../harness-loop.ts';
import { git, gitWorktree, newDir, newRepo } from '../util.ts';

const h = useHarness();

// 工厂、同步落盘、模型请求和工具续接跨越多个状态边界；旧指令须保持在历史前缀里，新值只追加一次通知。
test('首次指令固定，后续上下文变化落盘并作为通知追加到历史', async () => {
  const source: ContextSource = {
    definition: {
      version: 2, id: 'editable', title: '可编辑上下文', scene: 'thread.create',
      blocks: [{
        type: 'paragraph', id: 'rules', title: '规则',
        parts: [{ type: 'text', text: '旧段落：' }, { type: 'variable', name: 'project.rules' }],
      }],
    },
    bindings: { 'project.rules': { text: '旧材料', sources: [{ path: 'AGENTS.md', sha256: 'a'.repeat(64) }] } },
  };
  const root = h.root();
  const model = new ManualModel();
  const { runner, path } = h.runner(root, {
    model,
    instructions: () => source,
    tools: [tool('next', async () => success('继续'))],
  });

  await runner.send(input('context'));
  const first = await model.call(1);
  const firstRecords = diskRecords(path);
  const firstSnapshot = firstRecords.find((record) => record.type === 'context.prepared');
  const firstStart = firstRecords.find((record) => record.type === 'request.started');
  if (firstSnapshot?.type !== 'context.prepared' || firstStart?.type !== 'request.started') throw new Error('缺少首请求上下文记录');
  expect(firstSnapshot.seq).toBeLessThan(firstStart.seq);
  expect(firstStart.contextId).toBe(firstSnapshot.snapshot.id);
  expect(first.request.instructions).toBe(restoreContext(firstSnapshot.snapshot).instructions);
  expect(first.request.instructions).toContain('旧段落：');
  expect(first.request.instructions).toContain('旧材料');

  source.definition.blocks[0] = {
    type: 'paragraph', id: 'rules', title: '规则',
    parts: [{ type: 'text', text: '新段落：' }, { type: 'variable', name: 'project.rules' }],
  };
  source.bindings['project.rules']!.text = '新材料';
  source.bindings['project.rules']!.sources![0]!.sha256 = 'b'.repeat(64);
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
  expect(snapshots[0]!.snapshot.bindings['project.rules']!.text).toBe('旧材料');
  expect(snapshots[0]!.snapshot.definition.blocks[0]).toMatchObject({
    parts: [{ type: 'text', text: '旧段落：' }, { type: 'variable', name: 'project.rules' }],
  });
  expect(snapshots[1]!.snapshot.bindings['project.rules']!.text).toBe('新材料');
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
  second.response.complete();
  await runner.settled();
  source.bindings['project.rules']!.sources![0]!.sha256 = 'c'.repeat(64);
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
test('未引用的项目材料不读取，也不触发重复通知', async () => {
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
    model, instructions: () => projectContext(source.definition, directoryVariables(root)),
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
        parts: [{ type: 'variable', name: 'project.rules' }] }] }],
    otherwise: { id: 'fixed-branch', title: '固定规则', blocks: [{ type: 'paragraph', id: 'fixed', title: '固定规则',
      parts: [{ type: 'text', text: '仅遵守这一段固定文字。' }] }] },
  }];
  expect(Object.keys(projectContext(source.definition, directoryVariables(root)).bindings)).toEqual(['environment.cwd']);
  await runner.send(input('hidden-material'));
  const third = await model.call(3);
  expect(third.request.instructions).toBe(first.request.instructions);
  expect(third.request.history.filter((entry) => entry.type === 'notification')).toEqual([]);
  expect(diskRecords(path).filter((record) => record.type === 'request.started').at(-1)!.notifications ?? []).toEqual([]);
  third.response.complete();
  await runner.settled();
}, 1000);

// 组装异常发生在输入封定之前；恢复时必须原样重试同一条 pending 输入。
test('缺少上下文绑定时保留输入，补齐后恢复并保存分支快照', async () => {
  const source: ContextSource = {
    definition: {
      version: 2, id: 'conditional', title: '条件上下文', scene: 'thread.create',
      blocks: [{
        type: 'condition', id: 'project-rule', title: '项目规则', variable: 'environment.cwd',
        cases: [{
          id: 'with-project', title: '带项目', equals: 'project',
          blocks: [{ type: 'paragraph', id: 'documents', title: '材料', parts: [{ type: 'variable', name: 'project.rules' }] }],
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

  source.bindings['project.rules'] = { text: '恢复后的项目规则' };
  await runner.resume();
  const call = await model.call(1);
  records = diskRecords(path);
  const snapshot = records.find((record) => record.type === 'context.prepared');
  const started = records.find((record) => record.type === 'request.started');
  if (snapshot?.type !== 'context.prepared' || started?.type !== 'request.started') throw new Error('恢复后未封定上下文');
  expect(started.contextId).toBe(snapshot.snapshot.id);
  expect(started.inputIds).toEqual(['retry-me']);
  expect(call.request.history.filter((entry) => entry.type === 'input')).toEqual([{ type: 'input', input: input('retry-me') }]);
  const restored = restoreContext(snapshot.snapshot);
  expect(restored.blocks[0]).toMatchObject({ type: 'condition', id: 'project-rule', branchId: 'with-project' });
  expect(call.request.instructions).toBe(restored.instructions);
  expect(call.request.instructions).toContain('恢复后的项目规则');
  call.response.complete();
  await runner.settled();
  expect(runner.state).toMatchObject({ phase: 'idle', busy: false, waitingForResume: false });
  expect(runner.state.lastOutcome).toEqual({ kind: 'completed' });
}, 1000);

// 依赖 git 的磁盘布局，不起 git 进程直接读：HEAD 文件在分支上写 `ref: refs/heads/<分支>`，分离时写提交号；
// 子目录要往上找到 .git；`git worktree add` 出来的工作树里 .git 是写着 `gitdir: <主仓库>/.git/worktrees/<名字>` 的文件，
// 工作树自己的 HEAD 在那个目录里，不是主仓库的 HEAD。
test('当前分支按 git 实际布局取：带斜杠的分支、子目录、工作树各取自己的 HEAD，分离 HEAD 和仓库外为空', () => {
  const root = h.root();
  const repo = newRepo(root, 'repo', { 'sub/dir/a.txt': 'a\n' }, null);
  git(repo, 'checkout', '-q', '-b', 'feature/x');
  const worktree = gitWorktree(repo, join(root, 'wt'), 'wt/own');
  const outside = newDir(root, 'outside');
  const branch = (cwd: string) => directoryVariables(cwd)['workspace.branch']().text;

  expect(branch(repo)).toBe('feature/x');
  expect(branch(join(repo, 'sub', 'dir'))).toBe('feature/x');
  expect(branch(worktree)).toBe('wt/own');
  expect(branch(join(worktree, 'sub'))).toBe('wt/own');
  expect(branch(outside)).toBe('');

  git(repo, 'checkout', '-q', '--detach');
  expect(branch(repo)).toBe('');
  expect(branch(worktree)).toBe('wt/own');
}, 1000);

// 日志解析（contextSnapshotSchema）、快照摘要校验与 runner 恢复历史要一起成立。project.documents 拆成 rules 和 memory 时，
// 记录里的快照若按当前变量目录校验，引用已删除名字的旧会话会全部打不开；旧名字只允许留在历史里，不能再用于新模板。
test('变量目录删掉旧名字后，引用旧名字的会话记录仍能还原并继续请求，新组装拒绝旧名字', async () => {
  const root = h.root();
  const source: ContextSource = {
    definition: {
      version: 2, id: 'legacy', title: '旧模板', scene: 'thread.create',
      blocks: [{ type: 'paragraph', id: 'documents', title: '项目材料',
        parts: [{ type: 'text', text: '旧段落：' }, { type: 'variable', name: 'project.rules' }] }],
    },
    bindings: { 'project.rules': { text: '旧文档材料' } },
  };
  const model = new ManualModel();
  const { runner, path } = h.runner(root, { model, instructions: () => source });
  await runner.send(input('before-rename'));
  const first = await model.call(1);
  first.response.complete();
  await runner.settled();
  await runner.shutdown();

  // 把记录改写成拆分前的样子：定义与绑定引用 project.documents，摘要按快照的算法重算
  //（sha256 of JSON {definition, bindings}，绑定键排序；这里只有一个键），引用旧摘要的地方一并替换。
  const prepared = diskRecords(path).find((record) => record.type === 'context.prepared');
  if (prepared?.type !== 'context.prepared') throw new Error('缺少上下文快照记录');
  const legacy = JSON.parse(JSON.stringify({ definition: prepared.snapshot.definition, bindings: prepared.snapshot.bindings })
    .replaceAll('"project.rules"', '"project.documents"')) as { definition: ContextDefinition; bindings: ContextSource['bindings'] };
  const legacyId = createHash('sha256').update(JSON.stringify(legacy)).digest('hex');
  expect(legacyId).not.toBe(prepared.snapshot.id);
  writeFileSync(path, readFileSync(path, 'utf8')
    .replaceAll('"project.rules"', '"project.documents"').replaceAll(prepared.snapshot.id, legacyId));
  expect(Object.keys(diskRecords(path).find((record) => record.type === 'context.prepared')!.snapshot.bindings))
    .toEqual(['project.documents']);

  expect(() => bindContext(legacy.definition, { 'project.documents': () => ({ text: '旧文档材料' }) })).toThrow(/project\.documents/);
  expect(() => assembleContext({ definition: legacy.definition, bindings: legacy.bindings })).toThrow(/project\.documents/);

  source.bindings['project.rules'] = { text: '新规则材料' };
  const reopenedModel = new ManualModel();
  const reopened = h.runner(root, { model: reopenedModel, instructions: () => source });
  await reopened.runner.send(input('after-rename'));
  const second = await reopenedModel.call(1);
  expect(second.request.instructions).toBe('旧段落：旧文档材料');
  expect(second.request.history.filter((entry) => entry.type === 'input').map((entry) => entry.type === 'input' && entry.input.id))
    .toEqual(['before-rename', 'after-rename']);
  second.response.complete();
  await reopened.runner.settled();
}, 1000);
