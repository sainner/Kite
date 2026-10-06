/**
 * 检出与远程之间的网络操作。不改写用户的 origin 写法：账号为这个平台绑定了凭据时，执行时临时改用 HTTPS 地址带上凭据；
 * 没有绑定（例如用户自己配了 SSH key）就照原样使用 origin 与用户自己的 git 配置。
 */
import { KiteError } from '../errors.ts';
import { credentialEnv } from '../git-credential.ts';
import { httpsRemote } from '../remote-url.ts';
import type { AccountClient } from '../account-client.ts';
import { git, gitTry } from './git.ts';

export interface RemoteAccess {
  url: string;
  env: Record<string, string>;
}

export async function originURL(cwd: string): Promise<string | null> {
  const r = await gitTry(cwd, ['remote', 'get-url', 'origin']);
  return r.code === 0 && r.stdout.trim() ? r.stdout.trim() : null;
}

export async function remoteAccess(remote: string, account: AccountClient): Promise<RemoteAccess> {
  const https = httpsRemote(remote);
  const credential = https && account.linked ? await account.credential(https) : null;
  if (credential) return { url: https!, env: credentialEnv(https!, credential) };
  return { url: remote, env: { GIT_TERMINAL_PROMPT: '0' } };
}

/** 失败时只保留 git 输出的最后几行，凭据不会出现在其中。 */
function failure(action: string, stderr: string): KiteError {
  return new KiteError(`${action}失败：${stderr.trim().split('\n').slice(-3).join('\n') || '未知错误'}`, 409);
}

/** clone 后 origin 保留用户填写的写法（去掉其中的凭据）。 */
export async function clone(remote: string, dest: string, account: AccountClient): Promise<void> {
  const access = await remoteAccess(remote, account);
  const r = await gitTry('/', ['clone', '-q', '--origin', 'origin', '--', access.url, dest], { env: access.env });
  if (r.code !== 0) throw failure('clone', r.stderr);
  const origin = /^https?:\/\//i.test(remote.trim()) ? httpsRemote(remote)! : remote.trim();
  if (origin !== access.url) await git(dest, ['remote', 'set-url', 'origin', origin]);
}

/** 远程还没有任何分支时，把检出的全部分支和标签推上去。用于 Kite 新建的托管远程。 */
export async function seedRemote(cwd: string, account: AccountClient): Promise<void> {
  const origin = await originURL(cwd);
  if (!origin) throw new KiteError('检出没有 origin', 409);
  const access = await remoteAccess(origin, account);
  const heads = await gitTry(cwd, ['ls-remote', '--heads', '--', access.url], { env: access.env });
  if (heads.code !== 0) throw failure('读取远程', heads.stderr);
  if (heads.stdout.trim()) return;
  const r = await gitTry(cwd, ['push', '-q', '--', access.url, 'refs/heads/*:refs/heads/*', 'refs/tags/*:refs/tags/*'], { env: access.env });
  if (r.code !== 0) throw failure('推送到远程', r.stderr);
}

/** 检出现场当前所在的分支，即主线；分离 HEAD 时为 null。 */
export async function currentBranch(cwd: string): Promise<string | null> {
  const r = await gitTry(cwd, ['symbolic-ref', '-q', '--short', 'HEAD']);
  return r.code === 0 && r.stdout.trim() ? r.stdout.trim() : null;
}

const tracking = (branch: string) => `refs/remotes/origin/${branch}`;

/** 拉取远程上的同名分支到 origin 的跟踪引用，返回其 commit；远程还没有这个分支时为 null。 */
export async function fetchBranch(cwd: string, branch: string, account: AccountClient): Promise<string | null> {
  const origin = await originURL(cwd);
  if (!origin) throw new KiteError('检出没有 origin', 409);
  const access = await remoteAccess(origin, account);
  const heads = await gitTry(cwd, ['ls-remote', '--heads', '--', access.url, `refs/heads/${branch}`], { env: access.env });
  if (heads.code !== 0) throw failure('读取远程', heads.stderr);
  if (!heads.stdout.trim()) return null;
  const r = await gitTry(cwd, ['fetch', '-q', '--no-tags', '--', access.url, `+refs/heads/${branch}:${tracking(branch)}`], { env: access.env });
  if (r.code !== 0) throw failure('拉取远程', r.stderr);
  return git(cwd, ['rev-parse', tracking(branch)]);
}

/** 把本地分支推到远程同名分支。远程有本地没有的提交时返回 rejected，由调用方拉取后重试。 */
export async function pushBranch(cwd: string, branch: string, account: AccountClient): Promise<'pushed' | 'rejected'> {
  const origin = await originURL(cwd);
  if (!origin) throw new KiteError('检出没有 origin', 409);
  const access = await remoteAccess(origin, account);
  const ref = `refs/heads/${branch}`;
  const r = await gitTry(cwd, ['push', '--porcelain', '--', access.url, `${ref}:${ref}`], { env: access.env });
  if (r.code !== 0) {
    if (/^!\t.*\[rejected\]/m.test(r.stdout)) return 'rejected';
    throw failure('推送', r.stderr || r.stdout);
  }
  await git(cwd, ['update-ref', tracking(branch), ref]);
  return 'pushed';
}

export interface CheckoutSync {
  branch: string | null;
  dirty: boolean;
  /** 相对最近一次拉取到的远程分支；没有拉取过时为 null。 */
  ahead: number | null;
  behind: number | null;
}

/** 现场与远程的关系，只用本地已有的跟踪引用，不访问网络。 */
export async function checkoutSync(cwd: string): Promise<CheckoutSync> {
  const [branch, status] = await Promise.all([currentBranch(cwd), git(cwd, ['status', '--porcelain', '--untracked-files=all'])]);
  const dirty = status !== '';
  if (!branch) return { branch, dirty, ahead: null, behind: null };
  const counts = await gitTry(cwd, ['rev-list', '--left-right', '--count', `HEAD...${tracking(branch)}`]);
  if (counts.code !== 0) return { branch, dirty, ahead: null, behind: null };
  const [ahead, behind] = counts.stdout.trim().split(/\s+/).map(Number);
  return { branch, dirty, ahead: ahead!, behind: behind! };
}
