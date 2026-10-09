import { join } from 'node:path';
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
import type { History } from './protocol.ts';

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

  constructor(private store: Store, private home: string, bus: Bus, private feed: TranscriptFeed) {
    bus.subscribe(undefined, (event) => {
      switch (event.type) {
        case 'workspace.changed':
        case 'workspace.error':
          for (const t of this.store.threads(event.workspaceId)) {
            const transcript = this.transcripts.get(t.id);
            if (event.type === 'workspace.changed') transcript?.lifecycle(event.status, t.status);
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
        case 'context-templates.changed':
        case 'workspace.setup':
        case 'workspace.snapshot':
        case 'workspace.adopt':
          this.feed.emit(event);
          break;
        default:
          this.transcripts.get(event.threadId)?.accept(event);
      }
    });
  }

  snapshot(id: string): History {
    const t = this.transcripts.get(id);
    if (!t) throw new KiteError('请先加载线程历史', 409);
    return t.snapshot();
  }

  /** 只在空会话切换后端后重建；已开始的原生历史不得用显示记录续跑。 */
  async reset(t: ThreadContext): Promise<void> {
    await this.loadingTranscripts.get(t.id);
    this.transcripts.delete(t.id);
    const projection = await this.load(t);
    this.feed.emit({ type: 'thread.state', threadId: t.id, state: projection.state() });
  }

  load(t: ThreadContext): Promise<TranscriptProjection> {
    const cached = this.transcripts.get(t.id);
    if (cached) return Promise.resolve(cached);
    const loading = this.loadingTranscripts.get(t.id);
    if (loading) return loading;
    const promise = (async () => {
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
      projection.finishReplay();
      this.transcripts.set(t.id, projection);
      return projection;
    })().finally(() => this.loadingTranscripts.delete(t.id));
    this.loadingTranscripts.set(t.id, promise);
    return promise;
  }
}
