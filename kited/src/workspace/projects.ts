/**
 * 登记项目在本机的检出。已有仓库直接用，提交归用户；
 * 普通文件夹由 Kite git init、写入 .gitignore 模板并提交初始版本，此后提交由 Kite 代做。
 * 放在 iCloud、Dropbox 这类同步目录里的，仓库本体放到 Kite 目录，文件夹里只留 .git 指针文件。
 */
import { existsSync, mkdirSync, realpathSync, statSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { basename, join, isAbsolute } from 'node:path';
import { KiteError } from '../errors.ts';
import { commitAll, git, gitTry, revParse } from './git.ts';
import { within } from '../paths.ts';
import type { Store } from '../store.ts';
import type { CommitOwner, Project, Checkout, Workspace, WorkspaceModel } from '../model.ts';
import { randomUUID } from 'node:crypto';
// 模板只有一份，在项目规范（kite-onboard skill）里。文本 import：模板一改，依赖图就会选中登记相关的测试
import GITIGNORE_TEMPLATE from '../../../.claude/skills/kite-onboard/templates/gitignore' with { type: 'text' };

/** 同步目录。iCloud「桌面与文稿」的判断方式未核实。 */
function isSynced(path: string): boolean {
  const h = homedir();
  const roots = [join(h, 'Library', 'Mobile Documents'), join(h, 'Library', 'CloudStorage'), join(h, 'Dropbox')];
  for (const d of ['Desktop', 'Documents']) {
    if (existsSync(join(h, 'Library', 'Mobile Documents', 'com~apple~CloudDocs', d))) roots.push(join(h, d));
  }
  return roots.some((r) => within(path, r));
}

export async function register(store: Store, home: string, rawPath: string, identity?: Project): Promise<WorkspaceModel> {
  if (!isAbsolute(rawPath)) throw new KiteError('路径要写绝对路径');
  let path: string;
  try { path = realpathSync(rawPath); } catch { throw new KiteError(`找不到文件夹：${rawPath}`, 404); }
  if (!statSync(path).isDirectory()) throw new KiteError(`不是文件夹：${path}`);

  const known = identity && store.project(identity.id);
  if (identity && known && (known.name !== identity.name || known.createdAt !== identity.createdAt)) {
    throw new KiteError('这个项目 ID 已有不同的名称或创建时间，请使用已登记的项目身份', 409);
  }
  const checkouts = store.checkouts();
  const same = checkouts.find((p) => p.path === path);
  if (same) {
    if (identity && identity.id !== same.projectId) throw new KiteError('这个目录已属于另一个项目', 409);
    return store.rootWorkspaceModel(same.id)!;
  }
  const overlap = checkouts.find((p) => within(path, p.path) || within(p.path, path));
  if (overlap) throw new KiteError(`和已登记的检出 ${overlap.id}（${overlap.path}）重叠`, 409);
  if (within(path, home) || within(home, path)) throw new KiteError('不能登记 Kite 自己的目录');

  const project: Project = known || identity || { id: randomUUID(), name: basename(path).trim() || '未命名项目', createdAt: Date.now() };
  const checkoutId = randomUUID();
  const top = await gitTry(path, ['rev-parse', '--show-toplevel']);
  let commits: CommitOwner;
  if (top.code === 0) {
    const root = realpathSync(top.stdout.trim());
    if (root !== path) throw new KiteError(`这个文件夹在仓库 ${root} 里面，请登记仓库根目录`);
    if (!(await revParse(path, 'HEAD'))) throw new KiteError('仓库还没有任何提交，先提交一次再登记');
    commits = 'user';
  } else {
    // 同一项目可以有多个检出，独立 Git 目录按检出 ID 命名。
    await initFolder(path, home, checkoutId);
    commits = 'kite';
  }
  const checkout: Checkout = { id: checkoutId, projectId: project.id, machineId: store.machine.id, path, commits, createdAt: Date.now() };
  const workspace: Workspace = { id: randomUUID(), checkoutId: checkout.id, name: basename(path), cwd: path,
    kind: 'root', branch: null, base: null, status: 'open', createdAt: checkout.createdAt };
  store.register(project, checkout, workspace);
  return store.workspaceModel(workspace.id)!;
}

async function initFolder(path: string, home: string, id: string): Promise<void> {
  const synced = isSynced(path);
  const repos = join(home, 'repos');
  if (synced) mkdirSync(repos, { recursive: true });
  const separate = synced ? [`--separate-git-dir=${join(repos, `${id}.git`)}`] : [];
  await git(path, ['init', '-q', '-b', 'main', ...separate, path]);
  const ignore = join(path, '.gitignore');
  if (!existsSync(ignore)) writeFileSync(ignore, GITIGNORE_TEMPLATE);
  await commitAll(path, ['--allow-empty', '-m', 'Kite：初始版本']);
  // 首次提交时每个文件一个松散对象，立刻打包，否则对象库会膨胀
  await git(path, ['repack', '-adq']);
}
