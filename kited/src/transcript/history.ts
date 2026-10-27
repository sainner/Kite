import { join } from 'node:path';
import { instanceAgent } from '../agents/definition.ts';
import { readClaudeMessages } from '../claude/history.ts';
import { claudeState, readClaudeControl } from '../claude/control.ts';
import { KiteError } from '../errors.ts';
import type { Bus } from '../events.ts';
import { readJournal } from '../harness/journal.ts';
import type { JournalRecord } from '../harness/types.ts';
import { readClaudeEntries } from '../handoff/claude-records.ts';
import type { ThreadContext } from '../model.ts';
import type { Store } from '../store.ts';
import type { TranscriptFeed } from './feed.ts';
import { TranscriptProjection } from './projection.ts';
import type { DisplayState, History, ThreadActivity } from './protocol.ts';

type ClaudeMessage = Awaited<ReturnType<typeof readClaudeMessages>>[number];
interface Run<T> { steps: T[]; needs?: number; covers: number; at: number }

/**
 * 按段拼接两份原生记录：每份记录只显示自己产生的内容，导入部分由来源记录提供。导入标明来源位置，
 * 一段须等它导入的来源内容显示之后才能显示。
 */
function mergeSegments(journal: JournalRecord[], claude: ClaudeMessage[], positions: Map<string | undefined, number>): Array<JournalRecord | ClaudeMessage> {
  const journalRuns: Run<JournalRecord>[] = [];
  for (const row of journal) {
    if (row.type === 'context.imported' || !journalRuns.length) {
      const last = journalRuns.at(-1);
      if (last) last.covers = row.seq - 1;
      journalRuns.push({ steps: [], covers: Infinity, at: row.at,
        ...(row.type === 'context.imported' ? { needs: positions.get(row.source.through) ?? Infinity } : {}) });
    }
    journalRuns.at(-1)!.steps.push(row);
  }
  const claudeRuns: Run<ClaudeMessage>[] = [];
  let needs: number | undefined;
  for (const message of claude) {
    const position = positions.get(message.uuid) ?? Infinity;
    if (message.kite) {
      const last = claudeRuns.at(-1);
      if (last && last.covers === Infinity) last.covers = position - 1;
      needs = Number(message.kite.through);
      continue;
    }
    if (!claudeRuns.length || needs !== undefined) {
      claudeRuns.push({ steps: [], covers: Infinity, at: message.at, ...(needs !== undefined ? { needs } : {}) });
      needs = undefined;
    }
    claudeRuns.at(-1)!.steps.push(message);
  }
  const merged: Array<JournalRecord | ClaudeMessage> = [];
  let journalEnd = 0;
  let claudeEnd = -1;
  let j = 0;
  let c = 0;
  while (j < journalRuns.length || c < claudeRuns.length) {
    const nextJournal = journalRuns[j];
    const nextClaude = claudeRuns[c];
    const journalReady = !!nextJournal && (nextJournal.needs === undefined || claudeEnd >= nextJournal.needs);
    const claudeReady = !!nextClaude && (nextClaude.needs === undefined || journalEnd >= nextClaude.needs);
    // 两段都就绪或记录不一致时按时间排，不丢显示内容。
    const takeJournal = journalReady === claudeReady ? !nextClaude || (!!nextJournal && nextJournal.at <= nextClaude.at) : journalReady;
    if (takeJournal) { merged.push(...nextJournal!.steps); journalEnd = nextJournal!.covers; j++; }
    else { merged.push(...nextClaude!.steps); claudeEnd = nextClaude!.covers; c++; }
  }
  return merged;
}

/** 历史读取与实时事件共用一份显示投影；加载历史不打开执行后端。 */
export class TranscriptHistory {
  private transcripts = new Map<string, TranscriptProjection>();
  private loadingTranscripts = new Map<string, Promise<TranscriptProjection>>();
  private activities = new Map<string, ThreadActivity>();
  /** 从空闲开始压缩的线程：阶段照显示协议是 running，但压缩不是回合。 */
  private compactingFromIdle = new Set<string>();
  /** 投影被丢掉、等重建的线程：还连着的客户端副本出自旧投影，重建后在线程流里补一份完整历史。 */
  private replaced = new Set<string>();

  constructor(private store: Store, private home: string, bus: Bus, private feed: TranscriptFeed) {
    feed.subscribe((e) => e.type === 'thread.state', (e) => { if (e.type === 'thread.state') this.observe(e.threadId, e.state, e.at); });
    bus.subscribe(undefined, (event) => {
      switch (event.type) {
        case 'workspace.changed':
        case 'workspace.error':
          for (const t of this.store.threads(event.workspaceId)) {
            const transcript = this.transcripts.get(t.id);
            if (event.type === 'workspace.changed') {
              transcript?.configureModel(instanceAgent(t).model.model);
              transcript?.lifecycle(event.status, t.status);
            }
            else transcript?.workspaceError(event.message);
          }
          this.feed.emit(event);
          break;
        case 'thread.changed':
          this.transcripts.get(event.threadId)?.lifecycle(this.store.workspace(event.workspaceId)!.status, event.status);
          this.feed.emit(event);
          break;
        case 'checkout.changed':
        case 'model-accounts.changed':
        case 'library.changed':
        case 'line.inbox':
        case 'line.notification':
        case 'monitor.changed':
        case 'instance.show':
        case 'update.changed':
        case 'mcp.changed':
        case 'workspace.setup':
        case 'workspace.snapshot':
        case 'workspace.adopt':
        case 'workspace.sync':
          this.feed.emit(event);
          break;
        default:
          this.transcripts.get(event.threadId)?.accept(event);
      }
    });
  }

  snapshot(id: string, after?: string): History {
    const t = this.transcripts.get(id);
    if (!t) throw new KiteError('请先加载线程历史', 409);
    return t.snapshot(after);
  }

  /** 切换后端、回退对话之后按原生记录重建，连着的客户端收到一份完整历史；已开始的原生历史不得用显示记录续跑。 */
  async reset(t: ThreadContext): Promise<void> {
    await this.loadingTranscripts.get(t.id);
    this.transcripts.delete(t.id);
    this.replaced.add(t.id);
    const projection = await this.load(t);
    this.feed.emit({ type: 'thread.state', threadId: t.id, state: projection.state() });
  }

  load(t: ThreadContext): Promise<TranscriptProjection> {
    const cached = this.transcripts.get(t.id);
    if (cached) return Promise.resolve(cached);
    const loading = this.loadingTranscripts.get(t.id);
    if (loading) return loading;
    const read = async () => {
      const projection = new TranscriptProjection(t, this.feed);
      const directory = join(this.home, 'sessions', t.id);
      const control = claudeState(readClaudeControl(directory));
      if (t.runtime === 'claude') projection.claudeControl(control);
      else projection.claudeInputs(control);
      const positions = new Map(readClaudeEntries(t.workspace.cwd, t.nativeId).map((entry, index) => [entry.uuid, index]));
      for (const step of mergeSegments(readJournal(join(directory, 'journal.jsonl')), await readClaudeMessages(t.nativeId, t.workspace.cwd), positions)) {
        if ('seq' in step) projection.journal(step);
        else projection.claude(step, step.at);
      }
      // 旧段的记录不决定执行状态，以当前后端为准。
      if (t.runtime === 'claude') projection.claudeControl(control);
      const current = this.store.threadContext(t.id);
      if (!current) throw new KiteError(`没有这个线程：${t.id}`, 404);
      projection.lifecycle(current.workspace.status, current.status);
      projection.setAsks(this.store.asks(t.id));
      projection.finishReplay();
      // 读的途中记录被换掉（forget）的，读出来的只交给这次的调用方，不留作缓存
      if (this.loadingTranscripts.get(t.id) !== promise) return projection;
      this.transcripts.set(t.id, projection);
      this.observe(t.id, projection.state());
      // 连着的客户端收到的新事件会越过新投影的载入时刻，重连时只补变化就补不回旧投影与新投影的差别，这里整份替换
      if (this.replaced.delete(t.id)) this.feed.emit({ type: 'thread.history', ...projection.snapshot() });
      return projection;
    };
    const promise = read().finally(() => { if (this.loadingTranscripts.get(t.id) === promise) this.loadingTranscripts.delete(t.id); });
    this.loadingTranscripts.set(t.id, promise);
    return promise;
  }

  /** 线程的会话记录在磁盘上被整份换掉（流转导入、还原）：丢掉按旧记录建的投影和摘要，下次读时重建。 */
  forget(ids: string[]): void {
    for (const id of ids) {
      this.transcripts.delete(id);
      this.loadingTranscripts.delete(id);
      this.replaced.add(id);
      this.activities.delete(id);
      this.compactingFromIdle.delete(id);
    }
  }

  activity(id: string): ThreadActivity | undefined { return this.activities.get(id); }

  /** 摘要变了才推送；收尾时间只在实时看到回合从执行转为空闲时记录，回放出来的旧结果不算。 */
  private observe(id: string, state: DisplayState, at?: number): void {
    const previous = this.activities.get(id);
    // 从空闲开始的压缩回到空闲时不记收尾；回合中途的自动压缩、压缩完直接接上的回合照常算。
    if (state.compacting && (!previous || previous.phase === 'idle')) this.compactingFromIdle.add(id);
    else if (!state.compacting && state.phase === 'running') this.compactingFromIdle.delete(id);
    const compactionOnly = this.compactingFromIdle.has(id);
    if (state.phase === 'idle') this.compactingFromIdle.delete(id);
    const next: ThreadActivity = { phase: state.phase, waitingForResume: state.waitingForResume,
      // 没回应的请求不阻塞回合，代理停下以后才算在等
      ...(state.waiting ? { waiting: state.waiting.kind } : state.phase === 'idle' && state.asks?.[0] ? { waiting: state.asks[0].kind } : {}),
      ...(state.lastOutcome ? { outcome: state.lastOutcome.kind } : {}), ...(state.error ? { error: true as const } : {}) };
    if (previous && previous.phase === next.phase && previous.waitingForResume === next.waitingForResume && previous.waiting === next.waiting
      && previous.outcome === next.outcome && previous.error === next.error) return;
    const settled = !compactionOnly && at !== undefined && previous !== undefined && previous.phase !== 'idle' && next.phase === 'idle' && next.outcome !== undefined;
    const changedAt = at ?? previous?.changedAt;
    const settledAt = settled ? at : previous?.settledAt;
    if (changedAt !== undefined) next.changedAt = changedAt;
    if (settledAt !== undefined) next.settledAt = settledAt;
    this.activities.set(id, next);
    const workspaceId = this.store.instance(id)?.workspaceId;
    if (workspaceId) this.feed.emit({ type: 'thread.activity', workspaceId, threadId: id, activity: next });
  }
}
