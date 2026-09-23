/**
 * 登记项目（src/projects.ts 的 register）：P1–P5。
 */
import { afterEach, expect, test } from 'bun:test';
import { existsSync, mkdirSync, symlinkSync } from 'node:fs';
import { join } from 'node:path';
import template from '../../../.claude/skills/kite-onboard/templates/gitignore' with { type: 'text' };
import { KiteError } from '../../src/errors.ts';
import { register } from '../../src/projects.ts';
import { Store } from '../../src/store.ts';
import { git, gitOk, listTree, newDir, newRepo, read, repoState, useTemp, writeFiles } from '../util.ts';

const temp = useTemp();
const stores: Store[] = [];
afterEach(() => { for (const s of stores.splice(0)) s.close(); });

/** 一套 KITE_HOME 和数据库，root 下放项目文件夹。 */
function kite() {
  const root = temp();
  const home = join(root, 'kite');
  mkdirSync(home);
  const store = new Store(join(home, 'kite.db'));
  stores.push(store);
  return { root, home, store };
}

const lsHead = (dir: string) => git(dir, 'ls-tree', '-r', '--name-only', 'HEAD').split('\n').filter(Boolean).sort();

async function rejected(p: Promise<unknown>): Promise<KiteError> {
  const e = await p.then(() => undefined, (err) => err);
  expect(e).toBeInstanceOf(KiteError);
  expect((e as KiteError).status).toBeGreaterThanOrEqual(400);
  expect((e as KiteError).status).toBeLessThan(500);
  return e as KiteError;
}

test('普通文件夹登记后成为 git 仓库、commits 为 kite：没有 .gitignore 时写入 kite-onboard 的模板，已有的不改，初始提交只含未被忽略的文件', async () => {
  const { root, home, store } = kite();
  const plain = newDir(root, 'plain', {
    '正文.md': '# 正文\n',
    'sub/b.txt': 'b\n',
    '图.svg': '<svg/>\n',
    '.env.example': 'KEY=\n',
    'doc.pdf': '%PDF-fake',
    'IMG.PNG': 'png-fake',
    '.env': 'SECRET=1\n',
    'node_modules/pkg/index.js': '1\n',
  });
  const p = await register(store, home, plain);
  expect(p.commits).toBe('kite');
  expect(p.path).toBe(plain);
  expect(git(plain, 'rev-parse', '--show-toplevel')).toBe(plain);
  expect(read(join(plain, '.gitignore'))).toBe(template);
  expect(lsHead(plain)).toEqual(['.env.example', '.gitignore', 'sub/b.txt', '图.svg', '正文.md'].sort());
  expect(git(plain, 'status', '--porcelain', '--untracked-files=all')).toBe('');
  expect(read(join(plain, 'IMG.PNG'))).toBe('png-fake');

  const own = '*.log\n# 我自己的规则\n';
  const hasIgnore = newDir(root, 'has-ignore', { '.gitignore': own, 'x.txt': 'x\n', 'a.log': 'log\n', 'doc.pdf': '%PDF' });
  const q = await register(store, home, hasIgnore);
  expect(q.commits).toBe('kite');
  expect(read(join(hasIgnore, '.gitignore'))).toBe(own);
  expect(lsHead(hasIgnore)).toEqual(['.gitignore', 'doc.pdf', 'x.txt']);
});

test('有提交的仓库登记后 commits 为 user、Kite 不写文件不提交；没有任何提交的仓库拒绝登记', async () => {
  const { root, home, store } = kite();
  const repo = newRepo(root, 'repo', { 'a.txt': 'a\n', 'doc.pdf': '%PDF' });
  writeFiles(repo, { 'a.txt': 'a changed\n', 'staged.txt': 's\n', 'untracked.txt': 'u\n' });
  git(repo, 'add', 'staged.txt');
  const before = { state: repoState(repo), refs: git(repo, 'for-each-ref'), tree: listTree(repo) };
  const p = await register(store, home, repo);
  expect(p.commits).toBe('user');
  expect(p.path).toBe(repo);
  expect({ state: repoState(repo), refs: git(repo, 'for-each-ref'), tree: listTree(repo) }).toEqual(before);

  const empty = newDir(root, 'empty-repo', { 'a.txt': 'a\n' });
  git(empty, 'init', '-q', '-b', 'main');
  const tree = listTree(empty);
  await rejected(register(store, home, empty));
  expect(gitOk(empty, 'rev-parse', '--verify', 'HEAD')).toBe(false);
  expect(listTree(empty)).toEqual(tree);
});

test('同一路径重复登记、经符号链接别名登记，都返回同一个项目', async () => {
  const { root, home, store } = kite();
  const dir = newDir(root, 'dup', { 'a.txt': 'a\n' });
  const p1 = await register(store, home, dir);
  const head = git(dir, 'rev-parse', 'HEAD');
  expect(await register(store, home, dir)).toEqual(p1);
  const alias = join(root, 'alias');
  symlinkSync(dir, alias);
  expect(await register(store, home, alias)).toEqual(p1);
  expect(git(dir, 'rev-parse', 'HEAD')).toBe(head);
  expect(store.projects()).toHaveLength(1);
});

test('拒绝登记：和已登记项目互相包含的路径、未登记仓库里的子文件夹、相对路径、不存在的路径、KITE_HOME 及其里面', async () => {
  const { root, home, store } = kite();
  // 已登记项目里的子文件夹
  const outer = newDir(root, 'outer', { 'sub/a.txt': 'a\n' });
  await register(store, home, outer);
  await rejected(register(store, home, join(outer, 'sub')));
  // 包含已登记项目的上层文件夹：拒绝，也不被初始化
  const parent = newDir(root, 'parent', { 'top.txt': 't\n', 'inner/a.txt': 'a\n' });
  await register(store, home, join(parent, 'inner'));
  await rejected(register(store, home, parent));
  expect(existsSync(join(parent, '.git'))).toBe(false);
  // 未登记的 git 仓库里的子文件夹
  const repo = newRepo(root, 'somerepo', { 'sub/a.txt': 'a\n' });
  await rejected(register(store, home, join(repo, 'sub')));
  expect(existsSync(join(repo, 'sub', '.git'))).toBe(false);
  // 相对路径、不存在的路径
  await rejected(register(store, home, 'some/relative'));
  await rejected(register(store, home, join(root, 'no-such-dir')));
  expect(existsSync(join(root, 'no-such-dir'))).toBe(false);
  // KITE_HOME 和它里面的文件夹
  await rejected(register(store, home, home));
  const inside = newDir(home, 'user-folder', { 'a.txt': 'a\n' });
  await rejected(register(store, home, inside));
  expect(existsSync(join(inside, '.git'))).toBe(false);

  expect(store.projects().map((p) => p.path).sort()).toEqual([outer, join(parent, 'inner')].sort());
});

test('项目 id 由文件夹名生成，只含 ASCII，中文名和同名文件夹也互不重复', async () => {
  const { root, home, store } = kite();
  // 用已有仓库登记：id 的生成和是不是 Kite 初始化的无关，省掉初始化的时间
  const alpha = await register(store, home, newRepo(root, 'alpha', { 'a.txt': 'a\n' }));
  expect(alpha.id.toLowerCase()).toContain('alpha');
  const dirs = [
    newRepo(join(root, '1'), 'same', { 'a.txt': '1\n' }),
    newRepo(join(root, '2'), 'same', { 'a.txt': '2\n' }),
    newRepo(join(root, '3'), '论文', { 'a.txt': '3\n' }),
    newRepo(join(root, '4'), '报告', { 'a.txt': '4\n' }),
  ];
  const ids = [alpha.id];
  for (const d of dirs) ids.push((await register(store, home, d)).id);
  for (const id of ids) expect(id).toMatch(/^[\x20-\x7e]+$/);
  expect(new Set(ids).size).toBe(ids.length);
});
