/**
 * 集成时工作树与主线之间的 Git 历史和冲突：检出是裸仓库（主线 main），工作区是从它开出的工作树（分支 kite/s）。
 */
import { expect, test } from 'bun:test';
import { rmSync } from 'node:fs';
import { join } from 'node:path';
import { advanceMainline, mergeMainline } from '../../src/workspace/mainline.ts';
import { commitMainline, git, gitOk, newRepo, useTemp, writeFiles } from '../util.ts';

const temp = useTemp();

/** 裸仓库检出（分支 main）加一个从它开出的会话工作树（分支 kite/s）。 */
function setup(files: Record<string, string>) {
  const root = temp();
  const checkout = join(root, 'checkout.git');
  git(root, 'clone', '-q', '--bare', newRepo(root, 'source', files, null), checkout);
  const wt = join(root, 'wt');
  git(checkout, 'worktree', 'add', '-q', '-b', 'kite/s', wt, 'main');
  return { checkout, wt, project: { path: checkout } };
}

const MAIN = ['refs/heads/main'];
const head = (dir: string) => git(dir, 'rev-parse', 'HEAD');
const show = (checkout: string, path: string) => git(checkout, 'show', `main:${path}`);
const has = (checkout: string, path: string) => gitOk(checkout, 'cat-file', '-e', `main:${path}`);
const clean = (dir: string) => git(dir, 'status', '--porcelain', '--untracked-files=all') === '';

/*
 * 依赖几条 git 命令合起来的效果：在会话工作树里提交、把主线合进会话分支、主线快进到会话分支，
 * 合起来两边的改动都在，主线停在会话分支的提交上。
 */
test('合进主线保留两边的新提交，主线快进到工作树 HEAD', async () => {
  const { checkout, wt, project } = setup({ 'a.txt': 'a\n', 'b.txt': 'b\n' });
  writeFiles(wt, { 'a.txt': 'a-session\n', 's.txt': 'session\n' });
  const mainCommit = commitMainline(checkout, { 'b.txt': 'b-main\n', 'm.txt': 'main\n' }, 'main moves');

  const r = await mergeMainline(wt, '会话', MAIN);
  expect(r).toEqual({ status: 'merged', commit: head(wt) });
  if (r.status !== 'merged') return;
  await advanceMainline(project, 'main', r.commit);
  expect(git(checkout, 'rev-parse', 'main')).toBe(head(wt));
  expect(gitOk(checkout, 'merge-base', '--is-ancestor', mainCommit, 'main')).toBe(true);
  expect([show(checkout, 'a.txt'), show(checkout, 's.txt'), show(checkout, 'b.txt'), show(checkout, 'm.txt')])
    .toEqual(['a-session', 'session', 'b-main', 'main']);
  expect(clean(wt)).toBe(true);
});

/*
 * 依赖 git 合并中的状态和 add -A、commit 对未合并条目的效果：冲突留在会话工作树里，下一次调用时还在，
 * 主线不受影响。agent 在沙箱里不能写 Git 元数据，只能改文件（真实 bug：原来只认 agent 自己
 * add 并提交的解决，沙箱里永远合不回去）；只改文件时，宿主标记解决（stageResolved）后才提交合并，
 * 仍带冲突标记的文件不放行，删掉的文件算已解决。
 */
test('合进主线冲突留在工作树，agent 只改文件时由宿主标记解决后合进，仍带冲突标记的文件不放行', async () => {
  const { checkout, wt, project } = setup({ 'c.txt': 'base\n', 'd.txt': 'base-d\n', 'o.txt': 'o\n' });
  writeFiles(wt, { 'c.txt': 'session\n', 'd.txt': 'session-d\n', 'o.txt': 'session-o\n' });
  const mainCommit = commitMainline(checkout, { 'c.txt': 'main\n', 'd.txt': 'main-d\n' }, 'main edits c and d');

  const r1 = await mergeMainline(wt, '会话', MAIN);
  expect(r1.status).toBe('conflict');
  if (r1.status !== 'conflict') return;
  expect([...r1.files].sort()).toEqual(['c.txt', 'd.txt']);
  expect(git(checkout, 'rev-parse', 'main')).toBe(mainCommit);

  const r2 = await mergeMainline(wt, '会话', MAIN);
  expect(r2.status).toBe('conflict');
  if (r2.status !== 'conflict') return;
  expect([...r2.files].sort()).toEqual(['c.txt', 'd.txt']);

  // 模拟沙箱里的 agent：只改文件内容去掉 c.txt 的冲突标记，不碰 git；d.txt 仍带标记。
  writeFiles(wt, { 'c.txt': 'session\n' });
  const r3 = await mergeMainline(wt, '会话', MAIN);
  expect(r3.status).toBe('conflict');
  if (r3.status !== 'conflict') return;
  expect([...r3.files].sort()).toEqual(['c.txt', 'd.txt']);
  const r4 = await mergeMainline(wt, '会话', MAIN, { stageResolved: true });
  expect(r4).toEqual({ status: 'conflict', files: ['d.txt'] });
  expect(git(checkout, 'rev-parse', 'main')).toBe(mainCommit);

  // d.txt 以删除作出取舍
  rmSync(join(wt, 'd.txt'));
  const r5 = await mergeMainline(wt, '会话', MAIN, { stageResolved: true });
  expect(r5.status).toBe('merged');
  if (r5.status !== 'merged') return;
  await advanceMainline(project, 'main', r5.commit);
  const [mainHead, sessionHead] = git(checkout, 'rev-parse', 'main', 'kite/s').split('\n');
  expect(mainHead).toBe(sessionHead);
  expect(gitOk(checkout, 'merge-base', '--is-ancestor', mainCommit, 'main')).toBe(true);
  expect([show(checkout, 'c.txt'), show(checkout, 'o.txt'), has(checkout, 'd.txt')]).toEqual(['session', 'session-o', false]);
  expect(clean(wt)).toBe(true);
});
