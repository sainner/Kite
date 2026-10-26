/** 单个线程的执行实例：控制入口保持可用，单个 pump 推进模型、工具和收尾。 */
import { randomUUID } from 'node:crypto';
import { setTimeout as wait } from 'node:timers/promises';
import { ToolBatch } from './tools.ts';
import { HarnessHistory, type ContextUnit } from './history.ts';
import { inputSchema, returnedOnStop, sameInput } from './input.ts';
import { loadedDefinitions, sameDefinition, TOOL_SEARCH } from './tool-search.ts';
import { assembleContext, literalContext, restoreContext } from './context/assembler.ts';
import { contextUpdateContext } from './context/notifications.ts';
import { notificationSchema, requestSnapshot } from './request-config.ts';
import { AUTO_COMPACT_RATIO, compactInstructions, compactionItems, compactTemplate, summaryText } from './compaction.ts';
import type { ContextAssembly } from './context/types.ts';
import { ModelRequestError } from './types.ts';
import type {
  CompactionRequest, ContextItem, HarnessRequest, Input, InputMaterial, JournalEvent, JournalRecord, JsonObject, ModelItem, Outcome, Phase,
  RequestSnapshot, StopRequest, HarnessEvent, HarnessOptions, ThreadRunner, ThreadState, Tool, ToolDefinition,
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
const retryable = (error: unknown) => error instanceof ModelRequestError && error.retryable;

/** 连续被 kited 崩溃打断到这个次数，多半是在崩溃循环，不再自动继续；两个后端共用。 */
export const EXIT_LIMIT = 3;
/** 被 kited 退出打断的回合结果；crashes 是连上这一次的连续崩溃次数，关闭时停下的传 undefined。 */
export const exitOutcome = (crashes?: number): Outcome => ({ kind: 'failed', message: crashes === undefined ? '被 kited 关闭打断'
  : crashes >= EXIT_LIMIT ? `连续 ${EXIT_LIMIT} 次被 kited 崩溃打断，可能是崩溃循环，不再自动继续` : '被 kited 意外退出打断' });
/** 接着被 kited 退出打断的回合时放进队列的说明，note 是上层附加的情况；两个后端共用。 */
export const interruptionNotice = (note?: string): Input => ({ id: randomUUID(), source: 'kite',
  text: `上次执行被 kited 退出打断，当时在执行的工具被意外打断，结果未知${note ? `；${note}` : ''}。先检查实际状态再接着做。`,
  notice: { kind: 'resumed', title: '接着被打断的任务' } });
/** 模型请求可重试的失败最多重试几次；间隔从 2 秒起每次翻倍，前后约一分钟。 */
const MODEL_RETRIES = 5;
const MODEL_RETRY_MS = 2000;

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
  /** 会话记录写入失败的说明；有它之后不再追加记录，见 broken。 */
  private storageFailure?: string;
  private closing = false;
  private closed = false;
  private forceRun = false;
  /** 打开时发现上次被 kited 退出打断，还没由上层决定接着做（见 continueInterrupted）；新输入、继续和停止也算处理了。 */
  private interrupted: boolean;

  constructor(private options: HarnessOptions) {
    this.history = new HarnessHistory(options.journal.records);
    this.recover();
    // 打开本身不开始执行：被切断的回合（记为失败，已在等待继续）、退出前收下还没开始的输入，都停在等待继续。
    this.interrupted = this.history.exited || (this.history.pending.size > 0 && !this.history.waitingForResume);
    if (this.interrupted) this.history.waitingForResume = true;
  }

  /** 连续被 kited 崩溃打断到了上限：停下等人，只有人发的消息或显式继续能解除；自动来的输入照常排队，不起回合。 */
  private get crashLooping(): boolean { return this.history.exits >= EXIT_LIMIT; }

  /** 回合在跑，或被 kited 退出打断后还没续跑（到了连续崩溃上限的不再续跑）：会话目录的运行标记照它放下、收起，见 markRunning。 */
  get running(): boolean { return !!this.history.openTurn || (this.history.exited && !this.crashLooping); }

  get state(): ThreadState {
    return {
      phase: this.phase, busy: !!this.active || !!this.pumping,
      ...(this.compaction ? { compacting: true } : {}),
      waitingForResume: this.history.waitingForResume || this.crashLooping,
      ...(this.active ? { turnId: this.active.id } : {}),
      ...(this.history.lastOutcome ? { lastOutcome: structuredClone(this.history.lastOutcome) } : {}),
    };
  }

  get lifecycle(): 'open' | 'closing' | 'closed' { return this.closed ? 'closed' : this.closing ? 'closing' : 'open'; }
  get broken(): boolean { return this.storageFailure !== undefined; }

  /** material 由宿主在收下时给出，随这条输入记下，见 InputMaterial。 */
  async send(input: Input, material: InputMaterial = {}): Promise<boolean> {
    this.assertOpen();
    if (!inputSchema.safeParse(input).success) throw new Error('输入 id、正文和来源必须有效');
    if (material.skill !== undefined && (input.source !== 'human' || !input.skill || !material.skill)) throw new Error('skill 正文只能随点选了 skill 的人发消息一起收下');
    const previous = this.history.inputs.get(input.id);
    if (previous) {
      if (!sameInput(previous, input)) throw new Error(`输入 id 冲突：${input.id}`);
      return false;
    }
    if (this.stopping) throw new Error('会话正在停止，请稍后发送');
    const { images, skill } = material;
    this.interrupted = false;
    this.record({ type: 'input.received', input, ...(images?.length ? { images } : {}), ...(skill ? { skill } : {}) });
    this.kick();
    // 没起回合的只有连续崩溃到上限时自动来的输入；观察者按收下的记录会以为暂停解除了，补报实际状态。
    if (!this.pumping) this.emit({ type: 'state', state: this.state });
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
    this.interrupted = false;
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
    if (this.stopping) throw new Error('会话正在停止，请稍后继续');
    if (this.active) return;
    if (!this.history.pending.size && !this.history.segments.length) throw new Error('没有可以继续的会话内容');
    this.interrupted = false;
    this.record({ type: 'thread.resumed' });
    this.forceRun = true;
    this.kick();
  }

  async continueInterrupted(note?: string): Promise<void> {
    this.assertOpen();
    if (!this.interrupted || this.crashLooping) return;
    this.interrupted = false;
    if (this.history.exited) { await this.send(interruptionNotice(note)); return; }
    this.history.waitingForResume = false;
    this.kick();
  }

  async compact(request: CompactionRequest): Promise<void> {
    this.assertOpen();
    if (!request.id) throw new Error('压缩请求必须有 id');
    if (this.history.compactions.has(request.id)) return;
    if (this.active || this.pumping || this.stopping) throw new Error('会话正在执行，空闲后才能压缩');
    let from: number;
    let until: number | undefined;
    let range: string;
    if (!('from' in request)) {
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
      await this.summarize({ id: request.id, from, until, automatic: !('from' in request) && request.automatic === true, range,
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
    if (this.storageFailure) throw new Error(`${this.storageFailure}，须重新打开`);
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
    if (this.storageFailure) throw new Error('会话记录已经发生写入故障，不能继续追加');
    let row: JournalRecord;
    try { row = this.options.journal.append(event); }
    catch (error) {
      this.storageFailure = `会话记录写入失败：${message(error)}`;
      this.history.lastOutcome = { kind: 'failed', message: this.storageFailure };
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

  /**
   * kited 崩溃时留下的回合：没结束的请求记为中断，开始了没结果的工具记为结果未知，回合记为被退出打断。
   * 已收到手动停止的按停止补完收尾：结果是被停止，不算被 kited 打断，不计入连续崩溃，也不接着做。
   */
  private recover(): void {
    const turnId = this.history.openTurn;
    if (!turnId) return;
    const stopped = this.history.stoppedTurn === turnId;
    for (const request of this.history.requests.values()) {
      if (request.turnId !== turnId) continue;
      if (!request.ended) this.record({ type: 'request.failed', turnId, requestId: request.id, message: 'kited 退出，请求已中断' });
      for (const item of request.items) {
        const call = item.call;
        if (!call || request.results.has(call.id)) continue;
        const started = request.started.has(call.id);
        this.record({ type: 'tool.finished', turnId, requestId: request.id, callId: call.id, result: {
          status: started ? 'unknown' : 'not_executed',
          output: started ? '工具执行被意外打断，结果未知' : 'kited 退出前工具尚未开始，未执行。',
        } });
      }
    }
    this.record(stopped ? { type: 'turn.finished', turnId, outcome: { kind: 'interrupted' } }
      : { type: 'turn.finished', turnId, outcome: exitOutcome(this.history.exits + 1), exited: 'crashed' });
  }

  contextUnits(): ContextUnit[] { return this.history.contextUnits(); }

  private canRun(): boolean {
    return !this.closing && !this.stopping && !this.storageFailure && !this.history.waitingForResume && !this.crashLooping
      && (this.history.pending.size > 0 || this.forceRun);
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
    let retries = 0;
    try {
      while (true) {
        this.checkTurn(turn);
        let followUp: boolean;
        try {
          followUp = await this.sample(turn);
          retries = 0;
        } catch (error) {
          if (!retryable(error) || turn.failure || turn.stopRequested) throw error;
          if (retries === MODEL_RETRIES) throw new Error(`${message(error)}（已重试 ${MODEL_RETRIES} 次）`);
          await wait(MODEL_RETRY_MS * 2 ** retries++, undefined, { signal: turn.controller.signal });
          continue;
        }
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
    // kited 关闭时停下的回合（不是用户停的）记为被退出打断，kited 下次启动时接着做。
    const exited = this.closing && !this.stopping && outcome.kind !== 'completed';
    if (exited) outcome = exitOutcome();
    if (this.storageFailure) outcome = { kind: 'failed', message: this.storageFailure };
    this.history.lastOutcome = outcome;
    this.history.waitingForResume ||= outcome.kind === 'failed';
    if (!this.storageFailure) this.record({ type: 'turn.finished', turnId: turn.id, outcome, ...(exited ? { exited: 'closed' as const } : {}) });
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
    if (this.storageFailure) return { kind: 'failed', message: this.storageFailure };
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
    // 声明跟着本次可执行的内置工具走：新打开的补在后面，定义变了的换成新的；关掉的留在原位，调用时拒绝，关工具不改动声明。
    const current = new Map(prepared.tools.filter((tool) => !tool.deferred)
      .map(({ name, description, parameters }) => [name, { name, description, parameters }] as const));
    const previous = this.history.toolDefinitions ?? [];
    const definitions = [...previous.map((definition) => current.get(definition.name) ?? definition),
      ...[...current.values()].filter((definition) => !previous.some((old) => old.name === definition.name))];
    // 按需加载的定义在历史里，换不掉：要在当前上下文里加载过；定义变了的调用时拒绝，让模型重新加载。
    const loaded = prepared.tools.some((tool) => tool.deferred) ? loadedDefinitions(this.history.itemsView()) : new Map<string, ToolDefinition>();
    for (const tool of tools.values()) {
      if (!tool.deferred) continue;
      const definition = loaded.get(tool.name);
      if (!definition) tools.delete(tool.name);
      else if (!sameDefinition(definition, tool)) tools.set(tool.name, staleTool(tool));
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
    this.history.toolDefinitions = structuredClone(configuration.tools);
    const saved = this.history.requests.get(requestId)!;
    let needsFollowUp = false;
    let failure: { error: unknown } | undefined;
    const batch = new ToolBatch({
      cwd: this.options.cwd, signal: turn.controller.signal, turnId: turn.id, tools,
      // 模型流失败之后不再启动收到的调用；可重试的失败不取消回合，没有这一道，排在后面的调用会在重试前照样执行。
      blocked: (name) => failure ? '模型响应中途中断，工具未启动。' : prepared.blocked?.(name),
      started: (call) => this.record({ type: 'tool.started', ...ids, callId: call.id }),
      finished: (call, result) => this.record({ type: 'tool.finished', ...ids, callId: call.id, result }),
      output: (call, text, limit) => this.emit({ type: 'tool.output', ...ids, callId: call.id, text, limit }),
      fatal: (error) => { turn.failure ??= { error }; turn.controller.abort(); },
    });
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
      // 可重试的失败（连不上、中途断开）不停下这一回合：已开始的工具照常做完，没开始的记为未执行（见 blocked），
      // runTurn 退避后带着这些结果重发请求。
      if (turn.stopRequested || !retryable(error)) {
        if (!turn.stopRequested) turn.failure ??= failure;
        turn.controller.abort();
      }
      if (!saved.ended && !this.storageFailure) this.record({ type: 'request.failed', ...ids, message: message(error) });
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
