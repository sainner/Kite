/**
 * 主线：主文件夹当前检出的分支。这里是会话工作树和主线之间的 git 操作，不涉及 agent。
 * 合回主线的顺序：先在会话工作树里提交全部改动，再把主线合进会话分支，最后主文件夹快进到会话分支。
 * 冲突因此只会出现在会话工作树里，主文件夹永远不会处于冲突状态。
 */
import { existsSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { KiteError } from '../errors.ts';
import { commitAll, commitIdentity, gitTry, isAncestor, isDirty, revParse, unmergedPaths } from './git.ts';
import type { Checkout } from '../model.ts';

/**
 * 主线当前的 commit。Kite 代管提交的项目，先把主文件夹里没提交的改动存成一个版本：
 * 非技术用户会直接在主文件夹改文件，不存的话新会话看不到，合回主线时也可能被覆盖。
 */
export async function mainline(p: Pick<Checkout, 'path' | 'commits'>): Promise<string> {
  if (p.commits === 'kite' && (await isDirty(p.path))) await commitAll(p.path, ['-m', 'Kite：保存主文件夹里的改动']);
  const head = await revParse(p.path, 'HEAD');
  if (!head) throw new KiteError(`主文件夹没有可用的提交：${p.path}`, 409);
  return head;
}

export type MergeBack =
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
 * 把会话工作树的全部改动合回主线。message 用作会话里未提交改动的提交说明。
 * agent 在沙箱里不能写 Git 元数据，冲突只能改文件解决；stageResolved 表示解决冲突的回合已正常结束，
 * 由宿主把已去掉冲突标记的文件标为解决并提交。无标记的冲突（删改、二进制）只有这时才按当前文件采纳。
 */
export async function mergeBack(p: Pick<Checkout, 'path' | 'commits'>, worktree: string, message: string,
  options: { stageResolved?: boolean } = {}): Promise<MergeBack> {
  const merging = await revParse(worktree, 'MERGE_HEAD');
  if (merging) {
    const files = await unmergedPaths(worktree);
    const unresolved = options.stageResolved ? markedPaths(worktree, files) : files;
    if (unresolved.length) return { status: 'conflict', files: unresolved };
  }
  if (merging || (await isDirty(worktree))) await commitAll(worktree, merging ? ['--no-edit'] : ['-m', message]);
  const main = await mainline(p);
  if (!(await isAncestor(worktree, main, 'HEAD'))) {
    const r = await gitTry(worktree, ['merge', '-q', '--no-edit', main], { env: await commitIdentity(worktree) });
    if (r.code !== 0) {
      const files = await unmergedPaths(worktree);
      if (!files.length) throw new KiteError(`把主线合进会话分支失败：${r.stderr.trim()}`, 409);
      return { status: 'conflict', files };
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
  const [head, tip] = await Promise.all([revParse(worktree, 'HEAD'), revParse(main, 'HEAD')]);
  return !head || !tip || !(await isAncestor(main, head, tip));
}
