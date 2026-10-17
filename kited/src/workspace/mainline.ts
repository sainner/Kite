/**
 * 主线：检出（裸仓库）HEAD 指向的分支。这里是工作树和主线之间的 git 操作，不涉及 agent。
 * 集成与同步都先在工作树里提交全部改动，再把主线（本机的和刚拉取的远程主线）合进工作区分支；冲突因此只出现在工作树里。
 * 直接合入随后把本机主线快进到工作区分支，提交 PR 则推送工作区分支，见 docs/项目与远程仓库.md「工作区与集成」。
 */
import { existsSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { KiteError } from '../errors.ts';
import { commitAll, commitIdentity, commitOnto, fastForward, git, gitTry, isAncestor, isDirty, revParse, unmergedPaths } from './git.ts';
import { currentBranch, fetchBranch, tracking, type RemoteAccess } from './remote.ts';
import type { Checkout } from '../model.ts';

/** 主线分支名。 */
export async function mainBranch(p: Pick<Checkout, 'path'>): Promise<string> {
  const branch = await currentBranch(p.path);
  if (!branch) throw new KiteError(`检出的 HEAD 不在任何分支上：${p.path}`, 409);
  return branch;
}

/** 主线当前的 commit。远程还是空仓库时主线没有提交，先补一个空的初始提交，工作区从它开出，集成时一并推上去。 */
export async function mainline(p: Pick<Checkout, 'path'>): Promise<string> {
  const branch = await mainBranch(p);
  return await revParse(p.path, `refs/heads/${branch}`) ?? commitOnto(p.path, branch, await git(p.path, ['mktree'], { input: '' }), 'Kite：初始版本');
}

/**
 * 拉取远程主线到 origin 的跟踪引用，本机主线落后就快进；本机有没推上去的提交（上次推送失败）时不动，集成时一并合并。
 * 返回拉取后的主线引用（同 mainRefs），远程还没有这个分支时只有本机主线。
 */
export async function fetchMainline(p: Pick<Checkout, 'path'>, access: RemoteAccess): Promise<string[]> {
  const branch = await mainBranch(p);
  const upstream = await fetchBranch(p.path, branch, access);
  if (!upstream) return [`refs/heads/${branch}`];
  await fastForward(p.path, branch, upstream);
  return [`refs/heads/${branch}`, tracking(branch)];
}

/**
 * 主线的几个引用：本机主线，以及拉取过时的远程主线（按最近一次拉取）；集成、同步与落后计数都对着它们。
 * 用引用名而不是提交号，合并提交的说明里写的是分支。
 */
export async function mainRefs(p: Pick<Checkout, 'path'>): Promise<string[]> {
  const branch = await mainBranch(p);
  const upstream = tracking(branch);
  return [`refs/heads/${branch}`, ...(await revParse(p.path, upstream) ? [upstream] : [])];
}

export type Integration =
  | { status: 'merged'; commit: string }
  | { status: 'conflict'; files: string[] };

/** 仍带 git 冲突标记的文件；已删除的文件视为已作出取舍。 */
function markedPaths(worktree: string, files: string[]): string[] {
  return files.filter((file) => {
    const path = join(worktree, file);
    return existsSync(path) && /^(?:<{7}|>{7})(?: |$)/m.test(readFileSync(path, 'latin1'));
  });
}

/**
 * 提交工作树的全部改动（message 是提交说明），再把 mains 里的主线依次合进工作区分支。
 * agent 在沙箱里不能写 Git 元数据，冲突只能改文件解决；stageResolved 表示解决冲突的回合已正常结束，
 * 由宿主把已去掉冲突标记的文件标为解决并提交。无标记的冲突（删改、二进制）只有这时才按当前文件采纳。
 */
export async function mergeMainline(worktree: string, message: string, mains: Array<string | null>,
  options: { stageResolved?: boolean } = {}): Promise<Integration> {
  const merging = await revParse(worktree, 'MERGE_HEAD');
  if (merging) {
    const files = await unmergedPaths(worktree);
    const unresolved = options.stageResolved ? markedPaths(worktree, files) : files;
    if (unresolved.length) return { status: 'conflict', files: unresolved };
  }
  if (merging || (await isDirty(worktree))) await commitAll(worktree, merging ? ['--no-edit'] : ['-m', message]);
  for (const main of mains) {
    if (!main || (await isAncestor(worktree, main, 'HEAD'))) continue;
    const r = await gitTry(worktree, ['merge', '-q', '--no-edit', main], { env: await commitIdentity(worktree) });
    if (r.code !== 0) {
      const files = await unmergedPaths(worktree);
      if (!files.length) throw new KiteError(`把主线合进工作区分支失败：${r.stderr.trim()}`, 409);
      return { status: 'conflict', files };
    }
  }
  return { status: 'merged', commit: (await revParse(worktree, 'HEAD'))! };
}

/** 直接合入：本机主线快进到已合好主线的工作区提交。 */
export async function advanceMainline(p: Pick<Checkout, 'path'>, commit: string): Promise<void> {
  if (await fastForward(p.path, await mainBranch(p), commit) === 'diverged') throw new KiteError('主线刚有新的提交，请重试', 409);
}

/** 主线（mains，见 mainRefs）比工作区分支多出的提交数；工作树不在或不知道主线时为 null。 */
export async function behindCount(worktree: string, mains: string[]): Promise<number | null> {
  if (!mains.length || !existsSync(worktree)) return null;
  const r = await gitTry(worktree, ['rev-list', '--count', ...mains, '^HEAD']);
  return r.code === 0 ? Number(r.stdout.trim()) : null;
}

/** 工作树里有没有还没合进主线的东西：未提交的改动，或主线还没包含的提交。 */
export async function hasUnmerged(p: Pick<Checkout, 'path'>, worktree: string): Promise<boolean> {
  if (!existsSync(worktree)) return false;
  if (await isDirty(worktree)) return true;
  const head = await revParse(worktree, 'HEAD');
  const tip = await revParse(p.path, `refs/heads/${await mainBranch(p)}`);
  return !head || !tip || !(await isAncestor(p.path, head, tip));
}
