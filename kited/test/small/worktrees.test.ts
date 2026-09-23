/**
 * 会话工作树（src/worktrees.ts）：W1–W5。
 */
import { expect, test } from 'bun:test';
import { chmodSync, existsSync, mkdirSync, realpathSync, symlinkSync } from 'node:fs';
import { join } from 'node:path';
import { addWorktree, removeWorktree, runSetup } from '../../src/worktrees.ts';
import { commitAll, git, gitOk, gitWorktree, isSymlink, lexists, listTree, newRepo, read, repoState, useTemp, writeFiles } from '../util.ts';

const temp = useTemp();

test('addWorktree 在给定路径建工作树，新分支从 base 开始，主文件夹的文件、HEAD、分支、暂存区都不变', async () => {
  const root = temp();
  const main = newRepo(root, 'main', { 'a.txt': 'a\n' });
  const base = git(main, 'rev-parse', 'HEAD');
  // 主文件夹停在另一个分支、比 base 多一个提交，还有暂存和未暂存的改动
  git(main, 'checkout', '-q', '-b', 'dev');
  writeFiles(main, { 'b.txt': 'b\n' });
  commitAll(main, 'second');
  writeFiles(main, { 'a.txt': 'dirty\n', 'staged.txt': 's\n', 'u.txt': 'u\n' });
  git(main, 'add', 'staged.txt');
  const before = { state: repoState(main), tree: listTree(main) };

  const wt = join(root, 'wts', 'w1');
  await addWorktree(main, wt, 'kite/w1', base);

  expect(git(wt, 'symbolic-ref', 'HEAD')).toBe('refs/heads/kite/w1');
  expect(git(wt, 'rev-parse', 'HEAD')).toBe(base);
  expect(realpathSync(git(wt, 'rev-parse', '--path-format=absolute', '--git-common-dir'))).toBe(join(main, '.git'));
  expect(read(join(wt, 'a.txt'))).toBe('a\n');
  expect(lexists(join(wt, 'b.txt'))).toBe(false);
  expect({ state: repoState(main), tree: listTree(main) }).toEqual(before);
});

test('.worktreeinclude 按 gitignore 语法匹配：匹配且被忽略的文件复制进工作树，匹配但未被忽略的保持检出版本，符号链接不复制', async () => {
  const root = temp();
  const main = newRepo(root, 'main', {
    '.gitignore': '.env\nsecrets/\n*.local\n*.log\n*.secret\n',
    '.worktreeinclude': '.env\nsecrets/\n*.local\ntracked.txt\n/root.secret\n',
    'tracked.txt': 'committed\n',
  });
  writeFiles(main, {
    '.env': 'root\n',
    'app/.env': 'nested\n',
    'secrets/key.txt': 'key\n',
    'secrets/deep/more.txt': 'more\n',
    'config.local': 'local\n',
    'debug.log': 'not included\n',
    'root.secret': 'r\n',
    'app/root.secret': 'nested secret\n',
    'tracked.txt': 'dirty in main\n',
  });
  writeFiles(root, { 'outside/target.txt': 'target\n' });
  symlinkSync(join(root, 'outside/target.txt'), join(main, 'link.local'));
  symlinkSync(join(root, 'outside/target.txt'), join(main, 'secrets/link.txt'));
  symlinkSync(join(root, 'outside'), join(main, 'secrets/linkdir'));

  const wt = join(root, 'wts', 'w2');
  await addWorktree(main, wt, 'kite/w2', git(main, 'rev-parse', 'HEAD'));

  expect(read(join(wt, '.env'))).toBe('root\n');
  // 不带斜杠的模式匹配任意层级
  expect(read(join(wt, 'app/.env'))).toBe('nested\n');
  expect(read(join(wt, 'secrets/key.txt'))).toBe('key\n');
  expect(read(join(wt, 'secrets/deep/more.txt'))).toBe('more\n');
  expect(read(join(wt, 'config.local'))).toBe('local\n');
  // 前导斜杠只匹配根
  expect(read(join(wt, 'root.secret'))).toBe('r\n');
  expect(lexists(join(wt, 'app/root.secret'))).toBe(false);
  // 被忽略但没列在 .worktreeinclude 里
  expect(lexists(join(wt, 'debug.log'))).toBe(false);
  // 符号链接不复制
  expect(lexists(join(wt, 'link.local'))).toBe(false);
  expect(lexists(join(wt, 'secrets/link.txt'))).toBe(false);
  expect(lexists(join(wt, 'secrets/linkdir'))).toBe(false);
  // 匹配但未被忽略：检出的版本，不是主文件夹里改过的
  expect(read(join(wt, 'tracked.txt'))).toBe('committed\n');
  expect(git(wt, 'status', '--porcelain')).toBe('');
});

test('worktree.symlinkDirectories 里主文件夹中存在的目录在工作树里是指向它的软链接，不存在的、绝对路径、含 .. 的跳过', async () => {
  const root = temp();
  const absDir = join(root, 'abs-target');
  writeFiles(absDir, { 'x.txt': 'x\n' });
  const main = newRepo(root, 'main', {
    '.gitignore': 'node_modules/\ndata/\ncache/\n',
    '.claude/settings.json': JSON.stringify({
      worktree: { symlinkDirectories: ['node_modules', 'data/big', 'missing', absDir, '../sibling', 'x/../cache'] },
    }),
  });
  writeFiles(main, { 'node_modules/pkg/index.js': '1\n', 'data/big/blob.bin': 'blob\n', 'cache/c.txt': 'c\n' });
  mkdirSync(join(root, 'sibling'));

  const wt = join(root, 'wts', 'w3');
  await addWorktree(main, wt, 'kite/w3', git(main, 'rev-parse', 'HEAD'));

  expect(isSymlink(join(wt, 'node_modules'))).toBe(true);
  expect(realpathSync(join(wt, 'node_modules'))).toBe(join(main, 'node_modules'));
  expect(isSymlink(join(wt, 'data/big'))).toBe(true);
  expect(realpathSync(join(wt, 'data/big'))).toBe(join(main, 'data/big'));
  expect(lexists(join(wt, 'missing'))).toBe(false);
  expect(lexists(join(wt, absDir))).toBe(false);
  expect(isSymlink(absDir)).toBe(false);
  expect(lexists(join(wt, '..', 'sibling'))).toBe(false);
  expect(lexists(join(wt, 'cache'))).toBe(false);
  expect(lexists(join(wt, 'x'))).toBe(false);
});

test('runSetup：没有 .kite/setup 返回 null；有就在工作树里执行、KITE_MAIN_DIR 是主文件夹、输出进日志、返回退出码；不可执行时返回非 0', async () => {
  const root = temp();
  const main = newRepo(root, 'main', { 'a.txt': 'a\n' });
  const wt = gitWorktree(main, join(root, 'wts', 'w4'), 'kite/w4');
  const log = join(root, 'setup.log');

  expect(await runSetup(main, wt, log)).toBeNull();

  writeFiles(wt, {
    '.kite/setup': '#!/bin/sh\necho "cwd=$(pwd -P)"\necho "main=$KITE_MAIN_DIR"\necho "to-stderr" >&2\nexit 7\n',
  });
  chmodSync(join(wt, '.kite/setup'), 0o755);
  expect(await runSetup(main, wt, log)).toBe(7);
  const out = read(log);
  expect(out).toContain(`cwd=${wt}`);
  expect(out).toContain(`main=${main}`);
  expect(out).toContain('to-stderr');

  chmodSync(join(wt, '.kite/setup'), 0o644);
  const code = await runSetup(main, wt, log);
  expect(code).not.toBeNull();
  expect(code).not.toBe(0);
});

test('removeWorktree 删掉工作树目录和会话分支（有没提交和没合回的改动也删），快照引用还在', async () => {
  const root = temp();
  const main = newRepo(root, 'main', { 'a.txt': 'a\n' });
  const wt = gitWorktree(main, join(root, 'wts', 'w5'), 'kite/w5');
  writeFiles(wt, { 'b.txt': 'b\n' });
  const snap = commitAll(wt, 'session work');
  git(main, 'update-ref', 'refs/kite/snapshots/w5', snap);
  writeFiles(wt, { 'a.txt': 'dirty\n', 'untracked.txt': 'u\n' });

  await removeWorktree(main, wt, 'kite/w5');

  expect(existsSync(wt)).toBe(false);
  expect(gitOk(main, 'rev-parse', '--verify', '--quiet', 'refs/heads/kite/w5')).toBe(false);
  expect(git(main, 'worktree', 'list', '--porcelain')).not.toContain(wt);
  expect(git(main, 'rev-parse', 'refs/kite/snapshots/w5')).toBe(snap);
});
