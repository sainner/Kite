/**
 * 子工作区与父工作区之间的 git 操作，见 docs/项目与远程仓库.md「子工作区」。两个工作树开在同一个检出上，分支互相看得见。
 * 开出时先把父工作区的现状提交到它的分支上，子工作区从这个提交开出：合回时两边的共同祖先就是开出那一刻，父工作区之后撤销的改动不会被带回来。
 * 合回分两步：先把父工作区的现状合进子工作区分支，冲突留在子工作区；再把子工作区分支合进父工作区，这一步有冲突就不动父工作区，由调用方从第一步重来。
 */
import { existsSync } from 'node:fs';
import { KiteError } from '../errors.ts';
import { commitAll, commitIdentity, git, gitTry, isDirty, revParse } from './git.ts';
import { mergeMainline, type Integration } from './mainline.ts';

/**
 * 父工作区的现状记成它分支上的提交（没有改动时不提交），返回它的 HEAD。代理不能写 Git 元数据，父工作区的索引只有宿主在用。
 * 父工作区停在集成或同步的合并中途时拒绝，免得把冲突标记当成解决结果提交。
 */
export async function commitParent(parent: { cwd: string; name: string }): Promise<string> {
  if (await revParse(parent.cwd, 'MERGE_HEAD')) throw new KiteError('父工作区停在合并主线的冲突里，先把冲突处理完', 409);
  if (await isDirty(parent.cwd)) await commitAll(parent.cwd, ['-m', parent.name]);
  return git(parent.cwd, ['rev-parse', 'HEAD']);
}

/** 第一步：父工作区的现状合进子工作区分支，冲突留在子工作区。stageResolved 同 mergeMainline。 */
export async function mergeParent(child: { cwd: string; name: string }, parent: { cwd: string; name: string; branch: string },
  stageResolved: boolean): Promise<Integration> {
  await commitParent(parent);
  return mergeMainline(child.cwd, child.name, [`refs/heads/${parent.branch}`], { stageResolved });
}

/**
 * 第二步：子工作区分支合进父工作区。先不动工作树试合，父工作区在第一步之后又改了同一处时返回 conflict，父工作区的文件里不会出现冲突标记；
 * 父工作区的线程刚写的文件挡住合并时同样不动，也返回 conflict。
 */
export async function mergeChild(parent: { cwd: string; name: string }, childBranch: string): Promise<{ status: 'merged' | 'conflict' }> {
  await commitParent(parent);
  const ref = `refs/heads/${childBranch}`;
  const probe = await gitTry(parent.cwd, ['merge-tree', '--write-tree', '--quiet', 'HEAD', ref]);
  if (probe.code === 1) return { status: 'conflict' };
  if (probe.code !== 0) throw new KiteError(`试合子工作区失败：${probe.stderr.trim()}`, 409);
  const r = await gitTry(parent.cwd, ['merge', '-q', '--no-edit', ref], { env: await commitIdentity(parent.cwd) });
  if (r.code === 0) return { status: 'merged' };
  if (await revParse(parent.cwd, 'MERGE_HEAD')) await git(parent.cwd, ['merge', '--abort']);
  return { status: 'conflict' };
}

/** 子工作区相对起点有没有改动：没提交的，或起点之后的提交。工作树没建成时没有。 */
export async function childChanged(child: { cwd: string; base: string }): Promise<boolean> {
  if (!existsSync(child.cwd)) return false;
  return (await isDirty(child.cwd)) || (await revParse(child.cwd, 'HEAD')) !== child.base;
}
