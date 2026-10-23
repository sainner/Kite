/**
 * 检出（裸仓库）与远程之间的网络操作。不改写用户的 origin 写法：为这个平台绑定了凭据时，执行时临时改用 HTTPS 地址带上凭据；
 * 没有绑定（例如用户自己配了 SSH key）就照原样使用 origin 与用户自己的 git 配置。
 * 一次操作开头取一次访问方式（地址与凭据），其中的拉取、推送与重试共用。
 */
import { GitLoginRequired, KiteError } from '../errors.ts';
import { credentialEnv, type GitCredentials } from '../git-credential.ts';
import { httpsRemote } from '../remote-url.ts';
import { git, gitTry } from './git.ts';

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

/** 失败时只保留 git 输出的最后几行，凭据不会出现在其中。HTTPS 远程要账号或拒绝了令牌时，换成去哪里绑定的说明。 */
export function gitFailure(action: string, stderr: string): KiteError {
  const login = /(could not read Username|Authentication failed) for '(https?:\/\/[^/']+)/.exec(stderr);
  if (login) {
    const host = new URL(login[2]!).host;
    const fix = login[1] === 'Authentication failed' ? '拒绝了访问令牌，到「资源库 → 凭据」的 Git 账号里重新绑定' : '要求登录，到「资源库 → 凭据」的 Git 账号里用访问令牌绑定它';
    return new GitLoginRequired(`${action}失败：${host} ${fix}`, host);
  }
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

/** 确认能访问远程，返回远程的默认分支；远程还是空仓库时为 null。 */
export async function remoteHead(remote: string, credentials: GitCredentials): Promise<string | null> {
  const access = await remoteAccess(remote, credentials);
  const r = await gitTry('/', ['ls-remote', '--symref', '--', access.url, 'HEAD'], { env: access.env });
  if (r.code !== 0) throw gitFailure('访问远程', r.stderr);
  return /^ref: refs\/heads\/(\S+)\tHEAD$/m.exec(r.stdout)?.[1] ?? null;
}

/** clone 成裸仓库，origin 保留用户填写的写法。 */
export async function clone(remote: string, dest: string, credentials: GitCredentials): Promise<void> {
  const access = await remoteAccess(remote, credentials);
  const r = await gitTry('/', ['clone', '-q', '--bare', '--', access.url, dest], { env: access.env });
  if (r.code !== 0) throw gitFailure('clone', r.stderr);
  const origin = originSpelling(remote);
  if (origin !== access.url) await git(dest, ['remote', 'set-url', 'origin', origin]);
}

/** 把检出的全部分支和标签推到远程。用于给没有远程的项目设远程。 */
export async function pushAll(cwd: string, access: RemoteAccess): Promise<void> {
  const r = await gitTry(cwd, ['push', '-q', '--', access.url, 'refs/heads/*:refs/heads/*', 'refs/tags/*:refs/tags/*'], { env: access.env });
  if (r.code !== 0) throw gitFailure('推送到远程', r.stderr);
}

/** 仓库 HEAD 指向的分支；检出里就是主线。分离 HEAD 时为 null。 */
export async function currentBranch(cwd: string): Promise<string | null> {
  const r = await gitTry(cwd, ['symbolic-ref', '-q', '--short', 'HEAD']);
  return r.code === 0 && r.stdout.trim() ? r.stdout.trim() : null;
}

/** 远程分支在检出里的跟踪引用。 */
export const tracking = (branch: string) => `refs/remotes/origin/${branch}`;

/** 按 refspec 取一条 ref；远程没有这条 ref 时返回 false，其他失败按 action 报错。 */
export async function fetchRef(cwd: string, access: RemoteAccess, spec: string, action: string): Promise<boolean> {
  const r = await gitTry(cwd, ['fetch', '-q', '--no-tags', '--', access.url, spec], { env: { ...access.env, LC_ALL: 'C' } });
  if (r.code === 0) return true;
  if (missingRef(r.stderr)) return false;
  throw gitFailure(action, r.stderr);
}

/** Git 没有为缺少 ref 提供单独退出码，固定语言（LC_ALL=C）后按说明识别这一种失败。 */
export const missingRef = (stderr: string) => /couldn't find remote ref/i.test(stderr);

/** 拉取远程上的同名分支到 origin 的跟踪引用，返回其 commit；远程还没有这个分支时为 null。 */
export async function fetchBranch(cwd: string, branch: string, access: RemoteAccess): Promise<string | null> {
  if (!(await fetchRef(cwd, access, `+refs/heads/${branch}:${tracking(branch)}`, '拉取远程'))) return null;
  return git(cwd, ['rev-parse', tracking(branch)]);
}

/**
 * 把本地分支推到远程分支 to（默认同名）。远程有本地没有的提交时返回 rejected，由调用方拉取后重试；因保护规则被拒时返回 protected。
 */
export async function pushBranch(cwd: string, branch: string, access: RemoteAccess, to = branch): Promise<'pushed' | 'rejected' | 'protected'> {
  const ref = `refs/heads/${branch}`;
  const r = await gitTry(cwd, ['push', '--porcelain', '--', access.url, `${ref}:refs/heads/${to}`], { env: access.env });
  if (r.code !== 0) {
    if (/^!\t.*\[rejected\]/m.test(r.stdout)) return 'rejected';
    if (/protected branch|GH006|pre-receive hook declined/i.test(r.stderr + r.stdout)) return 'protected';
    throw gitFailure('推送', r.stderr || r.stdout);
  }
  await git(cwd, ['update-ref', tracking(to), ref]);
  return 'pushed';
}
