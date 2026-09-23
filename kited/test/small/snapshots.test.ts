/**
 * 快照与回退（src/snapshots.ts）：S1–S2。
 */
import { expect, test } from 'bun:test';
import { renameSync, rmSync } from 'node:fs';
import { join } from 'node:path';
import { capture, list, restore } from '../../src/snapshots.ts';
import { git, gitWorktree, lexists, newRepo, read, repoState, useTemp, writeFiles } from '../util.ts';

const temp = useTemp();

/*
 * 回归两个 bug：标签曾在第 80 个字处截断（这里用超过 80 字的标签）；快照曾挂在 refs/kite/<会话>，
 * 和会话分支 kite/<会话> 的短名相同，git 优先把短名解析成快照。
 */
test('capture 在 refs/kite/snapshots/<会话> 上建提交：树没变不产生新提交，list 原样读回标签和工具调用 id、新的在前，不动 HEAD、分支、暂存区，会话分支短名仍解析到分支', async () => {
  const root = temp();
  const main = newRepo(root, 'main', { 'a.txt': 'a\n', 'b.txt': 'b\n' });
  writeFiles(main, { 'b.txt': 'main dirty\n', 'm.txt': 'm\n' });
  git(main, 'add', 'm.txt');
  const id = 's1';
  const wt = gitWorktree(main, join(root, 'wt'), `kite/${id}`);
  writeFiles(wt, { 'staged.txt': 'st\n' });
  git(wt, 'add', 'staged.txt');
  writeFiles(wt, { 'a.txt': 'a1\n' });
  const before = [repoState(main), repoState(wt)];

  const first = await capture(wt, id, '会话开始');
  expect(first.created).toBe(true);
  expect(git(main, 'show', `${first.commit}:a.txt`)).toBe('a1');

  const same = await capture(wt, id, '没有变化');
  expect(same.created).toBe(false);
  expect(same.commit).toBe(first.commit);

  // 已改过的文件再改一次：工作区状态的样子不变，树变了
  writeFiles(wt, { 'a.txt': 'a2\n' });
  const label = `RUN echo 长标签 # ${'这是一条比较长的用户消息，'.repeat(8)}结尾`;
  expect(label.length).toBeGreaterThan(80);
  const second = await capture(wt, id, label, ['toolu_a', 'toolu_b']);
  expect(second.created).toBe(true);
  // 快照是这个引用上的提交链：引用指向最新的一枚，list 沿它读回
  expect(git(main, 'rev-parse', `refs/kite/snapshots/${id}`)).toBe(second.commit);

  const snaps = await list(main, id);
  expect(snaps.map((s) => s.commit)).toEqual([second.commit, first.commit]);
  expect(snaps[0]!.label).toBe(label);
  expect(snaps[0]!.toolUseIds).toEqual(['toolu_a', 'toolu_b']);
  expect(snaps[1]!.label).toBe('会话开始');
  expect(snaps[1]!.toolUseIds).toEqual([]);

  expect([repoState(main), repoState(wt)]).toEqual(before);
  const [short, branch] = git(main, 'rev-parse', `kite/${id}`, `refs/heads/kite/${id}`).split('\n');
  expect(short).toBe(branch);
});

test('restore 把工作树恢复成快照：删掉和改名的文件回来、之后新建的删掉、被忽略的不动；有快照之外的改动先存一枚「回退前自动保存」，能回退回去', async () => {
  const root = temp();
  const main = newRepo(root, 'main', {
    '.gitignore': '.env\n',
    'keep.txt': 'v0\n',
    'del.txt': 'to be deleted\n',
    'ren.txt': 'to be renamed\n',
    'dir/inner.txt': 'inner\n',
  });
  const id = 's2';
  const wt = gitWorktree(main, join(root, 'wt'), `kite/${id}`);
  writeFiles(wt, { '.env': 'SECRET=1\n', 'keep.txt': 'v1\n' });
  const s1 = await capture(wt, id, 'v1');

  // 之后的改动，还没进任何快照
  rmSync(join(wt, 'del.txt'));
  renameSync(join(wt, 'ren.txt'), join(wt, 'renamed.txt'));
  rmSync(join(wt, 'dir'), { recursive: true });
  writeFiles(wt, { 'created.txt': 'new\n', 'newdir/deep/f.txt': 'nd\n', 'keep.txt': 'v2\n', '.env': 'SECRET=2\n' });

  const r = await restore(wt, id, s1.commit);
  expect(read(join(wt, 'keep.txt'))).toBe('v1\n');
  expect(read(join(wt, 'del.txt'))).toBe('to be deleted\n');
  expect(read(join(wt, 'ren.txt'))).toBe('to be renamed\n');
  expect(read(join(wt, 'dir/inner.txt'))).toBe('inner\n');
  expect(lexists(join(wt, 'renamed.txt'))).toBe(false);
  expect(lexists(join(wt, 'created.txt'))).toBe(false);
  expect(lexists(join(wt, 'newdir/deep/f.txt'))).toBe(false);
  expect(read(join(wt, '.env'))).toBe('SECRET=2\n');

  const auto = (await list(main, id)).find((s) => s.label === '回退前自动保存');
  expect(auto).toBeDefined();
  expect(r.safety.created).toBe(true);
  expect(r.safety.commit).toBe(auto!.commit);
  expect(git(main, 'show', `${auto!.commit}:created.txt`)).toBe('new');

  await restore(wt, id, auto!.commit);
  expect(read(join(wt, 'keep.txt'))).toBe('v2\n');
  expect(read(join(wt, 'created.txt'))).toBe('new\n');
  expect(read(join(wt, 'newdir/deep/f.txt'))).toBe('nd\n');
  expect(read(join(wt, 'renamed.txt'))).toBe('to be renamed\n');
  expect(lexists(join(wt, 'del.txt'))).toBe(false);
  expect(lexists(join(wt, 'ren.txt'))).toBe(false);
  expect(lexists(join(wt, 'dir/inner.txt'))).toBe(false);
  expect(read(join(wt, '.env'))).toBe('SECRET=2\n');
});
