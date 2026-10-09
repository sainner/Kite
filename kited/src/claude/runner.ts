/**
 * 一个会话的 Claude Code 进程。消息直接写进进程的输入流；进程已关闭就用原生会话 id 就地 resume。
 *
 * 常驻（resident）时进程随宿主存续：回合结束只报告空闲，不关闭输入流，由宿主在实例结束时 shutdown。
 * 非常驻时沿用 Pigeon 的收口判据（依据官方 hooks 文档「Stop input」一节）：回合结束时看 Stop 钩子输入里的
 * background_tasks 和 session_crons，两份都是空数组才关闭输入流，让进程退出；读不到不当空处理。
 * Stop 之后又来了消息就不关，CLI 会接着开下一轮。关闭期间来的消息先存着，进程退出后带着它们重新 resume。
 * 进程被杀、崩溃等同于关闭，下一条消息到来时 resume。
 */
import {
  getSessionInfo, query,
  type Options, type PostToolBatchHookInput, type Query, type SDKControlInterruptResponse, type SDKMessage, type SDKUserMessage,
  type StopHookInput, type UserPromptSubmitHookInput,
} from '@anthropic-ai/claude-agent-sdk';
import { claudeOptions } from './options.ts';

/*
 * Claude 的工具、上下文和外围功能由 Kite 逐项开放，不自动带入本机或项目的 Claude Code 配置。
 * 不用 --bare：它会同时禁用 OAuth 与钥匙串认证。功能清单见 docs/kited.md。
 */

/**
 * 一条要投递的消息。human 为 true 表示人发的，记录里带 origin: human；Kite 自己发的（如合并冲突的说明）不带，
 * 翻译时靠这一点区分。
 */
export interface Outgoing { text: string; human: boolean; id?: string }

export type InputState = 'queued' | 'started' | 'completed' | 'cancelled';
// 锁定的 SDK 0.3.280 已实现这些控制方法，但公开的 Query 声明漏掉了它们。
// 适配只补类型，不自行实现 CLI 队列；升级时由真实 SDK 中测试核对收据。
type InputControl = { cancelAsyncMessage(id: string): Promise<boolean>; interrupt(options: { cancelQueued: true }): Promise<SDKControlInterruptResponse | undefined> };

class Inbox implements AsyncIterable<SDKUserMessage> {
  private buf: Outgoing[] = [];
  private wake?: () => void;
  private closed = false;
  push(m: Outgoing) { this.buf.push(m); this.wake?.(); }
  close() { this.closed = true; this.wake?.(); }
  /** 没被进程读走的消息。 */
  drain(): Outgoing[] { return this.buf.splice(0); }
  cancel(id: string): boolean {
    const index = this.buf.findIndex((input) => input.id === id);
    if (index < 0) return false;
    this.buf.splice(index, 1); return true;
  }
  async *[Symbol.asyncIterator](): AsyncIterator<SDKUserMessage> {
    while (true) {
      while (this.buf.length) {
        const { text, human, id } = this.buf.shift()!;
        yield { type: 'user', message: { role: 'user', content: text }, parent_tool_use_id: null,
          ...(id ? { uuid: id as `${string}-${string}-${string}-${string}-${string}` } : {}), client_composed: true,
          ...(human ? { origin: { kind: 'human' } } : {}) };
      }
      if (this.closed) return;
      await new Promise<void>((r) => (this.wake = r));
      this.wake = undefined;
    }
  }
}

/** closed：没有进程；running：进程在跑；closing：输入流已关，等进程退出。 */
export type RunnerState = 'closed' | 'running' | 'closing';

export interface RunnerEvents {
  message(m: SDKMessage): void;
  input?(id: string, state: InputState): void;
  /** 一批工具调用全部完成、下一次调用模型之前。等它返回，agent 才继续。 */
  toolBatch(input: PostToolBatchHookInput): Promise<string | void>;
  turnStart(prompt: string, source: UserPromptSubmitHookInput['source']): string | void;
  turnEnd(): Promise<void>;
  /** 回合结束且之后没有新消息，busy 变为 false。 */
  idle(): void;
  state(state: RunnerState, error?: string): void;
}

export interface RunnerConfig {
  cwd: string;
  nativeId: string;
  title: string;
  /** 只注入 Kite 已开放的能力；每次启动进程重新创建 SDK MCP 服务器。 */
  mcpServers?: () => Options['mcpServers'];
  configuration?: () => Pick<Options, 'model' | 'effort' | 'maxTurns' | 'systemPrompt'>;
  /** 进程随宿主常驻：回合结束、输入收齐后只报告空闲，不关闭输入流。 */
  resident?: boolean;
}

export class Runner {
  state: RunnerState = 'closed';
  /** 可能有回合在进行：投递了消息或回合开始后为 true，回合结束且之后没有新消息为 false。 */
  busy = false;
  private inbox?: Inbox;
  private q?: Query;
  private ended: Promise<void> = Promise.resolve();
  private pending: Outgoing[] = [];
  private disposed = false;
  /** UserPromptSubmit 之后、result 之前：有回合在跑。 */
  private turnActive = false;
  /** 消息已投递、回合还没开始时收到的打断：等回合开始时拦下。 */
  private interruptPending = false;
  /** 本回合 Stop 钩子报的是否已无后台任务和定时任务；没跑过 Stop 为 null，被打断的回合可能没有。 */
  private stopIdle: boolean | null = null;
  private sentAfterStop = false;
  private stderrTail: string[] = [];
  private inputStates = new Map<string, InputState | undefined>();
  private inputWaiters = new Set<() => void>();
  private ready?: PromiseWithResolvers<Query>;
  private stopping = false;
  private hadResult = false;
  private abortedTools = false;

  constructor(private cfg: RunnerConfig, private on: RunnerEvents) {}

  send(m: Outgoing): void {
    if (this.disposed) throw new Error('runner 已关闭');
    if (this.stopping) throw new Error('runner 正在停止');
    if (m.id) this.inputStates.set(m.id, undefined);
    // 常驻进程上的新一轮：上一轮的结果不能当作这一轮已经收口。
    if (!this.busy) this.hadResult = false;
    this.busy = true;
    this.sentAfterStop = true;
    if (this.state === 'running') this.inbox!.push(m);
    else {
      this.pending.push(m);
      if (this.state === 'closed') this.start();
    }
  }

  /**
   * 打断。回合在跑就打断它；消息已投递但回合还没开始（进程在启动、在 resume），就在回合开始时拦下；
   * 输入流已关、等进程退出时，撤回等着重启的消息。
   */
  async interrupt(): Promise<void> {
    if (this.state === 'closing') { this.pending = []; return; }
    if (this.state !== 'running' || !this.busy) return;
    if (this.turnActive && this.q) {
      // 进程恰好在退出时 SDK 会抛错，这时也没有回合可打断
      await this.q.interrupt().catch(() => {});
    } else this.interruptPending = true;
  }

  /** 只在上游明确确认撤回时成功；已纳入请求的消息不能假装撤回。 */
  async cancel(id: string): Promise<boolean> {
    const index = this.pending.findIndex((input) => input.id === id);
    if (index >= 0 || this.inbox?.cancel(id)) {
      if (index >= 0) this.pending.splice(index, 1);
      this.inputStates.set(id, 'cancelled'); return true;
    }
    if (!this.inputStates.has(id)) return false;
    const q = await this.ready?.promise;
    if (!q) return false;
    while (this.inputStates.get(id) === undefined && this.state !== 'closed') {
      await new Promise<void>((resolve) => this.inputWaiters.add(resolve));
    }
    const state = this.inputStates.get(id);
    if (state === 'cancelled') return true;
    if (state === 'started' || state === 'completed') return false;
    if (this.state === 'closed') throw new Error('Claude 已退出，消息撤回尚未确认');
    return (q as unknown as InputControl).cancelAsyncMessage(id);
  }

  /** 一个上游控制请求同时打断执行并撤掉队列，返回确实没有被纳入的输入 ID。 */
  async stop(): Promise<string[]> {
    this.stopping = true;
    const cancelled = [...this.pending.splice(0), ...(this.inbox?.drain() ?? [])].flatMap((input) => input.id ? [input.id] : []);
    for (const id of cancelled) this.inputStates.set(id, 'cancelled');
    const q = await this.ready?.promise;
    if (q && this.state === 'running') {
      const receipt = await (q as unknown as InputControl).interrupt({ cancelQueued: true });
      if (!receipt || !Array.isArray(receipt.cancelled) || receipt.still_queued.length) {
        q.close(); throw new Error('Claude 未确认清空输入队列，请核查后恢复');
      }
      cancelled.push(...receipt.cancelled);
    }
    return cancelled;
  }

  /** 关输入流，等进程退出；超时就杀掉。之后不再接受消息。归档和 kited 退出时用。 */
  async shutdown(): Promise<void> {
    this.disposed = true;
    this.pending = [];
    this.inbox?.close();
    const timer = setTimeout(() => this.q?.close(), 10_000);
    await this.ended;
    clearTimeout(timer);
  }

  private start(): void {
    const inbox = new Inbox();
    for (const t of this.pending.splice(0)) inbox.push(t);
    this.inbox = inbox;
    this.stopIdle = null;
    this.turnActive = false;
    this.interruptPending = false;
    this.hadResult = false;
    this.abortedTools = false;
    this.ready = Promise.withResolvers<Query>();
    void this.ready.promise.catch(() => {});
    this.setState('running');
    this.ended = this.run(inbox);
  }

  private setState(s: RunnerState, error?: string): void {
    this.state = s;
    this.on.state(s, error);
  }

  private async run(inbox: Inbox): Promise<void> {
    let error: string | undefined;
    try {
      const exists = await getSessionInfo(this.cfg.nativeId, { dir: this.cfg.cwd });
      this.q = query({ prompt: inbox, options: this.options(!!exists) });
      const initialized = await this.q.initializationResult();
      if (initialized.plugins_applied !== true || initialized.hooks_applied !== true) {
        this.q.close();
        throw new Error('Claude Code 未接收 Kite 提示过滤插件或生命周期回调');
      }
      this.ready?.resolve(this.q);
      for await (const m of this.q) {
        const lifecycle = m as unknown as { type: string; command_uuid?: string; state?: InputState };
        if (lifecycle.type === 'command_lifecycle' && lifecycle.command_uuid && lifecycle.state) {
          this.inputStates.set(lifecycle.command_uuid, lifecycle.state);
          this.on.input?.(lifecycle.command_uuid, lifecycle.state);
          for (const resolve of this.inputWaiters) resolve();
          this.inputWaiters.clear();
          // 主输入的 completed 可在 result 之后才到：常驻进程在这时才算空闲。
          if (this.cfg.resident && this.busy && this.hadResult && !this.turnActive && this.state === 'running' && this.settled()) this.becomeIdle();
        }
        this.on.message(m);
        if (m.type === 'result') {
          this.hadResult = true;
          this.abortedTools = this.stopping && 'terminal_reason' in m && m.terminal_reason === 'aborted_tools';
          // 主输入的 completed 可在 result 后才到；result 的消费清单同样是上游收据。
          const receipt = m as typeof m & { user_message_uuids?: string[] };
          for (const id of receipt.user_message_uuids ?? []) this.inputStates.set(id, 'completed');
          await this.turnEnded(inbox);
        }
      }
    } catch (e) {
      // 上游用 error result + exit 1 收口被取消的工具；只有明确的原生中断结果才属于正常停止。
      const exit = e as { errorClass?: string; exitCode?: number };
      if (!(this.abortedTools && exit.errorClass === 'process_exited_nonzero' && exit.exitCode === 1)) {
        error = [(e as Error).message, ...this.stderrTail].join('\n');
      }
    }
    this.ready?.reject(new Error(error ?? 'Claude 进程已关闭'));
    this.q = undefined;
    // 进程没读走的消息留给下一次启动
    this.pending.unshift(...inbox.drain());
    if (this.pending.length && !error && !this.disposed) { this.start(); return; }
    const wasBusy = this.busy;
    this.busy = false;
    this.setState('closed', error);
    for (const resolve of this.inputWaiters) resolve();
    this.inputWaiters.clear();
    if (wasBusy) this.on.idle();
  }

  private async turnEnded(inbox: Inbox): Promise<void> {
    this.turnActive = false;
    await this.on.turnEnd();
    const idle = this.stopIdle;
    this.stopIdle = null;
    // Stop 之后又来了消息：CLI 会接着开下一轮
    if (!this.stopping && (!this.settled() || (idle !== null && this.sentAfterStop))) return;
    if (this.cfg.resident && !this.stopping) { this.becomeIdle(); return; }
    this.busy = false;
    if (idle) {
      this.setState('closing');
      inbox.close();
    }
    this.on.idle();
  }

  /** 已投递的输入都有了终态（完成或撤回）。 */
  private settled(): boolean {
    return [...this.inputStates.values()].every((state) => state === 'completed' || state === 'cancelled');
  }

  /** 常驻进程回合收口：清掉已终结的输入状态，进程留着等下一轮。 */
  private becomeIdle(): void {
    this.busy = false;
    this.inputStates.clear();
    this.on.idle();
  }

  /** CLI 估算的上下文用量与它认定的窗口，不发模型请求；进程不在或查询失败时为 undefined。 */
  async contextUsage(cancellation?: AbortSignal): Promise<{ tokens: number; window: number } | undefined> {
    // 只是本地控制查询；超时或停止时不让它拖住回合收尾，迟到的结果不再交给宿主。
    const signal = AbortSignal.any([AbortSignal.timeout(2000), ...(cancellation ? [cancellation] : [])]);
    let abort: (() => void) | undefined;
    try {
      if (signal.aborted) return undefined;
      const usage = await Promise.race([this.q?.getContextUsage({ detail: 'summary' }), new Promise<undefined>((resolve) => {
        abort = () => resolve(undefined);
        signal.addEventListener('abort', abort, { once: true });
      })]);
      return usage && Number.isSafeInteger(usage.rawMaxTokens) && usage.rawMaxTokens > 0
        ? { tokens: usage.totalTokens, window: usage.rawMaxTokens } : undefined;
    } catch { return undefined; }
    finally { if (abort) signal.removeEventListener('abort', abort); }
  }

  private options(resume: boolean): Options {
    const { cwd, nativeId, title } = this.cfg;
    return {
      ...claudeOptions(cwd),
      mcpServers: this.cfg.mcpServers?.(),
      // 新会话沿用 Kite 标题；SDK 的 title 参数同时跳过首条消息的自动命名。
      ...(resume ? { resume: nativeId } : { sessionId: nativeId, title }),
      ...this.cfg.configuration?.(),
      stderr: (d) => { this.stderrTail = [...this.stderrTail, ...d.split('\n').filter(Boolean)].slice(-20); },
      hooks: {
        UserPromptSubmit: [{ hooks: [async (i) => {
          const input = i as UserPromptSubmitHookInput;
          if (this.interruptPending || this.stopping) {
            this.interruptPending = false;
            // block 会把这条消息从上下文里删掉；continue: false 只是停下，消息会并进下一回合
            return { decision: 'block', reason: '已打断' };
          }
          this.turnActive = true;
          this.busy = true;
          try {
            const additionalContext = this.on.turnStart(input.prompt, input.source);
            return additionalContext ? { hookSpecificOutput: { hookEventName: 'UserPromptSubmit', additionalContext } } : {};
          }
          catch (error) { this.q?.close(); throw error; }
        }] }],
        PostToolBatch: [{ hooks: [async (i) => {
          try {
            const additionalContext = await this.on.toolBatch(i as PostToolBatchHookInput);
            return additionalContext ? { hookSpecificOutput: { hookEventName: 'PostToolBatch', additionalContext } } : {};
          }
          catch (error) {
            // SDK 把普通 hook 异常当诊断继续运行；快照失败须让本次进程停止，等待宿主核查。
            this.q?.close();
            throw error;
          }
        }] }],
        Stop: [{ hooks: [async (i) => {
          const s = i as StopHookInput;
          this.stopIdle = Array.isArray(s.background_tasks) && s.background_tasks.length === 0
            && Array.isArray(s.session_crons) && s.session_crons.length === 0;
          this.sentAfterStop = false;
          return {};
        }] }],
      },
    };
  }
}
