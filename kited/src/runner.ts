/**
 * 一个会话的 Claude Code 进程。消息直接写进进程的输入流；进程已关闭就用原生会话 id 就地 resume。
 *
 * 收口判据（沿用 Pigeon，依据官方 hooks 文档「Stop input」一节）：回合结束时看 Stop 钩子输入里的
 * background_tasks 和 session_crons，两份都是空数组才关闭输入流，让进程退出；读不到不当空处理。
 * Stop 之后又来了消息就不关，CLI 会接着开下一轮。关闭期间来的消息先存着，进程退出后带着它们重新 resume。
 * 进程被杀、崩溃等同于关闭，下一条消息到来时 resume。
 */
import {
  getSessionInfo, query,
  type Options, type PostToolBatchHookInput, type Query, type SDKMessage, type SDKUserMessage,
  type StopHookInput, type UserPromptSubmitHookInput,
} from '@anthropic-ai/claude-agent-sdk';
import { join } from 'node:path';

/**
 * 一条要投递的消息。human 为 true 表示人发的，记录里带 origin: human；Kite 自己发的（如合并冲突的说明）不带，
 * 翻译时靠这一点区分。
 */
export interface Outgoing { text: string; human: boolean }

class Inbox implements AsyncIterable<SDKUserMessage> {
  private buf: Outgoing[] = [];
  private wake?: () => void;
  private closed = false;
  push(m: Outgoing) { this.buf.push(m); this.wake?.(); }
  close() { this.closed = true; this.wake?.(); }
  /** 没被进程读走的消息。 */
  drain(): Outgoing[] { return this.buf.splice(0); }
  async *[Symbol.asyncIterator](): AsyncIterator<SDKUserMessage> {
    while (true) {
      while (this.buf.length) {
        const { text, human } = this.buf.shift()!;
        yield { type: 'user', message: { role: 'user', content: text }, parent_tool_use_id: null, ...(human ? { origin: { kind: 'human' } } : {}) };
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
  /** 一批工具调用全部完成、下一次调用模型之前。等它返回，agent 才继续。 */
  toolBatch(input: PostToolBatchHookInput): Promise<void>;
  turnStart(prompt: string, source: UserPromptSubmitHookInput['source']): void;
  turnEnd(): Promise<void>;
  /** 回合结束且之后没有新消息，busy 变为 false。 */
  idle(): void;
  state(state: RunnerState, error?: string): void;
}

export interface RunnerConfig { cwd: string; nativeId: string; title: string }

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
  /** 本回合的 Stop 钩子跑过没有；被打断的回合可能没有。 */
  private stopInTurn = false;
  private idleAtStop = false;
  private sentAfterStop = false;
  private stderrTail: string[] = [];

  constructor(private cfg: RunnerConfig, private on: RunnerEvents) {}

  send(m: Outgoing): void {
    if (this.disposed) throw new Error('runner 已关闭');
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

  /** 关输入流，等进程退出；超时就杀掉。之后不再接受消息。归档和 kited 退出时用。 */
  async shutdown(timeoutMs = 10_000): Promise<void> {
    this.disposed = true;
    this.pending = [];
    this.inbox?.close();
    const timer = setTimeout(() => this.q?.close(), timeoutMs);
    await this.ended;
    clearTimeout(timer);
  }

  private start(): void {
    const inbox = new Inbox();
    for (const t of this.pending.splice(0)) inbox.push(t);
    this.inbox = inbox;
    this.stopInTurn = false;
    this.turnActive = false;
    this.interruptPending = false;
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
      for await (const m of this.q) {
        this.on.message(m);
        if (m.type === 'result') await this.turnEnded(inbox);
      }
    } catch (e) {
      error = [(e as Error).message, ...this.stderrTail].join('\n');
    }
    this.q = undefined;
    // 进程没读走的消息留给下一次启动
    this.pending.unshift(...inbox.drain());
    if (this.pending.length && !error && !this.disposed) { this.start(); return; }
    const wasBusy = this.busy;
    this.busy = false;
    this.setState('closed', error);
    if (wasBusy) this.on.idle();
  }

  private async turnEnded(inbox: Inbox): Promise<void> {
    this.turnActive = false;
    await this.on.turnEnd();
    const stopped = this.stopInTurn;
    this.stopInTurn = false;
    // Stop 之后又来了消息：CLI 会接着开下一轮
    if (stopped && this.sentAfterStop) return;
    this.busy = false;
    if (stopped && this.idleAtStop) {
      this.setState('closing');
      inbox.close();
    }
    this.on.idle();
  }

  private options(resume: boolean): Options {
    const { cwd, nativeId, title } = this.cfg;
    return {
      cwd,
      ...(resume ? { resume: nativeId } : { sessionId: nativeId, title }),
      // 和裸跑 Claude Code 一样：不指定时 SDK 只发一段极简系统提示，没有记忆、git 状态等段落
      systemPrompt: { type: 'preset', preset: 'claude_code' },
      settingSources: ['user', 'project', 'local'],
      settings: { autoMemoryDirectory: join(cwd, '.kite', 'memory') },
      permissionMode: 'bypassPermissions',
      allowDangerouslySkipPermissions: true,
      stderr: (d) => { this.stderrTail = [...this.stderrTail, ...d.split('\n').filter(Boolean)].slice(-20); },
      hooks: {
        UserPromptSubmit: [{ hooks: [async (i) => {
          const input = i as UserPromptSubmitHookInput;
          if (this.interruptPending) {
            this.interruptPending = false;
            // block 会把这条消息从上下文里删掉；continue: false 只是停下，消息会并进下一回合
            return { decision: 'block', reason: '已打断' };
          }
          this.turnActive = true;
          this.busy = true;
          this.on.turnStart(input.prompt, input.source);
          return {};
        }] }],
        PostToolBatch: [{ hooks: [async (i) => {
          await this.on.toolBatch(i as PostToolBatchHookInput);
          return {};
        }] }],
        Stop: [{ hooks: [async (i) => {
          const s = i as StopHookInput;
          this.stopInTurn = true;
          this.idleAtStop = Array.isArray(s.background_tasks) && s.background_tasks.length === 0
            && Array.isArray(s.session_crons) && s.session_crons.length === 0;
          this.sentAfterStop = false;
          return {};
        }] }],
      },
    };
  }
}
