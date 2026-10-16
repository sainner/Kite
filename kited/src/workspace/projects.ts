/**
 * 登记项目在本机的检出。项目 ID 由项目登记表（account-data/registry.ts）分配。
 * 已有 origin 的仓库按 origin 登记，同一远程总是同一个项目；普通文件夹或没有 origin 的仓库登记成没有远程的项目，
 * 普通文件夹由 Kite 补齐 git 与初始版本。没有远程的项目在别的工作机上从这台的检出 clone（peer-git.ts）。
 * 现场的提交始终归用户，Kite 不代为提交。放在 iCloud、Dropbox 这类同步目录里的，仓库本体放到 Kite 目录，文件夹里只留 .git 指针文件。
 */
import { existsSync, mkdirSync, readdirSync, realpathSync, statSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { basename, dirname, join, isAbsolute } from 'node:path';
import { KiteError } from '../errors.ts';
import { commitAll, git, gitTry, revParse } from './git.ts';
import { defaultCheckoutPath, defaultClonePath, within } from '../paths.ts';
import { normalizeRemote } from '../remote-url.ts';
import { clone, originURL } from './remote.ts';
import type { Peer } from '../peer-fetch.ts';
import { clonePeer, type PeerRoute } from './peer-git.ts';
import type { GitCredentials } from '../git-credential.ts';
import type { ProjectRegistry, RegisteredProject } from '../account-data/registry.ts';
import type { Store } from '../store.ts';
import type { Project, Checkout, Workspace, WorkspaceModel } from '../model.ts';
import { randomUUID } from 'node:crypto';
// 模板只有一份，在项目规范（kite-onboard skill）里。文本 import：模板一改，依赖图就会选中登记相关的测试
import GITIGNORE_TEMPLATE from '../../../.claude/skills/kite-onboard/templates/gitignore' with { type: 'text' };
import GITATTRIBUTES_TEMPLATE from '../../../.claude/skills/kite-onboard/templates/gitattributes' with { type: 'text' };

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

/** 新检出不能和已登记的检出、正在 clone 的目录或 Kite 自己的目录重叠；重叠时给出原因。 */
function overlap(store: Store, home: string, path: string, cloning: Iterable<string> = []): KiteError | undefined {
  const checkout = store.checkouts().find((p) => within(path, p.path) || within(p.path, path));
  if (checkout) return new KiteError(`和已登记的检出 ${checkout.id}（${checkout.path}）重叠`, 409);
  for (const p of cloning) if (within(path, p) || within(p, path)) return new KiteError(`和正在 clone 的 ${p} 重叠`, 409);
  if (within(path, home) || within(home, path)) return new KiteError('不能登记 Kite 自己的目录');
  return undefined;
}

function assertFree(store: Store, home: string, path: string, cloning: Iterable<string> = []): void {
  const error = overlap(store, home, path, cloning);
  if (error) throw error;
}

/** 位置上已有内容：是文件，或者是非空的文件夹。 */
const occupied = (path: string) => existsSync(path) && (!statSync(path).isDirectory() || readdirSync(path).length > 0);

export const projectOf = (r: RegisteredProject): Project => ({ id: r.id, name: r.name, remote: r.remote, createdAt: r.createdAt });

/** 登记项目与访问远程要用的：项目登记表、Git 凭据，以及没有远程的项目可以从哪几台工作机拉取。 */
export interface ProjectAccess {
  registry: ProjectRegistry;
  git: GitCredentials;
  peers(projectId: string): { route: PeerRoute; peers: Peer[] };
}

/** cloned 是刚 clone 出这个目录时登记得到的项目，不再重复登记与探测远程。 */
export async function register(store: Store, home: string, projects: ProjectAccess, rawPath: string,
  options: { cloned?: RegisteredProject; cloning?: Iterable<string> } = {}): Promise<WorkspaceModel> {
  const path = realDirectory(rawPath);
  const same = store.checkouts().find((p) => p.path === path);
  if (same) return store.rootWorkspaceModel(same.id)!;
  assertFree(store, home, path, options.cloning);

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
  if (options.cloned) registered = options.cloned;
  else if (origin) {
    if (!normalizeRemote(origin)) throw new KiteError(`无法识别 origin 的地址：${origin}，请使用 GitHub、GitLab 等平台的仓库地址`);
    registered = projects.registry.register(origin);
  } else registered = projects.registry.createLocal(basename(path).trim() || '未命名项目');

  const project = projectOf(registered);
  // 首次登记先取得已有的约束；已有项目的缓存由资源库同步持续更新。
  const constraints = store.projectConstraints(project.id) ?? projects.registry.constraints(project.id);
  const checkout: Checkout = { id: checkoutId, projectId: project.id, machineId: store.machine.id, path,
    remote: project.remote, createdAt: Date.now() };
  const workspace: Workspace = { id: randomUUID(), epoch: 1, checkoutId: checkout.id, name: basename(path), cwd: path,
    kind: 'root', branch: null, base: null, status: 'open', createdAt: checkout.createdAt };
  store.transaction(() => {
    store.register(project, checkout, workspace);
    store.saveProjectConstraints(project.id, constraints);
  });
  return store.workspaceModel(workspace.id)!;
}

/**
 * clone 的目标位置：有远程的默认 ~/code/<域名>/<owner>/<repo>，没有远程的默认 ~/code/<项目名>。目标可以不存在或为空，
 * 其他情况拒绝，避免覆盖用户文件。只做本地检查，在登记锁内调用；clone 本身较慢，由调用方放在锁外。
 */
export function cloneTarget(store: Store, home: string, source: { remote: string } | { id: string; name: string }, rawPath: string | undefined,
  cloning: Iterable<string>): string {
  let dest = rawPath;
  if ('remote' in source) {
    const normalized = normalizeRemote(source.remote);
    if (!normalized) throw new KiteError('远程地址格式无法识别');
    dest ??= defaultClonePath(normalized);
  } else if (!dest) {
    // 没有远程的项目按名字放，同名的几个会抢同一个位置：已被占用时名字后加项目 ID 的前 8 位。
    const plain = defaultCheckoutPath({ remote: null, name: source.name });
    dest = occupied(plain) || overlap(store, home, plain, cloning) ? `${plain}-${source.id.slice(0, 8)}` : plain;
  }
  if (!isAbsolute(dest)) throw new KiteError('路径要写绝对路径');
  if (occupied(dest)) throw new KiteError(`目标位置已有内容：${dest}`, 409);
  mkdirSync(dirname(dest), { recursive: true });
  const real = existsSync(dest) ? realpathSync(dest) : join(realpathSync(dirname(dest)), basename(dest));
  assertFree(store, home, real, cloning);
  return real;
}

/** 先登记再 clone：远程地址无效时不留下半成品目录。返回的项目交给 register。 */
export async function cloneRemote(projects: ProjectAccess, remote: string, dest: string): Promise<RegisteredProject> {
  const registered = projects.registry.register(remote);
  await clone(remote, dest, projects.git);
  return registered;
}

/** 没有远程的项目从别的工作机的检出 clone，依次试在线的几台。返回的项目交给 register。 */
export async function clonePeerProject(projects: ProjectAccess, projectId: string, dest: string): Promise<RegisteredProject> {
  const project = projects.registry.require(projectId);
  if (project.remote) throw new KiteError('这个项目有远程，从远程 clone', 409);
  const { route, peers } = projects.peers(projectId);
  if (!peers.length) throw new KiteError('这个项目没有远程，有它检出的工作机都不在线', 409);
  let failure: unknown;
  for (const peer of peers) {
    try { await clonePeer(peer, projectId, dest, route); return project; }
    catch (error) { failure = error; }
  }
  throw failure;
}

async function initFolder(path: string, home: string, id: string): Promise<void> {
  const synced = isSynced(path);
  const repos = join(home, 'repos');
  if (synced) mkdirSync(repos, { recursive: true });
  const separate = synced ? [`--separate-git-dir=${join(repos, `${id}.git`)}`] : [];
  await git(path, ['init', '-q', '-b', 'main', ...separate, path]);
  for (const [name, template] of [['.gitignore', GITIGNORE_TEMPLATE], ['.gitattributes', GITATTRIBUTES_TEMPLATE]] as const) {
    const file = join(path, name);
    if (!existsSync(file)) writeFileSync(file, template);
  }
  await commitAll(path, ['--allow-empty', '-m', 'Kite：初始版本']);
  // 首次提交时每个文件一个松散对象，立刻打包，否则对象库会膨胀
  await git(path, ['repack', '-adq']);
}
