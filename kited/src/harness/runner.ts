/** 单个线程的执行实例：控制入口保持可用，单个 pump 推进模型、工具和收尾。 */
import { randomUUID } from 'node:crypto';
import { ToolBatch } from './tools.ts';
import { assembleContext, literalContext, restoreContext } from './context/assembler.ts';
import { contextUpdateContext } from './context/notifications.ts';
import { notificationSchema, requestSnapshot } from './request-config.ts';
import { AUTO_COMPACT_RATIO, compactInstructions, compactionItems, compactTemplate, roughTokens, summaryText } from './compaction.ts';
import type { ContextAssembly } from './context/types.ts';
import type {
  CompactionRequest, ContextItem, HarnessRequest, Input, JournalEvent, JournalRecord, JsonObject, ModelItem, Outcome, Phase,
  Recovery, RequestSnapshot, StopRequest, HarnessEvent, HarnessOptions, ThreadRunner, ThreadState, Tool, ToolDefinition, ToolResult,
} from './types.ts';

/** 段由产生它的记录 seq 标识，压缩按 seq 区间替换。 */
interface Placed { seq: number; at: number }

interface SavedRequest extends Placed {
  id: string;
  turnId: string;
  inputs: Input[];
  notifications: Extract<ContextItem, { type: 'notification' }>[];
  items: ModelItem[];
  started: Set<string>;
  results: Map<string, ToolResult>;
  ended: boolean;
  /** 上游实测的输入与输出 token，用于估算下一次请求的用量。 */
  usage?: { input: number; output: number };
}

/** 导入段记着来源后端中已导入的最后位置，重组 Claude 会话时据此原样拷贝原生条目。 */
type Imported = Placed & { imported: ContextItem[]; source: { id: string; through: string } };
type Segment = SavedRequest | (Placed & { feedback: string }) | Imported;

/** 实际进入请求的历史中的一段：一个原始段，或一次压缩的替代内容。 */
export interface ContextUnit { items: ContextItem[]; imported?: { id: string; through: string } }

const quote = (text: string) => {
  const line = text.replace(/\s+/g, ' ').trim();
  return `「${line.length > 60 ? line.slice(0, 60) + '…' : line}」`;
};

interface Compaction {
  id: string;
  from: number;
  /** 不含；记录未给 until 时为压缩记录自己的 seq。 */
  end: number;
  items: ContextItem[];
  automatic: boolean;
  reverted: boolean;
  seq: number;
}

interface Turn {
  id: string;
  controller: AbortController;
  stopRequested: boolean;
  failure?: { error: unknown };
}

const message = (error: unknown) => error instanceof Error ? error.message : String(error);

/** 回合未正常结束、确认恢复后给模型的说明；跨后端翻译沿用同一正文。 */
export function outcomeFeedback(outcome: Outcome): string | undefined {
  if (outcome.kind === 'completed') return undefined;
  return outcome.kind === 'interrupted'
    ? '上一回合被打断。已完成的工具操作没有被撤销；请根据实际结果继续。'
    : `上一回合未完成：${outcome.message}。不要自动重复已有工具调用，先检查实际状态。`;
}
export const recoveryFeedback = '宿主已确认先前的执行停止。结果未知的操作仍需检查实际效果，不能假定已回滚。';

/** 按记录重放出当前实际进入请求的历史，已应用压缩；只读，不恢复、不执行。调用方须确认会话已停止。 */
export function replayHistory(records: readonly JournalRecord[]): ContextItem[] {
  return replayUnits(records).flatMap((unit) => unit.items);
}

/** 同 replayHistory，按段给出，导入段带来源位置。 */
export function replayUnits(records: readonly JournalRecord[]): ContextUnit[] {
  const fail = () => { throw new Error('只读重放不能追加记录或请求模型'); };
  return new HarnessRunner({ cwd: '', journal: { records, append: fail, close() {} }, prepareRequest: fail, startPaused: true }).contextUnits();
}

export class HarnessRunner implements ThreadRunner {
  private inputs = new Map<string, Input>();
  private pending = new Set<string>();
  private requests = new Map<string, SavedRequest>();
  /** 完整快照留在 journal；运行中只保留固定前缀和当前有效正文。 */
  private contexts = new Set<string>();
  private configurations = new Set<string>();
  private baseInstructions?: string;
  private currentInstructions?: string;
  private toolDefinitions?: ToolDefinition[];
  private notificationCursor = 0;
  private deliveredNotifications = new Set<string>();
  private calls = new Map<string, SavedRequest>();
  /** 从其他后端导入的调用已有结果，只用于防止 ID 重复。 */
  private importedCalls = new Set<string>();
  private segments: Segment[] = [];
  private compactions = new Map<string, Compaction>();
  /** 最近一次压缩或撤销；此前的实测用量不再代表当前历史。 */
  private contextChanged?: { seq: number; automatic: boolean };
  /** 正在生成压缩摘要；自动压缩沿用回合的取消信号。 */
  private compaction?: { controller: AbortController };
  private openTurn?: string;
  private active?: Turn;
  private pumping?: Promise<void>;
  private phase: Phase = 'idle';
  private lastOutcome?: Outcome;
  private waitingForResume = false;
  private recovery?: Recovery;
  private stopping?: string;
  private stops = new Map<string, Input[]>();
  private storageFailed = false;
  private closing = false;
  private closed = false;
  private forceRun = false;

  constructor(private options: HarnessOptions) {
    const records = options.journal.records;
    for (const row of records) this.apply(row);
    const first = records.find((row) => row.type === 'request.started');
    const last = records.findLast((row) => row.type === 'request.started');
    if (first && last) {
      const base = records.find((row) => row.type === 'context.prepared' && row.snapshot.id === first.contextId);
      const current = records.find((row) => row.type === 'context.prepared' && row.snapshot.id === last.contextId);
      const configuration = records.find((row) => row.type === 'request.configured' && row.snapshot.id === first.configurationId);
      if (base?.type === 'context.prepared') this.baseInstructions = restoreContext(base.snapshot).instructions;
      if (current?.type === 'context.prepared') this.currentInstructions = restoreContext(current.snapshot).instructions;
      if (configuration?.type === 'request.configured') this.toolDefinitions = structuredClone(configuration.snapshot.tools);
      // 另一后端在此后已告知的基础上下文，不再作为更新重复投递。
      const imported = records.findLast((row) => row.type === 'context.imported');
      if (imported?.type === 'context.imported' && imported.seq > last.seq && imported.instructions !== undefined) {
        this.currentInstructions = imported.instructions;
      }
    }
    this.recover();
    if (options.startPaused && this.pending.size) this.waitingForResume = true;
    this.phase = 'idle';
    this.kick();
  }

  get state(): ThreadState {
    return {
      phase: this.phase, busy: !!this.active || !!this.pumping,
      ...(this.compaction ? { compacting: true } : {}),
      waitingForResume: this.waitingForResume,
      ...(this.recovery ? { recovery: structuredClone(this.recovery) } : {}),
      ...(this.active ? { turnId: this.active.id } : {}),
      ...(this.lastOutcome ? { lastOutcome: structuredClone(this.lastOutcome) } : {}),
    };
  }

  get lifecycle(): 'open' | 'closing' | 'closed' { return this.closed ? 'closed' : this.closing ? 'closing' : 'open'; }

  async send(input: Input): Promise<void> {
    this.assertOpen();
    if (!input.id || !input.text.trim() || !['human', 'kite'].includes(input.source)) throw new Error('输入 id、正文和来源必须有效');
    const previous = this.inputs.get(input.id);
    if (previous) {
      if (previous.text !== input.text || previous.source !== input.source) throw new Error(`输入 id 冲突：${input.id}`);
      return;
    }
    if (this.stopping) throw new Error('会话正在停止，请稍后发送');
    if (this.recovery) throw new Error('会话需要先确认恢复');
    this.record({ type: 'input.received', input });
    this.kick();
  }

  async cancel(inputId: string): Promise<void> {
    this.assertOpen();
    if (!this.pending.has(inputId)) throw new Error('只能撤回尚未纳入请求的输入');
    this.record({ type: 'input.cancelled', inputId });
  }

  async interrupt(request: StopRequest = { id: randomUUID() }): Promise<Input[]> {
    this.assertOpen();
    if (!request.id) throw new Error('停止请求必须有 id');
    const previous = this.stops.get(request.id);
    if (previous) {
      if (this.stopping === request.id) await this.settled();
      return structuredClone(previous);
    }
    if (this.stopping) throw new Error('会话正在停止，请重试原停止请求');
    const returned = new Map([...this.pending].map((id) => [id, this.inputs.get(id)!]));
    for (const input of request.inputs ?? []) {
      if (!input.id || !input.text.trim() || !['human', 'kite'].includes(input.source)) throw new Error('待核定输入无效');
      const known = this.inputs.get(input.id) ?? returned.get(input.id);
      if (known && (known.text !== input.text || known.source !== input.source)) throw new Error(`输入 id 冲突：${input.id}`);
      if (!known) returned.set(input.id, input);
    }
    // 冻结后再落盘；同步事件观察者也不能趁这段窗口提交下一回合。
    this.stopping = request.id;
    this.forceRun = false;
    try {
      this.record({ type: 'thread.stopped', id: request.id, returned: [...returned.values()] });
      this.stopActive();
      await this.settled();
      return structuredClone(this.stops.get(request.id)!);
    } finally {
      this.stopping = undefined;
      if (!this.active && !this.pumping) this.setPhase('idle');
    }
  }

  private stopActive(): void {
    if (this.compaction && !this.active) {
      this.compaction.controller.abort();
      this.setPhase('stopping');
      return;
    }
    const turn = this.active;
    if (!turn || this.phase === 'finishing') return;
    turn.stopRequested = true;
    this.setPhase('stopping');
    turn.controller.abort();
  }

  async resume(): Promise<void> {
    this.assertOpen();
    if (this.recovery) throw new Error('会话需要先确认恢复');
    if (this.stopping) throw new Error('会话正在停止，请稍后继续');
    if (this.active) return;
    if (!this.pending.size && !this.segments.length) throw new Error('没有可以继续的会话内容');
    this.waitingForResume = false;
    this.forceRun = true;
    this.kick();
  }

  async confirmRecovery(): Promise<void> {
    this.assertOpen();
    if (this.active || this.pumping) throw new Error('执行尚未停止，不能确认恢复');
    if (this.storageFailed) throw new Error('记录写入失败，须重新打开并检查会话');
    if (!this.recovery) return;
    this.record({ type: 'recovery.confirmed' });
    this.setPhase('idle');
  }

  async compact(request: CompactionRequest): Promise<void> {
    this.assertOpen();
    if (!request.id) throw new Error('压缩请求必须有 id');
    if (this.compactions.has(request.id)) return;
    if (this.active || this.pumping || this.stopping) throw new Error('会话正在执行，空闲后才能压缩');
    if (this.recovery) throw new Error('会话需要先确认恢复');
    let from: number;
    let until: number | undefined;
    let range: string;
    if ('automatic' in request) {
      const first = this.segments[0];
      if (!first) throw new Error('压缩范围内没有内容');
      from = first.seq;
      range = '从会话开头到现在';
    } else {
      const start = this.inputSegment(request.from);
      const last = this.inputSegment(request.through);
      if (last.segment.seq < start.segment.seq) throw new Error('压缩终点不能早于起点');
      // 终点所在的那一轮包括到下一条输入纳入之前；导入段不能拆开，也算边界。
      until = this.segments.find((segment) => segment.seq > last.segment.seq
        && ('imported' in segment || ('inputs' in segment && segment.inputs.length > 0)))?.seq;
      from = start.segment.seq;
      // 写明两端：Claude 的摘要在完整原生上下文上生成，看得到范围之后的内容。
      range = start.input.id === last.input.id ? `用户消息${quote(start.input.text)}所在的那一轮`
        : `从用户消息${quote(start.input.text)}开始到用户消息${quote(last.input.text)}所在的那一轮结束`;
    }
    this.validateRange(from, until ?? Infinity);
    const controller = new AbortController();
    this.compaction = { controller };
    this.pumping = (async () => {
      const prepared = this.options.prepareRequest({ afterNotification: this.notificationCursor });
      const { context, configuration } = this.configure(prepared);
      await this.summarize({ id: request.id, from, until, automatic: 'automatic' in request, range,
        prepared, context, configuration, signal: controller.signal, turnId: request.id });
    })().catch((error: unknown) => {
      if (!controller.signal.aborted) this.emit({ type: 'error', message: `上下文压缩失败：${message(error)}` });
    }).then(() => {
      this.compaction = undefined;
      this.pumping = undefined;
      if (this.canRun()) this.kick();
      else this.setPhase('idle');
    });
    this.setPhase('running');
  }

  async revertCompaction(id: string): Promise<void> {
    this.assertOpen();
    if (this.active || this.pumping || this.stopping) throw new Error('会话正在执行，空闲后才能撤销压缩');
    if (this.recovery) throw new Error('会话需要先确认恢复');
    const compaction = this.compactions.get(id);
    if (!compaction) throw new Error('没有这次压缩');
    if (compaction.reverted) return;
    if (!this.outermost().includes(compaction)) throw new Error('只能撤销最外层的压缩');
    this.record({ type: 'context.compaction.reverted', id });
    this.setPhase('idle');
  }

  /** 输入所在的段；导入段只能从开头的那条输入切开。 */
  private inputSegment(id: string): { segment: Segment; input: Input } {
    for (const segment of this.segments) {
      if ('inputs' in segment) {
        const input = segment.inputs.find((entry) => entry.id === id);
        if (input) return { segment, input };
      } else if ('imported' in segment) {
        const inputs = segment.imported.flatMap((item) => item.type === 'input' ? [item.input] : []);
        if (inputs[0]?.id === id) return { segment, input: inputs[0] };
        if (inputs.some((input) => input.id === id)) throw new Error('这条消息在一段整体导入的历史中间，不能作为压缩边界');
      }
    }
    throw new Error('找不到这条消息，不能作为压缩边界');
  }

  /** 新范围只能完整包含或完全避开仍有效的压缩。 */
  private validateRange(from: number, end: number): void {
    for (const compaction of this.compactions.values()) {
      if (compaction.reverted || compaction.end <= from || compaction.from >= end) continue;
      if (from <= compaction.from && compaction.end <= end) continue;
      throw new Error('压缩范围与已有的压缩部分重叠；请先撤销那次压缩，或选择完整包含它的范围');
    }
    if (!this.segments.some((segment) => segment.seq >= from && segment.seq < end)) throw new Error('压缩范围内没有内容');
  }

  /** 仍然生效、且不被其他压缩包含的压缩；范围相同时较新的在外层。 */
  private outermost(): Compaction[] {
    const active = [...this.compactions.values()].filter((compaction) => !compaction.reverted);
    return active.filter((inner) => !active.some((outer) => outer !== inner && outer.from <= inner.from && inner.end <= outer.end
      && (outer.from < inner.from || inner.end < outer.end || outer.seq > inner.seq)));
  }

  async shutdown(): Promise<void> {
    if (this.closed) return;
    this.closing = true;
    this.stopActive();
    await this.settled();
    if (!this.closed) {
      this.closed = true;
      this.options.journal.close();
      this.setPhase('idle');
    }
  }

  async settled(): Promise<void> {
    while (this.pumping) await this.pumping;
  }

  private assertOpen(): void {
    if (this.closing || this.closed) throw new Error('会话正在关闭或已关闭');
    if (this.storageFailed) throw new Error('会话记录写入失败，须重新打开');
  }

  private emit(event: HarnessEvent): void {
    try { this.options.onEvent?.(structuredClone(event)); }
    catch (error) {
      // 观察者不拥有执行控制权；避免 UI 异常让已保存的调用失去结果。
      try { this.options.onEvent?.({ type: 'error', message: `事件回调失败：${message(error)}` }); } catch {}
    }
  }

  private setPhase(phase: Phase): void {
    this.phase = phase;
    this.emit({ type: 'state', state: this.state });
  }

  private record(event: JournalEvent): void {
    if (this.storageFailed) throw new Error('会话记录已经发生写入故障，不能继续追加');
    let row: JournalRecord;
    try { row = this.options.journal.append(event); }
    catch (error) {
      this.storageFailed = true;
      this.recovery = { message: `会话记录写入失败：${message(error)}` };
      this.lastOutcome = { kind: 'failed', message: this.recovery.message };
      if (this.active) {
        this.active.failure ??= { error };
        this.active.controller.abort();
      }
      this.emit({ type: 'state', state: this.state });
      throw error;
    }
    this.apply(row);
    this.emit({ type: 'record', record: row });
  }

  /** 同步重放事实；损坏的关联不能静默生成一份看似正常的上下文。 */
  private apply(row: JournalRecord): void {
    switch (row.type) {
      case 'input.received':
        if (this.inputs.has(row.input.id)) throw new Error('记录包含重复输入');
        this.inputs.set(row.input.id, structuredClone(row.input));
        this.pending.add(row.input.id);
        if (!this.recovery) this.waitingForResume = false;
        return;
      case 'input.cancelled':
        if (!this.pending.delete(row.inputId)) throw new Error('记录撤回了非待处理输入');
        return;
      case 'thread.stopped':
        if (this.stops.has(row.id)) throw new Error('停止收据重复');
        for (const input of row.returned) {
          const known = this.inputs.get(input.id);
          if (known && (!this.pending.has(input.id) || known.text !== input.text || known.source !== input.source)) throw new Error('停止收据包含已消费或冲突输入');
          this.inputs.set(input.id, structuredClone(input));
          this.pending.delete(input.id);
        }
        this.stops.set(row.id, structuredClone(row.returned));
        this.waitingForResume = false;
        if (!this.openTurn) this.lastOutcome = { kind: 'interrupted' };
        return;
      case 'turn.started':
        if (this.openTurn) throw new Error('记录包含重叠回合');
        this.openTurn = row.turnId;
        this.lastOutcome = undefined;
        return;
      case 'context.prepared':
        if (this.contexts.has(row.snapshot.id)) throw new Error('上下文快照重复');
        restoreContext(row.snapshot);
        this.contexts.add(row.snapshot.id);
        return;
      case 'request.configured':
        if (this.configurations.has(row.snapshot.id)) throw new Error('请求配置快照重复');
        this.configurations.add(row.snapshot.id);
        return;
      case 'request.started': {
        if (this.openTurn !== row.turnId || this.requests.has(row.requestId)) throw new Error('请求关联的回合或 id 无效');
        if (!this.contexts.has(row.contextId)) throw new Error('请求引用了未保存的上下文');
        if (!this.configurations.has(row.configurationId)) throw new Error('请求引用了未保存的配置');
        if (this.unfinishedRequest()) throw new Error('上一请求或工具尚未结束，不能开始新请求');
        const notifications = (row.notifications ?? []).map(({ context, ...notification }) => ({
          type: 'notification' as const, notification, text: restoreContext(context).instructions,
        }));
        for (const { notification } of notifications) {
          if (this.deliveredNotifications.has(notification.id)) throw new Error('通知重复投递');
          if (notification.sequence !== undefined) {
            if (notification.sequence <= this.notificationCursor) throw new Error('通知游标未递增');
            this.notificationCursor = notification.sequence;
          }
          this.deliveredNotifications.add(notification.id);
        }
        const inputs = row.inputIds.map((id) => {
          if (!this.pending.delete(id)) throw new Error('请求使用了非待处理输入');
          return this.inputs.get(id)!;
        });
        const request: SavedRequest = { id: row.requestId, turnId: row.turnId, inputs, notifications,
          items: [], started: new Set(), results: new Map(), ended: false, seq: row.seq, at: row.at };
        this.requests.set(row.requestId, request);
        this.segments.push(request);
        return;
      }
      case 'model.item': {
        const request = this.mustRequest(row);
        if (request.ended || request.items.some((item) => item.id === row.item.id)) throw new Error('重复或已结束请求的输出条目');
        if (row.item.call) {
          if (this.calls.has(row.item.call.id) || this.importedCalls.has(row.item.call.id)) throw new Error('工具调用 id 重复');
          this.calls.set(row.item.call.id, request);
        }
        request.items.push(structuredClone(row.item));
        return;
      }
      case 'request.completed':
      case 'request.failed': {
        const request = this.mustRequest(row);
        if (request.ended) throw new Error('请求重复结束');
        request.ended = true;
        if (row.type === 'request.completed') {
          const input = row.usage?.input_tokens;
          const output = row.usage?.output_tokens;
          if (typeof input === 'number' && typeof output === 'number') request.usage = { input, output };
        }
        return;
      }
      case 'tool.started': {
        const request = this.mustCall(row);
        if (request.started.has(row.callId) || request.results.has(row.callId)) throw new Error('工具重复启动');
        request.started.add(row.callId);
        return;
      }
      case 'tool.finished': {
        const request = this.mustCall(row);
        if (request.results.has(row.callId)) throw new Error('工具重复结束');
        request.results.set(row.callId, structuredClone(row.result));
        if (row.result.status === 'unknown') this.recovery = { message: row.result.output || '存在执行结果未知的工具，等待确认残留执行停止' };
        return;
      }
      case 'turn.feedback':
        if (this.openTurn !== row.turnId) throw new Error('停止反馈不属于当前回合');
        this.segments.push({ feedback: row.text, seq: row.seq, at: row.at });
        return;
      case 'turn.finished':
        if (this.openTurn !== row.turnId) throw new Error('回合结束记录不匹配');
        if (this.unfinishedRequest()?.turnId === row.turnId) throw new Error('回合结束时仍有未完成的请求或工具');
        this.openTurn = undefined;
        this.lastOutcome = row.outcome;
        this.waitingForResume = row.outcome.kind === 'failed';
        if (row.recovery) this.recovery = structuredClone(row.recovery);
        if (row.outcome.kind !== 'completed') this.segments.push({ feedback: outcomeFeedback(row.outcome)!, seq: row.seq, at: row.at });
        return;
      case 'recovery.confirmed':
        if (this.openTurn) throw new Error('回合尚未收尾，不能确认恢复');
        this.recovery = undefined;
        this.waitingForResume = true;
        this.segments.push({ feedback: recoveryFeedback, seq: row.seq, at: row.at });
        return;
      case 'context.imported':
        if (this.openTurn || this.unfinishedRequest() || this.pending.size) throw new Error('只能在空闲且没有待处理输入时导入上下文');
        for (const entry of row.items) {
          // 停止时退回的输入可能以同一 ID 改投另一后端；登记已知 ID 只用于拒绝重发。
          if (entry.type === 'input' && !this.inputs.has(entry.input.id)) this.inputs.set(entry.input.id, structuredClone(entry.input));
          if (entry.type === 'output' && entry.item.call) {
            if (this.calls.has(entry.item.call.id) || this.importedCalls.has(entry.item.call.id)) throw new Error('导入的工具调用 id 重复');
            this.importedCalls.add(entry.item.call.id);
          }
        }
        this.notificationCursor = Math.max(this.notificationCursor, row.notificationCursor);
        this.segments.push({ imported: structuredClone(row.items), source: { id: row.id, through: row.source.through }, seq: row.seq, at: row.at });
        return;
      case 'context.compacted': {
        if (this.compactions.has(row.id)) throw new Error('压缩记录重复');
        if (this.unfinishedRequest()) throw new Error('请求或工具尚未结束时不能压缩');
        const { from, until } = row.range;
        const end = until ?? row.seq;
        if (!this.segments.some((segment) => segment.seq === from) || end <= from
          || (until !== undefined && !this.segments.some((segment) => segment.seq === until))) throw new Error('压缩范围无效');
        this.validateRange(from, end);
        this.compactions.set(row.id, { id: row.id, from, end, items: structuredClone(row.items), automatic: row.automatic, reverted: false, seq: row.seq });
        this.contextChanged = { seq: row.seq, automatic: row.automatic };
        return;
      }
      case 'context.compaction.reverted': {
        const compaction = this.compactions.get(row.id);
        if (!compaction || compaction.reverted || !this.outermost().includes(compaction)) throw new Error('撤销压缩的记录无效');
        compaction.reverted = true;
        this.contextChanged = { seq: row.seq, automatic: false };
        return;
      }
    }
  }

  private unfinishedRequest(): SavedRequest | undefined {
    // 新请求开始前已确认前序请求及工具收齐；只需检查最后一次请求。
    const request = this.segments.findLast((segment): segment is SavedRequest => 'id' in segment);
    return request && (!request.ended || request.items.some((item) => item.call && !request.results.has(item.call.id)))
      ? request : undefined;
  }

  private mustRequest(row: { turnId: string; requestId: string }): SavedRequest {
    const request = this.requests.get(row.requestId);
    if (!request || request.turnId !== row.turnId || this.openTurn !== row.turnId) throw new Error('记录的请求关联无效');
    return request;
  }

  private mustCall(row: { turnId: string; requestId: string; callId: string }): SavedRequest {
    const request = this.mustRequest(row);
    if (this.calls.get(row.callId) !== request) throw new Error('记录的工具调用关联无效');
    return request;
  }

  private recover(): void {
    const turnId = this.openTurn;
    if (!turnId) return;
    for (const request of this.requests.values()) {
      if (request.turnId !== turnId) continue;
      if (!request.ended) this.record({ type: 'request.failed', turnId, requestId: request.id, message: '宿主退出，旧请求已中断' });
      for (const item of request.items) {
        const call = item.call;
        if (!call || request.results.has(call.id)) continue;
        const started = request.started.has(call.id);
        this.record({ type: 'tool.finished', turnId, requestId: request.id, callId: call.id, result: {
          status: started ? 'unknown' : 'not_executed',
          output: started ? '宿主退出前工具已开始，但没有结果。必须先确认残留执行停止，再检查实际效果。' : '宿主退出前工具尚未开始，未执行。',
        } });
      }
    }
    this.record({ type: 'turn.finished', turnId, outcome: { kind: 'failed',
      message: this.recovery?.message ?? '宿主退出中断了上一回合，等待显式继续' },
      ...(this.recovery ? { recovery: this.recovery } : {}) });
  }

  contextUnits(): ContextUnit[] { return structuredClone(this.units()); }

  /** 实际进入请求的历史；可只取 seq 位于 [from, until) 的段，被压缩的段换成替代内容。 */
  private history(until?: number, from?: number): ContextItem[] {
    return structuredClone(this.units(until, from).flatMap((unit) => unit.items));
  }

  private units(until?: number, from?: number): ContextUnit[] {
    const units: ContextUnit[] = [];
    const outer = this.outermost();
    const emitted = new Set<Compaction>();
    for (const segment of this.segments) {
      if (from !== undefined && segment.seq < from) continue;
      if (until !== undefined && segment.seq >= until) break;
      const compaction = outer.find((compaction) => compaction.from <= segment.seq && segment.seq < compaction.end);
      if (compaction) {
        if (!emitted.has(compaction)) { emitted.add(compaction); units.push({ items: compaction.items }); }
        continue;
      }
      if ('feedback' in segment) { units.push({ items: [{ type: 'feedback', text: segment.feedback }] }); continue; }
      if ('imported' in segment) { units.push({ items: segment.imported, imported: segment.source }); continue; }
      const items: ContextItem[] = [...segment.notifications];
      for (const input of segment.inputs) items.push({ type: 'input', input });
      for (const item of segment.items) items.push({ type: 'output', item });
      for (const item of segment.items) {
        if (!item.call) continue;
        const result = segment.results.get(item.call.id);
        if (result) items.push({ type: 'tool_result', callId: item.call.id, result });
      }
      units.push({ items });
    }
    return units;
  }

  private canRun(): boolean {
    return !this.closing && !this.stopping && !this.recovery && !this.waitingForResume && (this.pending.size > 0 || this.forceRun);
  }

  private kick(): void {
    if (this.pumping || !this.canRun()) return;
    // 先登记 pump 再广播状态，允许观察者同步插话、打断或关闭。
    this.pumping = Promise.resolve().then(() => this.pump()).catch((error: unknown) => {
      this.waitingForResume = true;
      this.emit({ type: 'error', message: message(error) });
    }).then(() => {
      this.pumping = undefined;
      if (this.canRun()) this.kick();
      else this.setPhase('idle');
    });
    this.setPhase('running');
  }

  private async pump(): Promise<void> {
    while (this.canRun()) {
      this.forceRun = false;
      const turn: Turn = {
        id: randomUUID(), controller: new AbortController(), stopRequested: false,
      };
      this.active = turn;
      this.setPhase('running');
      try {
        this.record({ type: 'turn.started', turnId: turn.id });
        await this.runTurn(turn);
      } finally {
        this.active = undefined;
      }
    }
  }

  private checkTurn(turn: Turn): void {
    if (turn.failure) throw turn.failure.error;
    turn.controller.signal.throwIfAborted();
  }

  private async runTurn(turn: Turn): Promise<void> {
    let outcome: Outcome = { kind: 'completed' };
    let requests = 0;
    try {
      while (true) {
        this.checkTurn(turn);
        const followUp = await this.sample(turn, requests);
        requests++;
        this.checkTurn(turn);
        if (followUp || this.pending.size) continue;
        const feedback = await this.options.beforeStop?.(turn.id);
        this.checkTurn(turn);
        if (feedback) this.record({ type: 'turn.feedback', turnId: turn.id, text: feedback });
        if (feedback || this.pending.size) continue;
        break;
      }
    } catch (error) {
      outcome = this.classify(turn, error);
    }
    this.setPhase('finishing');
    try { await this.options.afterTurn?.(turn.id, outcome); }
    catch (error) {
      outcome = { kind: 'failed', message: `回合收尾失败：${message(error)}` };
    }
    if (this.storageFailed) outcome = { kind: 'failed', message: this.recovery!.message };
    this.lastOutcome = outcome;
    this.waitingForResume = outcome.kind === 'failed';
    if (!this.storageFailed) this.record({ type: 'turn.finished', turnId: turn.id, outcome,
      ...(this.recovery ? { recovery: this.recovery } : {}) });
  }

  /** 估算达到上限时先压缩全部已有历史；自动压缩后尚未实测就不再触发，避免粗估偏高时反复压缩。 */
  private async autoCompact(turn: Turn, prepared: HarnessRequest, context: ContextAssembly, configuration: RequestSnapshot, extra: ContextItem[]): Promise<void> {
    const window = configuration.settings.contextWindow;
    const first = this.segments[0];
    if (window === undefined || !first) return;
    const limit = Math.floor(window * AUTO_COMPACT_RATIO);
    const changed = this.contextChanged;
    if (changed?.automatic && !this.segments.some((segment) => 'usage' in segment && segment.usage && segment.seq > changed.seq)) return;
    if (this.estimate(context.instructions, configuration.tools, extra) < limit) return;
    this.validateRange(first.seq, Infinity);
    this.compaction = { controller: turn.controller };
    this.emit({ type: 'state', state: this.state });
    try {
      await this.summarize({ id: randomUUID(), from: first.seq, automatic: true, range: '从会话开头到现在',
        prepared, context, configuration, signal: turn.controller.signal, turnId: turn.id });
    } catch (error) {
      this.checkTurn(turn);
      throw new Error(`上下文压缩失败：${message(error)}`);
    } finally {
      this.compaction = undefined;
      this.emit({ type: 'state', state: this.state });
    }
    this.checkTurn(turn);
  }

  private classify(turn: Turn, error: unknown): Outcome {
    if (this.recovery) return { kind: 'failed', message: this.recovery.message };
    if (turn.failure) return { kind: 'failed', message: message(turn.failure.error) };
    if (turn.stopRequested) return { kind: 'interrupted' };
    return { kind: 'failed', message: message(error) };
  }

  /** 本次请求的基础上下文、可执行工具与配置快照；只校验，不落盘。 */
  private configure(prepared: HarnessRequest): { context: ContextAssembly; tools: Map<string, Tool>; configuration: RequestSnapshot } {
    const source = prepared.instructions;
    const context = assembleContext(typeof source === 'string' ? literalContext(source) : source);
    const tools = new Map<string, Tool>();
    for (const tool of prepared.tools) {
      if (tools.has(tool.name)) throw new Error(`工具名重复：${tool.name}`);
      tools.set(tool.name, tool);
    }
    const definitions = this.toolDefinitions ?? prepared.toolDefinitions
      ?? prepared.tools.map(({ name, description, parameters }) => ({ name, description, parameters }));
    const declarations = new Map<string, ToolDefinition>();
    for (const definition of definitions) if (!declarations.has(definition.name)) declarations.set(definition.name, definition);
    for (const tool of tools.values()) {
      const declared = declarations.get(tool.name);
      if (!declared || JSON.stringify(declared.parameters) !== JSON.stringify(tool.parameters) || declared.description !== tool.description) {
        throw new Error(`工具 ${tool.name} 未声明或定义已变化，请新建会话使用新的工具定义`);
      }
    }
    return { context, tools, configuration: requestSnapshot({ ...prepared.settings, allowedTools: [...tools.keys()] }, definitions) };
  }

  /** 实测用量加之后新增内容的粗估；压缩或撤销之后还没有实测时，整段粗估。 */
  private estimate(instructions: string, tools: ToolDefinition[], extra: ContextItem[]): number {
    const changed = this.contextChanged?.seq ?? 0;
    const measured = this.segments.findLast((segment): segment is SavedRequest => 'usage' in segment && segment.usage !== undefined && segment.seq > changed);
    const pending = [...this.pending].map((id): ContextItem => ({ type: 'input', input: this.inputs.get(id)! }));
    if (!measured) return roughTokens(instructions) + roughTokens(JSON.stringify(tools)) + roughTokens([...this.history(), ...pending, ...extra]);
    const results = measured.items.flatMap((item): ContextItem[] => {
      const result = item.call && measured.results.get(item.call.id);
      return result ? [{ type: 'tool_result', callId: item.call!.id, result }] : [];
    });
    return measured.usage!.input + measured.usage!.output + roughTokens([...results, ...this.history(undefined, measured.seq + 1), ...pending, ...extra]);
  }

  /** 生成摘要并记录压缩；range 是给模型看的范围说明。 */
  private async summarize(options: {
    id: string; from: number; until?: number; automatic: boolean; range: string; prepared: HarnessRequest;
    context: ContextAssembly; configuration: RequestSnapshot; signal: AbortSignal; turnId: string;
  }): Promise<void> {
    const { from, until, signal, prepared } = options;
    const definition = prepared.compactionTemplates?.compact ?? compactTemplate;
    const items: ModelItem[] = [];
    let usage: JsonObject | undefined;
    let completed = false;
    // 历史只到范围末尾，范围之前与之内的前缀都能命中缓存；工具声明不变，但禁止调用。
    for await (const event of prepared.model.stream({
      id: randomUUID(), turnId: options.turnId, cwd: this.options.cwd,
      instructions: this.baseInstructions ?? options.context.instructions,
      history: [...this.history(until), { type: 'feedback', text: compactInstructions(definition, options.range) }],
      tools: structuredClone(options.configuration.tools), allowedTools: [],
    }, signal)) {
      signal.throwIfAborted();
      if (completed) throw new Error('压缩摘要完成后仍收到模型事件');
      if (event.type === 'item') items.push(event.item);
      else if (event.type === 'completed') { completed = true; usage = event.usage; }
    }
    signal.throwIfAborted();
    if (!completed) throw new Error('压缩摘要请求未完成');
    const summary = summaryText(items);
    const at = (seq: number) => this.segments.find((segment) => segment.seq === seq)!.at;
    const changes = await this.options.compactionFiles?.({ from: at(from), to: until === undefined ? Date.now() : at(until) }, signal);
    signal.throwIfAborted();
    const replacement = compactionItems({ range: this.history(until, from), after: until === undefined ? [] : this.history(undefined, until),
      automatic: options.automatic, summary, definition,
      ...(changes ? { files: { changes, ...(prepared.compactionTemplates?.fileChanges ? { definition: prepared.compactionTemplates.fileChanges } : {}) } } : {}) });
    this.record({ type: 'context.compacted', id: options.id, range: { from, ...(until !== undefined ? { until } : {}) },
      automatic: options.automatic, items: replacement, summary, ...(usage ? { usage } : {}) });
  }

  private async sample(turn: Turn, requests: number): Promise<boolean> {
    this.checkTurn(turn);
    const requestId = randomUUID();
    const ids = { turnId: turn.id, requestId };
    const prepared = this.options.prepareRequest({ afterNotification: this.notificationCursor });
    const { context, tools, configuration } = this.configure(prepared);
    const budget = configuration.settings.maxRequestsPerTurn;
    if (budget !== undefined && requests >= budget) throw new Error(`达到本回合 ${budget} 次模型请求预算`);
    const notifications = (prepared.notifications ?? []).map((notification) => notificationSchema.parse(notification));
    let cursor = this.notificationCursor;
    const seen = new Set(this.deliveredNotifications);
    for (const notification of notifications) {
      if (seen.has(notification.id)) throw new Error('宿主重复提供已投递通知');
      seen.add(notification.id);
      if (notification.sequence !== undefined) {
        if (notification.sequence <= cursor) throw new Error('宿主通知顺序无效');
        cursor = notification.sequence;
      }
    }
    if (this.currentInstructions !== undefined && this.currentInstructions !== context.instructions) notifications.push({
      id: randomUUID(), kind: 'context.updated', source: 'host.context', authority: 'instruction',
      context: assembleContext(contextUpdateContext(context.instructions, prepared.contextUpdateTemplate)).snapshot,
    });
    await this.autoCompact(turn, prepared, context, configuration, notifications.map(({ context, ...notification }) => ({
      type: 'notification', notification, text: restoreContext(context).instructions })));
    if (!this.contexts.has(context.snapshot.id)) this.record({ type: 'context.prepared', snapshot: context.snapshot });
    if (!this.configurations.has(configuration.id)) this.record({ type: 'request.configured', snapshot: configuration });
    this.checkTurn(turn);
    this.record({ type: 'request.started', ...ids, inputIds: [...this.pending], contextId: context.snapshot.id,
      configurationId: configuration.id, notifications });
    this.baseInstructions ??= context.instructions;
    this.currentInstructions = context.instructions;
    this.toolDefinitions ??= structuredClone(configuration.tools);
    const saved = this.requests.get(requestId)!;
    const batch = new ToolBatch({
      cwd: this.options.cwd, signal: turn.controller.signal, turnId: turn.id, tools,
      started: (call) => this.record({ type: 'tool.started', ...ids, callId: call.id }),
      finished: (call, result) => this.record({ type: 'tool.finished', ...ids, callId: call.id, result }),
      output: (call, text, limit) => this.emit({ type: 'tool.output', ...ids, callId: call.id, text, limit }),
      fatal: (error) => { turn.failure ??= { error }; turn.controller.abort(); },
    });
    let needsFollowUp = false;
    let failure: { error: unknown } | undefined;
    try {
      this.checkTurn(turn);
      const stream = prepared.model.stream({
        id: requestId, turnId: turn.id, cwd: this.options.cwd,
        instructions: this.baseInstructions!,
        history: this.history(), tools: structuredClone(configuration.tools), allowedTools: [...tools.keys()],
      }, turn.controller.signal);
      for await (const event of stream) {
        this.checkTurn(turn);
        if (saved.ended) throw new Error('模型在响应完成之后继续发送事件');
        switch (event.type) {
          case 'item.started': case 'delta': this.emit({ ...event, ...ids }); break;
          case 'item': {
            if (!event.item.id || saved.items.some((item) => item.id === event.item.id)) throw new Error('模型输出条目 id 无效或重复');
            if (event.item.call && (!event.item.call.id || this.calls.has(event.item.call.id) || this.importedCalls.has(event.item.call.id))) throw new Error('模型工具调用 id 无效或重复');
            this.record({ type: 'model.item', ...ids, item: event.item });
            if (event.item.call) batch.enqueue(structuredClone(event.item.call));
            break;
          }
          case 'completed':
            this.record({ type: 'request.completed', ...ids, responseId: event.responseId,
              needsFollowUp: event.needsFollowUp ?? false, ...(event.usage ? { usage: event.usage } : {}),
            });
            needsFollowUp = event.needsFollowUp ?? false;
            break;
          default: throw new Error('未知模型流事件');
        }
      }
      if (!saved.ended) throw new Error('模型响应流未给出完成事件');
    } catch (error) {
      failure = { error };
      if (!turn.stopRequested) turn.failure ??= failure;
      turn.controller.abort();
      if (!saved.ended && !this.storageFailed) this.record({ type: 'request.failed', ...ids, message: message(error) });
    } finally {
      // 先停止/收齐已启动的任务。即使记录失败，仍必须等执行本身结束。
      try { await batch.drain(); }
      catch (error) { failure ??= { error }; }
      if (batch.calls.length) {
        try { await this.options.afterTools?.(turn.id, batch.calls.map((call) => call.id)); }
        catch (error) {
          const snapshotFailure = { error: new Error(`工具批次收尾失败：${message(error)}`) };
          failure ??= snapshotFailure;
          turn.failure ??= snapshotFailure;
        }
      }
    }
    if (failure) throw failure.error;
    this.checkTurn(turn);
    return needsFollowUp || batch.calls.length > 0;
  }
}
