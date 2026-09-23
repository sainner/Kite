/**
 * 会话快照：把工作树的当前状态存成 commit，链在 refs/kite/snapshots/<会话> 上。
 * 不用 refs/kite/<会话>：会话分支叫 kite/<会话>，git 解析短名时 refs/<名字> 排在 refs/heads/<名字> 前面，
 * 按分支名操作会拿到快照。
 * 用每个工作树自己的私有索引（GIT_INDEX_FILE），不碰用户的 HEAD、分支和暂存区；
 * 索引记着文件的修改时间，下次只需逐个 stat。快照的第一个父节点永远是上一枚快照，
 * agent 自己提交过时另挂当时的 HEAD。调用方负责同一会话内串行。
 */
import { existsSync, mkdirSync } from 'node:fs';
import { join } from 'node:path';
import { git, isAncestor, KITE_IDENTITY, revParse } from './git.ts';

export const snapshotRef = (sessionId: string) => `refs/kite/snapshots/${sessionId}`;

export interface Captured { commit: string; tree: string; created: boolean; changedFiles: number }

export interface Snapshot { commit: string; at: number; label: string; toolUseIds: string[] }

// 每次调用 git 约 10 毫秒，快照在每批工具调用后都要打，agent 等它打完才继续，所以尽量少调
const indexes = new Map<string, string>();

/** 工作树自己的 git 目录下的 kite/index。工作树的 git 目录不会变，查一次就记住。 */
async function privateIndex(worktree: string): Promise<string> {
  let index = indexes.get(worktree);
  if (!index) {
    const dir = join(await git(worktree, ['rev-parse', '--absolute-git-dir']), 'kite');
    mkdirSync(dir, { recursive: true });
    index = join(dir, 'index');
    indexes.set(worktree, index);
  }
  return index;
}

/** 一次查出几个名字对应的对象，不存在的为 null。 */
async function resolve(cwd: string, names: string[]): Promise<(string | null)[]> {
  const out = await git(cwd, ['cat-file', '--batch-check=%(objectname)'], { input: names.join('\n') + '\n' });
  return out.split('\n').map((l) => (l.endsWith(' missing') ? null : l));
}

/** 标签是一行字，原样作为提交说明的第一行，列快照时读回来的和事件里的一致。 */
function message(sessionId: string, label: string, toolUseIds: string[]): string {
  return [label, '', `Kite-Session: ${sessionId}`, ...toolUseIds.map((id) => `Kite-Tool-Use: ${id}`)].join('\n');
}

/**
 * 把一棵树记成会话的一枚新快照，挂在 previous 之后。fromTree 是上一个状态的树，用来数改了几个文件。
 * head 是工作树当时的 HEAD：agent 自己提交过、HEAD 不在快照链上时，另挂成父节点；传 null 表示不用挂。
 */
async function record(worktree: string, sessionId: string, tree: string, fromTree: string | null, previous: string | null, head: string | null, label: string, toolUseIds: string[]): Promise<Captured> {
  const changedFiles = fromTree
    ? (await git(worktree, ['diff-tree', '-r', '--name-only', '--no-renames', fromTree, tree])).split('\n').filter(Boolean).length
    : (await git(worktree, ['ls-tree', '-r', '--name-only', tree])).split('\n').filter(Boolean).length;
  const parents: string[] = [];
  if (previous) parents.push('-p', previous);
  if (head && (!previous || !(await isAncestor(worktree, head, previous)))) parents.push('-p', head);
  const commit = await git(worktree, ['commit-tree', tree, ...parents, '-F', '-'], {
    env: KITE_IDENTITY, input: message(sessionId, label, toolUseIds),
  });
  // 比较并交换：引用在读取之后被动过就失败，不覆盖
  await git(worktree, ['update-ref', '--no-deref', snapshotRef(sessionId), commit, previous ?? '']);
  return { commit, tree, created: true, changedFiles };
}

/** 捕获整个工作树。树没变就复用上一枚，不产生新提交。 */
export async function capture(worktree: string, sessionId: string, label: string, toolUseIds: string[] = []): Promise<Captured> {
  const ref = snapshotRef(sessionId);
  const [previous, prevTree, head, headTree] = await resolve(worktree, [`${ref}^{commit}`, `${ref}^{tree}`, 'HEAD^{commit}', 'HEAD^{tree}']);
  const env = { GIT_INDEX_FILE: await privateIndex(worktree) };

  if (!existsSync(env.GIT_INDEX_FILE)) {
    const base = previous ?? head;
    await git(worktree, base ? ['read-tree', base] : ['read-tree', '--empty'], { env });
  }
  await git(worktree, ['add', '-A', '--', '.'], { env });
  const tree = await git(worktree, ['write-tree'], { env });

  if (previous && prevTree === tree) return { commit: previous, tree, created: false, changedFiles: 0 };
  return record(worktree, sessionId, tree, prevTree ?? headTree ?? null, previous ?? null, head ?? null, label, toolUseIds);
}

/**
 * 把工作树整体恢复成某一枚快照：只动文件，不动 HEAD、分支和工作树自己的暂存区。
 * 先捕获一次当前状态，私有索引此时等于「现在」，回退本身因此可以撤销；
 * 再在私有索引上 read-tree --reset -u：现在有而目标没有的文件被删，被忽略的文件不碰。
 * 之后工作树里未被忽略的部分正好是目标那棵树，直接把它记成新的一枚，不用再捕获一遍。
 */
export async function restore(worktree: string, sessionId: string, target: string): Promise<{ safety: Captured; current: Captured; label: string }> {
  const safety = await capture(worktree, sessionId, '回退前自动保存');
  const env = { GIT_INDEX_FILE: await privateIndex(worktree) };
  const [tree, subject] = (await git(worktree, ['log', '-1', '--format=%T%x00%s', target])).split('\0') as [string, string];
  const label = `回到「${subject}」`;
  await git(worktree, ['read-tree', '--reset', '-u', target], { env });
  // 目标就是现状时不产生新快照。HEAD 没动，safety 已经把它挂好了，所以不用再挂
  const current = tree === safety.tree
    ? { ...safety, created: false, changedFiles: 0 }
    : await record(worktree, sessionId, tree, safety.tree, safety.commit, null, label, []);
  return { safety, current, label };
}

/** 会话的快照链，新的在前。沿第一父节点走，遇到不属于本会话的提交就停。 */
export async function list(cwd: string, sessionId: string, limit = 1000): Promise<Snapshot[]> {
  const ref = snapshotRef(sessionId);
  if (!(await revParse(cwd, ref))) return [];
  const fmt = '%H%x1f%ct%x1f%s%x1f%(trailers:key=Kite-Session,valueonly,separator=%x2C)%x1f%(trailers:key=Kite-Tool-Use,valueonly,separator=%x2C)%x1e';
  const out = await git(cwd, ['log', '--first-parent', `-n${limit}`, `--format=${fmt}`, ref]);
  const snaps: Snapshot[] = [];
  for (const rec of out.split('\x1e')) {
    const [commit, at, label, owner, tools] = rec.trim().split('\x1f');
    if (!commit || owner?.trim() !== sessionId) break;
    snaps.push({ commit, at: Number(at) * 1000, label: label ?? '', toolUseIds: (tools ?? '').split(',').map((s) => s.trim()).filter(Boolean) });
  }
  return snaps;
}
