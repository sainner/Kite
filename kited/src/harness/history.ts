/** Journal 的同步投影：请求、工具与压缩段共享同一份历史状态。 */
import { restoreContext } from './context/assembler.ts';
import { roughTokens } from './compaction.ts';
import type { ContextItem, Input, JournalRecord, ModelItem, Outcome, Recovery, ToolDefinition, ToolResult } from './types.ts';

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
  const history = new HarnessHistory(records);
  if (history.openTurn) throw new Error('只读重放不能追加记录或请求模型');
  return history.contextUnits();
}

export class HarnessHistory {
  readonly inputs = new Map<string, Input>();
  readonly pending = new Set<string>();
  readonly requests = new Map<string, SavedRequest>();
  /** 完整快照留在 journal；运行中只保留固定前缀和当前有效正文。 */
  readonly contexts = new Set<string>();
  readonly configurations = new Set<string>();
  baseInstructions?: string;
  currentInstructions?: string;
  toolDefinitions?: ToolDefinition[];
  notificationCursor = 0;
  readonly deliveredNotifications = new Set<string>();
  readonly calls = new Map<string, SavedRequest>();
  /** 从其他后端导入的调用已有结果，只用于防止 ID 重复。 */
  readonly importedCalls = new Set<string>();
  readonly segments: Segment[] = [];
  readonly compactions = new Map<string, Compaction>();
  /** 最近一次压缩或撤销；此前的实测用量不再代表当前历史。 */
  contextChanged?: { seq: number; automatic: boolean };
  openTurn?: string;
  lastOutcome?: Outcome;
  waitingForResume = false;
  recovery?: Recovery;
  readonly stops = new Map<string, Input[]>();

  constructor(records: readonly JournalRecord[]) {
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
  }

  /** 同步重放事实；损坏的关联不能静默生成一份看似正常的上下文。 */
  apply(row: JournalRecord): void {
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

  /** 输入所在的段；导入段只能从开头的那条输入切开。 */
  inputSegment(id: string): { segment: Segment; input: Input } {
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
  validateRange(from: number, end: number): void {
    for (const compaction of this.compactions.values()) {
      if (compaction.reverted || compaction.end <= from || compaction.from >= end) continue;
      if (from <= compaction.from && compaction.end <= end) continue;
      throw new Error('压缩范围与已有的压缩部分重叠；请先撤销那次压缩，或选择完整包含它的范围');
    }
    if (!this.segments.some((segment) => segment.seq >= from && segment.seq < end)) throw new Error('压缩范围内没有内容');
  }

  /** 仍然生效、且不被其他压缩包含的压缩；范围相同时较新的在外层。 */
  outermost(): Compaction[] {
    const active = [...this.compactions.values()].filter((compaction) => !compaction.reverted);
    return active.filter((inner) => !active.some((outer) => outer !== inner && outer.from <= inner.from && inner.end <= outer.end
      && (outer.from < inner.from || inner.end < outer.end || outer.seq > inner.seq)));
  }

  contextUnits(): ContextUnit[] { return structuredClone(this.units()); }

  /** 实际进入请求的历史；可只取 seq 位于 [from, until) 的段，被压缩的段换成替代内容。 */
  items(until?: number, from?: number): ContextItem[] {
    return structuredClone(this.itemsView(until, from));
  }

  /** 同 items，但不拷贝：只供只读遍历，不能改动。 */
  itemsView(until?: number, from?: number): ContextItem[] {
    return this.units(until, from).flatMap((unit) => unit.items);
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

  /** 实测用量加之后新增内容的粗估；压缩或撤销之后还没有实测时，整段粗估。 */
  estimate(instructions: string, tools: ToolDefinition[], extra: ContextItem[]): number {
    const changed = this.contextChanged?.seq ?? 0;
    const measured = this.segments.findLast((segment): segment is SavedRequest => 'usage' in segment && segment.usage !== undefined && segment.seq > changed);
    const pending = [...this.pending].map((id): ContextItem => ({ type: 'input', input: this.inputs.get(id)! }));
    if (!measured) return roughTokens(instructions) + roughTokens(JSON.stringify(tools)) + roughTokens([...this.items(), ...pending, ...extra]);
    const results = measured.items.flatMap((item): ContextItem[] => {
      const result = item.call && measured.results.get(item.call.id);
      return result ? [{ type: 'tool_result', callId: item.call!.id, result }] : [];
    });
    return measured.usage!.input + measured.usage!.output + roughTokens([...results, ...this.items(undefined, measured.seq + 1), ...pending, ...extra]);
  }

}
