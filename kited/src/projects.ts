/**
 * 登记项目。每个项目都是标准 git 仓库：已有仓库直接用，提交归用户；
 * 普通文件夹由 Kite git init、写入 .gitignore 模板并提交初始版本，此后提交由 Kite 代做。
 * 放在 iCloud、Dropbox 这类同步目录里的，仓库本体放到 Kite 目录，文件夹里只留 .git 指针文件。
 */
import { existsSync, realpathSync, statSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { basename, join, relative, isAbsolute } from 'node:path';
import { KiteError } from './errors.ts';
import { commitIdentity, git, gitTry, revParse } from './git.ts';
import type { CommitOwner, Project, Store } from './store.ts';
// 模板只有一份，在项目规范（kite-onboard skill）里。文本 import：模板一改，依赖图就会选中登记相关的测试
import GITIGNORE_TEMPLATE from '../../.claude/skills/kite-onboard/templates/gitignore' with { type: 'text' };

/** a 在 b 里面，或就是 b。 */
export function within(a: string, b: string): boolean {
  const r = relative(b, a);
  return r === '' || (!r.startsWith('..') && !isAbsolute(r));
}

/** 同步目录。iCloud「桌面与文稿」的判断方式未核实。 */
function isSynced(path: string): boolean {
  const h = homedir();
  const roots = [join(h, 'Library', 'Mobile Documents'), join(h, 'Library', 'CloudStorage'), join(h, 'Dropbox')];
  for (const d of ['Desktop', 'Documents']) {
    if (existsSync(join(h, 'Library', 'Mobile Documents', 'com~apple~CloudDocs', d))) roots.push(join(h, d));
  }
  return roots.some((r) => within(path, r));
}

function uniqueId(store: Store, name: string): string {
  const base = name.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 40) || 'project';
  let id = base;
  for (let n = 2; store.project(id); n++) id = `${base}-${n}`;
  return id;
}

export async function register(store: Store, home: string, rawPath: string): Promise<Project> {
  if (!isAbsolute(rawPath)) throw new KiteError('路径要写绝对路径');
  let path: string;
  try { path = realpathSync(rawPath); } catch { throw new KiteError(`找不到文件夹：${rawPath}`, 404); }
  if (!statSync(path).isDirectory()) throw new KiteError(`不是文件夹：${path}`);

  const projects = store.projects();
  const same = projects.find((p) => p.path === path);
  if (same) return same;
  const overlap = projects.find((p) => within(path, p.path) || within(p.path, path));
  if (overlap) throw new KiteError(`和已登记的项目 ${overlap.id}（${overlap.path}）重叠`, 409);
  if (within(path, home) || within(home, path)) throw new KiteError('不能登记 Kite 自己的目录');

  const id = uniqueId(store, basename(path));
  const top = await gitTry(path, ['rev-parse', '--show-toplevel']);
  let commits: CommitOwner;
  if (top.code === 0) {
    const root = realpathSync(top.stdout.trim());
    if (root !== path) throw new KiteError(`这个文件夹在仓库 ${root} 里面，请登记仓库根目录`);
    if (!(await revParse(path, 'HEAD'))) throw new KiteError('仓库还没有任何提交，先提交一次再登记');
    commits = 'user';
  } else {
    await initFolder(path, home, id);
    commits = 'kite';
  }
  const project: Project = { id, path, commits, createdAt: Date.now() };
  store.addProject(project);
  return project;
}

async function initFolder(path: string, home: string, id: string): Promise<void> {
  const separate = isSynced(path) ? [`--separate-git-dir=${join(home, 'repos', `${id}.git`)}`] : [];
  await git(path, ['init', '-q', '-b', 'main', ...separate, path]);
  const ignore = join(path, '.gitignore');
  if (!existsSync(ignore)) writeFileSync(ignore, GITIGNORE_TEMPLATE);
  await git(path, ['add', '-A']);
  await git(path, ['commit', '-q', '--allow-empty', '-m', 'Kite：初始版本'], { env: await commitIdentity(path) });
  // 首次提交时每个文件一个松散对象，立刻打包，否则对象库会膨胀
  await git(path, ['repack', '-adq']);
}
