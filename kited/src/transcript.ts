/** 面向客户端的会话协议。原生 journal 负责恢复，显示投影只负责历史和实时事件。 */
import { randomUUID } from 'node:crypto';
import { Bus, type Envelope } from './events.ts';
import type { Input, JournalRecord, Json, Phase } from './harness/types.ts';
import type { Session, SessionStatus } from './store.ts';

export type DisplayBlock =
  | { type: 'human'; id: string; text: string; midTurn: boolean }
  | { type: 'kite' | 'text' | 'thinking' | 'error' | 'compacted'; text: string }
  | { type: 'tool_use'; id: string; name: string; input: Json }
  | { type: 'tool_result'; call: string; output: string; status: 'success' | 'error' | 'not_executed' | 'unknown' }
  | { type: 'interrupted' };
export interface DisplayRecord { id: string; at: number; parent?: string; partial?: boolean; block: DisplayBlock }
export interface PendingInput extends Input { midTurn: boolean }
export interface DisplayState {
  phase: Phase;
  busy: boolean;
  status: SessionStatus;
  error?: string;
  capabilities: { send: boolean; interrupt: boolean; resume: boolean; cancel: boolean };
}
export interface History {
  version: 1;
  session: string;
  cursor: string;
  records: DisplayRecord[];
  pending: PendingInput[];
  state: DisplayState;
}
export type DisplayEvent =
  | { type: 'record'; record: DisplayRecord }
  | { type: 'pending'; pending: PendingInput[] }
  | { type: 'state'; state: DisplayState }
  | Exclude<Envelope, { type: 'sdk' | 'harness' | 'runner' }>;
export type DisplayEnvelope = DisplayEvent & { session: string; cursor: string; at: number };

/** cursor 只标识本次服务进程中的投影版本。重连总发完整 history，不要求客户端保存原生游标。 */
export class TranscriptFeed extends Bus<DisplayEvent & { cursor: string }> {
  private epoch = randomUUID();
  private seq = 0;
  get cursor(): string { return `${this.epoch}:${this.seq}`; }
  override emit(session: string, event: DisplayEvent): void {
    this.seq++;
    super.emit(session, { ...event, cursor: this.cursor });
  }
}

const object = (value: unknown): Record<string, any> => value && typeof value === 'object' ? value as Record<string, any> : {};
const textParts = (value: unknown): string => Array.isArray(value)
  ? value.map((part) => object(part).text).filter((text) => typeof text === 'string').join('') : '';

export class TranscriptProjection {
  private records = new Map<string, DisplayRecord>();
  private pending = new Map<string, PendingInput>();
  private requests = new Set<string>();
  private lastSeq = 0;
  private replaying = true;
  private phase: Phase = 'idle';
  private busy = false;
  private error?: string;
  private status: SessionStatus;

  constructor(private session: Session, private feed: TranscriptFeed) { this.status = session.status; }

  finishReplay(): void {
    // 未收口的原生回合必须由宿主核查；读历史绝不能为此唤醒工具或模型。
    if (this.busy) { this.phase = 'needs_recovery'; this.busy = false; }
    else if (this.pending.size && this.phase === 'idle') this.phase = 'paused';
    this.replaying = false;
  }

  snapshot(): History {
    return { version: 1, session: this.session.id, cursor: this.feed.cursor,
      records: [...this.records.values()], pending: [...this.pending.values()], state: this.state() };
  }

  private state(): DisplayState {
    const open = this.status === 'open';
    // 旧 Claude 消息的可靠投递与排队取消还未统一，App 先提供只读历史。
    const interactive = open && this.session.runtime === 'harness';
    return { phase: this.phase, busy: this.busy, status: this.status,
      ...(this.error ? { error: this.error } : {}),
      capabilities: { send: interactive && this.phase !== 'needs_recovery', interrupt: interactive && this.busy && this.phase !== 'needs_recovery',
        resume: interactive && this.phase === 'paused', cancel: interactive } };
  }
  private emit(event: DisplayEvent): void { if (!this.replaying) this.feed.emit(this.session.id, event); }
  private put(record: DisplayRecord): void { this.records.set(record.id, record); this.emit({ type: 'record', record }); }
  private emitPending(): void { this.emit({ type: 'pending', pending: [...this.pending.values()] }); }

  accept(event: Envelope): void {
    switch (event.type) {
      case 'harness': {
        const e = event.event;
        if (e.type === 'record') this.journal(e.record);
        else if (e.type === 'state') {
          this.phase = e.state.phase; this.busy = e.state.busy;
          this.error = e.state.lastOutcome && 'message' in e.state.lastOutcome ? e.state.lastOutcome.message : undefined;
          this.emit({ type: 'state', state: this.state() });
        } else if (e.type === 'delta') {
          // 没有条目 id 的旧模型增量不能稳定替换，等完整条目再显示。
          if (!e.itemId) break;
          const id = `${e.requestId}:${e.itemId}`;
          const old = this.records.get(id)?.block;
          this.put({ id, at: this.records.get(id)?.at ?? event.at, partial: true,
            block: { type: 'text', text: (old?.type === 'text' ? old.text : '') + e.text } });
        } else { this.error = e.message; this.emit({ type: 'state', state: this.state() }); }
        break;
      }
      case 'sdk': this.claude(event.message, event.at); break;
      case 'runner':
        this.phase = event.state === 'running' ? 'running' : event.state === 'closing' ? 'finishing' : 'idle';
        this.busy = event.state === 'running'; this.error = event.error;
        this.emit({ type: 'state', state: this.state() });
        break;
      case 'idle':
        this.busy = false;
        if (this.phase === 'running' || this.phase === 'finishing') this.phase = 'idle';
        this.emit({ type: 'state', state: this.state() });
        this.emit(event);
        break;
      case 'status': this.status = event.status; this.emit({ type: 'state', state: this.state() }); this.emit(event); break;
      case 'error': this.error = event.message; this.emit({ type: 'state', state: this.state() }); this.emit(event); break;
      default: this.emit(event);
    }
  }

  journal(row: JournalRecord): void {
    if (row.seq <= this.lastSeq) return;
    this.lastSeq = row.seq;
    const put = (id: string, block: DisplayBlock) => this.put({ id, at: row.at, block });
    switch (row.type) {
      case 'input.received': this.pending.set(row.input.id, { ...row.input, midTurn: this.busy || this.pending.size > 0 }); this.emitPending(); break;
      case 'input.cancelled': this.pending.delete(row.inputId); this.emitPending(); break;
      case 'turn.started': this.phase = 'running'; this.busy = true; this.error = undefined; break;
      case 'request.started': {
        const midTurn = this.requests.has(row.turnId);
        this.requests.add(row.turnId);
        row.inputIds.forEach((id, index) => {
          const input = this.pending.get(id);
          if (!input) return;
          put(`input:${id}`, input.source === 'human'
            ? { type: 'human', id, text: input.text, midTurn: midTurn || index > 0 }
            : { type: 'kite', text: input.text });
          this.pending.delete(id);
        });
        this.emitPending();
        break;
      }
      case 'model.item': {
        const { item } = row;
        if (item.call) put(`call:${item.call.id}`, { type: 'tool_use', id: item.call.id, name: item.call.name, input: item.call.arguments });
        else {
          const thinking = item.raw.type === 'reasoning';
          const text = textParts(thinking ? item.raw.summary : item.raw.content);
          const id = `${row.requestId}:${item.id}`;
          if (text || this.records.has(id)) put(id, { type: thinking ? 'thinking' : 'text', text });
        }
        break;
      }
      case 'tool.finished': put(`result:${row.callId}`, { type: 'tool_result', call: row.callId, output: row.result.output, status: row.result.status }); break;
      case 'turn.feedback': put(`journal:${row.seq}`, { type: 'kite', text: row.text }); break;
      case 'turn.finished':
        this.busy = false;
        this.phase = row.outcome.kind === 'completed' ? 'idle' : row.outcome.kind === 'needs_recovery' ? 'needs_recovery' : 'paused';
        if (row.outcome.kind === 'interrupted') put(`journal:${row.seq}`, { type: 'interrupted' });
        if ('message' in row.outcome) { this.error = row.outcome.message; put(`journal:${row.seq}`, { type: 'error', text: row.outcome.message }); }
        break;
      case 'recovery.confirmed': this.phase = 'paused'; this.busy = false; this.error = undefined; break;
    }
  }

  /** SDK 历史和完整实时消息走同一转换。未知扩展块保留在原生记录，不让 App 依赖 SDK。 */
  claude(value: unknown, at: number): void {
    const row = object(value);
    const message = object(row.message);
    if (typeof row.uuid !== 'string') return;
    const parent = typeof row.parent_tool_use_id === 'string' ? row.parent_tool_use_id : undefined;
    const put = (index: number, block: DisplayBlock) => this.put({ id: `${row.uuid}:${index}`, at, ...(parent ? { parent } : {}), block });
    const content = typeof message.content === 'string' ? [{ type: 'text', text: message.content }] : message.content;
    if (Array.isArray(content)) content.forEach((part, index) => {
      const block = object(part);
      if (block.type === 'text' && typeof block.text === 'string') {
        put(index, row.type === 'user' ? { type: 'human', id: row.uuid, text: block.text, midTurn: false } : { type: 'text', text: block.text });
      } else if (block.type === 'thinking' && typeof block.thinking === 'string') put(index, { type: 'thinking', text: block.thinking });
      else if (block.type === 'tool_use') put(index, { type: 'tool_use', id: block.id, name: block.name, input: block.input });
      else if (block.type === 'tool_result') put(index, { type: 'tool_result', call: block.tool_use_id,
        output: typeof block.content === 'string' ? block.content : textParts(block.content), status: block.is_error ? 'error' : 'success' });
    });
    if (row.type === 'system' && row.subtype === 'compact_boundary') put(0, { type: 'compacted', text: '' });
    if (row.type === 'result' && row.is_error) put(0, { type: 'error', text: Array.isArray(row.errors) ? row.errors.join('\n') : '模型执行失败' });
  }
}
