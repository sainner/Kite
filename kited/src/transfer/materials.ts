/**
 * 工作区流转的恢复材料：项目远程 refs/kite/transfer/<工作区>/ 下的几个 ref。branch 是工作区分支头（根工作区没有），
 * snapshots 是快照链，worktree 是未提交改动打成的提交（以分支头为父，含未跟踪但未忽略的文件），records 是导出的记录树。
 * 源机推完即可下线；目标机接管后删除。
 */
import { mkdtempSync, readdirSync, rmSync, statSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { KiteError } from '../errors.ts';
import { KITE_IDENTITY, git, gitTry } from '../workspace/git.ts';
import type { RemoteAccess } from '../workspace/remote.ts';

export const materialNames = ['branch', 'snapshots', 'worktree', 'records'] as const;
export type MaterialName = (typeof materialNames)[number];
export type Materials = Partial<Record<MaterialName, string>>;

const prefix = (workspaceId: string) => `refs/kite/transfer/${workspaceId}/`;
export const transferRef = (workspaceId: string, name: MaterialName) => `${prefix(workspaceId)}${name}`;

const failure = (action: string, stderr: string) =>
  new KiteError(`${action}失败：${stderr.trim().split('\n').slice(-3).join('\n') || '未知错误'}`, 409);

function files(dir: string): string[] {
  return readdirSync(dir, { recursive: true, encoding: 'utf8' }).filter((path) => statSync(join(dir, path)).isFile()).sort();
}

/** 把目录里的文件原样提交成一棵树：逐个写对象，用临时索引组树，不经过忽略规则，也不碰仓库的工作树与索引。 */
export async function commitDirectory(repo: string, dir: string, message: string): Promise<string> {
  const paths = files(dir);
  const temp = mkdtempSync(join(tmpdir(), 'kite-records-'));
  try {
    const env = { GIT_INDEX_FILE: join(temp, 'index') };
    const blobs = paths.length ? (await git(repo, ['hash-object', '-w', '--stdin-paths'], { input: paths.map((path) => join(dir, path)).join('\n') + '\n' })).split('\n') : [];
    if (paths.length) await git(repo, ['update-index', '--add', '--index-info'], { env,
      input: paths.map((path, index) => `100644 ${blobs[index]}\t${path}`).join('\n') + '\n' });
    const tree = paths.length ? await git(repo, ['write-tree'], { env }) : await git(repo, ['mktree'], { input: '' });
    return await git(repo, ['commit-tree', tree, '-m', message], { env: KITE_IDENTITY });
  } finally { rmSync(temp, { recursive: true, force: true }); }
}

/** 把提交里的树取到一个新的临时目录，返回目录。 */
export async function extractCommit(repo: string, commit: string): Promise<string> {
  const dir = mkdtempSync(join(tmpdir(), 'kite-records-'));
  const archive = Bun.spawn(['git', 'archive', '--format=tar', commit], { cwd: repo, env: process.env, stdout: 'pipe', stderr: 'pipe' });
  const tar = Bun.spawn(['tar', '-x', '-f', '-', '-C', dir], { env: process.env, stdin: archive.stdout, stderr: 'pipe' });
  const [archived, extracted] = await Promise.all([archive.exited, tar.exited]);
  if (archived !== 0 || extracted !== 0) {
    rmSync(dir, { recursive: true, force: true });
    throw new KiteError(`读取流转记录失败：${(await new Response(archive.stderr).text()) || (await new Response(tar.stderr).text())}`, 409);
  }
  return dir;
}

/** 远程上这个工作区现有的材料。 */
export async function remoteMaterials(repo: string, access: RemoteAccess, workspaceId: string): Promise<Materials> {
  const r = await gitTry(repo, ['ls-remote', '--', access.url, `${prefix(workspaceId)}*`], { env: access.env });
  if (r.code !== 0) throw failure('读取流转材料', r.stderr);
  const found: Materials = {};
  for (const line of r.stdout.split('\n').filter(Boolean)) {
    const [commit, ref] = line.split('\t') as [string, string];
    const name = ref.slice(prefix(workspaceId).length) as MaterialName;
    if (materialNames.includes(name)) found[name] = commit;
  }
  return found;
}

/** 一次原子推送全部材料；这次没有的名字若远程上还留着旧的（上一次交接留下的），一并删掉。 */
export async function pushMaterials(repo: string, access: RemoteAccess, workspaceId: string, materials: Materials): Promise<void> {
  const stale = await remoteMaterials(repo, access, workspaceId);
  const specs = materialNames.flatMap((name) => materials[name] ? [`+${materials[name]}:${transferRef(workspaceId, name)}`]
    : stale[name] ? [`:${transferRef(workspaceId, name)}`] : []);
  const r = await gitTry(repo, ['push', '--porcelain', '--atomic', '--', access.url, ...specs], { env: access.env });
  if (r.code !== 0) throw failure('推送流转材料', r.stderr || r.stdout);
}

/** 取回材料到本地同名 ref，返回各自的提交。 */
export async function fetchMaterials(repo: string, access: RemoteAccess, workspaceId: string): Promise<Materials> {
  const remote = await remoteMaterials(repo, access, workspaceId);
  if (!remote.records) throw new KiteError('远程上没有这个工作区的流转材料，请先在源工作机发起交接', 404);
  const r = await gitTry(repo, ['fetch', '-q', '--no-tags', '--', access.url, `+${prefix(workspaceId)}*:${prefix(workspaceId)}*`], { env: access.env });
  if (r.code !== 0) throw failure('取回流转材料', r.stderr);
  return remote;
}

/** 接管成功或撤回交接后删除远程与本地的材料 ref；失败不影响已完成的流转。 */
export async function deleteMaterials(repo: string, access: RemoteAccess, workspaceId: string): Promise<void> {
  const remote = await remoteMaterials(repo, access, workspaceId);
  const names = materialNames.filter((name) => remote[name]);
  if (names.length) {
    const r = await gitTry(repo, ['push', '--porcelain', '--', access.url, ...names.map((name) => `:${transferRef(workspaceId, name)}`)], { env: access.env });
    if (r.code !== 0) throw failure('删除流转材料', r.stderr || r.stdout);
  }
  for (const name of materialNames) await gitTry(repo, ['update-ref', '-d', transferRef(workspaceId, name)]);
}

export const emptyDirectory = (): string => mkdtempSync(join(tmpdir(), 'kite-records-'));
