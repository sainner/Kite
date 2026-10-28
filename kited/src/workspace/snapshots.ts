/**
 * 工作区快照：把工作树的当前状态存成 commit，链在 refs/kite/snapshots/<工作区> 上。
 * 不用 refs/kite/<工作区>：会话分支叫 kite/<工作区>，git 解析短名时 refs/<名字> 排在 refs/heads/<名字> 前面，
 * 按分支名操作会拿到快照。
 * 用每个工作树自己的私有索引（GIT_INDEX_FILE），不碰用户的 HEAD、分支和暂存区；
 * 索引记着文件的修改时间，下次只需逐个 stat。快照的第一个父节点永远是上一枚快照，
 * agent 自己提交过时另挂当时的 HEAD。调用方负责同一会话内串行。
 */
import { copyFileSync, existsSync, lstatSync, mkdirSync, statSync, utimesSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { KiteError } from '../errors.ts';
import { git, gitTry, isAncestor, KITE_IDENTITY } from './git.ts';

export const snapshotRef = (workspaceId: string) => `refs/kite/snapshots/${workspaceId}`;

interface Captured {
  commit: string; tree: string; created: boolean; changedFiles: number;
  /** 这次因为太大没进快照的文件，见 SNAPSHOT_FILE_LIMIT。 */
  skipped?: string[];
}

/**
 * 单个文件超过这个大小、项目 Git 又没跟踪的，不进快照，与被忽略的文件一样：回退不碰，不随副本流转（docs/成果查看与位置.md「大文件」）。
 * 快照在每批工具调用后进行，agent 等它完成；压缩过的媒体每改一次就全量存一份。
 */
export const SNAPSHOT_FILE_LIMIT = 10 * 1024 * 1024;

/** threadId 是触发它的线程；工作区里几个线程并行时，内容可能含其他线程的改动。 */
export interface Snapshot { commit: string; at: number; label: string; toolUseIds: string[]; threadId?: string }

// 每次调用 git 约 10 毫秒，快照在每批工具调用后都要打，agent 等它打完才继续，所以尽量少调
const indexes = new Map<string, string>();
/** 每个工作树最近一个已经在快照链上的 HEAD：HEAD 没动就不用再问它是不是上一枚的祖先。 */
const chainedHeads = new Map<string, string>();

/**
 * 工作树删掉或在同一路径重建、快照链被流转来的材料替换时调用：git 目录可能换了名字，链上的 HEAD 也可能不再在新链上，
 * 两份缓存都按路径记着旧值，不清掉就会往已删除的 git 目录写索引锁，或漏挂 HEAD。
 */
export function forgetWorktree(worktree: string): void {
  indexes.delete(worktree);
  chainedHeads.delete(worktree);
}

/** 工作树自己的 git 目录下的 kite/index。同一工作树的 git 目录不会变，查一次就记住；删掉重建时见 forgetWorktree。 */
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
function message(workspaceId: string, label: string, toolUseIds: string[], threadId?: string): string {
  // 提交时间只到秒；毫秒时间用来与会话记录对齐（压缩范围的净变化）。
  return [label, '', `Kite-Workspace: ${workspaceId}`, `Kite-At: ${Date.now()}`, ...(threadId ? [`Kite-Thread: ${threadId}`] : []),
    ...toolUseIds.map((id) => `Kite-Tool-Use: ${id}`)].join('\n');
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
async function record(worktree: string, workspaceId: string, r: NewSnapshot, label: string, toolUseIds: string[], threadId?: string): Promise<Captured> {
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
      env: KITE_IDENTITY, input: message(workspaceId, label, toolUseIds, threadId),
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

/**
 * 这次要排除的大文件：私有索引看来是新增或改过的文件里，超过上限、项目 HEAD 里也没有的。
 * indexed 是其中已经在私有索引里的（上限以内时进过快照），要从索引拿掉。
 */
async function oversized(worktree: string, env: Record<string, string>): Promise<{ paths: string[]; indexed: string[] }> {
  // -t 给每行标上 ?（索引里没有）或 C（索引里有、工作树改过）
  const listed = await gitTry(worktree, ['ls-files', '-z', '-t', '--others', '--modified', '--exclude-standard'], { env });
  if (listed.code !== 0) throw new Error(`git ls-files 失败（${listed.code}）：${listed.stderr.trim()}`);
  const large: { path: string; indexed: boolean }[] = [];
  for (const entry of listed.stdout.split('\0')) {
    const path = entry.slice(2);
    if (!path) continue;
    try {
      const stat = lstatSync(join(worktree, path));
      if (stat.isFile() && stat.size > SNAPSHOT_FILE_LIMIT) large.push({ path, indexed: entry[0] !== '?' });
    } catch { /* 删掉了。 */ }
  }
  // 含换行的路径没法逐行查，当作项目没跟踪
  const tracked = large.length ? await resolve(worktree, large.map(({ path }) => path.includes('\n') ? 'HEAD:' : `HEAD:${path}`)) : [];
  const kept = large.filter(({ path }, index) => path.includes('\n') || tracked[index] === null);
  return { paths: kept.map(({ path }) => path), indexed: kept.filter(({ indexed }) => indexed).map(({ path }) => path) };
}

/** 捕获整个工作树。树没变就复用上一枚，不产生新提交。 */
export async function capture(worktree: string, workspaceId: string, label: string, toolUseIds: string[] = [], threadId?: string): Promise<Captured> {
  const ref = snapshotRef(workspaceId);
  const env = { GIT_INDEX_FILE: await privateIndex(worktree) };
  const fresh = !existsSync(env.GIT_INDEX_FILE);
  // 私有索引已经在的时候，找大文件和查引用同时做，agent 少等一次 git
  const scan = fresh ? undefined : oversized(worktree, env);
  scan?.catch(() => undefined);
  const [previous, prevTree, head, headTree] = await resolve(worktree, [`${ref}^{commit}`, `${ref}^{tree}`, 'HEAD^{commit}', 'HEAD^{tree}']);

  if (fresh) {
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
  const large = await (scan ?? oversized(worktree, env));
  if (large.indexed.length) {
    await git(worktree, ['rm', '--cached', '-f', '-q', '--ignore-unmatch', '--pathspec-from-file=-', '--pathspec-file-nul'],
      { env, input: large.indexed.map((path) => `:(literal)${path}`).join('\0') });
  }
  await git(worktree, large.paths.length ? ['add', '-A', '--pathspec-from-file=-', '--pathspec-file-nul'] : ['add', '-A', '--', '.'],
    { env, ...(large.paths.length ? { input: ['.', ...large.paths.map((path) => `:(exclude,literal)${path}`)].join('\0') } : {}) });
  const tree = await git(worktree, ['write-tree'], { env });

  const skipped = large.paths.length ? { skipped: large.paths } : {};
  if (previous && prevTree === tree) return { commit: previous, tree, created: false, changedFiles: 0, ...skipped };
  return { ...await record(worktree, workspaceId, { tree, fromTree: prevTree ?? headTree, previous, head }, label, toolUseIds, threadId), ...skipped };
}

/**
 * 把工作树整体恢复成某一枚快照：只动文件，不动 HEAD、分支和工作树自己的暂存区。
 * 先捕获一次当前状态，私有索引此时等于「现在」，回退本身因此可以撤销；
 * 再在私有索引上以安全快照为基线做双树更新：现在有而目标没有的文件被删，被忽略的和太大没进快照的文件不碰。
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
  for (const file of [...ignored.stdout.split('\0').filter(Boolean), ...nested.map((entry) => entry.path), ...safety.skipped ?? []]) {
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

/**
 * 回退对话时文件该回到的快照：作废的工具调用最早改出的那一枚的前一枚。snapshots 是 list 的结果（新的在前），
 * undone 是会被撤掉的那几枚，含其他线程打的。作废的调用没改过文件时为 undefined。
 */
export function rewindTarget(snapshots: Snapshot[], calls: string[]): { target: Snapshot; undone: Snapshot[] } | undefined {
  const dropped = new Set(calls);
  const first = snapshots.findLastIndex((snapshot) => snapshot.toolUseIds.some((id) => dropped.has(id)));
  if (first < 0) return undefined;
  const target = snapshots[first + 1];
  if (!target) throw new KiteError('找不到代理处理这条消息之前的快照', 409);
  return { target, undone: snapshots.slice(0, first + 1) };
}

/** 找本会话的一枚快照，commit 可以是缩写；不存在或不属于本会话返回 null。 */
export async function findSnapshot(cwd: string, workspaceId: string, commit: string): Promise<string | null> {
  // 只收提交号，别的写法（分支名、以 - 开头的参数）一律不认
  if (!/^[0-9a-f]{4,64}$/i.test(commit)) return null;
  const r = await gitTry(cwd, ['log', '-1', '--format=%H%x1f%(trailers:key=Kite-Workspace,valueonly)', commit, '--']);
  const [full, owner] = r.stdout.trim().split('\x1f');
  return r.code === 0 && full && owner?.trim() === workspaceId ? full : null;
}

const trailer = (key: string) => `%(trailers:key=${key},valueonly,separator=%x2C)`;
/** git log 里一枚快照的字段（--format 用，以 \x1f 分隔，不带记录分隔符；尾注都带 separator，不会多出换行），parseSnapshot 按同样的顺序读。 */
export const snapshotFormat = ['%H', '%ct', '%s', ...['Kite-Workspace', 'Kite-At', 'Kite-Thread', 'Kite-Tool-Use'].map(trailer)].join('%x1f');

/** 按 snapshotFormat 读一条记录（见 message）；owner 是它所属的工作区，不是快照的提交为空。 */
export function parseSnapshot(fields: string): { snapshot: Snapshot; owner: string } | undefined {
  const [commit, seconds, label, owner, ms, thread, tools] = fields.trim().split('\x1f');
  if (!commit) return undefined;
  return { owner: owner?.trim() ?? '', snapshot: { commit, at: Number(ms?.trim()) || Number(seconds) * 1000, label: label ?? '',
    toolUseIds: (tools ?? '').split(',').map((s) => s.trim()).filter(Boolean), ...(thread?.trim() ? { threadId: thread.trim() } : {}) } };
}

/**
 * 快照链外的第一条提交，即第一枚快照的第一父节点，多是工作区开始时项目的 HEAD；按同 list 的规则沿第一父节点找。
 * 只读提交说明、不比树，走到它就停。链一直到根（开始时项目还没有提交）时为 null，还没有快照时为 undefined。
 */
export async function chainBase(cwd: string, workspaceId: string): Promise<string | null | undefined> {
  const owner = `^Kite-Workspace: ${workspaceId.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}$`;
  const r = await gitTry(cwd, ['rev-list', '-1', '--first-parent', '--invert-grep', '-E', `--grep=${owner}`, snapshotRef(workspaceId)]);
  return r.code === 0 ? r.stdout.trim() || null : undefined;
}

/** 会话的快照链，新的在前，最多 limit 枚（Infinity 不限）。沿第一父节点走，遇到不属于本会话的提交就停。 */
export async function list(cwd: string, workspaceId: string, limit = 1000): Promise<Snapshot[]> {
  // 还没有快照时引用不存在，log 失败
  const r = await gitTry(cwd, ['log', '--first-parent', ...Number.isFinite(limit) ? [`-n${limit}`] : [],
    `--format=${snapshotFormat}%x1e`, snapshotRef(workspaceId)]);
  if (r.code !== 0) return [];
  const snaps: Snapshot[] = [];
  for (const rec of r.stdout.split('\x1e')) {
    const parsed = parseSnapshot(rec);
    if (!parsed || parsed.owner !== workspaceId) break;
    snaps.push(parsed.snapshot);
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
