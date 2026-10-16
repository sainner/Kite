/**
 * 工作区副本：执行设备上工作区的执行数据——数据库行、各线程的会话目录（journal、控制状态、命令日志）、Claude 原生记录与历史差异——
 * 由其他工作机持续拉取，按文件增量续传；快照链、工作区分支与根工作区的主线经组网从执行设备的检出拉（workspace/peer-git.ts）。
 * 交接时目标只要把副本补到末尾，执行权一递就能接着做；执行设备失联时，用户可以让别的工作机用手上的副本强制接管。
 * 副本只是跟进，权威在执行设备，epoch 低的不覆盖高的。副本在本机的布局与流转记录（records.ts）相同，还原沿用同一套安装。
 * 见 docs/分布式架构.md「数据的归属与同步」。
 */
import { createHash } from 'node:crypto';
import { appendFileSync, closeSync, existsSync, mkdirSync, openSync, readFileSync, readSync, readdirSync, realpathSync, renameSync, rmSync, statSync, truncateSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { readClaudeControl } from '../claude/control.ts';
import { claudeRecordPath } from '../handoff/claude-records.ts';
import { readJournal } from '../harness/journal.ts';
import type { AgentInstance, Workspace, WorkspaceStatus } from '../model.ts';
import { peerJSON, type Peer, type PeerFetch } from '../peer-fetch.ts';
import type { WorkspaceRows } from '../store.ts';
import { revParse } from '../workspace/git.ts';
import type { RecordsManifest } from './records.ts';

/** 跟进方手上一个文件的情况：执行设备上的大小与修改时刻（复制时的），以及本地这份末尾一段的摘要，用来确认能接着追加。 */
export interface FileState { size: number; mtime: number; hash: string }
export interface ReplicaEntry { workspaceId: string; projectId: string; epoch: number; status: WorkspaceStatus; digest: string }
/** 一页增量。数据库行、清单、摘要与 Git 的位置只在最后一页（more 为假）带。 */
export interface ReplicaPage {
  epoch: number;
  /** 变了的文件：offset 为 0 是整份，否则从 offset 起追加；size 是追加后的大小，mtime 是执行设备上的（只取了一段时为 0，下页接着取）。 */
  files: Array<{ path: string; offset: number; size: number; mtime: number; data: string }>;
  removed: string[];
  more: boolean;
  digest?: string;
  manifest?: RecordsManifest;
  rows?: WorkspaceRows;
  /** 执行设备检出里的快照链与工作区分支，跟进方变了才取。 */
  git?: { snapshots: string | null; branch: string | null };
}
/** 副本对应的 Git：快照链与工作区分支，取到本机检出的 refs/kite/replica/<工作区>/ 下。 */
export const replicaRef = (workspaceId: string, name: 'snapshots' | 'branch') => `refs/kite/replica/${workspaceId}/${name}`;

/** 一页最多带这么多字节；大文件分几页取完。 */
const PAGE_BYTES = 8 * 1024 * 1024;
/** 判断能否接着追加时，比对已有部分末尾这么长的一段。 */
const TAIL_BYTES = 64 * 1024;
const sha256 = (data: Uint8Array | string) => createHash('sha256').update(data).digest('hex');

function readRange(fd: number, start: number, end: number): Buffer {
  const buffer = Buffer.alloc(end - start);
  let read = 0;
  while (read < buffer.length) {
    const n = readSync(fd, buffer, read, buffer.length - read, start + read);
    if (n === 0) break;
    read += n;
  }
  return buffer.subarray(0, read);
}

/** 文件前 size 字节里末尾一段的摘要。 */
function tailHash(fd: number, size: number): string { return sha256(readRange(fd, Math.max(0, size - TAIL_BYTES), size)); }

/** 执行设备一侧：副本要的文件，键是副本里的相对路径，值是本机路径。 */
export function replicaSources(home: string, workspace: Workspace, threads: AgentInstance[]): Map<string, string> {
  const sources = new Map<string, string>();
  const walk = (root: string, prefix: string) => {
    if (!existsSync(root)) return;
    for (const name of readdirSync(root, { recursive: true, encoding: 'utf8' })) {
      const path = join(root, name);
      if (statSync(path).isFile()) sources.set(`${prefix}/${name}`, path);
    }
  };
  for (const thread of threads) {
    const session = join(home, 'sessions', thread.id);
    for (const name of ['journal.jsonl', 'metadata.json', 'claude-control.json']) {
      if (existsSync(join(session, name))) sources.set(`sessions/${thread.id}/${name}`, join(session, name));
    }
    walk(join(session, 'commands'), `sessions/${thread.id}/commands`);
    const claude = existsSync(workspace.cwd) ? claudeRecordPath(workspace.cwd, thread.nativeId) : undefined;
    if (claude) sources.set(`claude/${thread.nativeId}.jsonl`, claude);
  }
  walk(join(home, 'diffs', workspace.id), 'diffs');
  return sources;
}

/** 控制状态里的进程登记只对本机有意义，副本里清空；它很小，每次整份给。 */
const controlFile = (rel: string) => rel.endsWith('/claude-control.json');

/** 执行设备一侧：副本的摘要，数据库行、状态或任一文件变了就变。 */
export function replicaDigest(workspace: Workspace, rows: WorkspaceRows, sources: Map<string, string>): string {
  const files = [...sources].sort(([a], [b]) => a.localeCompare(b)).map(([rel, path]) => {
    const stat = statSync(path);
    return [rel, stat.size, stat.mtimeMs];
  });
  return sha256(JSON.stringify({ epoch: workspace.epoch, status: workspace.status, rows, files }));
}

/**
 * 执行设备一侧：按跟进方手上的情况给一页文件增量。只长不改的文件（journal、命令日志）末尾一段对得上就从原来的末尾接着给；
 * 单个文件超过一页的只给一段，修改时刻记为 0，下一页接着取。
 */
export function replicaFiles(sources: Map<string, string>, known: Record<string, FileState>): Pick<ReplicaPage, 'files' | 'removed' | 'more'> {
  const files: ReplicaPage['files'] = [];
  let bytes = 0;
  let more = false;
  for (const [rel, path] of [...sources].sort(([a], [b]) => a.localeCompare(b))) {
    const stat = statSync(path);
    const held = known[rel];
    if (held && held.size === stat.size && held.mtime === stat.mtimeMs) continue;
    if (bytes >= PAGE_BYTES) { more = true; break; }
    if (controlFile(rel)) {
      const data = Buffer.from(JSON.stringify({ ...JSON.parse(readFileSync(path, 'utf8')), processes: [] }));
      // 大小记执行设备上原文件的，没变就不再给。
      files.push({ path: rel, offset: 0, size: stat.size, mtime: stat.mtimeMs, data: data.toString('base64') });
      bytes += data.length;
      continue;
    }
    const fd = openSync(path, 'r');
    try {
      const append = !!held && held.size > 0 && held.size <= stat.size && tailHash(fd, held.size) === held.hash;
      const offset = append ? held.size : 0;
      const end = Math.min(stat.size, offset + PAGE_BYTES - bytes);
      const data = readRange(fd, offset, end);
      const partial = offset + data.length < stat.size;
      files.push({ path: rel, offset, size: offset + data.length, mtime: partial ? 0 : stat.mtimeMs, data: data.toString('base64') });
      bytes += data.length;
      if (partial) { more = true; break; }
    } finally { closeSync(fd); }
  }
  return { files, removed: Object.keys(known).filter((rel) => !sources.has(rel)), more };
}

/** harness 的通知游标与它恢复时的算法一致：请求开始记录里交接的通知，以及跨后端导入时带过来的游标。按大小与修改时刻缓存。 */
const cursors = new Map<string, { size: number; mtime: number; cursor: number }>();
function journalCursor(path: string): number {
  if (!existsSync(path)) return 0;
  const stat = statSync(path);
  const cached = cursors.get(path);
  if (cached && cached.size === stat.size && cached.mtime === stat.mtimeMs) return cached.cursor;
  let cursor = 0;
  for (const row of readJournal(path)) {
    if (row.type === 'request.started') for (const notification of row.notifications ?? []) cursor = Math.max(cursor, notification.sequence ?? 0);
    if (row.type === 'context.imported') cursor = Math.max(cursor, row.notificationCursor);
  }
  cursors.set(path, { size: stat.size, mtime: stat.mtimeMs, cursor });
  return cursor;
}

/** 执行设备一侧：副本的清单，装到目标机时用。head 是根工作区此刻的主线。 */
export function replicaManifest(options: { home: string; machine: string; projectId: string; workspace: Workspace; head: string | null;
  threads: AgentInstance[] }): RecordsManifest {
  const { home, workspace } = options;
  return {
    version: 1, workspaceId: workspace.id, epoch: workspace.epoch, machine: options.machine, projectId: options.projectId,
    kind: workspace.kind, name: workspace.name, branch: workspace.branch, base: workspace.base,
    // Claude 原生记录里的 cwd 是进程的真实路径。
    cwd: existsSync(workspace.cwd) ? realpathSync(workspace.cwd) : workspace.cwd, head: options.head,
    threads: options.threads.map((thread) => {
      const session = join(home, 'sessions', thread.id);
      return { instanceId: thread.id, runtime: thread.runtime, nativeId: thread.nativeId,
        cursor: thread.runtime === 'claude' ? readClaudeControl(session).through : journalCursor(join(session, 'journal.jsonl')) };
    }),
    at: Date.now(),
  };
}

/** refsPending：最后一页指到的快照链或工作区分支还没取到本机检出（还没有检出，或取失败了），摘要没变也要再拉。 */
interface ReplicaState { holder: string; epoch: number; digest: string; complete: boolean; projectId?: string; refsPending?: boolean; files: Record<string, FileState> }

/** 跟进方一侧：本机手上的各工作区副本，放在 <home>/replicas/<工作区>/，目录布局同流转记录。 */
export class ReplicaStore {
  constructor(private root: string) {}

  dir(workspaceId: string): string { return join(this.root, workspaceId); }

  state(workspaceId: string): ReplicaState | undefined {
    const path = join(this.dir(workspaceId), 'state.json');
    return existsSync(path) ? JSON.parse(readFileSync(path, 'utf8')) : undefined;
  }

  ids(): string[] { return existsSync(this.root) ? readdirSync(this.root) : []; }

  /**
   * 写进一页；换了执行设备或 epoch 时照样按内容接着追加，全部取完（最后一页）才记下摘要。
   * 追加前本地文件要正好停在 offset：长了截掉多出的部分；短了说明本地这份被动过，丢掉，副本记为不完整，下一轮整份重取。
   */
  apply(workspaceId: string, holder: string, page: ReplicaPage): boolean {
    const dir = this.dir(workspaceId);
    const previous = this.state(workspaceId);
    const state: ReplicaState = { holder, epoch: page.epoch, digest: '', complete: false, files: previous?.files ?? {},
      ...(previous?.projectId ? { projectId: previous.projectId } : {}), refsPending: previous?.refsPending ?? false };
    mkdirSync(dir, { recursive: true, mode: 0o700 });
    let broken = false;
    for (const file of page.files) {
      const path = join(dir, file.path);
      mkdirSync(dirname(path), { recursive: true });
      const data = Buffer.from(file.data, 'base64');
      if (file.offset > 0) {
        const size = existsSync(path) ? statSync(path).size : 0;
        if (size < file.offset) {
          rmSync(path, { force: true });
          delete state.files[file.path];
          broken = true;
          continue;
        }
        if (size > file.offset) truncateSync(path, file.offset);
        appendFileSync(path, data);
      } else writeFileSync(path, data);
      const fd = openSync(path, 'r');
      try { state.files[file.path] = { size: file.size, mtime: file.mtime, hash: tailHash(fd, file.size) }; } finally { closeSync(fd); }
    }
    for (const rel of page.removed) {
      rmSync(join(dir, rel), { force: true });
      delete state.files[rel];
    }
    if (page.rows) writeFileSync(join(dir, 'rows.json'), JSON.stringify(page.rows));
    if (page.manifest) {
      writeFileSync(join(dir, 'manifest.json'), JSON.stringify(page.manifest));
      state.projectId = page.manifest.projectId;
    }
    if (!page.more && !broken) { state.complete = true; state.digest = page.digest ?? ''; }
    if (!page.more) state.refsPending = !!(page.git?.snapshots || page.git?.branch);
    this.write(workspaceId, state);
    return state.complete;
  }

  /** 最后一页指到的 Git 已取到本机检出。 */
  refsFetched(workspaceId: string): void {
    const state = this.state(workspaceId);
    if (state?.refsPending) this.write(workspaceId, { ...state, refsPending: false });
  }

  private write(workspaceId: string, state: ReplicaState): void {
    const temporary = join(this.dir(workspaceId), 'state.json.tmp');
    writeFileSync(temporary, JSON.stringify(state));
    renameSync(temporary, join(this.dir(workspaceId), 'state.json'));
  }

  remove(workspaceId: string): void { rmSync(this.dir(workspaceId), { recursive: true, force: true }); }
}

/**
 * 跟进方一侧的轮询：定时向各台在线的工作机要它持有的工作区清单，摘要变了就按文件增量拉，再从它的检出取变了的快照链与工作区分支
 * （本机有这个项目的检出时；检出后来才有、或上次取失败的，摘要没变也再拉一次补上）。同一工作区出现在几台上时跟 epoch 最高的那台；本机自己持有的不跟。各台之间并行，同一工作区同时只拉一份。
 * 执行设备在线却不再列出的（已归档或流转回本机），副本删掉。
 */
export class Replicas {
  private timer?: Timer;
  private running?: Promise<void>;
  private closed = false;
  /** 正在拉的工作区；交接时只等同一工作区的那一次。 */
  private pulling = new Map<string, Promise<void>>();
  /** 每台连不上时只记一次日志。 */
  private failing = new Set<string>();
  /** 正在本机还原的工作区：轮询不拉也不删它的副本。 */
  private inUse = new Set<string>();

  constructor(readonly store: ReplicaStore, private deps: {
    /** 在线的其他工作机。 */
    holders(): Peer[];
    /** 本机此刻持有的工作区（未流转走、未归档）的 epoch；不持有为 undefined。 */
    held(workspaceId: string): number | undefined;
    /** 本机这个项目的检出目录；没有时不取 Git。 */
    checkout(projectId: string): string | undefined;
    fetch: PeerFetch;
    fetchRefs(cwd: string, holder: Peer, projectId: string, specs: string[]): Promise<void>;
  }) {}

  start(intervalMs = 15_000): void {
    this.timer = setInterval(() => void this.sync(), intervalMs);
    this.timer.unref();
    void this.sync();
  }

  async close(): Promise<void> {
    this.closed = true;
    clearInterval(this.timer);
    await Promise.all([this.running, ...this.pulling.values()]);
  }

  /** 跟进一轮；进行中时等这一轮结束。 */
  sync(): Promise<void> {
    if (this.closed) return Promise.resolve();
    this.running ??= this.round().finally(() => { this.running = undefined; });
    return this.running;
  }

  /** 交接时把副本补到执行设备的末尾：执行设备已停下工作区，内容不再变。排在正在进行的那次拉取之后。 */
  catchUp(holder: Peer, workspaceId: string): Promise<void> { return this.pull(holder, workspaceId); }

  /**
   * 还原期间占用副本：工作区记录进入本机后 held 已经给出它的 epoch，轮询照常会当成本机持有而删掉副本；
   * 占用期间不删也不拉，还原失败回滚后副本还在。同一工作区的还原由调用方串行。
   */
  async using<T>(workspaceId: string, action: () => Promise<T>): Promise<T> {
    this.inUse.add(workspaceId);
    try { return await action(); } finally { this.inUse.delete(workspaceId); }
  }

  private async round(): Promise<void> {
    const listings = await Promise.all(this.deps.holders().map(async (holder) => {
      try {
        const entries = await peerJSON<ReplicaEntry[]>(this.deps.fetch, holder, '/replica', { stallMs: 20_000 });
        this.failing.delete(holder.id);
        return { holder, entries };
      } catch (error) {
        if (!this.failing.has(holder.id)) console.warn(`[工作区副本] 读 ${holder.id} 的清单失败：${(error as Error).message}`);
        this.failing.add(holder.id);
        return { holder, entries: undefined };
      }
    }));
    const latest = new Map<string, { holder: Peer; entry: ReplicaEntry }>();
    for (const { holder, entries } of listings) {
      for (const entry of entries ?? []) {
        const current = latest.get(entry.workspaceId);
        if (!current || entry.epoch > current.entry.epoch) latest.set(entry.workspaceId, { holder, entry });
      }
    }
    const due = [...latest.values()].filter(({ holder, entry }) => {
      if (this.inUse.has(entry.workspaceId) || this.pulling.has(entry.workspaceId)) return false;
      if ((this.deps.held(entry.workspaceId) ?? 0) >= entry.epoch) return false;
      const state = this.store.state(entry.workspaceId);
      if (state && state.epoch > entry.epoch) return false;
      const current = state?.holder === holder.id && state.epoch === entry.epoch && state.digest === entry.digest;
      return !current || (!!state.refsPending && !!this.deps.checkout(entry.projectId));
    });
    // 各台之间并行，同一台上的逐个拉，免得一台的大文件拖住别的。
    const byHolder = Map.groupBy(due, ({ holder }) => holder.id);
    await Promise.all([...byHolder.values()].map(async (items) => {
      for (const { holder, entry } of items) {
        if (this.closed) return;
        try { await this.pull(holder, entry.workspaceId); }
        catch (error) { console.warn(`[工作区副本] 从 ${holder.id} 跟进工作区 ${entry.workspaceId} 失败：${(error as Error).message}`); }
      }
    }));
    const answered = new Set(listings.filter((listing) => listing.entries).map((listing) => listing.holder.id));
    for (const id of this.store.ids()) {
      if (this.inUse.has(id) || this.pulling.has(id)) continue;
      const state = this.store.state(id);
      const held = this.deps.held(id);
      const ours = held !== undefined && !!state && held >= state.epoch;
      if (latest.has(id) && !ours) continue;
      if (!state || answered.has(state.holder) || ours) this.store.remove(id);
    }
  }

  /** 拉一个工作区；同一工作区的几次拉取依次进行，页按本地已有的接着追加，交错了会重复追加。 */
  private pull(holder: Peer, workspaceId: string): Promise<void> {
    const previous = this.pulling.get(workspaceId)?.catch(() => {});
    const running = (async () => {
      await previous;
      let page: ReplicaPage;
      for (let retried = false; ;) {
        page = await peerJSON<ReplicaPage>(this.deps.fetch, holder, `/replica/${workspaceId}`,
          { json: { known: this.store.state(workspaceId)?.files ?? {} }, stallMs: 120_000 });
        const complete = this.store.apply(workspaceId, holder.id, page);
        if (this.closed || (!page.more && (complete || retried))) break;
        // 本地被动过的文件丢掉了，再取一次整份。
        if (!page.more) retried = true;
      }
      const projectId = page.manifest?.projectId;
      const checkout = projectId && this.deps.checkout(projectId);
      if (!checkout || !page.git) return;
      const specs: string[] = [];
      for (const [name, sha, ref] of [['snapshots', page.git.snapshots, `refs/kite/snapshots/${workspaceId}`],
        ['branch', page.git.branch, page.manifest?.branch ? `refs/heads/${page.manifest.branch}` : null]] as const) {
        if (sha && ref && await revParse(checkout, replicaRef(workspaceId, name)) !== sha) specs.push(`+${ref}:${replicaRef(workspaceId, name)}`);
      }
      await this.deps.fetchRefs(checkout, holder, projectId, specs);
      this.store.refsFetched(workspaceId);
    })().finally(() => { if (this.pulling.get(workspaceId) === running) this.pulling.delete(workspaceId); });
    this.pulling.set(workspaceId, running);
    return running;
  }
}
