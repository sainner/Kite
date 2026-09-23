/**
 * 主线：主文件夹当前检出的分支。这里是会话工作树和主线之间的 git 操作，不涉及 agent。
 * 合回主线的顺序：先在会话工作树里提交全部改动，再把主线合进会话分支，最后主文件夹快进到会话分支。
 * 冲突因此只会出现在会话工作树里，主文件夹永远不会处于冲突状态。
 */
import { existsSync } from 'node:fs';
import { KiteError } from './errors.ts';
import { commitIdentity, git, gitTry, isAncestor, isDirty, revParse, unmergedPaths } from './git.ts';
import type { Project } from './store.ts';

/**
 * 主线当前的 commit。Kite 代管提交的项目，先把主文件夹里没提交的改动存成一个版本：
 * 非技术用户会直接在主文件夹改文件，不存的话新会话看不到，合回主线时也可能被覆盖。
 */
export async function mainline(p: Pick<Project, 'path' | 'commits'>): Promise<string> {
  if (p.commits === 'kite' && (await isDirty(p.path))) {
    await git(p.path, ['add', '-A']);
    await git(p.path, ['commit', '-q', '-m', 'Kite：保存主文件夹里的改动'], { env: await commitIdentity(p.path) });
  }
  const head = await revParse(p.path, 'HEAD');
  if (!head) throw new KiteError(`主文件夹没有可用的提交：${p.path}`, 409);
  return head;
}

export type MergeBack =
  | { status: 'merged'; commit: string }
  /** fresh：这次刚把主线合进来产生的冲突；否则是上次留下、还没解决的。 */
  | { status: 'conflict'; files: string[]; fresh: boolean };

/** 把会话工作树的全部改动合回主线。message 用作会话里未提交改动的提交说明。 */
export async function mergeBack(p: Pick<Project, 'path' | 'commits'>, worktree: string, message: string): Promise<MergeBack> {
  const identity = await commitIdentity(worktree);
  const merging = await revParse(worktree, 'MERGE_HEAD');
  if (merging) {
    const files = await unmergedPaths(worktree);
    if (files.length) return { status: 'conflict', files, fresh: false };
  }
  if (merging || (await isDirty(worktree))) {
    await git(worktree, ['add', '-A']);
    await git(worktree, ['commit', '-q', ...(merging ? ['--no-edit'] : ['-m', message])], { env: identity });
  }
  const main = await mainline(p);
  if (!(await isAncestor(worktree, main, 'HEAD'))) {
    const r = await gitTry(worktree, ['merge', '-q', '--no-edit', main], { env: identity });
    if (r.code !== 0) {
      const files = await unmergedPaths(worktree);
      if (!files.length) throw new KiteError(`把主线合进会话分支失败：${r.stderr.trim()}`, 409);
      return { status: 'conflict', files, fresh: true };
    }
  }
  const head = (await revParse(worktree, 'HEAD'))!;
  const ff = await gitTry(p.path, ['merge', '-q', '--ff-only', head]);
  if (ff.code !== 0) throw new KiteError(`主文件夹没法快进到会话的版本：${ff.stderr.trim()}`, 409);
  return { status: 'merged', commit: head };
}

/** 会话工作树里有没有还没合回主线的东西：未提交的改动，或主线还没包含的提交。 */
export async function hasUnmerged(main: string, worktree: string): Promise<boolean> {
  if (!existsSync(worktree)) return false;
  if (await isDirty(worktree)) return true;
  const head = await revParse(worktree, 'HEAD');
  const tip = await revParse(main, 'HEAD');
  return !head || !tip || !(await isAncestor(main, head, tip));
}
