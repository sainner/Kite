import { join } from 'node:path';
import { readClaudeMessages } from '../claude/history.ts';
import { claudeState, readClaudeControl } from '../claude/control.ts';
import { KiteError } from '../errors.ts';
import type { Bus } from '../events.ts';
import { readJournal } from '../harness/journal.ts';
import type { ThreadContext } from '../model.ts';
import type { Store } from '../store.ts';
import type { TranscriptFeed } from './feed.ts';
import { TranscriptProjection } from './projection.ts';
import type { History } from './protocol.ts';

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

  load(t: ThreadContext): Promise<TranscriptProjection> {
    const cached = this.transcripts.get(t.id);
    if (cached) return Promise.resolve(cached);
    const loading = this.loadingTranscripts.get(t.id);
    if (loading) return loading;
    const promise = (async () => {
      const projection = new TranscriptProjection(t, this.feed);
      if (t.runtime === 'harness') {
        for (const row of readJournal(join(this.home, 'sessions', t.id, 'journal.jsonl'))) projection.journal(row);
      } else {
        projection.claudeControl(claudeState(readClaudeControl(join(this.home, 'sessions', t.id))));
        for (const row of await readClaudeMessages(t.nativeId, t.workspace.cwd)) projection.claude(row, row.at);
      }
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
