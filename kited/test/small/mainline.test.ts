/**
 * 合回主线时的 Git 历史和冲突。
 */
import { expect, test } from 'bun:test';
import { existsSync, rmSync } from 'node:fs';
import { join } from 'node:path';
import { mergeBack } from '../../src/workspace/mainline.ts';
import { commitAll, git, gitOk, gitWorktree, newRepo, read, repoState, useTemp, writeFiles } from '../util.ts';

const temp = useTemp();

/** 主文件夹（分支 main）加一个会话工作树（分支 kite/s）。 */
function setup(files: Record<string, string>) {
  const root = temp();
  const main = newRepo(root, 'main', files);
  const wt = gitWorktree(main, join(root, 'wt'), 'kite/s');
  return { main, wt, project: { path: main } };
}

const head = (dir: string) => git(dir, 'rev-parse', 'HEAD');
const clean = (dir: string) => git(dir, 'status', '--porcelain', '--untracked-files=all') === '';

/*
 * 依赖几条 git 命令合起来的效果：在会话工作树里提交、把主线合进会话分支、主文件夹快进到会话分支，
 * 合起来两边的改动都在，主文件夹停在会话分支的提交上。
 */
test('合回保留两边的新提交，主线快进到工作树 HEAD', async () => {
  const { main, wt, project } = setup({ 'a.txt': 'a\n', 'b.txt': 'b\n' });
  writeFiles(wt, { 'a.txt': 'a-session\n', 's.txt': 'session\n' });
  writeFiles(main, { 'b.txt': 'b-main\n', 'm.txt': 'main\n' });
  const mainCommit = commitAll(main, 'main moves');

  const r = await mergeBack(project, wt, '会话');
  expect(r.status).toBe('merged');
  expect(head(main)).toBe(head(wt));
  expect(gitOk(main, 'merge-base', '--is-ancestor', mainCommit, 'HEAD')).toBe(true);
  expect(read(join(main, 'a.txt'))).toBe('a-session\n');
  expect(read(join(main, 's.txt'))).toBe('session\n');
  expect(read(join(main, 'b.txt'))).toBe('b-main\n');
  expect(read(join(main, 'm.txt'))).toBe('main\n');
  expect(clean(main)).toBe(true);
});

/*
 * 依赖 git 合并中的状态和 add -A、commit 对未合并条目的效果：冲突留在会话工作树里，下一次调用时还在，
 * 主文件夹不受影响。agent 在沙箱里不能写 Git 元数据，只能改文件（真实 bug：原来只认 agent 自己
 * add 并提交的解决，沙箱里永远合不回去）；只改文件时，宿主标记解决（stageResolved）后才提交合并，
 * 仍带冲突标记的文件不放行，删掉的文件算已解决。
 */
test('合回冲突留在工作树，agent 只改文件时由宿主标记解决后合回，仍带冲突标记的文件不放行', async () => {
  const { main, wt, project } = setup({ 'c.txt': 'base\n', 'd.txt': 'base-d\n', 'o.txt': 'o\n' });
  writeFiles(wt, { 'c.txt': 'session\n', 'd.txt': 'session-d\n', 'o.txt': 'session-o\n' });
  writeFiles(main, { 'c.txt': 'main\n', 'd.txt': 'main-d\n' });
  const mainCommit = commitAll(main, 'main edits c and d');
  // 主文件夹此时干净，停在 mainCommit
  const mainState = repoState(main);

  const r1 = await mergeBack(project, wt, '会话');
  expect(r1.status).toBe('conflict');
  if (r1.status !== 'conflict') return;
  expect([...r1.files].sort()).toEqual(['c.txt', 'd.txt']);
  expect(repoState(main)).toBe(mainState);
  expect(read(join(main, 'c.txt'))).toBe('main\n');

  const r2 = await mergeBack(project, wt, '会话');
  expect(r2.status).toBe('conflict');
  if (r2.status !== 'conflict') return;
  expect([...r2.files].sort()).toEqual(['c.txt', 'd.txt']);
  expect(repoState(main)).toBe(mainState);

  // 模拟沙箱里的 agent：只改文件内容去掉 c.txt 的冲突标记，不碰 git；d.txt 仍带标记。
  writeFiles(wt, { 'c.txt': 'session\n' });
  const r3 = await mergeBack(project, wt, '会话');
  expect(r3.status).toBe('conflict');
  if (r3.status !== 'conflict') return;
  expect([...r3.files].sort()).toEqual(['c.txt', 'd.txt']);
  const r4 = await mergeBack(project, wt, '会话', { stageResolved: true });
  expect(r4).toEqual({ status: 'conflict', files: ['d.txt'] });
  expect(repoState(main)).toBe(mainState);

  // d.txt 以删除作出取舍
  rmSync(join(wt, 'd.txt'));
  const r5 = await mergeBack(project, wt, '会话', { stageResolved: true });
  expect(r5.status).toBe('merged');
  const [mainHead, sessionHead] = git(main, 'rev-parse', 'HEAD', 'kite/s').split('\n');
  expect(mainHead).toBe(sessionHead);
  expect(gitOk(main, 'merge-base', '--is-ancestor', mainCommit, 'HEAD')).toBe(true);
  expect(read(join(main, 'c.txt'))).toBe('session\n');
  expect(read(join(main, 'o.txt'))).toBe('session-o\n');
  expect(existsSync(join(main, 'd.txt'))).toBe(false);
  expect(clean(main)).toBe(true);
  expect(clean(wt)).toBe(true);
});
