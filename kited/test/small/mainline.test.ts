/**
 * 合回主线（src/mainline.ts）：M1–M6。
 */
import { expect, test } from 'bun:test';
import { rmSync } from 'node:fs';
import { join } from 'node:path';
import { KiteError } from '../../src/errors.ts';
import { hasUnmerged, mainline, mergeBack } from '../../src/mainline.ts';
import type { CommitOwner } from '../../src/store.ts';
import { commitAll, git, gitOk, gitWorktree, lexists, listTree, newRepo, read, repoState, useTemp, writeFiles } from '../util.ts';

const temp = useTemp();

/** 主文件夹（分支 main）加一个会话工作树（分支 kite/s）。 */
function setup(commits: CommitOwner, files: Record<string, string>) {
  const root = temp();
  const main = newRepo(root, 'main', files);
  const wt = gitWorktree(main, join(root, 'wt'), 'kite/s');
  return { main, wt, project: { path: main, commits } };
}

const head = (dir: string) => git(dir, 'rev-parse', 'HEAD');
const clean = (dir: string) => git(dir, 'status', '--porcelain', '--untracked-files=all') === '';

test('mergeBack 在主线没动时：会话里未提交的改动以给定说明提交，主文件夹快进到会话分支，文件出现，主文件夹干净', async () => {
  const { main, wt, project } = setup('kite', { 'a.txt': 'a\n', 'gone.txt': 'g\n' });
  const h0 = head(main);
  writeFiles(wt, { 'a.txt': 'a2\n', 'feat.txt': 'feature\n' });
  rmSync(join(wt, 'gone.txt'));

  const r = await mergeBack(project, wt, '把第二章的图注统一成中文');
  expect(r.status).toBe('merged');
  if (r.status !== 'merged') return;
  expect(head(wt)).toBe(r.commit);
  expect(git(wt, 'log', '-1', '--format=%B', r.commit).trim()).toBe('把第二章的图注统一成中文');
  expect(git(main, 'rev-parse', `${r.commit}^`)).toBe(h0);
  expect(head(main)).toBe(r.commit);
  expect(git(main, 'symbolic-ref', 'HEAD')).toBe('refs/heads/main');
  expect(read(join(main, 'a.txt'))).toBe('a2\n');
  expect(read(join(main, 'feat.txt'))).toBe('feature\n');
  expect(lexists(join(main, 'gone.txt'))).toBe(false);
  expect(clean(main)).toBe(true);
});

test('mergeBack 在主线有不冲突的新提交时：合回后两边的改动都在，主文件夹 HEAD 等于工作树 HEAD', async () => {
  const { main, wt, project } = setup('user', { 'a.txt': 'a\n', 'b.txt': 'b\n' });
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

test('mergeBack 遇到冲突：返回冲突文件且 fresh 为 true，主文件夹干净、HEAD 不变；不解决再调返回同样的文件、fresh 为 false；在工作树里解决并提交后再调就合回', async () => {
  const { main, wt, project } = setup('user', { 'c.txt': 'base\n', 'd.txt': 'base-d\n', 'o.txt': 'o\n' });
  writeFiles(wt, { 'c.txt': 'session\n', 'd.txt': 'session-d\n', 'o.txt': 'session-o\n' });
  writeFiles(main, { 'c.txt': 'main\n', 'd.txt': 'main-d\n' });
  const mainCommit = commitAll(main, 'main edits c and d');
  // 主文件夹此时干净，停在 mainCommit
  const mainState = repoState(main);

  const r1 = await mergeBack(project, wt, '会话');
  expect(r1).toEqual({ status: 'conflict', files: expect.any(Array), fresh: true });
  if (r1.status !== 'conflict') return;
  expect([...r1.files].sort()).toEqual(['c.txt', 'd.txt']);
  expect(repoState(main)).toBe(mainState);
  expect(read(join(main, 'c.txt'))).toBe('main\n');

  const r2 = await mergeBack(project, wt, '会话');
  expect(r2.status).toBe('conflict');
  if (r2.status !== 'conflict') return;
  expect([...r2.files].sort()).toEqual(['c.txt', 'd.txt']);
  expect(r2.fresh).toBe(false);
  expect(repoState(main)).toBe(mainState);

  // 以会话一侧解决冲突并提交
  git(wt, 'checkout', '--ours', '--', '.');
  commitAll(wt, '解决冲突');
  const r3 = await mergeBack(project, wt, '会话');
  expect(r3.status).toBe('merged');
  const [mainHead, sessionHead] = git(main, 'rev-parse', 'HEAD', 'kite/s').split('\n');
  expect(mainHead).toBe(sessionHead);
  expect(gitOk(main, 'merge-base', '--is-ancestor', mainCommit, 'HEAD')).toBe(true);
  expect(read(join(main, 'c.txt'))).toBe('session\n');
  expect(read(join(main, 'o.txt'))).toBe('session-o\n');
  expect(clean(main)).toBe(true);
});

test('commits 为 kite 的项目：主文件夹里没提交的改动由 mainline() 和 mergeBack 先存成「Kite：保存主文件夹里的改动」提交，合回后两边都在、主文件夹干净', async () => {
  const SAVE = 'Kite：保存主文件夹里的改动';
  const { main, wt, project } = setup('kite', { 'a.txt': 'a\n', 'gone.txt': 'g\n', 'u.txt': 'u0\n' });

  writeFiles(main, { 'u.txt': 'u1\n', 'new.txt': 'new\n' });
  const base = await mainline(project);
  expect(base).toBe(head(main));
  expect(git(main, 'log', '-1', '--format=%s')).toBe(SAVE);
  expect(git(main, 'show', 'HEAD:new.txt')).toBe('new');
  expect(clean(main)).toBe(true);

  writeFiles(wt, { 's.txt': 'session\n' });
  writeFiles(main, { 'a.txt': 'a-user\n', 'user.txt': 'user\n' });
  rmSync(join(main, 'gone.txt'));
  const r = await mergeBack(project, wt, '会话');
  expect(r.status).toBe('merged');
  expect(git(main, 'log', '--format=%s', `${base}..HEAD`).split('\n')).toContain(SAVE);
  expect(read(join(main, 's.txt'))).toBe('session\n');
  expect(read(join(main, 'a.txt'))).toBe('a-user\n');
  expect(read(join(main, 'user.txt'))).toBe('user\n');
  expect(lexists(join(main, 'gone.txt'))).toBe(false);
  expect(git(main, 'show', 'HEAD:user.txt')).toBe('user');
  expect(clean(main)).toBe(true);
});

test('commits 为 user 的项目：主文件夹里和会话无关的未提交改动合回后仍未提交、内容不变；和会话改了同一个文件时 mergeBack 抛 409，主文件夹不变', async () => {
  const { main, wt, project } = setup('user', { 'a.txt': 'a\n', 'notes.txt': 'notes0\n' });
  writeFiles(wt, { 'a.txt': 'a-session\n', 's.txt': 'session\n' });
  writeFiles(main, { 'a.txt': 'a-user\n', 'notes.txt': 'notes-dirty\n', 'scratch.txt': 'scratch\n', 'staged.txt': 'staged\n' });
  git(main, 'add', 'staged.txt');
  const h0 = head(main);
  const before = { tree: listTree(main), status: git(main, 'status', '--porcelain') };

  const e = await mergeBack(project, wt, '会话').then(() => undefined, (err) => err);
  expect(e).toBeInstanceOf(KiteError);
  expect((e as KiteError).status).toBe(409);
  expect(head(main)).toBe(h0);
  expect({ tree: listTree(main), status: git(main, 'status', '--porcelain') }).toEqual(before);

  // 用户放弃对 a.txt 的改动，其余的留着
  git(main, 'checkout', '--', 'a.txt');
  const r = await mergeBack(project, wt, '会话');
  expect(r.status).toBe('merged');
  expect(head(main)).toBe(head(wt));
  expect(read(join(main, 'a.txt'))).toBe('a-session\n');
  expect(read(join(main, 's.txt'))).toBe('session\n');
  expect(read(join(main, 'notes.txt'))).toBe('notes-dirty\n');
  expect(read(join(main, 'scratch.txt'))).toBe('scratch\n');
  expect(read(join(main, 'staged.txt'))).toBe('staged\n');
  expect(git(main, 'show', 'HEAD:notes.txt')).toBe('notes0');
  expect(gitOk(main, 'cat-file', '-e', 'HEAD:scratch.txt')).toBe(false);
  expect(gitOk(main, 'cat-file', '-e', 'HEAD:staged.txt')).toBe(false);
  // 三个文件都还是未提交状态（暂存与否不论）
  const status = git(main, 'status', '--porcelain').split('\n');
  for (const f of ['notes.txt', 'scratch.txt', 'staged.txt']) expect(status.some((l) => l.endsWith(` ${f}`))).toBe(true);
});

test('hasUnmerged：工作树有未提交改动、提交了没合回、合回后又有新改动为 true；完全合回、工作树不存在为 false', async () => {
  const { main, wt } = setup('user', { 'a.txt': 'a\n' });
  const rows: Array<[string, () => void, boolean]> = [
    ['工作树有未提交的新文件', () => writeFiles(wt, { 'n.txt': 'n\n' }), true],
    ['提交了但没合回', () => commitAll(wt, 'session'), true],
    ['完全合回', () => git(main, 'merge', '-q', '--ff-only', 'kite/s'), false],
    ['合回后又改了文件', () => writeFiles(wt, { 'a.txt': 'again\n' }), true],
    ['工作树不存在', () => git(main, 'worktree', 'remove', '--force', wt), false],
  ];
  const got: Array<[string, boolean]> = [];
  for (const [name, step] of rows) {
    step();
    got.push([name, await hasUnmerged(main, wt)]);
  }
  expect(got).toEqual(rows.map(([name, , want]) => [name, want]));
});
