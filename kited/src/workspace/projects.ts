/**
 * 项目在本机的检出：Kite 数据目录里的裸仓库（paths.ts 的 checkoutPath），用户自己的文件夹 Kite 不碰。
 * 有远程的项目在这台工作机第一次建工作区时从远程 clone；没有远程的项目从别的工作机的检出 clone（peer-git.ts），
 * 或在添加项目时从本机文件夹导入：只读文件夹，取它的分支与工作目录里的内容，不往里写任何东西。见 docs/项目与远程仓库.md。
 */
import { existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { basename, dirname, isAbsolute, join } from 'node:path';
import { KiteError } from '../errors.ts';
import { commitOnto, git, gitTry, revParse } from './git.ts';
import { WorkspaceFiles } from './files.ts';
import { currentBranch, originURL } from './remote.ts';
import type { Peer } from '../peer-fetch.ts';
import { clonePeer, type PeerRoute } from './peer-git.ts';
import type { RegisteredProject } from '../account-data/registry.ts';
import type { Project } from '../model.ts';
// 模板只有一份，在项目规范（kite-onboard skill）里。文本 import：模板一改，依赖图就会选中导入相关的测试
import GITIGNORE_TEMPLATE from '../../../.claude/skills/kite-onboard/templates/gitignore' with { type: 'text' };
import GITATTRIBUTES_TEMPLATE from '../../../.claude/skills/kite-onboard/templates/gitattributes' with { type: 'text' };

export const projectOf = (r: RegisteredProject): Project => ({ id: r.id, name: r.name, remote: r.remote, createdAt: r.createdAt });

/** 添加项目时选的本机文件夹：repository 表示是仓库根，origin 是它的 origin 地址（没有时为 null）。 */
export interface Folder { path: string; repository: boolean; origin: string | null }

/** 读文件夹：要写绝对路径、存在、是文件夹；在仓库里时必须是仓库根。 */
export async function inspectFolder(rawPath: string): Promise<Folder> {
  if (!isAbsolute(rawPath)) throw new KiteError('路径要写绝对路径');
  let path: string;
  try { path = realpathSync(rawPath); } catch { throw new KiteError(`找不到文件夹：${rawPath}`); }
  if (!statSync(path).isDirectory()) throw new KiteError(`不是文件夹：${path}`);
  const top = await gitTry(path, ['rev-parse', '--show-toplevel']);
  if (top.code !== 0) return { path, repository: false, origin: null };
  const root = realpathSync(top.stdout.trim());
  if (root !== path) throw new KiteError(`这个文件夹在仓库 ${root} 里面，请选仓库根目录`);
  return { path, repository: true, origin: await originURL(path) };
}

/** 不是仓库的文件夹借一个临时裸仓库按忽略规则列文件：模板放进它的 info/exclude，文件夹里已有 .gitignore 时以文件夹的为准。 */
async function withScratchRepository<T>(folder: string, action: (gitDir: string) => Promise<T>): Promise<T> {
  const scratch = mkdtempSync(join(tmpdir(), 'kite-import-'));
  try {
    await git('/', ['init', '-q', '--bare', scratch]);
    if (!existsSync(join(folder, '.gitignore'))) writeFileSync(join(scratch, 'info', 'exclude'), GITIGNORE_TEMPLATE);
    return await action(scratch);
  } finally { rmSync(scratch, { recursive: true, force: true }); }
}

const split = (text: string) => text.split('\0').filter(Boolean);

/**
 * 文件夹里被忽略的环境变量文件（任意层级的 .env、.env.*）的相对路径，依赖目录里的不算。
 * 不是仓库的文件夹按 Kite 的忽略模板判断。--directory 让 git 不进被忽略的目录（node_modules 这类），只列出目录名，再滤掉。
 */
export async function findEnvFiles(folder: Folder): Promise<string[]> {
  const args = ['ls-files', '-z', '--others', '--ignored', '--exclude-standard', '--directory', '--', ':(glob)**/.env', ':(glob)**/.env.*'];
  const listed = folder.repository ? split(await git(folder.path, args))
    : await withScratchRepository(folder.path, async (gitDir) => split(await git(folder.path, [`--git-dir=${gitDir}`, `--work-tree=${folder.path}`, ...args])));
  return listed.filter((path) => !path.endsWith('/') && !path.split('/').includes('node_modules')).sort();
}

/** 环境变量文件的内容，供存成项目密钥：按文件夹的边界读（不跟着链接或 .. 出去），不是文本时报错。 */
export const readEnvFile = (folder: Folder, path: string): string => new WorkspaceFiles(folder.path).text(path);

/**
 * 用 repo 的对象库在临时索引里写出一棵树：给了 folder 时按它的工作目录（从 base 的树开始，加上没被忽略的全部文件，含未跟踪的），
 * 再放进 extra 里的文件（相对路径 → 内容）。索引用完即删，文件夹本身不写任何东西。
 */
async function writeTree(repo: string, options: { folder?: string; base?: string | null; extra?: Record<string, string> }): Promise<string> {
  const scratch = mkdtempSync(join(tmpdir(), 'kite-index-'));
  try {
    const env = { GIT_INDEX_FILE: join(scratch, 'index') };
    const cwd = options.folder ?? repo;
    const at = options.folder ? [`--git-dir=${repo}`, `--work-tree=${options.folder}`] : [];
    if (options.base) await git(cwd, [...at, 'read-tree', options.base], { env });
    if (options.folder) await git(cwd, [...at, 'add', '-A'], { env });
    for (const [name, content] of Object.entries(options.extra ?? {})) {
      const blob = await git(cwd, [...at, 'hash-object', '-w', '--stdin'], { input: content });
      await git(cwd, [...at, 'update-index', '--add', '--cacheinfo', `100644,${blob},${name}`], { env });
    }
    return await git(cwd, [...at, 'write-tree'], { env });
  } finally { rmSync(scratch, { recursive: true, force: true }); }
}

/** 建检出 dest（裸仓库）：build 往里写内容，失败时不留下 dest；最后把新的松散对象打包，否则对象库会膨胀。 */
async function buildRepository(dest: string, build: () => Promise<void>): Promise<void> {
  if (existsSync(dest)) throw new KiteError(`检出位置已有内容：${dest}`, 409);
  mkdirSync(dirname(dest), { recursive: true });
  try {
    await build();
    await git(dest, ['repack', '-dq']);
  } catch (error) {
    rmSync(dest, { recursive: true, force: true });
    throw error;
  }
}

/**
 * 把没有远程的文件夹导入成检出 dest（裸仓库）。已有仓库的取全部分支，工作目录里未提交的改动另作一个提交放在主线上，
 * 仓库自己的 info/exclude 一并带上；不是仓库的按忽略模板把文件提交进去，模板只进检出，不写进文件夹。
 */
export function importFolder(folder: Folder, dest: string): Promise<void> {
  return buildRepository(dest, async () => {
    if (!folder.repository) {
      await git('/', ['init', '-q', '--bare', '-b', 'main', dest]);
      mkdirSync(join(dest, 'info'), { recursive: true });
      const templates = Object.fromEntries(([['.gitignore', GITIGNORE_TEMPLATE], ['.gitattributes', GITATTRIBUTES_TEMPLATE]] as const)
        .filter(([name]) => !existsSync(join(folder.path, name))));
      if (templates['.gitignore']) writeFileSync(join(dest, 'info', 'exclude'), GITIGNORE_TEMPLATE);
      const tree = await writeTree(dest, { folder: folder.path, extra: templates });
      // 模板已提交成 .gitignore，之后的工作树按它忽略。
      writeFileSync(join(dest, 'info', 'exclude'), '');
      await commitOnto(dest, 'main', tree, 'Kite：初始版本');
      return;
    }
    const branch = await currentBranch(folder.path);
    if (!branch) throw new KiteError('文件夹的仓库不在任何分支上，先切回主线分支再添加', 409);
    const head = await revParse(folder.path, 'HEAD');
    if (head) {
      const r = await gitTry('/', ['clone', '-q', '--bare', '--no-hardlinks', '--', folder.path, dest]);
      if (r.code !== 0) throw new KiteError(`导入仓库失败：${r.stderr.trim()}`, 409);
      await git(dest, ['remote', 'remove', 'origin']);
    } else await git('/', ['init', '-q', '--bare', '-b', branch, dest]);
    await git(dest, ['symbolic-ref', 'HEAD', `refs/heads/${branch}`]);
    mkdirSync(join(dest, 'info'), { recursive: true });
    const exclude = join(await git(folder.path, ['rev-parse', '--path-format=absolute', '--git-common-dir']), 'info', 'exclude');
    if (existsSync(exclude)) writeFileSync(join(dest, 'info', 'exclude'), readFileSync(exclude));
    const tree = await writeTree(dest, { folder: folder.path, base: head });
    if (!head || tree !== await git(dest, ['rev-parse', `${head}^{tree}`])) {
      await commitOnto(dest, branch, tree, head ? 'Kite：导入时工作目录里未提交的改动' : 'Kite：初始版本', head);
    }
  });
}

/** 新建只有一个初始版本的检出 dest（裸仓库，主线 main），files 是初始版本里的文件（相对路径 → 内容）。 */
export function createRepository(dest: string, files: Record<string, string>): Promise<void> {
  return buildRepository(dest, async () => {
    await git('/', ['init', '-q', '--bare', '-b', 'main', dest]);
    await commitOnto(dest, 'main', await writeTree(dest, { extra: files }), 'Kite：初始版本');
  });
}

/** 文件夹的显示名：没有远程的项目用它作项目名。 */
export const folderName = (folder: Folder) => basename(folder.path).trim() || '未命名项目';

/** 没有远程的项目从别的工作机的检出 clone，依次试在线的几台。 */
export async function clonePeers(peers: Peer[], route: PeerRoute, projectId: string, dest: string): Promise<void> {
  if (!peers.length) throw new KiteError('这个项目没有远程，有它检出的工作机都不在线', 409);
  let failure: unknown;
  for (const peer of peers) {
    try { await clonePeer(peer, projectId, dest, route); return; }
    catch (error) { failure = error; rmSync(dest, { recursive: true, force: true }); }
  }
  throw failure;
}
