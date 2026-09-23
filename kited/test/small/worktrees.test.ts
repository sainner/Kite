/**
 * 会话工作树（src/worktrees.ts）：W2、W3。
 */
import { expect, test } from 'bun:test';
import { realpathSync, symlinkSync } from 'node:fs';
import { join } from 'node:path';
import { addWorktree } from '../../src/worktrees.ts';
import { git, isSymlink, lexists, newRepo, read, useTemp, writeFiles } from '../util.ts';

const temp = useTemp();

/*
 * 依赖代码之外的行为：哪些文件算匹配由 git 按忽略规则的语法判定；
 * 规则照 Claude Code 2.1.280 自己建工作树时的做法（匹配且被 .gitignore 忽略的才复制，符号链接不复制）。
 */
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

/* 依赖上游：SDK 的 resolveSettings 从项目设置里读出 worktree.symlinkDirectories。 */
test('项目 .claude/settings.json 里 worktree.symlinkDirectories 写的目录，在工作树里是指向主文件夹里那个目录的软链接', async () => {
  const root = temp();
  const main = newRepo(root, 'main', {
    '.gitignore': 'node_modules/\ndata/\n',
    '.claude/settings.json': JSON.stringify({ worktree: { symlinkDirectories: ['node_modules', 'data/big'] } }),
  });
  writeFiles(main, { 'node_modules/pkg/index.js': '1\n', 'data/big/blob.bin': 'blob\n' });

  const wt = join(root, 'wts', 'w3');
  await addWorktree(main, wt, 'kite/w3', git(main, 'rev-parse', 'HEAD'));

  expect(isSymlink(join(wt, 'node_modules'))).toBe(true);
  expect(realpathSync(join(wt, 'node_modules'))).toBe(join(main, 'node_modules'));
  expect(isSymlink(join(wt, 'data/big'))).toBe(true);
  expect(realpathSync(join(wt, 'data/big'))).toBe(join(main, 'data/big'));
});
