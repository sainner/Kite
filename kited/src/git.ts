/** git 子进程。异步执行，不阻塞 kited 的事件循环；多个会话的快照可以同时进行。 */

export interface GitResult { code: number; stdout: string; stderr: string }

export class GitError extends Error {
  constructor(readonly args: string[], readonly result: GitResult) {
    super(`git ${args.join(' ')} 失败（${result.code}）：${result.stderr.trim() || result.stdout.trim()}`);
  }
}

export interface GitOptions { env?: Record<string, string>; input?: string }

export async function gitTry(cwd: string, args: string[], opts: GitOptions = {}): Promise<GitResult> {
  const p = Bun.spawn(['git', '-c', 'core.quotePath=false', ...args], {
    cwd,
    env: { ...process.env, ...opts.env },
    stdin: opts.input === undefined ? 'ignore' : new TextEncoder().encode(opts.input),
    stdout: 'pipe',
    stderr: 'pipe',
  });
  const [stdout, stderr, code] = await Promise.all([new Response(p.stdout).text(), new Response(p.stderr).text(), p.exited]);
  return { code, stdout, stderr };
}

/** 失败抛 GitError；返回去掉首尾空白的标准输出。 */
export async function git(cwd: string, args: string[], opts: GitOptions = {}): Promise<string> {
  const r = await gitTry(cwd, args, opts);
  if (r.code !== 0) throw new GitError(args, r);
  return r.stdout.trim();
}

/** 解析成 commit；不存在返回 null。 */
export async function revParse(cwd: string, rev: string): Promise<string | null> {
  const r = await gitTry(cwd, ['rev-parse', '--verify', '--quiet', `${rev}^{commit}`]);
  return r.code === 0 ? r.stdout.trim() : null;
}

export async function isAncestor(cwd: string, a: string, b: string): Promise<boolean> {
  return (await gitTry(cwd, ['merge-base', '--is-ancestor', a, b])).code === 0;
}

export const KITE_IDENTITY = {
  GIT_AUTHOR_NAME: 'Kite', GIT_AUTHOR_EMAIL: 'kite@localhost',
  GIT_COMMITTER_NAME: 'Kite', GIT_COMMITTER_EMAIL: 'kite@localhost',
};

/** 代用户提交时的身份：仓库配了用户就用用户的，没配就署名 Kite。 */
export async function commitIdentity(cwd: string): Promise<Record<string, string>> {
  const name = (await gitTry(cwd, ['config', 'user.name'])).stdout.trim();
  const email = (await gitTry(cwd, ['config', 'user.email'])).stdout.trim();
  return name && email ? {} : KITE_IDENTITY;
}

/** 工作树里有没有未提交的改动（含未跟踪、不含被忽略的文件）。 */
export async function isDirty(cwd: string): Promise<boolean> {
  return (await git(cwd, ['status', '--porcelain', '--untracked-files=all'])) !== '';
}

/** 未合并（冲突中）的文件。 */
export async function unmergedPaths(cwd: string): Promise<string[]> {
  return (await git(cwd, ['diff', '--name-only', '--diff-filter=U'])).split('\n').filter(Boolean);
}
