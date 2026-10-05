/** 单个线程的执行实例：控制入口保持可用，单个 pump 推进模型、工具和收尾。 */
import { randomUUID } from 'node:crypto';
import { ToolBatch } from './tools.ts';
import { assembleContext, literalContext, restoreContext } from './context/assembler.ts';
import { contextUpdateContext } from './context/notifications.ts';
import { notificationSchema, requestSnapshot } from './request-config.ts';
import type {
  ContextItem, Input, JournalEvent, JournalRecord, ModelItem, Outcome, Phase, Recovery, StopRequest,
  HarnessEvent, HarnessOptions, ThreadRunner, ThreadState, Tool, ToolDefinition, ToolResult,
} from './types.ts';

interface SavedRequest {
  id: string;
  turnId: string;
  inputs: Input[];
  notifications: Extract<ContextItem, { type: 'notification' }>[];
  items: ModelItem[];
  started: Set<string>;
  results: Map<string, ToolResult>;
  ended: boolean;
}

interface Turn {
  id: string;
  controller: AbortController;
  stopRequested: boolean;
  failure?: { error: unknown };
}

const message = (error: unknown) => error instanceof Error ? error.message : String(error);

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
  private segments: Array<SavedRequest | { feedback: string }> = [];
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
    }
    this.recover();
    if (options.startPaused && this.pending.size) this.waitingForResume = true;
    this.phase = 'idle';
    this.kick();
  }

  get state(): ThreadState {
    return {
      phase: this.phase, busy: !!this.active || !!this.pumping,
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
          items: [], started: new Set(), results: new Map(), ended: false };
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
        if (row.result.status === 'unknown') this.recovery = { message: row.result.output || '存在执行结果未知的工具，等待确认残留执行停止' };
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
        this.waitingForResume = row.outcome.kind === 'failed';
        if (row.recovery) this.recovery = structuredClone(row.recovery);
        if (row.outcome.kind !== 'completed') this.segments.push({
          feedback: row.outcome.kind === 'interrupted'
            ? '上一回合被打断。已完成的工具操作没有被撤销；请根据实际结果继续。'
            : `上一回合未完成：${row.outcome.message}。不要自动重复已有工具调用，先检查实际状态。`,
        });
        return;
      case 'recovery.confirmed':
        if (this.openTurn) throw new Error('回合尚未收尾，不能确认恢复');
        this.recovery = undefined;
        this.waitingForResume = true;
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
    this.record({ type: 'turn.finished', turnId, outcome: { kind: 'failed',
      message: this.recovery?.message ?? '宿主退出中断了上一回合，等待显式继续' },
      ...(this.recovery ? { recovery: this.recovery } : {}) });
  }

  private history(): ContextItem[] {
    const history: ContextItem[] = [];
    for (const segment of this.segments) {
      if ('feedback' in segment) { history.push({ type: 'feedback', text: segment.feedback }); continue; }
      history.push(...segment.notifications);
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

  private classify(turn: Turn, error: unknown): Outcome {
    if (this.recovery) return { kind: 'failed', message: this.recovery.message };
    if (turn.failure) return { kind: 'failed', message: message(turn.failure.error) };
    if (turn.stopRequested) return { kind: 'interrupted' };
    return { kind: 'failed', message: message(error) };
  }

  private async sample(turn: Turn, requests: number): Promise<boolean> {
    this.checkTurn(turn);
    const requestId = randomUUID();
    const ids = { turnId: turn.id, requestId };
    const prepared = this.options.prepareRequest({ afterNotification: this.notificationCursor });
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
    const configuration = requestSnapshot({ ...prepared.settings, allowedTools: [...tools.keys()] }, definitions);
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
