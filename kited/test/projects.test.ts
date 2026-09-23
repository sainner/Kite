/**
 * 登记项目：需求 1–4。
 */
import { describe, expect, setDefaultTimeout, test } from 'bun:test';
import { existsSync, mkdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { git, gitOk, listTree, newDir, newRepo, read, register, useKited, writeFiles } from './util.ts';

setDefaultTimeout(60_000);

const DOC = join(import.meta.dir, '..', '..', 'docs', '项目规范.md');
const TEMPLATE = join(import.meta.dir, '..', 'templates', 'gitignore');

/** 文档里 ```gitignore 代码块的内容（不含围栏），按文件的形态补上末尾换行。 */
function docGitignore(): string {
  const m = /```gitignore\n([\s\S]*?)\n```/.exec(readFileSync(DOC, 'utf8'));
  if (!m) throw new Error('项目规范.md 里没有 ```gitignore 代码块');
  return m[1]! + '\n';
}

const lsHead = (dir: string) => git(dir, 'ls-tree', '-r', '--name-only', 'HEAD').split('\n').filter(Boolean).sort();

describe('gitignore 模板', () => {
  test('templates/gitignore 与项目规范文档里的模板完全一致', () => {
    expect(read(TEMPLATE)).toBe(docGitignore());
  });
});

describe('需求 1：普通文件夹登记', () => {
  const kited = useKited();

  test('普通文件夹成为标准 git 仓库，commits 为 kite，写入模板 .gitignore，初始提交只含未被忽略的文件', async () => {
    const k = kited();
    const dir = newDir(k, 'plain', {
      '正文.md': '# 正文\n',
      'sub/b.txt': 'b\n',
      '图.svg': '<svg/>\n',
      '.env.example': 'KEY=\n',
      // 被模板忽略的
      'doc.pdf': '%PDF-fake',
      'IMG.PNG': 'png-fake',
      'photo.jpg': 'jpg-fake',
      '.env': 'SECRET=1\n',
      '.DS_Store': 'x',
      'node_modules/pkg/index.js': 'module.exports = 1;\n',
      'big.zip': 'zip-fake',
    });
    expect(existsSync(join(dir, '.git'))).toBe(false);

    const p = await register(k, dir);
    expect(p.commits).toBe('kite');
    expect(p.path).toBe(dir);
    expect(typeof p.id).toBe('string');
    expect(typeof p.createdAt).toBe('number');

    // 标准 git 仓库：工作区根就是这个文件夹，不是裸库，HEAD 在分支上且有提交
    expect(git(dir, 'rev-parse', '--show-toplevel')).toBe(dir);
    expect(git(dir, 'rev-parse', '--is-bare-repository')).toBe('false');
    expect(gitOk(dir, 'symbolic-ref', '-q', 'HEAD')).toBe(true);
    expect(gitOk(dir, 'rev-parse', '--verify', 'HEAD^{commit}')).toBe(true);

    // .gitignore 与文档模板完全一致
    expect(read(join(dir, '.gitignore'))).toBe(docGitignore());

    // 初始提交：所有未被忽略的文件（含 .gitignore 本身），不含被忽略的大文件、密钥、依赖
    expect(lsHead(dir)).toEqual(['.env.example', '.gitignore', 'sub/b.txt', '图.svg', '正文.md'].sort());
    // 什么都没漏：工作区干净
    expect(git(dir, 'status', '--porcelain')).toBe('');
    // 被忽略的文件原样留在磁盘上
    expect(read(join(dir, 'IMG.PNG'))).toBe('png-fake');
    expect(read(join(dir, '.env'))).toBe('SECRET=1\n');
  });

  test('已有 .gitignore 时不改它，初始提交按它来', async () => {
    const k = kited();
    const own = '*.log\n# 我自己的规则\n';
    const dir = newDir(k, 'has-ignore', {
      '.gitignore': own,
      'x.txt': 'x\n',
      'a.log': 'log\n',
      'doc.pdf': '%PDF-fake',
    });
    const p = await register(k, dir);
    expect(p.commits).toBe('kite');
    expect(read(join(dir, '.gitignore'))).toBe(own);
    // 原 .gitignore 没忽略 pdf，所以 pdf 进提交；a.log 被忽略
    expect(lsHead(dir)).toEqual(['.gitignore', 'doc.pdf', 'x.txt']);
    expect(git(dir, 'status', '--porcelain')).toBe('');
  });
});

describe('需求 2：已有 git 仓库登记', () => {
  const kited = useKited();

  test('有提交的仓库：commits 为 user，Kite 不写文件、不提交', async () => {
    const k = kited();
    const dir = newRepo(k, 'repo', { 'a.txt': 'a\n', 'doc.pdf': '%PDF' });
    // 用户自己的未提交状态：改了一个已跟踪文件，暂存了一个新文件，还有未跟踪文件
    writeFiles(dir, { 'a.txt': 'a changed\n', 'staged.txt': 's\n', 'untracked.txt': 'u\n' });
    git(dir, 'add', 'staged.txt');

    const before = {
      head: git(dir, 'rev-parse', 'HEAD'),
      refs: git(dir, 'for-each-ref'),
      status: git(dir, 'status', '--porcelain'),
      cached: git(dir, 'diff', '--cached'),
      tree: listTree(dir),
    };
    const p = await register(k, dir);
    expect(p.commits).toBe('user');
    expect(p.path).toBe(dir);

    expect(git(dir, 'rev-parse', 'HEAD')).toBe(before.head);
    expect(git(dir, 'for-each-ref')).toBe(before.refs);
    expect(git(dir, 'status', '--porcelain')).toBe(before.status);
    expect(git(dir, 'diff', '--cached')).toBe(before.cached);
    expect(listTree(dir)).toEqual(before.tree);
    expect(existsSync(join(dir, '.gitignore'))).toBe(false);
  });

  test('没有任何提交的仓库拒绝登记', async () => {
    const k = kited();
    const dir = newDir(k, 'empty-repo', { 'a.txt': 'a\n' });
    git(dir, 'init', '-q', '-b', 'main');
    const before = listTree(dir);

    const r = await k.call('POST', '/projects', { path: dir });
    expect(r.status).toBeGreaterThanOrEqual(400);
    expect(r.status).toBeLessThan(500);
    expect(typeof r.body.error).toBe('string');

    expect(gitOk(dir, 'rev-parse', '--verify', 'HEAD')).toBe(false);
    expect(listTree(dir)).toEqual(before);
    const list = await k.call('GET', '/projects');
    expect(list.body.some((x: any) => x.path === dir)).toBe(false);
  });
});

describe('需求 3：路径校验', () => {
  const kited = useKited();

  const expect4xx = (r: { status: number; body: any }) => {
    expect(r.status).toBeGreaterThanOrEqual(400);
    expect(r.status).toBeLessThan(500);
    expect(typeof r.body.error).toBe('string');
  };

  test('同一路径重复登记返回同一个项目，列表里只有一个', async () => {
    const k = kited();
    const dir = newDir(k, 'dup', { 'a.txt': 'a\n' });
    const p1 = await register(k, dir);
    const head = git(dir, 'rev-parse', 'HEAD');
    const p2 = await register(k, dir);
    expect(p2).toEqual(p1);
    // 第二次登记不再动仓库
    expect(git(dir, 'rev-parse', 'HEAD')).toBe(head);
    const list = (await k.call('GET', '/projects')).body as any[];
    expect(list.filter((x) => x.path === dir)).toHaveLength(1);
  });

  test('带末尾斜杠的同一路径也返回同一个项目', async () => {
    const k = kited();
    const dir = newDir(k, 'dup-slash', { 'a.txt': 'a\n' });
    const p1 = await register(k, dir);
    const r = await k.call('POST', '/projects', { path: dir + '/' });
    expect(r.status).toBe(200);
    expect(r.body.id).toBe(p1.id);
  });

  test('已登记项目里的子文件夹拒绝（409）', async () => {
    const k = kited();
    const dir = newDir(k, 'outer', { 'sub/a.txt': 'a\n' });
    await register(k, dir);
    const r = await k.call('POST', '/projects', { path: join(dir, 'sub') });
    expect(r.status).toBe(409);
    expect(typeof r.body.error).toBe('string');
  });

  test('包含已登记项目的上层文件夹拒绝（409），且不被初始化', async () => {
    const k = kited();
    const parent = newDir(k, 'parent', { 'top.txt': 't\n' });
    const inner = join(parent, 'inner');
    mkdirSync(inner);
    writeFiles(inner, { 'a.txt': 'a\n' });
    await register(k, inner);
    const r = await k.call('POST', '/projects', { path: parent });
    expect(r.status).toBe(409);
    expect(typeof r.body.error).toBe('string');
    expect(existsSync(join(parent, '.git'))).toBe(false);
    expect(existsSync(join(parent, '.gitignore'))).toBe(false);
  });

  test('未登记的 git 仓库里的子文件夹拒绝', async () => {
    const k = kited();
    const repo = newRepo(k, 'somerepo', { 'sub/a.txt': 'a\n' });
    const r = await k.call('POST', '/projects', { path: join(repo, 'sub') });
    expect4xx(r);
    expect(existsSync(join(repo, 'sub', '.git'))).toBe(false);
    expect(existsSync(join(repo, 'sub', '.gitignore'))).toBe(false);
  });

  test('相对路径拒绝', async () => {
    const k = kited();
    expect4xx(await k.call('POST', '/projects', { path: 'some/relative' }));
    expect4xx(await k.call('POST', '/projects', { path: './x' }));
  });

  test('不存在的路径拒绝', async () => {
    const k = kited();
    expect4xx(await k.call('POST', '/projects', { path: join(k.root, 'no-such-dir') }));
    expect(existsSync(join(k.root, 'no-such-dir'))).toBe(false);
  });

  test('KITE_HOME 目录拒绝', async () => {
    const k = kited();
    const home = k.env.KITE_HOME!;
    expect4xx(await k.call('POST', '/projects', { path: home }));
    expect(existsSync(join(home, '.gitignore'))).toBe(false);
  });

  test('KITE_HOME 里面的文件夹拒绝', async () => {
    const k = kited();
    const inside = join(k.env.KITE_HOME!, 'user-folder');
    mkdirSync(inside);
    writeFiles(inside, { 'a.txt': 'a\n' });
    expect4xx(await k.call('POST', '/projects', { path: inside }));
    expect(existsSync(join(inside, '.git'))).toBe(false);
  });
});

describe('需求 4：项目 id', () => {
  const kited = useKited();
  const ascii = /^[\x20-\x7e]+$/;

  test('id 由文件夹名生成', async () => {
    const k = kited();
    const p = await register(k, newDir(k, 'alpha', { 'a.txt': 'a\n' }));
    expect(p.id.toLowerCase()).toContain('alpha');
  });

  test('中文文件夹名的 id 只含 ASCII', async () => {
    const k = kited();
    const p = await register(k, newDir(k, '论文项目', { 'a.txt': 'a\n' }));
    expect(p.id).toMatch(ascii);
    // id 能直接用在接口路径里
    const r = await k.call('GET', `/sessions?project=${encodeURIComponent(p.id)}`);
    expect(r.status).toBe(200);
  });

  test('同名文件夹、以及都转成 ASCII 后可能撞车的文件夹，id 互不相同', async () => {
    const k = kited();
    const dirs = [
      newDir(k, 'same', { 'a.txt': '1\n' }),
      newDir(k, 'same', { 'a.txt': '2\n' }),
      newDir(k, 'Same', { 'a.txt': '3\n' }),
      newDir(k, '论文', { 'a.txt': '4\n' }),
      newDir(k, '报告', { 'a.txt': '5\n' }),
      newDir(k, '报告', { 'a.txt': '6\n' }),
    ];
    const ps = [];
    for (const d of dirs) ps.push(await register(k, d));
    for (const p of ps) expect(p.id).toMatch(ascii);
    expect(new Set(ps.map((p) => p.id)).size).toBe(dirs.length);
    // 列表里每个 id 对应各自的路径
    const list = (await k.call('GET', '/projects')).body as any[];
    for (const p of ps) expect(list.find((x) => x.id === p.id)?.path).toBe(p.path);
  });
});
