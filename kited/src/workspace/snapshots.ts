/**
 * 工作区快照：把工作树的当前状态存成 commit，链在 refs/kite/snapshots/<工作区> 上。
 * 不用 refs/kite/<工作区>：会话分支叫 kite/<工作区>，git 解析短名时 refs/<名字> 排在 refs/heads/<名字> 前面，
 * 按分支名操作会拿到快照。
 * 用每个工作树自己的私有索引（GIT_INDEX_FILE），不碰用户的 HEAD、分支和暂存区；
 * 索引记着文件的修改时间，下次只需逐个 stat。快照的第一个父节点永远是上一枚快照，
 * agent 自己提交过时另挂当时的 HEAD。调用方负责同一会话内串行。
 */
import { copyFileSync, existsSync, mkdirSync, statSync, utimesSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { KiteError } from '../errors.ts';
import { git, gitTry, isAncestor, KITE_IDENTITY } from './git.ts';

const snapshotRef = (workspaceId: string) => `refs/kite/snapshots/${workspaceId}`;

interface Captured { commit: string; tree: string; created: boolean; changedFiles: number }

export interface Snapshot { commit: string; at: number; label: string; toolUseIds: string[] }

// 每次调用 git 约 10 毫秒，快照在每批工具调用后都要打，agent 等它打完才继续，所以尽量少调
const indexes = new Map<string, string>();
/** 每个工作树最近一个已经在快照链上的 HEAD：HEAD 没动就不用再问它是不是上一枚的祖先。 */
const chainedHeads = new Map<string, string>();

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
function message(workspaceId: string, label: string, toolUseIds: string[]): string {
  // 提交时间只到秒；毫秒时间用来与会话记录对齐（压缩范围的净变化）。
  return [label, '', `Kite-Workspace: ${workspaceId}`, `Kite-At: ${Date.now()}`, ...toolUseIds.map((id) => `Kite-Tool-Use: ${id}`)].join('\n');
}

interface NewSnapshot {
  tree: string;
  /** 上一个状态的树，用来数改了几个文件。 */
  fromTree?: string | null;
  previous?: string | null;
  /** 工作树当时的 HEAD：agent 自己提交过、HEAD 不在快照链上时，另挂成父节点。 */
  head?: string | null;
}

/** 把一棵树记成会话的一枚新快照，挂在 previous 之后。数改动和提交互不依赖，同时做，agent 少等一次 git。 */
async function record(worktree: string, workspaceId: string, r: NewSnapshot, label: string, toolUseIds: string[]): Promise<Captured> {
  const count = git(worktree, r.fromTree
    ? ['diff-tree', '-r', '--name-only', '--no-renames', r.fromTree, r.tree]
    : ['ls-tree', '-r', '--name-only', r.tree]);
  const chain = (async () => {
    const parents: string[] = [];
    if (r.previous) parents.push('-p', r.previous);
    // HEAD 已在链上就不用再查是不是祖先
    if (r.head && chainedHeads.get(worktree) !== r.head && (!r.previous || !(await isAncestor(worktree, r.head, r.previous)))) {
      parents.push('-p', r.head);
    }
    const commit = await git(worktree, ['commit-tree', r.tree, ...parents, '-F', '-'], {
      env: KITE_IDENTITY, input: message(workspaceId, label, toolUseIds),
    });
    // 比较并交换：引用在读取之后被动过就失败，不覆盖
    await git(worktree, ['update-ref', '--no-deref', snapshotRef(workspaceId), commit, r.previous ?? '']);
    // 这枚快照之后，HEAD 已经在链上：要么本来就是祖先，要么刚挂成了父节点
    if (r.head) chainedHeads.set(worktree, r.head);
    return commit;
  })();
  const [files, commit] = await Promise.all([count, chain]);
  return { commit, tree: r.tree, created: true, changedFiles: files.split('\n').filter(Boolean).length };
}

/** 捕获整个工作树。树没变就复用上一枚，不产生新提交。 */
export async function capture(worktree: string, workspaceId: string, label: string, toolUseIds: string[] = []): Promise<Captured> {
  const ref = snapshotRef(workspaceId);
  const [previous, prevTree, head, headTree] = await resolve(worktree, [`${ref}^{commit}`, `${ref}^{tree}`, 'HEAD^{commit}', 'HEAD^{tree}']);
  const env = { GIT_INDEX_FILE: await privateIndex(worktree) };

  if (!existsSync(env.GIT_INDEX_FILE)) {
    // 第一枚从工作树自己的索引起步：刚建的工作树的索引记着文件的修改时间，add 只需逐个 stat，
    // 按树重建的索引没有修改时间，得把每个文件重读一遍。已有快照链（私有索引丢了）才按上一枚重建
    const own = join(dirname(dirname(env.GIT_INDEX_FILE)), 'index');
    if (!previous && existsSync(own)) {
      const { atime, mtime } = statSync(own);
      copyFileSync(own, env.GIT_INDEX_FILE);
      // Git 用索引时间判断同一时刻的文件是否可能已改写；副本时间变新会跳过同长度改动。
      utimesSync(env.GIT_INDEX_FILE, atime, mtime);
    }
    else {
      const base = previous ?? head;
      await git(worktree, base ? ['read-tree', base] : ['read-tree', '--empty'], { env });
    }
  }
  await git(worktree, ['add', '-A', '--', '.'], { env });
  const tree = await git(worktree, ['write-tree'], { env });

  if (previous && prevTree === tree) return { commit: previous, tree, created: false, changedFiles: 0 };
  return record(worktree, workspaceId, { tree, fromTree: prevTree ?? headTree, previous, head }, label, toolUseIds);
}

/**
 * 把工作树整体恢复成某一枚快照：只动文件，不动 HEAD、分支和工作树自己的暂存区。
 * 先捕获一次当前状态，私有索引此时等于「现在」，回退本身因此可以撤销；
 * 再在私有索引上以安全快照为基线做双树更新：现在有而目标没有的文件被删，被忽略的文件不碰。
 * Git 的合并更新仍会覆盖忽略内容，先拒绝这类路径碰撞；双树更新另保护已捕获文件的后续改动。
 * 之后工作树里未被忽略的部分正好是目标那棵树，直接把它记成新的一枚，不用再捕获一遍。
 */
export async function restore(worktree: string, workspaceId: string, target: string): Promise<{ safety: Captured; current: Captured; label: string }> {
  const safety = await capture(worktree, workspaceId, '回退前自动保存');
  const env = { GIT_INDEX_FILE: await privateIndex(worktree) };
  const [tree, subject] = (await git(worktree, ['log', '-1', '--format=%T%x00%s', target])).split('\0') as [string, string];
  const label = `回到「${subject}」`;
  const [ignored, targetFiles, safetyFiles, ignoreCase] = await Promise.all([
    gitTry(worktree, ['ls-files', '--others', '--ignored', '--exclude-standard', '-z'], { env }),
    gitTry(worktree, ['ls-tree', '-r', '-z', target]),
    gitTry(worktree, ['ls-tree', '-r', '-z', safety.commit]),
    git(worktree, ['config', '--bool', '--get', '--default=false', 'core.ignorecase']),
  ]);
  for (const result of [ignored, targetFiles, safetyFiles]) {
    if (result.code !== 0) throw new KiteError(`无法核对回退路径：${result.stderr.trim()}`, 409);
  }
  const pathKey = (path: string) => {
    // ls-files 把被忽略的嵌套仓库列为带 / 的目录；大小写按 Git 检测出的文件系统规则比较。
    const name = path.replace(/\/$/, '');
    return ignoreCase === 'true' ? name.toLowerCase() : name;
  };
  const entries = (output: string) => output.split('\0').filter(Boolean).map((entry) => ({
    mode: entry.slice(0, 6), path: entry.slice(entry.indexOf('\t') + 1),
  }));
  const targetEntries = entries(targetFiles.stdout);
  const files = new Set(targetEntries.map((entry) => pathKey(entry.path)));
  const targetLinks = new Set(targetEntries.filter((entry) => entry.mode === '160000').map((entry) => pathKey(entry.path)));
  // 捕获可能把原文件改记为嵌套仓库的 gitlink；它只保存提交号，内部内容没有进入安全快照。
  const nested = entries(safetyFiles.stdout).filter((entry) => entry.mode === '160000' && !targetLinks.has(pathKey(entry.path)));
  const directories = new Set<string>();
  for (const file of files) {
    for (let directory = dirname(file); directory !== '.'; directory = dirname(directory)) directories.add(directory);
  }
  for (const file of [...ignored.stdout.split('\0').filter(Boolean), ...nested.map((entry) => entry.path)]) {
    // 同名文件、文件挡住目标目录、目标文件覆盖整个本地目录，都必须保住未入快照的内容。
    const key = pathKey(file);
    let collision = directories.has(key);
    for (let path = key; !collision && path !== '.'; path = dirname(path)) collision = files.has(path);
    if (collision) throw new KiteError(`回退会覆盖未被快照保存的本地内容，请先移走或保存：${file}`, 409);
  }
  await git(worktree, ['read-tree', '-m', '-u', safety.commit, target], { env });
  // 目标就是现状时不产生新快照。HEAD 没动，safety 已经把它挂好了，所以不用再挂
  const current = tree === safety.tree
    ? { ...safety, created: false, changedFiles: 0 }
    : await record(worktree, workspaceId, { tree, fromTree: safety.tree, previous: safety.commit }, label, []);
  return { safety, current, label };
}

/** 找本会话的一枚快照，commit 可以是缩写；不存在或不属于本会话返回 null。 */
export async function findSnapshot(cwd: string, workspaceId: string, commit: string): Promise<string | null> {
  // 只收提交号，别的写法（分支名、以 - 开头的参数）一律不认
  if (!/^[0-9a-f]{4,64}$/i.test(commit)) return null;
  const r = await gitTry(cwd, ['log', '-1', '--format=%H%x1f%(trailers:key=Kite-Workspace,valueonly)', commit, '--']);
  const [full, owner] = r.stdout.trim().split('\x1f');
  return r.code === 0 && full && owner?.trim() === workspaceId ? full : null;
}

/** 会话的快照链，新的在前，最多 1000 枚。沿第一父节点走，遇到不属于本会话的提交就停。 */
export async function list(cwd: string, workspaceId: string): Promise<Snapshot[]> {
  const fmt = '%H%x1f%ct%x1f%s%x1f%(trailers:key=Kite-Workspace,valueonly,separator=%x2C)%x1f%(trailers:key=Kite-Tool-Use,valueonly,separator=%x2C)%x1f%(trailers:key=Kite-At,valueonly)%x1e';
  // 还没有快照时引用不存在，log 失败
  const r = await gitTry(cwd, ['log', '--first-parent', '-n1000', `--format=${fmt}`, snapshotRef(workspaceId)]);
  if (r.code !== 0) return [];
  const out = r.stdout.trim();
  const snaps: Snapshot[] = [];
  for (const rec of out.split('\x1e')) {
    const [commit, at, label, owner, tools, ms] = rec.trim().split('\x1f');
    if (!commit || owner?.trim() !== workspaceId) break;
    snaps.push({ commit, at: Number(ms?.trim()) || Number(at) * 1000, label: label ?? '', toolUseIds: (tools ?? '').split(',').map((s) => s.trim()).filter(Boolean) });
  }
  return snaps;
}

/**
 * 两个时刻之间工作区的净变化：各取当时最近的一枚快照比较，每行「状态 路径 (+增 -删)」，最多 limit 行。
 * 没有更早的快照或两枚相同时返回 undefined。
 */
export async function changesBetween(cwd: string, workspaceId: string, from: number, to: number, limit = 200): Promise<string | undefined> {
  const snaps = await list(cwd, workspaceId);
  const base = snaps.find((snap) => snap.at <= from);
  const end = snaps.find((snap) => snap.at <= to);
  if (!base || !end || base.commit === end.commit) return undefined;
  const [status, numstat] = await Promise.all([
    git(cwd, ['diff-tree', '-r', '--no-renames', '--name-status', '-z', base.commit, end.commit]),
    git(cwd, ['diff-tree', '-r', '--no-renames', '--numstat', '-z', base.commit, end.commit]),
  ]);
  const counts = new Map<string, string>();
  const stats = numstat.split('\0');
  for (let index = 0; index + 1 < stats.length; index += 1) {
    const [added, deleted, path] = stats[index]!.split('\t');
    if (path === undefined) continue;
    counts.set(path, added === '-' ? '二进制' : `+${added} -${deleted}`);
  }
  const names: Record<string, string> = { A: '新增', M: '修改', D: '删除', T: '类型变化' };
  const fields = status.split('\0').filter(Boolean);
  const lines: string[] = [];
  for (let index = 0; index + 1 < fields.length; index += 2) {
    const path = fields[index + 1]!;
    lines.push(`${names[fields[index]!] ?? fields[index]} ${path}${counts.has(path) ? ` (${counts.get(path)})` : ''}`);
  }
  if (!lines.length) return undefined;
  return (lines.length > limit ? [...lines.slice(0, limit), `……另有 ${lines.length - limit} 个文件`] : lines).join('\n');
}
