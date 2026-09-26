/** 自研会话循环：控制入口保持可用，单个 pump 推进模型、工具和收尾。 */
import { randomUUID } from 'node:crypto';
import { ToolBatch } from './tools.ts';
import { assembleContext, literalContext } from './context/assembler.ts';
import type {
  ContextItem, Input, JournalEvent, JournalRecord, ModelItem, Outcome, Phase,
  SessionEvent, SessionOptions, SessionRunner, SessionState, Tool, ToolResult,
} from './types.ts';

interface SavedRequest {
  id: string;
  turnId: string;
  inputs: Input[];
  items: ModelItem[];
  started: Set<string>;
  results: Map<string, ToolResult>;
  ended: boolean;
}

interface Turn {
  id: string;
  controller: AbortController;
  done: Promise<void>;
  resolve(): void;
  stopRequested: boolean;
  initialInputs: string[];
  hasRequest: boolean;
  failure?: { error: unknown };
}

const message = (error: unknown) => error instanceof Error ? error.message : String(error);

export class HarnessSession implements SessionRunner {
  private inputs = new Map<string, Input>();
  private pending = new Set<string>();
  private requests = new Map<string, SavedRequest>();
  private contexts = new Set<string>();
  private calls = new Map<string, SavedRequest>();
  private segments: Array<SavedRequest | { feedback: string }> = [];
  private openTurn?: string;
  private active?: Turn;
  private pumping?: Promise<void>;
  private phase: Phase = 'idle';
  private lastOutcome?: Outcome;
  private paused = false;
  private blocked = false;
  private storageFailed = false;
  private closing = false;
  private closed = false;
  private forceRun = false;
  private tools = new Map<string, Tool>();

  constructor(private options: SessionOptions) {
    if (options.maxRequestsPerTurn !== undefined &&
      (!Number.isSafeInteger(options.maxRequestsPerTurn) || options.maxRequestsPerTurn < 1)) {
      throw new Error('模型请求预算必须是正整数');
    }
    for (const tool of options.tools) {
      if (this.tools.has(tool.name)) throw new Error(`工具名重复：${tool.name}`);
      this.tools.set(tool.name, tool);
    }
    for (const row of options.journal.records) this.apply(row);
    this.recover();
    if (options.startPaused && this.pending.size) this.paused = true;
    this.phase = this.blocked ? 'needs_recovery' : this.paused ? 'paused' : 'idle';
    this.kick();
  }

  get state(): SessionState {
    return {
      phase: this.phase, busy: !!this.active || !!this.pumping || this.blocked,
      ...(this.active ? { turnId: this.active.id } : {}),
      ...(this.lastOutcome ? { lastOutcome: structuredClone(this.lastOutcome) } : {}),
    };
  }

  async send(input: Input): Promise<void> {
    this.assertOpen();
    if (!input.id || !input.text.trim() || !['human', 'kite'].includes(input.source)) throw new Error('输入 id、正文和来源必须有效');
    const previous = this.inputs.get(input.id);
    if (previous) {
      if (previous.text !== input.text || previous.source !== input.source) throw new Error(`输入 id 冲突：${input.id}`);
      return;
    }
    this.record({ type: 'input.received', input });
    this.kick();
  }

  async cancel(inputId: string): Promise<void> {
    this.assertOpen();
    if (!this.pending.has(inputId)) throw new Error('只能撤回尚未纳入请求的输入');
    this.record({ type: 'input.cancelled', inputId });
  }

  async interrupt(): Promise<void> {
    const turn = this.active;
    if (!turn) {
      // pump 还没开始时，将此刻等待首个请求的输入撤回；后来到达的输入不受影响。
      if (this.pumping) {
        for (const inputId of [...this.pending]) this.record({ type: 'input.cancelled', inputId });
        this.forceRun = false;
      }
      return;
    }
    if (this.phase !== 'finishing') {
      turn.stopRequested = true;
      if (!turn.hasRequest && !this.closing) {
        for (const inputId of turn.initialInputs) {
          if (this.pending.has(inputId)) this.record({ type: 'input.cancelled', inputId });
        }
      }
      this.setPhase('stopping');
      turn.controller.abort();
    }
    await turn.done;
  }

  async resume(): Promise<void> {
    this.assertOpen();
    if (this.blocked) throw new Error('会话需要先确认恢复');
    if (this.active) return;
    if (!this.pending.size && !this.segments.length) throw new Error('没有可以继续的会话内容');
    this.paused = false;
    this.forceRun = true;
    this.kick();
  }

  async confirmRecovery(): Promise<void> {
    this.assertOpen();
    if (this.active || this.pumping) throw new Error('执行尚未停止，不能确认恢复');
    if (this.storageFailed) throw new Error('记录写入失败，须重新打开并检查会话');
    if (!this.blocked) return;
    this.record({ type: 'recovery.confirmed' });
    this.setPhase('paused');
  }

  async shutdown(): Promise<void> {
    if (this.closed) return;
    this.closing = true;
    if (this.active) await this.interrupt();
    await this.settled();
    if (!this.closed) {
      this.closed = true;
      this.options.journal.close();
      this.setPhase('closed');
    }
  }

  async settled(): Promise<void> {
    while (this.pumping) await this.pumping;
  }

  private assertOpen(): void {
    if (this.closing || this.closed) throw new Error('会话正在关闭或已关闭');
    if (this.storageFailed) throw new Error('会话记录写入失败，须重新打开');
  }

  private emit(event: SessionEvent): void {
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
      this.blocked = true;
      this.lastOutcome = { kind: 'needs_recovery', message: `会话记录写入失败：${message(error)}` };
      if (this.active) {
        this.active.failure ??= { error };
        this.active.controller.abort();
      }
      this.setPhase('needs_recovery');
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
        if (!this.blocked) this.paused = false;
        return;
      case 'input.cancelled':
        if (!this.pending.delete(row.inputId)) throw new Error('记录撤回了非待处理输入');
        return;
      case 'turn.started':
        if (this.openTurn) throw new Error('记录包含重叠回合');
        this.openTurn = row.turnId;
        return;
      case 'context.prepared':
        if (this.contexts.has(row.snapshot.id)) throw new Error('上下文快照重复');
        this.contexts.add(row.snapshot.id);
        return;
      case 'request.started': {
        if (this.openTurn !== row.turnId || this.requests.has(row.requestId)) throw new Error('请求关联的回合或 id 无效');
        if (row.contextId !== undefined && !this.contexts.has(row.contextId)) throw new Error('请求引用了未保存的上下文');
        if (this.unfinishedRequest()) throw new Error('上一请求或工具尚未结束，不能开始新请求');
        const inputs = row.inputIds.map((id) => {
          if (!this.pending.delete(id)) throw new Error('请求使用了非待处理输入');
          return this.inputs.get(id)!;
        });
        const request: SavedRequest = { id: row.requestId, turnId: row.turnId, inputs, items: [], started: new Set(), results: new Map(), ended: false };
        this.requests.set(row.requestId, request);
        this.segments.push(request);
        return;
      }
      case 'model.item': {
        const request = this.mustRequest(row);
        if (request.ended || request.items.some((item) => item.id === row.item.id)) throw new Error('重复或已结束请求的输出条目');
        if (row.item.call) {
          if (this.calls.has(row.item.call.id)) throw new Error('工具调用 id 重复');
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
        if (row.result.status === 'unknown') this.blocked = true;
        return;
      }
      case 'turn.feedback':
        if (this.openTurn !== row.turnId) throw new Error('停止反馈不属于当前回合');
        this.segments.push({ feedback: row.text });
        return;
      case 'turn.finished':
        if (this.openTurn !== row.turnId) throw new Error('回合结束记录不匹配');
        if (this.unfinishedRequest()?.turnId === row.turnId) throw new Error('回合结束时仍有未完成的请求或工具');
        this.openTurn = undefined;
        this.lastOutcome = row.outcome;
        this.paused = row.outcome.kind === 'failed' || row.outcome.kind === 'needs_recovery';
        if (row.outcome.kind === 'needs_recovery') this.blocked = true;
        if (row.outcome.kind !== 'completed') this.segments.push({
          feedback: row.outcome.kind === 'interrupted'
            ? '上一回合被打断。已完成的工具操作没有被撤销；请根据实际结果继续。'
            : `上一回合未完成：${row.outcome.message}。不要自动重复已有工具调用，先检查实际状态。`,
        });
        return;
      case 'recovery.confirmed':
        if (this.openTurn) throw new Error('回合尚未收尾，不能确认恢复');
        this.blocked = false;
        this.paused = true;
        this.segments.push({ feedback: '宿主已确认先前的执行停止。结果未知的操作仍需检查实际效果，不能假定已回滚。' });
        return;
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
    this.record({ type: 'turn.finished', turnId, outcome: this.blocked
      ? { kind: 'needs_recovery', message: '存在执行结果未知的工具，等待宿主确认残留执行停止' }
      : { kind: 'failed', message: '宿主退出中断了上一回合，等待显式继续' } });
  }

  private history(): ContextItem[] {
    const history: ContextItem[] = [];
    for (const segment of this.segments) {
      if ('feedback' in segment) { history.push({ type: 'feedback', text: segment.feedback }); continue; }
      for (const input of segment.inputs) history.push({ type: 'input', input });
      for (const item of segment.items) history.push({ type: 'output', item });
      for (const item of segment.items) {
        if (!item.call) continue;
        const result = segment.results.get(item.call.id);
        if (result) history.push({ type: 'tool_result', callId: item.call.id, result });
      }
    }
    return structuredClone(history);
  }

  private canRun(): boolean {
    return !this.closing && !this.blocked && !this.paused && (this.pending.size > 0 || this.forceRun);
  }

  private kick(): void {
    if (this.pumping || !this.canRun()) return;
    // 先登记 pump 再广播状态，允许观察者同步插话、打断或关闭。
    this.pumping = Promise.resolve().then(() => this.pump()).catch((error: unknown) => {
      this.paused = true;
      this.emit({ type: 'error', message: message(error) });
    }).then(() => {
      this.pumping = undefined;
      if (this.canRun()) this.kick();
      else this.setPhase(this.blocked ? 'needs_recovery' : this.paused ? 'paused' : 'idle');
    });
    this.setPhase('running');
  }

  private async pump(): Promise<void> {
    while (this.canRun()) {
      this.forceRun = false;
      let resolve!: () => void;
      const done = new Promise<void>((r) => { resolve = r; });
      const turn: Turn = {
        id: randomUUID(), controller: new AbortController(), done, resolve, stopRequested: false,
        initialInputs: [...this.pending], hasRequest: false,
      };
      this.active = turn;
      this.setPhase('running');
      try {
        this.record({ type: 'turn.started', turnId: turn.id });
        await this.runTurn(turn);
      } finally {
        this.active = undefined;
        turn.resolve();
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
        if (this.options.maxRequestsPerTurn !== undefined && requests >= this.options.maxRequestsPerTurn) {
          throw new Error(`达到本回合 ${this.options.maxRequestsPerTurn} 次模型请求预算`);
        }
        const followUp = await this.sample(turn);
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
      if (outcome.kind !== 'needs_recovery') outcome = { kind: 'failed', message: `回合收尾失败：${message(error)}` };
    }
    if (this.storageFailed) outcome = { kind: 'needs_recovery', message: '会话记录写入失败，必须重新打开并检查' };
    this.lastOutcome = outcome;
    this.paused = outcome.kind === 'failed' || outcome.kind === 'needs_recovery';
    if (outcome.kind === 'needs_recovery') this.blocked = true;
    if (!this.storageFailed) this.record({ type: 'turn.finished', turnId: turn.id, outcome });
  }

  private classify(turn: Turn, error: unknown): Outcome {
    if (this.blocked) return { kind: 'needs_recovery', message: message(error) };
    if (turn.failure) return { kind: 'failed', message: message(turn.failure.error) };
    if (turn.stopRequested) return { kind: 'interrupted' };
    return { kind: 'failed', message: message(error) };
  }

  private async sample(turn: Turn): Promise<boolean> {
    this.checkTurn(turn);
    const requestId = randomUUID();
    const ids = { turnId: turn.id, requestId };
    const source = typeof this.options.instructions === 'function' ? this.options.instructions() : this.options.instructions;
    const context = assembleContext(typeof source === 'string' ? literalContext(source) : source);
    if (!this.contexts.has(context.snapshot.id)) this.record({ type: 'context.prepared', snapshot: context.snapshot });
    this.checkTurn(turn);
    turn.hasRequest = true;
    this.record({ type: 'request.started', ...ids, inputIds: [...this.pending], contextId: context.snapshot.id });
    const saved = this.requests.get(requestId)!;
    const batch = new ToolBatch({
      cwd: this.options.cwd, signal: turn.controller.signal, tools: this.tools,
      started: (call) => this.record({ type: 'tool.started', ...ids, callId: call.id }),
      finished: (call, result) => this.record({ type: 'tool.finished', ...ids, callId: call.id, result }),
      fatal: (error) => { turn.failure ??= { error }; turn.controller.abort(); },
    });
    let needsFollowUp = false;
    let failure: { error: unknown } | undefined;
    try {
      this.checkTurn(turn);
      const definitions = [...this.tools.values()].map(({ name, description, parameters }) => ({ name, description, parameters }));
      const stream = this.options.model.stream({
        id: requestId, turnId: turn.id, cwd: this.options.cwd, instructions: context.instructions,
        history: this.history(), tools: structuredClone(definitions),
      }, turn.controller.signal);
      for await (const event of stream) {
        this.checkTurn(turn);
        if (saved.ended) throw new Error('模型在响应完成之后继续发送事件');
        switch (event.type) {
          case 'delta': this.emit({ type: 'delta', ...ids, text: event.text, ...(event.itemId ? { itemId: event.itemId } : {}) }); break;
          case 'item': {
            if (!event.item.id || saved.items.some((item) => item.id === event.item.id)) throw new Error('模型输出条目 id 无效或重复');
            if (event.item.call && (!event.item.call.id || this.calls.has(event.item.call.id))) throw new Error('模型工具调用 id 无效或重复');
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
