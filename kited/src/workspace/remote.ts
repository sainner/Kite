/**
 * 检出与远程之间的网络操作。不改写用户的 origin 写法：为这个平台绑定了凭据时，执行时临时改用 HTTPS 地址带上凭据；
 * 没有绑定（例如用户自己配了 SSH key）就照原样使用 origin 与用户自己的 git 配置。
 * 一次操作开头取一次访问方式（地址与凭据），其中的拉取、推送与重试共用。
 */
import { KiteError } from '../errors.ts';
import { credentialEnv, type GitCredentials } from '../git-credential.ts';
import { httpsRemote } from '../remote-url.ts';
import { git, gitTry, isDirty } from './git.ts';

export interface RemoteAccess {
  url: string;
  env: Record<string, string>;
}

export async function originURL(cwd: string): Promise<string | null> {
  const r = await gitTry(cwd, ['remote', 'get-url', 'origin']);
  return r.code === 0 && r.stdout.trim() ? r.stdout.trim() : null;
}

/** 访问某个远程的方式。 */
export async function remoteAccess(remote: string, credentials: GitCredentials): Promise<RemoteAccess> {
  const https = httpsRemote(remote);
  const credential = https ? await credentials.credential(https) : null;
  const url = credential ? https! : remote;
  return { url, env: credentialEnv(url, credential) };
}

/** 访问检出 origin 的方式。 */
export async function originAccess(cwd: string, credentials: GitCredentials): Promise<RemoteAccess> {
  const origin = await originURL(cwd);
  if (!origin) throw new KiteError('检出没有 origin', 409);
  return remoteAccess(origin, credentials);
}

/** 失败时只保留 git 输出的最后几行，凭据不会出现在其中。 */
export function gitFailure(action: string, stderr: string): KiteError {
  return new KiteError(`${action}失败：${stderr.trim().split('\n').slice(-3).join('\n') || '未知错误'}`, 409);
}

/** 远程上匹配 pattern（如 refs/kite/lease/*）的 ref 与各自的提交；失败按 action 报错。 */
export async function lsRemote(cwd: string, access: RemoteAccess, pattern: string, action: string): Promise<Map<string, string>> {
  const r = await gitTry(cwd, ['ls-remote', '--', access.url, pattern], { env: access.env });
  if (r.code !== 0) throw gitFailure(action, r.stderr);
  return new Map(r.stdout.split('\n').filter(Boolean).map((line) => {
    const [commit, ref] = line.split('\t') as [string, string];
    return [ref, commit];
  }));
}

/** origin 保留用户填写的写法，http(s) 地址去掉其中的凭据。 */
export const originSpelling = (remote: string): string => /^https?:\/\//i.test(remote.trim()) ? httpsRemote(remote)! : remote.trim();

/** clone 后 origin 保留用户填写的写法。 */
export async function clone(remote: string, dest: string, credentials: GitCredentials): Promise<void> {
  const access = await remoteAccess(remote, credentials);
  const r = await gitTry('/', ['clone', '-q', '--origin', 'origin', '--', access.url, dest], { env: access.env });
  if (r.code !== 0) throw gitFailure('clone', r.stderr);
  const origin = originSpelling(remote);
  if (origin !== access.url) await git(dest, ['remote', 'set-url', 'origin', origin]);
}

/** 把检出的全部分支和标签推到远程。用于给没有远程的项目设远程。 */
export async function pushAll(cwd: string, access: RemoteAccess): Promise<void> {
  const r = await gitTry(cwd, ['push', '-q', '--', access.url, 'refs/heads/*:refs/heads/*', 'refs/tags/*:refs/tags/*'], { env: access.env });
  if (r.code !== 0) throw gitFailure('推送到远程', r.stderr);
}

/** 检出现场当前所在的分支，即主线；分离 HEAD 时为 null。 */
export async function currentBranch(cwd: string): Promise<string | null> {
  const r = await gitTry(cwd, ['symbolic-ref', '-q', '--short', 'HEAD']);
  return r.code === 0 && r.stdout.trim() ? r.stdout.trim() : null;
}

const tracking = (branch: string) => `refs/remotes/origin/${branch}`;

/** 按 refspec 取一条 ref；远程没有这条 ref 时返回 false，其他失败按 action 报错。 */
export async function fetchRef(cwd: string, access: RemoteAccess, spec: string, action: string): Promise<boolean> {
  // Git 没有为缺少 ref 提供单独退出码，固定语言后识别这一种失败。
  const r = await gitTry(cwd, ['fetch', '-q', '--no-tags', '--', access.url, spec], { env: { ...access.env, LC_ALL: 'C' } });
  if (r.code === 0) return true;
  if (/couldn't find remote ref/i.test(r.stderr)) return false;
  throw gitFailure(action, r.stderr);
}

/** 拉取远程上的同名分支到 origin 的跟踪引用，返回其 commit；远程还没有这个分支时为 null。 */
export async function fetchBranch(cwd: string, branch: string, access: RemoteAccess): Promise<string | null> {
  if (!(await fetchRef(cwd, access, `+refs/heads/${branch}:${tracking(branch)}`, '拉取远程'))) return null;
  return git(cwd, ['rev-parse', tracking(branch)]);
}

/** 把本地分支推到远程同名分支。远程有本地没有的提交时返回 rejected，由调用方拉取后重试。 */
export async function pushBranch(cwd: string, branch: string, access: RemoteAccess): Promise<'pushed' | 'rejected'> {
  const ref = `refs/heads/${branch}`;
  const r = await gitTry(cwd, ['push', '--porcelain', '--', access.url, `${ref}:${ref}`], { env: access.env });
  if (r.code !== 0) {
    if (/^!\t.*\[rejected\]/m.test(r.stdout)) return 'rejected';
    throw gitFailure('推送', r.stderr || r.stdout);
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
  const [branch, dirty] = await Promise.all([currentBranch(cwd), isDirty(cwd)]);
  if (!branch) return { branch, dirty, ahead: null, behind: null };
  const counts = await gitTry(cwd, ['rev-list', '--left-right', '--count', `HEAD...${tracking(branch)}`]);
  if (counts.code !== 0) return { branch, dirty, ahead: null, behind: null };
  const [ahead, behind] = counts.stdout.trim().split(/\s+/).map(Number);
  return { branch, dirty, ahead: ahead!, behind: behind! };
}
