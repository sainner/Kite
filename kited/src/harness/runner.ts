/** 单个线程的执行实例：控制入口保持可用，单个 pump 推进模型、工具和收尾。 */
import { randomUUID } from 'node:crypto';
import { ToolBatch } from './tools.ts';
import { HarnessHistory, type ContextUnit } from './history.ts';
import { inputSchema, returnedOnStop, sameInput } from './input.ts';
import { loadedDefinitions, sameDefinition, TOOL_SEARCH } from './tool-search.ts';
import { assembleContext, literalContext, restoreContext } from './context/assembler.ts';
import { contextUpdateContext } from './context/notifications.ts';
import { notificationSchema, requestSnapshot } from './request-config.ts';
import { AUTO_COMPACT_RATIO, compactInstructions, compactionItems, compactTemplate, summaryText } from './compaction.ts';
import type { ContextAssembly } from './context/types.ts';
import type {
  CompactionRequest, ContextItem, HarnessRequest, Input, JournalEvent, JournalRecord, JsonObject, ModelItem, Outcome, Phase,
  RequestSnapshot, StopRequest, HarnessEvent, HarnessOptions, ThreadRunner, ThreadState, Tool, ToolDefinition, ToolImage,
} from './types.ts';

const quote = (text: string) => {
  const line = text.replace(/\s+/g, ' ').trim();
  return `「${line.length > 60 ? line.slice(0, 60) + '…' : line}」`;
};

interface Turn {
  id: string;
  controller: AbortController;
  stopRequested: boolean;
  failure?: { error: unknown };
}

const message = (error: unknown) => error instanceof Error ? error.message : String(error);

/** 加载之后插件升级、定义变了：不按旧参数执行，让模型重新加载。 */
const staleTool = (tool: Tool): Tool => ({ ...tool, validate() {},
  async execute() { return { status: 'error', output: `工具 ${tool.name} 的定义已变化，请先用 ${TOOL_SEARCH} 重新加载再调用` }; } });

export class HarnessRunner implements ThreadRunner {
  private readonly history: HarnessHistory;
  /** 正在生成压缩摘要；自动压缩沿用回合的取消信号。 */
  private compaction?: { controller: AbortController };
  private active?: Turn;
  private pumping?: Promise<void>;
  private phase: Phase = 'idle';
  private stopping?: string;
  private storageFailed = false;
  private closing = false;
  private closed = false;
  private forceRun = false;

  constructor(private options: HarnessOptions) {
    this.history = new HarnessHistory(options.journal.records);
    this.recover();
    if (options.startPaused && this.history.pending.size) this.history.waitingForResume = true;
    this.phase = 'idle';
    this.kick();
  }

  get state(): ThreadState {
    return {
      phase: this.phase, busy: !!this.active || !!this.pumping,
      ...(this.compaction ? { compacting: true } : {}),
      waitingForResume: this.history.waitingForResume,
      ...(this.history.recovery ? { recovery: structuredClone(this.history.recovery) } : {}),
      ...(this.active ? { turnId: this.active.id } : {}),
      ...(this.history.lastOutcome ? { lastOutcome: structuredClone(this.history.lastOutcome) } : {}),
    };
  }

  get lifecycle(): 'open' | 'closing' | 'closed' { return this.closed ? 'closed' : this.closing ? 'closing' : 'open'; }

  /** images 是附件里的图片交给模型的样子，由宿主在收下时给出，随这条输入记下。 */
  async send(input: Input, images?: ToolImage[]): Promise<boolean> {
    this.assertOpen();
    if (!inputSchema.safeParse(input).success) throw new Error('输入 id、正文和来源必须有效');
    const previous = this.history.inputs.get(input.id);
    if (previous) {
      if (!sameInput(previous, input)) throw new Error(`输入 id 冲突：${input.id}`);
      return false;
    }
    if (this.stopping) throw new Error('会话正在停止，请稍后发送');
    if (this.history.recovery) throw new Error('会话需要先确认恢复');
    this.record({ type: 'input.received', input, ...(images?.length ? { images } : {}) });
    this.kick();
    return true;
  }

  async cancel(inputId: string): Promise<void> {
    this.assertOpen();
    if (!this.history.pending.has(inputId)) throw new Error('只能撤回尚未纳入请求的输入');
    this.record({ type: 'input.cancelled', inputId });
  }

  async interrupt(request: StopRequest = { id: randomUUID() }): Promise<Input[]> {
    this.assertOpen();
    if (!request.id) throw new Error('停止请求必须有 id');
    const previous = this.history.stops.get(request.id);
    if (previous) {
      if (this.stopping === request.id) await this.settled();
      return structuredClone(previous);
    }
    if (this.stopping) throw new Error('会话正在停止，请重试原停止请求');
    const returned = new Map<string, Input>();
    for (const id of this.history.pending) {
      const input = this.history.inputs.get(id)!;
      if (returnedOnStop(input, request.by)) returned.set(input.id, input);
    }
    for (const input of request.inputs ?? []) {
      if (!inputSchema.safeParse(input).success) throw new Error('待核定输入无效');
      const known = this.history.inputs.get(input.id) ?? returned.get(input.id);
      if (known && !sameInput(known, input)) throw new Error(`输入 id 冲突：${input.id}`);
      if (!known) returned.set(input.id, input);
    }
    // 冻结后再落盘；同步事件观察者也不能趁这段窗口提交下一回合。
    this.stopping = request.id;
    this.forceRun = false;
    try {
      this.record({ type: 'thread.stopped', id: request.id, returned: [...returned.values()] });
      this.stopActive();
      await this.settled();
      return structuredClone(this.history.stops.get(request.id)!);
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
    if (this.history.recovery) throw new Error('会话需要先确认恢复');
    if (this.stopping) throw new Error('会话正在停止，请稍后继续');
    if (this.active) return;
    if (!this.history.pending.size && !this.history.segments.length) throw new Error('没有可以继续的会话内容');
    this.history.waitingForResume = false;
    this.forceRun = true;
    this.kick();
  }

  async confirmRecovery(): Promise<void> {
    this.assertOpen();
    if (this.active || this.pumping) throw new Error('执行尚未停止，不能确认恢复');
    if (this.storageFailed) throw new Error('记录写入失败，须重新打开并检查会话');
    if (!this.history.recovery) return;
    this.record({ type: 'recovery.confirmed' });
    this.setPhase('idle');
  }

  async compact(request: CompactionRequest): Promise<void> {
    this.assertOpen();
    if (!request.id) throw new Error('压缩请求必须有 id');
    if (this.history.compactions.has(request.id)) return;
    if (this.active || this.pumping || this.stopping) throw new Error('会话正在执行，空闲后才能压缩');
    if (this.history.recovery) throw new Error('会话需要先确认恢复');
    let from: number;
    let until: number | undefined;
    let range: string;
    if ('automatic' in request) {
      const first = this.history.segments[0];
      if (!first) throw new Error('压缩范围内没有内容');
      from = first.seq;
      range = '从会话开头到现在';
    } else {
      const start = this.history.inputSegment(request.from);
      const last = this.history.inputSegment(request.through);
      if (last.segment.seq < start.segment.seq) throw new Error('压缩终点不能早于起点');
      // 终点所在的那一轮包括到下一条输入纳入之前；导入段不能拆开，也算边界。
      until = this.history.segments.find((segment) => segment.seq > last.segment.seq
        && ('imported' in segment || ('inputs' in segment && segment.inputs.length > 0)))?.seq;
      from = start.segment.seq;
      // 写明两端：Claude 的摘要在完整原生上下文上生成，看得到范围之后的内容。
      range = start.input.id === last.input.id ? `用户消息${quote(start.input.text)}所在的那一轮`
        : `从用户消息${quote(start.input.text)}开始到用户消息${quote(last.input.text)}所在的那一轮结束`;
    }
    this.history.validateRange(from, until ?? Infinity);
    const controller = new AbortController();
    this.compaction = { controller };
    this.pumping = (async () => {
      const prepared = this.options.prepareRequest({ afterNotification: this.history.notificationCursor });
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
    if (this.history.recovery) throw new Error('会话需要先确认恢复');
    const compaction = this.history.compactions.get(id);
    if (!compaction) throw new Error('没有这次压缩');
    if (compaction.reverted) return;
    if (!this.history.outermost().includes(compaction)) throw new Error('只能撤销最外层的压缩');
    this.record({ type: 'context.compaction.reverted', id });
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
      this.history.recovery = { message: `会话记录写入失败：${message(error)}` };
      this.history.lastOutcome = { kind: 'failed', message: this.history.recovery.message };
      if (this.active) {
        this.active.failure ??= { error };
        this.active.controller.abort();
      }
      this.emit({ type: 'state', state: this.state });
      throw error;
    }
    this.history.apply(row);
    this.emit({ type: 'record', record: row });
  }

  private recover(): void {
    const turnId = this.history.openTurn;
    if (!turnId) return;
    for (const request of this.history.requests.values()) {
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
      message: this.history.recovery?.message ?? '宿主退出中断了上一回合，等待显式继续' },
      ...(this.history.recovery ? { recovery: this.history.recovery } : {}) });
  }

  contextUnits(): ContextUnit[] { return this.history.contextUnits(); }

  private canRun(): boolean {
    return !this.closing && !this.stopping && !this.history.recovery && !this.history.waitingForResume && (this.history.pending.size > 0 || this.forceRun);
  }

  private kick(): void {
    if (this.pumping || !this.canRun()) return;
    // 先登记 pump 再广播状态，允许观察者同步插话、打断或关闭。
    this.pumping = Promise.resolve().then(() => this.pump()).catch((error: unknown) => {
      this.history.waitingForResume = true;
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
    try {
      while (true) {
        this.checkTurn(turn);
        const followUp = await this.sample(turn);
        this.checkTurn(turn);
        if (followUp || this.history.pending.size) continue;
        const feedback = await this.options.beforeStop?.(turn.id);
        this.checkTurn(turn);
        if (feedback) this.record({ type: 'turn.feedback', turnId: turn.id, text: feedback });
        if (feedback || this.history.pending.size) continue;
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
    if (this.storageFailed) outcome = { kind: 'failed', message: this.history.recovery!.message };
    this.history.lastOutcome = outcome;
    this.history.waitingForResume ||= outcome.kind === 'failed';
    if (!this.storageFailed) this.record({ type: 'turn.finished', turnId: turn.id, outcome,
      ...(this.history.recovery ? { recovery: this.history.recovery } : {}) });
  }

  /** 估算达到上限时先压缩全部已有历史；自动压缩后尚未实测就不再触发，避免粗估偏高时反复压缩。 */
  private async autoCompact(turn: Turn, prepared: HarnessRequest, context: ContextAssembly, configuration: RequestSnapshot, extra: ContextItem[]): Promise<void> {
    const window = configuration.settings.contextWindow;
    const first = this.history.segments[0];
    if (window === undefined || !first) return;
    const limit = Math.floor(window * AUTO_COMPACT_RATIO);
    const changed = this.history.contextChanged;
    if (changed?.automatic && !this.history.segments.some((segment) => 'usage' in segment && segment.usage && segment.seq > changed.seq)) return;
    if (this.history.estimate(context.instructions, configuration.tools, extra) < limit) return;
    this.history.validateRange(first.seq, Infinity);
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
    if (this.history.recovery) return { kind: 'failed', message: this.history.recovery.message };
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
    const definitions = this.history.toolDefinitions ?? prepared.toolDefinitions
      ?? prepared.tools.filter((tool) => !tool.deferred).map(({ name, description, parameters }) => ({ name, description, parameters }));
    const declarations = new Map<string, ToolDefinition>();
    for (const definition of definitions) if (!declarations.has(definition.name)) declarations.set(definition.name, definition);
    // 按需加载的要在当前上下文里加载过；定义变了的调用时拒绝，让模型重新加载。
    const loaded = prepared.tools.some((tool) => tool.deferred) ? loadedDefinitions(this.history.itemsView()) : new Map<string, ToolDefinition>();
    for (const tool of tools.values()) {
      if (tool.deferred) {
        const definition = loaded.get(tool.name);
        if (!definition) tools.delete(tool.name);
        else if (!sameDefinition(definition, tool)) tools.set(tool.name, staleTool(tool));
        continue;
      }
      const declared = declarations.get(tool.name);
      if (!declared || !sameDefinition(declared, tool)) {
        throw new Error(`工具 ${tool.name} 未声明或定义已变化，请新建会话使用新的工具定义`);
      }
    }
    return { context, tools, configuration: requestSnapshot({ ...prepared.settings, allowedTools: [...tools.keys()] }, definitions) };
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
      instructions: this.history.baseInstructions ?? options.context.instructions,
      history: [...this.history.items(until), { type: 'feedback', text: compactInstructions(definition, options.range, prepared.variables) }],
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
    const at = (seq: number) => this.history.segments.find((segment) => segment.seq === seq)!.at;
    const changes = await this.options.compactionFiles?.({ from: at(from), to: until === undefined ? Date.now() : at(until) }, signal);
    signal.throwIfAborted();
    const replacement = compactionItems({ range: this.history.items(until, from), after: until === undefined ? [] : this.history.items(undefined, until),
      automatic: options.automatic, summary, definition, ...(prepared.variables ? { values: prepared.variables } : {}),
      ...(changes ? { files: { changes, ...(prepared.compactionTemplates?.fileChanges ? { definition: prepared.compactionTemplates.fileChanges } : {}) } } : {}) });
    this.record({ type: 'context.compacted', id: options.id, range: { from, ...(until !== undefined ? { until } : {}) },
      automatic: options.automatic, items: replacement, summary, ...(usage ? { usage } : {}) });
  }

  private async sample(turn: Turn): Promise<boolean> {
    this.checkTurn(turn);
    const requestId = randomUUID();
    const ids = { turnId: turn.id, requestId };
    const prepared = this.options.prepareRequest({ afterNotification: this.history.notificationCursor });
    const { context, tools, configuration } = this.configure(prepared);
    const notifications = (prepared.notifications ?? []).map((notification) => notificationSchema.parse(notification));
    let cursor = this.history.notificationCursor;
    const seen = new Set(this.history.deliveredNotifications);
    for (const notification of notifications) {
      if (seen.has(notification.id)) throw new Error('宿主重复提供已投递通知');
      seen.add(notification.id);
      if (notification.sequence !== undefined) {
        if (notification.sequence <= cursor) throw new Error('宿主通知顺序无效');
        cursor = notification.sequence;
      }
    }
    if (this.history.currentInstructions !== undefined && this.history.currentInstructions !== context.instructions) notifications.push({
      id: randomUUID(), kind: 'context.updated', source: 'host.context', authority: 'instruction',
      context: assembleContext(contextUpdateContext(context.instructions, prepared.variables, prepared.contextUpdateTemplate)).snapshot,
    });
    await this.autoCompact(turn, prepared, context, configuration, notifications.map(({ context, ...notification }) => ({
      type: 'notification', notification, text: restoreContext(context).instructions })));
    if (!this.history.contexts.has(context.snapshot.id)) this.record({ type: 'context.prepared', snapshot: context.snapshot });
    if (!this.history.configurations.has(configuration.id)) this.record({ type: 'request.configured', snapshot: configuration });
    this.checkTurn(turn);
    this.record({ type: 'request.started', ...ids, inputIds: [...this.history.pending], contextId: context.snapshot.id,
      configurationId: configuration.id, notifications });
    this.history.baseInstructions ??= context.instructions;
    this.history.currentInstructions = context.instructions;
    this.history.toolDefinitions ??= structuredClone(configuration.tools);
    const saved = this.history.requests.get(requestId)!;
    const batch = new ToolBatch({
      cwd: this.options.cwd, signal: turn.controller.signal, turnId: turn.id, tools, blocked: prepared.blocked,
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
        instructions: this.history.baseInstructions!,
        history: this.history.items(), tools: structuredClone(configuration.tools), allowedTools: [...tools.keys()],
      }, turn.controller.signal);
      for await (const event of stream) {
        this.checkTurn(turn);
        if (saved.ended) throw new Error('模型在响应完成之后继续发送事件');
        switch (event.type) {
          case 'item.started': case 'delta': this.emit({ ...event, ...ids }); break;
          case 'item': {
            if (!event.item.id || saved.items.some((item) => item.id === event.item.id)) throw new Error('模型输出条目 id 无效或重复');
            if (event.item.call && (!event.item.call.id || this.history.calls.has(event.item.call.id) || this.history.importedCalls.has(event.item.call.id))) throw new Error('模型工具调用 id 无效或重复');
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
