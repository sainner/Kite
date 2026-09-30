/** 面向客户端的会话协议。原生 journal 负责恢复，显示投影只负责历史和实时事件。 */
import { randomUUID } from 'node:crypto';
import type { DiffReference } from './file-diffs.ts';
import { Bus, type DomainEvent, type EventScope, type Stamped, type ThreadEvent } from './events.ts';
import type { CheckResult } from './check.ts';
import type { Input, JournalRecord, Json, Phase, Outcome, Recovery, ModelStreamEvent } from './harness/types.ts';
import type { PluginInstance, ThreadContext, WorkspaceStatus } from './model.ts';
import { ToolInputPreview } from './tool-input-preview.ts';

export type DisplayBlock =
  | { type: 'human'; id: string; text: string; midTurn: boolean }
  | { type: 'kite' | 'error' | 'compacted'; text: string }
  | { type: 'text' | 'thinking'; text: string; parts?: string[] }
  | { type: 'tool_use'; id: string; name: string; input: Json; batch?: string; arguments?: string;
      stage?: 'generating' | 'queued' | 'running' | 'finished' | 'not_executed' | 'unfinished';
      output?: string; outputTruncated?: boolean; outputLimit?: number; startedAt?: number; finishedAt?: number }
  | { type: 'tool_result'; call: string; output: string; diff?: DiffReference; status: 'success' | 'error' | 'not_executed' | 'unknown' }
  | { type: 'interrupted' };
export interface DisplayRecord { id: string; at: number; parent?: string; generation?: 'streaming' | 'complete' | 'interrupted'; block: DisplayBlock }
export interface DisplayDelta { id: string; field: 'text' | 'arguments' | 'output'; text: string; part?: number; replace?: boolean; limit?: number; input?: Json }
export interface PendingInput extends Input { midTurn: boolean }
export interface DisplayState {
  phase: Phase;
  busy: boolean;
  waitingForResume: boolean;
  lastOutcome?: Outcome;
  recovery?: Recovery;
  status: WorkspaceStatus;
  error?: string;
  /** 最近一次完成请求的输入用量；窗口上限缺失时不能计算百分比。 */
  context?: { requestId: string; inputTokens: number; windowTokens?: number; measuredAt: number };
  capabilities: { send: boolean; interrupt: boolean; resume: boolean; cancel: boolean };
}
export interface History {
  version: 1;
  threadId: string;
  cursor: string;
  records: DisplayRecord[];
  pending: PendingInput[];
  state: DisplayState;
}
type ThreadDisplayEvent =
  | { type: 'thread.record'; record: DisplayRecord }
  | { type: 'thread.record.delta'; delta: DisplayDelta }
  | { type: 'thread.pending'; pending: PendingInput[] }
  | { type: 'thread.state'; state: DisplayState }
  | { type: 'thread.idle' }
  | { type: 'thread.check'; result: CheckResult }
  | { type: 'thread.error'; message: string };
export type DisplayEvent = DomainEvent | (ThreadDisplayEvent & { threadId: string });
export type DisplayEnvelope = Stamped<DisplayEvent & { cursor: string }>;

/** 显示协议按对象归属过滤；目录流只包含概要变更。 */
export function inScope(event: DisplayEvent, scope: EventScope): boolean {
  if (scope === 'catalog') return ['checkout.changed', 'workspace.changed', 'thread.changed'].includes(event.type);
  if ('workspaceId' in scope) return 'workspaceId' in event && event.workspaceId === scope.workspaceId;
  return 'threadId' in event && event.threadId === scope.threadId;
}

/** cursor 只标识本次服务进程中的投影版本。重连总发完整快照。 */
export class TranscriptFeed extends Bus<DisplayEvent & { cursor: string }> {
  private epoch = randomUUID();
  private seq = 0;
  get cursor(): string { return `${this.epoch}:${this.seq}`; }
  override emit(event: DisplayEvent): void {
    this.seq++;
    super.emit({ ...event, cursor: this.cursor });
  }
}

const object = (value: unknown): Record<string, any> => value && typeof value === 'object' ? value as Record<string, any> : {};
const textParts = (value: unknown, separator = ''): string => Array.isArray(value)
  ? value.map((part) => object(part).text).filter((text) => typeof text === 'string').join(separator) : '';

export class TranscriptProjection {
  private records = new Map<string, DisplayRecord>();
  private pending = new Map<string, PendingInput>();
  private streamIds = new Map<string, string>();
  private inputPreviews = new Map<string, ToolInputPreview>();
  private requests = new Set<string>();
  private lastSeq = 0;
  private replaying = true;
  private phase: Phase = 'idle';
  private busy = false;
  private waitingForResume = false;
  private lastOutcome?: Outcome;
  private recovery?: Recovery;
  private error?: string;
  private context?: DisplayState['context'];
  private workspaceStatus: WorkspaceStatus;
  private threadStatus: PluginInstance['status'];
  private readonly threadId: string;
  private readonly runtime: ThreadContext['runtime'];

  constructor(thread: ThreadContext, private feed: TranscriptFeed) {
    this.threadId = thread.id;
    this.runtime = thread.runtime;
    this.workspaceStatus = thread.workspace.status;
    this.threadStatus = thread.status;
  }

  lifecycle(workspaceStatus: WorkspaceStatus, threadStatus: PluginInstance['status']): void {
    const previous = this.state().status;
    this.workspaceStatus = workspaceStatus;
    this.threadStatus = threadStatus;
    if (this.state().status === previous) return;
    this.emit({ type: 'thread.state', state: this.state() });
  }

  workspaceError(message: string): void {
    this.error = message;
    this.emit({ type: 'thread.state', state: this.state() });
  }

  finishReplay(): void {
    // 未收口的原生回合必须由宿主核查；读历史绝不能为此唤醒工具或模型。
    if (this.busy) {
      this.recovery = { message: '上一回合未收尾，须由宿主核查执行状态' };
      this.waitingForResume = true;
    } else if (this.pending.size) this.waitingForResume = true;
    this.endDrafts();
    for (const record of this.records.values()) {
      if (record.block.type === 'tool_use' && ['queued', 'running'].includes(record.block.stage ?? '')) {
        this.put({ ...record, block: { ...record.block, stage: 'unfinished' } });
      }
    }
    this.phase = 'idle';
    this.busy = false;
    this.replaying = false;
  }

  snapshot(): History {
    return { version: 1, threadId: this.threadId, cursor: this.feed.cursor,
      records: [...this.records.values()], pending: [...this.pending.values()], state: this.state() };
  }

  state(): DisplayState {
    const status = this.threadStatus === 'archived' ? 'archived' : this.workspaceStatus;
    const open = status === 'open';
    // 旧 Claude 消息的可靠投递与排队取消还未统一，App 先提供只读历史。
    const interactive = open && this.runtime === 'harness';
    const error = this.recovery?.message ?? this.error;
    return { phase: this.phase, busy: this.busy, waitingForResume: this.waitingForResume, status,
      ...(this.lastOutcome ? { lastOutcome: this.lastOutcome } : {}),
      ...(this.recovery ? { recovery: this.recovery } : {}),
      ...(error ? { error } : {}),
      ...(this.context ? { context: this.context } : {}),
      capabilities: { send: interactive && !this.recovery && this.phase !== 'stopping',
        interrupt: interactive && (this.busy || this.pending.size > 0) && this.phase !== 'stopping',
        resume: interactive && !this.busy && !this.recovery && this.waitingForResume, cancel: interactive } };
  }
  private emit(event: ThreadDisplayEvent): void { if (!this.replaying) this.feed.emit({ ...event, threadId: this.threadId }); }
  private put(record: DisplayRecord): void {
    if (record.generation !== 'streaming') this.inputPreviews.delete(record.id);
    this.records.set(record.id, record);
    this.emit({ type: 'thread.record', record });
  }
  private emitPending(): void { this.emit({ type: 'thread.pending', pending: [...this.pending.values()] }); }

  accept(event: Stamped<ThreadEvent>): void {
    switch (event.type) {
      case 'harness': {
        const e = event.event;
        if (e.type === 'record') this.journal(e.record);
        else if (e.type === 'state') {
          this.phase = e.state.phase; this.busy = e.state.busy;
          this.waitingForResume = e.state.waitingForResume;
          this.lastOutcome = e.state.lastOutcome;
          this.recovery = e.state.recovery;
          this.error = this.recovery?.message ?? (this.phase === 'idle' && this.lastOutcome?.kind === 'failed' ? this.lastOutcome.message : undefined);
          this.emit({ type: 'thread.state', state: this.state() });
        } else if (e.type === 'delta' || e.type === 'item.started') {
          this.stream(e, e.requestId, event.at);
        } else if (e.type === 'tool.output') {
          const record = this.records.get(`call:${e.callId}`);
          if (record?.block.type === 'tool_use' && record.block.stage === 'running') {
            this.delta({ id: record.id, field: 'output', text: e.text, limit: e.limit });
          }
        } else { this.error = e.message; this.emit({ type: 'thread.state', state: this.state() }); }
        break;
      }
      case 'sdk': this.claude(event.message, event.at); break;
      case 'runner':
        this.phase = event.state === 'running' ? 'running' : event.state === 'closing' ? 'finishing' : 'idle';
        this.busy = event.state === 'running'; this.error = event.error;
        this.emit({ type: 'thread.state', state: this.state() });
        break;
      case 'idle':
        this.busy = false;
        if (this.phase === 'running' || this.phase === 'finishing') this.phase = 'idle';
        this.emit({ type: 'thread.state', state: this.state() });
        this.emit({ type: 'thread.idle' });
        break;
      case 'error': this.error = event.message; this.emit({ type: 'thread.state', state: this.state() }); this.emit({ type: 'thread.error', message: event.message }); break;
      case 'check': this.emit({ type: 'thread.check', result: event.result }); break;
    }
  }

  journal(row: JournalRecord): void {
    if (row.seq <= this.lastSeq) return;
    this.lastSeq = row.seq;
    const put = (id: string, block: DisplayBlock) => this.put({ id, at: row.at, block });
    switch (row.type) {
      case 'input.received':
        if (!this.recovery) this.waitingForResume = false;
        this.pending.set(row.input.id, { ...row.input, midTurn: this.busy || this.pending.size > 0 }); this.emitPending(); break;
      case 'input.cancelled': this.pending.delete(row.inputId); this.emitPending(); break;
      case 'thread.stopped':
        for (const input of row.returned) this.pending.delete(input.id);
        this.waitingForResume = false;
        if (!this.busy) { this.lastOutcome = { kind: 'interrupted' }; this.error = undefined; }
        this.emitPending();
        break;
      case 'turn.started':
        this.phase = 'running'; this.busy = true; this.waitingForResume = false;
        this.lastOutcome = undefined; this.error = undefined; break;
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
        if (item.call) this.put({ id: `call:${item.call.id}`, at: this.records.get(`call:${item.call.id}`)?.at ?? row.at,
          generation: 'complete', block: { type: 'tool_use', id: item.call.id, name: item.call.name,
            input: item.call.arguments, arguments: typeof item.raw.arguments === 'string' ? item.raw.arguments : JSON.stringify(item.call.arguments),
            batch: row.requestId, stage: 'queued' } });
        else {
          const thinking = item.raw.type === 'reasoning';
          const text = textParts(thinking ? item.raw.summary : item.raw.content, '\n\n');
          const id = `${row.requestId}:${item.id}`;
          if (text || this.records.has(id)) this.put({ id, at: this.records.get(id)?.at ?? row.at,
            generation: item.raw.status === 'incomplete' ? 'interrupted' : 'complete', block: { type: thinking ? 'thinking' : 'text', text } });
        }
        break;
      }
      case 'request.failed': this.endDrafts(row.requestId); break;
      case 'request.completed': {
        this.endDrafts(row.requestId);
        const tokens = row.usage?.input_tokens;
        this.context = typeof tokens === 'number' && Number.isSafeInteger(tokens) && tokens >= 0
          ? { requestId: row.requestId, inputTokens: tokens, measuredAt: row.at } : undefined;
        this.emit({ type: 'thread.state', state: this.state() });
        break;
      }
      case 'tool.started': {
        const record = this.records.get(`call:${row.callId}`);
        if (record?.block.type === 'tool_use') this.put({ ...record, block: { ...record.block, stage: 'running', startedAt: row.at } });
        break;
      }
      case 'tool.finished': {
        const record = this.records.get(`call:${row.callId}`);
        if (record?.block.type === 'tool_use') this.put({ ...record, block: { ...record.block, stage: 'finished', finishedAt: row.at } });
        if (row.result.status === 'unknown') this.recovery = { message: row.result.output || '存在执行结果未知的工具，等待确认残留执行停止' };
        put(`result:${row.callId}`, { type: 'tool_result', call: row.callId, output: row.result.output, status: row.result.status, ...(row.result.diff ? { diff: row.result.diff } : {}) }); break;
      }
      case 'turn.feedback': put(`journal:${row.seq}`, { type: 'kite', text: row.text }); break;
      case 'turn.finished':
        this.endDrafts();
        this.busy = false;
        this.phase = 'idle';
        this.lastOutcome = row.outcome;
        this.waitingForResume = row.outcome.kind === 'failed';
        if (row.recovery) this.recovery = row.recovery;
        this.error = undefined;
        if (row.outcome.kind === 'interrupted') put(`journal:${row.seq}`, { type: 'interrupted' });
        if ('message' in row.outcome) { this.error = row.outcome.message; put(`journal:${row.seq}`, { type: 'error', text: row.outcome.message }); }
        break;
      case 'recovery.confirmed':
        this.phase = 'idle'; this.busy = false; this.waitingForResume = true;
        this.recovery = undefined;
        this.error = this.lastOutcome?.kind === 'failed' ? this.lastOutcome.message : undefined; break;
    }
  }

  private stream(event: ModelStreamEvent, requestId: string, at: number): void {
    if (!event.itemId) return;
    const key = `${requestId}:${event.itemId}`;
    if (event.type === 'item.started') {
      const id = event.kind === 'tool_use' && event.callId ? `call:${event.callId}` : key;
      this.streamIds.set(key, id);
      if (this.records.has(id)) return;
      if (event.kind === 'tool_use') {
        if (!event.callId || !event.name) return;
        this.put({ id, at, generation: 'streaming', block: { type: 'tool_use', id: event.callId, name: event.name,
          batch: requestId, input: null, arguments: '', stage: 'generating' } });
      } else this.put({ id, at, generation: 'streaming', block: { type: event.kind, text: '', parts: [] } });
      return;
    }
    const id = this.streamIds.get(key) ?? key;
    // 旧适配器可直接发正文/摘要增量；参数必须先有调用身份。
    if (!this.records.has(id)) {
      if (event.field === 'arguments') return;
      this.put({ id, at, generation: 'streaming', block: { type: event.field === 'thinking' ? 'thinking' : 'text', text: '', parts: [] } });
    }
    if (this.records.get(id)?.generation !== 'streaming') return;
    this.delta({ id, field: event.field === 'arguments' ? 'arguments' : 'text', text: event.text,
      ...(event.part !== undefined ? { part: event.part } : {}), ...(event.replace ? { replace: true } : {}) });
  }

  private delta(delta: DisplayDelta): void {
    const record = this.records.get(delta.id);
    if (!record) return;
    const block = record.block;
    let updated: DisplayBlock;
    if (delta.field === 'text' && (block.type === 'text' || block.type === 'thinking')) {
      const part = delta.part ?? 0;
      // 分段序号由模型适配器校验，不能把稀疏数组扩大成无限草稿。
      if (part < 0 || part > 1024 || !Number.isSafeInteger(part)) throw new Error('显示内容分段序号无效');
      const parts = [...(block.parts ?? [block.text])];
      while (parts.length <= part) parts.push('');
      parts[part] = delta.replace ? delta.text : parts[part]! + delta.text;
      updated = { ...block, parts, text: parts.join('\n\n') };
    } else if (delta.field === 'arguments' && block.type === 'tool_use') {
      const arguments_ = delta.replace ? delta.text : (block.arguments ?? '') + delta.text;
      let input = block.input;
      // 正常追加只喂新片段；不同的全文校正才重置解析，done 重复原文时直接复用。
      if (!delta.replace || arguments_ !== block.arguments) {
        let preview = this.inputPreviews.get(record.id);
        if (!preview || delta.replace) {
          preview = new ToolInputPreview(block.name);
          this.inputPreviews.set(record.id, preview);
        }
        input = preview.append(delta.text);
      }
      updated = { ...block, arguments: arguments_, input };
      if (input !== block.input) delta = { ...delta, input };
    } else if (delta.field === 'output' && block.type === 'tool_use') {
      const limit = delta.limit;
      if (limit === undefined || !Number.isSafeInteger(limit) || limit < 1) throw new Error('显示输出限制无效');
      const output = (block.output ?? '') + delta.text;
      // 以 Unicode 码点裁剪，Swift 与 JS 使用同一单位，且不拆开代理对。
      const characters = Array.from(output);
      updated = { ...block, output: characters.slice(-limit).join(''), outputLimit: limit,
        outputTruncated: block.outputTruncated === true || characters.length > limit };
    } else return;
    this.records.set(record.id, { ...record, block: updated });
    this.emit({ type: 'thread.record.delta', delta });
  }

  private endDrafts(requestId?: string): void {
    for (const record of this.records.values()) {
      if (record.generation !== 'streaming') continue;
      const belongs = record.block.type === 'tool_use' ? record.block.batch === requestId : record.id.startsWith(`${requestId}:`);
      if (requestId !== undefined && !belongs) continue;
      this.put({ ...record, generation: 'interrupted', block: record.block.type === 'tool_use'
        ? { ...record.block, stage: 'not_executed' } : record.block });
    }
    if (requestId === undefined) this.streamIds.clear();
    else for (const key of this.streamIds.keys()) if (key.startsWith(`${requestId}:`)) this.streamIds.delete(key);
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
