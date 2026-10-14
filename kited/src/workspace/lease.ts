/**
 * 工作区执行权：项目远程上的 refs/kite/lease/<工作区> 指向一个提交，树里的 lease.json 是 {machine, epoch, state}。
 * 更新一律带上预期的旧值推送（--force-with-lease），远程收到时按旧值比较后更新，同一时刻只有一方成功。
 * 从未流转过的工作区没有 lease，本机即持有者；查不到远程时按仍持有处理。
 */
import { z } from 'zod';
import { KiteError } from '../errors.ts';
import { KITE_IDENTITY, git, gitTry } from './git.ts';
import type { RemoteAccess } from './remote.ts';

const leaseSchema = z.object({ machine: z.string().min(1), epoch: z.number().int().positive(), state: z.enum(['active', 'handing_off']) }).strict();
export type Lease = z.infer<typeof leaseSchema>;

export const leaseRef = (workspaceId: string) => `refs/kite/lease/${workspaceId}`;

const failure = (action: string, stderr: string) =>
  new KiteError(`${action}失败：${stderr.trim().split('\n').slice(-3).join('\n') || '未知错误'}`, 409);

/** 远程上全部工作区 lease 的当前提交，按工作区 ID。 */
export async function remoteLeases(cwd: string, access: RemoteAccess): Promise<Map<string, string>> {
  const r = await gitTry(cwd, ['ls-remote', '--', access.url, 'refs/kite/lease/*'], { env: access.env });
  if (r.code !== 0) throw failure('读取执行权', r.stderr);
  return new Map(r.stdout.split('\n').filter(Boolean).map((line) => {
    const [commit, ref] = line.split('\t') as [string, string];
    return [ref.slice('refs/kite/lease/'.length), commit];
  }));
}

/** 本地还没有这个 lease 提交时从远程取回。 */
async function ensureLease(cwd: string, workspaceId: string, commit: string, access: RemoteAccess): Promise<void> {
  if ((await gitTry(cwd, ['cat-file', '-e', `${commit}^{commit}`])).code === 0) return;
  const ref = leaseRef(workspaceId);
  const r = await gitTry(cwd, ['fetch', '-q', '--no-tags', '--', access.url, `+${ref}:${ref}`], { env: access.env });
  if (r.code !== 0) throw failure('取回执行权', r.stderr);
}

/** 读出一个 lease 提交的内容。 */
export async function readLease(cwd: string, workspaceId: string, commit: string, access: RemoteAccess): Promise<Lease> {
  await ensureLease(cwd, workspaceId, commit, access);
  const parsed = leaseSchema.safeParse(JSON.parse(await git(cwd, ['show', `${commit}:lease.json`])));
  if (!parsed.success) throw new KiteError(`工作区 ${workspaceId} 的执行权记录无效`, 409);
  return parsed.data;
}

/**
 * 比较后更新：expected 是读到的旧提交，null 表示远程上还不能有这个 ref。新提交以旧提交为父，留下流转历史。
 * 远程的值已不是 expected 时返回 conflict，由调用方重新读取后决定。
 */
export async function writeLease(cwd: string, workspaceId: string, lease: Lease, expected: string | null,
  access: RemoteAccess): Promise<{ status: 'written'; commit: string } | { status: 'conflict' }> {
  // 远程已经前进、取不回 expected 时同样是被抢先。
  if (expected) try { await ensureLease(cwd, workspaceId, expected, access); } catch { return { status: 'conflict' }; }
  const blob = await git(cwd, ['hash-object', '-w', '--stdin'], { input: JSON.stringify(leaseSchema.parse(lease)) + '\n' });
  const tree = await git(cwd, ['mktree'], { input: `100644 blob ${blob}\tlease.json\n` });
  const commit = await git(cwd, ['commit-tree', tree, ...(expected ? ['-p', expected] : []),
    '-m', `Kite：工作区 ${workspaceId} 执行权 epoch ${lease.epoch} ${lease.state}`], { env: KITE_IDENTITY });
  const ref = leaseRef(workspaceId);
  const r = await gitTry(cwd, ['push', '--porcelain', `--force-with-lease=${ref}:${expected ?? ''}`, '--', access.url, `${commit}:${ref}`],
    { env: access.env });
  if (r.code !== 0) {
    // 本地按 expected 判出远程已变是 [rejected]；两方同时推、远程加锁或核对旧值时输的一方是 [remote rejected] 带锁或旧值的原因。
    // 钩子拒绝等平台原因不是冲突，照常报错。
    if (/^!\t.*\[rejected\]/m.test(r.stdout)
      || /^!\t.*\[remote rejected\] \((?:reference already exists|cannot lock ref|failed to (?:lock|update ref)|incorrect old value|.*but expected)/m.test(r.stdout)) {
      return { status: 'conflict' };
    }
    throw failure('更新执行权', r.stderr || r.stdout);
  }
  await git(cwd, ['update-ref', ref, commit]);
  return { status: 'written', commit };
}
