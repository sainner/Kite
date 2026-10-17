/**
 * 添加本机文件夹导入成没有远程的项目（docs/项目与远程仓库.md「添加项目」「删除项目」，docs/kited.md 的 POST /project-registry）：
 * 检出是数据目录里 repos/<项目 ID>.git 的裸仓库，从文件夹导入分支与工作目录里的内容，用户自己的文件夹不写任何东西。
 * 几条真实 git 命令合起来的效果（临时索引加 --git-dir/--work-tree 指向文件夹做 add -A、从文件夹取全部分支）会不会写到
 * 文件夹的 .git 里，只有跑了才知道，所以对文件夹做逐字节的前后对照。模型用不到，不起 Claude Code。
 */
import { afterEach, expect, test } from 'bun:test';
import { createHash } from 'node:crypto';
import { existsSync, lstatSync, readdirSync, readFileSync, rmSync } from 'node:fs';
import { join } from 'node:path';
import GITATTRIBUTES_TEMPLATE from '../../../.claude/skills/kite-onboard/templates/gitattributes' with { type: 'text' };
import GITIGNORE_TEMPLATE from '../../../.claude/skills/kite-onboard/templates/gitignore' with { type: 'text' };
import type { RegisteredProject } from '../../src/account-data/registry.ts';
import type { WorkspaceModel } from '../../src/model.ts';
import { checkoutPath } from '../../src/paths.ts';
import { chatgptLogin, type Kited, startKited } from '../harness.ts';
import { commitAll, git, lexists, listTree, newDir, newRepo, repoState, writeFiles } from '../util.ts';

let kited: Kited | undefined;
afterEach(async () => {
  await kited?.stop();
  kited = undefined;
});

async function addProject(k: Kited, path: string): Promise<RegisteredProject> {
  const r = await k.call('POST', '/project-registry', { path });
  if (r.status !== 200) throw new Error(`添加 ${path} 失败：${r.status} ${JSON.stringify(r.body)}`);
  return r.body as RegisteredProject;
}

/**
 * 文件夹里每个文件与目录（含 .git）：文件记内容摘要，目录记为 dir。不含 .git/index：
 * 测试自己跑 git status 时 git 会顺手刷新索引里的文件时间戳，那不是 Kite 写的；索引里的内容由 repoState 对照。
 */
function folderBytes(dir: string): Record<string, string> {
  const out: Record<string, string> = {};
  for (const entry of readdirSync(dir, { recursive: true }) as string[]) {
    if (entry === '.git/index') continue;
    const path = join(dir, entry);
    const st = lstatSync(path);
    out[entry] = st.isDirectory() ? 'dir' : createHash('sha256').update(readFileSync(path)).digest('hex');
  }
  return out;
}

const branches = (repo: string) => git(repo, 'for-each-ref', '--format=%(refname) %(objectname)', 'refs/heads').split('\n').sort();
const files = (repo: string, ref: string) => git(repo, 'ls-tree', '-r', '--name-only', ref).split('\n').sort();

/*
 * 几条 git 命令合起来的效果：从文件夹仓库取全部分支，再用临时索引把工作目录（含未跟踪、不含被忽略、删掉的文件也算）
 * 提交成主线上的一个新提交；暂存区与工作目录不同的文件取工作目录的内容。文件夹的 git status、HEAD、引用、对象目录
 * 和工作目录逐字节不变。删除项目时检出与 worktrees/<项目> 一起删掉，文件夹仍然不变。
 */
test('导入没有远程的仓库文件夹：检出有全部分支、主线多一个装着工作目录改动的提交，删除项目后检出与工作树都删掉，文件夹前后逐字节不变', async () => {
  const k = kited = startKited();
  const folder = newRepo(k.root, 'notes', { 'a.txt': '一\n', 'gone.txt': '要删\n', '.gitignore': 'build/\n*.log\n' }, null);
  git(folder, 'switch', '-q', '-c', 'feature');
  writeFiles(folder, { 'f.txt': '分支上的\n' });
  commitAll(folder, '分支提交');
  git(folder, 'switch', '-q', 'main');
  writeFiles(folder, { 'a.txt': '二\n', 'new/b.txt': '未跟踪\n', 'staged.txt': '暂存的\n', 'build/out.js': '被忽略\n', 'debug.log': '被忽略\n' });
  git(folder, 'add', 'staged.txt');
  writeFiles(folder, { 'staged.txt': '工作目录里的\n' });
  rmSync(join(folder, 'gone.txt'));
  const head = git(folder, 'rev-parse', 'HEAD');
  const folderBranches = branches(folder);
  const status = repoState(folder);
  const bytes = folderBytes(folder);
  const unchanged = () => {
    expect(repoState(folder)).toBe(status);
    expect(folderBytes(folder)).toEqual(bytes);
  };

  const project = await addProject(k, folder);
  expect(project.remote).toBeNull();
  unchanged();

  const checkout = checkoutPath(k.home, project.id);
  const imported = git(checkout, 'rev-parse', 'refs/heads/main');
  expect(git(checkout, 'rev-parse', 'refs/heads/feature')).toBe(git(folder, 'rev-parse', 'feature'));
  expect(branches(checkout)).toEqual(folderBranches.map((line) => line.startsWith('refs/heads/main ') ? `refs/heads/main ${imported}` : line));
  expect(git(checkout, 'rev-list', '--parents', '-n', '1', imported)).toBe(`${imported} ${head}`);
  expect(files(checkout, imported)).toEqual(['.gitignore', 'a.txt', 'new/b.txt', 'staged.txt']);
  expect(git(checkout, 'show', `${imported}:a.txt`)).toBe('二');
  expect(git(checkout, 'show', `${imported}:staged.txt`)).toBe('工作目录里的');

  chatgptLogin(k.home);
  const created = await k.call('POST', '/workspaces', { project: project.id });
  expect(created.status).toBe(200);
  const workspace = (created.body as WorkspaceModel).workspace;
  await k.waitEvent((e) => e.type === 'workspace.changed' && e.workspaceId === workspace.id && e.status === 'open');
  const worktrees = join(k.home, 'worktrees', project.id);
  expect(existsSync(join(workspace.cwd, 'new', 'b.txt'))).toBe(true);
  expect(existsSync(worktrees)).toBe(true);

  expect(await k.call('DELETE', `/project-registry/${project.id}`)).toEqual({ status: 200, body: { ok: true } });
  expect(lexists(checkout)).toBe(false);
  expect(lexists(worktrees)).toBe(false);
  expect(((await k.call('GET', '/project-registry')).body as RegisteredProject[]).map((p) => p.id)).not.toContain(project.id);
  unchanged();
}, 1000);

/*
 * 几条 git 命令合起来的效果：不是仓库的文件夹按 Kite 的 .gitignore 与 .gitattributes 模板（文件夹里本来没有）提交进检出，
 * 模板忽略的文件（图片、node_modules、.env、.DS_Store）不进去；模板只进检出，文件夹里不出现 .git 与模板文件。
 */
test('导入不是仓库的文件夹：检出的初始版本带 Kite 的忽略与合并规则模板、被模板忽略的文件不进去，文件夹里不出现 .git 与模板文件', async () => {
  const k = kited = startKited();
  const folder = newDir(k.root, 'site', {
    'index.html': '<h1>站点</h1>\n', 'src/app.js': 'console.log(1)\n', 'photo.png': '假图片',
    'node_modules/left-pad/index.js': 'module.exports = 1\n', '.env': 'SECRET=1\n', '.DS_Store': '系统文件',
  });
  const before = listTree(folder);

  const project = await addProject(k, folder);
  expect(project.remote).toBeNull();
  const checkout = checkoutPath(k.home, project.id);
  expect(files(checkout, 'refs/heads/main')).toEqual(['.gitattributes', '.gitignore', 'index.html', 'src/app.js']);
  expect(git(checkout, 'show', 'refs/heads/main:.gitignore')).toBe(GITIGNORE_TEMPLATE.replace(/\n$/, ''));
  expect(git(checkout, 'show', 'refs/heads/main:.gitattributes')).toBe(GITATTRIBUTES_TEMPLATE.replace(/\n$/, ''));

  expect(listTree(folder)).toEqual(before);
  for (const name of ['.git', '.gitignore', '.gitattributes']) expect(lexists(join(folder, name))).toBe(false);
}, 1000);
