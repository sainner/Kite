/**
 * 登记项目在本机的检出。项目以远程为身份，项目 ID 由账号服务的登记表分配。
 * 已有 origin 的仓库按 origin 登记；普通文件夹或没有 origin 的仓库，由 Kite 补齐 git 与初始版本，
 * 在托管服务建远程并推送。现场的提交始终归用户，Kite 不代为提交。
 * 放在 iCloud、Dropbox 这类同步目录里的，仓库本体放到 Kite 目录，文件夹里只留 .git 指针文件。
 */
import { existsSync, mkdirSync, readdirSync, realpathSync, statSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { basename, dirname, join, isAbsolute } from 'node:path';
import { KiteError } from '../errors.ts';
import { commitAll, git, gitTry, revParse } from './git.ts';
import { within } from '../paths.ts';
import { normalizeRemote } from '../remote-url.ts';
import { clone, originURL, seedRemote } from './remote.ts';
import type { AccountClient, RegisteredProject } from '../account-client.ts';
import type { Store } from '../store.ts';
import type { Project, Checkout, Workspace, WorkspaceModel } from '../model.ts';
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

function realDirectory(rawPath: string): string {
  if (!isAbsolute(rawPath)) throw new KiteError('路径要写绝对路径');
  let path: string;
  try { path = realpathSync(rawPath); } catch { throw new KiteError(`找不到文件夹：${rawPath}`, 404); }
  if (!statSync(path).isDirectory()) throw new KiteError(`不是文件夹：${path}`);
  return path;
}

/** 新检出不能和已登记的检出或 Kite 自己的目录重叠。 */
function assertFree(store: Store, home: string, path: string): void {
  const overlap = store.checkouts().find((p) => within(path, p.path) || within(p.path, path));
  if (overlap) throw new KiteError(`和已登记的检出 ${overlap.id}（${overlap.path}）重叠`, 409);
  if (within(path, home) || within(home, path)) throw new KiteError('不能登记 Kite 自己的目录');
}

const projectOf = (r: RegisteredProject): Project => ({ id: r.id, name: r.name, remote: r.remote, createdAt: r.createdAt });

export async function register(store: Store, home: string, account: AccountClient, rawPath: string): Promise<WorkspaceModel> {
  const path = realDirectory(rawPath);
  const same = store.checkouts().find((p) => p.path === path);
  if (same) return store.rootWorkspaceModel(same.id)!;
  assertFree(store, home, path);
  if (!account.linked) throw new KiteError('这台工作机还没有加入 Kite 账号，请先在 App 中登录', 409);

  const checkoutId = randomUUID();
  const top = await gitTry(path, ['rev-parse', '--show-toplevel']);
  let origin: string | null = null;
  if (top.code === 0) {
    const root = realpathSync(top.stdout.trim());
    if (root !== path) throw new KiteError(`这个文件夹在仓库 ${root} 里面，请登记仓库根目录`);
    if (!(await revParse(path, 'HEAD'))) throw new KiteError('仓库还没有任何提交，先提交一次再登记');
    origin = await originURL(path);
  } else {
    // 同一项目可以有多个检出，独立 Git 目录按检出 ID 命名。
    await initFolder(path, home, checkoutId);
  }
  let registered: RegisteredProject;
  if (origin) {
    if (!normalizeRemote(origin)) throw new KiteError(`无法识别 origin 的地址：${origin}，请使用 GitHub、GitLab 等平台的仓库地址`);
    registered = await account.register(origin);
  } else {
    registered = await account.createHosted(basename(path).trim() || '未命名项目');
    await git(path, ['remote', 'add', 'origin', registered.url]);
  }
  // 托管远程由 Kite 创建，初始内容来自第一份检出；上次推送失败后重试时，origin 已指向托管地址，在这里补推。
  if (registered.hosted) await seedRemote(path, account);

  const project = projectOf(registered);
  const checkout: Checkout = { id: checkoutId, projectId: project.id, machineId: store.machine.id, path,
    remote: project.remote, createdAt: Date.now() };
  const workspace: Workspace = { id: randomUUID(), checkoutId: checkout.id, name: basename(path), cwd: path,
    kind: 'root', branch: null, base: null, status: 'open', createdAt: checkout.createdAt };
  store.register(project, checkout, workspace);
  return store.workspaceModel(workspace.id)!;
}

/** 远程在本机的默认位置：~/code/<域名>/<owner>/<repo>。 */
export function defaultClonePath(remote: string): string {
  const normalized = normalizeRemote(remote);
  if (!normalized) throw new KiteError('远程地址格式无法识别');
  return join(homedir(), 'code', ...normalized.split('/'));
}

/** clone 远程并登记。目标目录可以不存在或为空，其他情况拒绝，避免覆盖用户文件。 */
export async function cloneCheckout(store: Store, home: string, account: AccountClient, remote: string, rawPath?: string): Promise<WorkspaceModel> {
  if (!normalizeRemote(remote)) throw new KiteError('远程地址格式无法识别');
  const dest = rawPath ?? defaultClonePath(remote);
  if (!isAbsolute(dest)) throw new KiteError('路径要写绝对路径');
  if (existsSync(dest) && (!statSync(dest).isDirectory() || readdirSync(dest).length)) {
    throw new KiteError(`目标位置已有内容：${dest}`, 409);
  }
  mkdirSync(dirname(dest), { recursive: true });
  assertFree(store, home, join(realpathSync(dirname(dest)), basename(dest)));
  // 先登记再 clone：远程地址无效或不属于本账号时，不留下半成品目录。
  await account.register(remote);
  await clone(remote, dest, account);
  return register(store, home, account, dest);
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
