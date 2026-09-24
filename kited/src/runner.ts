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
  type McpSdkServerConfigWithInstance, type Options, type PostToolBatchHookInput, type Query, type SDKMessage, type SDKUserMessage,
  type SettingSource, type StopHookInput, type UserPromptSubmitHookInput,
} from '@anthropic-ai/claude-agent-sdk';
import { join } from 'node:path';
import { TOOLS_ENV } from './tools.ts';

/*
 * Kite 会话只带做事用的上游功能。会话上下文里有什么见 kited/README.md「会话的上下文」。
 *
 * 设置只读项目的两层。用户级（~/.claude 下的设置、CLAUDE.md、skill、子 agent、插件）是给人自己用 Claude Code 的，
 * 不带进 Kite 会话；从 claude.ai 同步来的 skill、插件和连接器也不带，开关在 options() 的 settings 里。
 */
export const SETTING_SOURCES: SettingSource[] = ['project', 'local'];
const DISALLOWED_TOOLS = [
  // 每个会话本来就在 Kite 建的工作树里，agent 自己进出工作树，快照和合回主线就对不上了
  'EnterWorktree', 'ExitWorktree',
  // 通知由 Kite App 负责
  'PushNotification',
  // claude.ai 的云端例行任务、设计系统同步
  'RemoteTrigger', 'DesignSync',
  // 交给宿主界面渲染审查结果；Kite App 没有这个界面，结果照常写在回复里
  'ReportFindings',
  // 多 agent 编排、/loop 自定节奏，连同下面的 workflow-authoring、loop 两个 skill 一起去掉
  'Workflow', 'ScheduleWakeup',
  // 配置终端状态栏的子 agent
  'Agent(statusline-setup)',
];
/** Claude Code 自带的 skill 只留 code-review、simplify、security-review、claude-api。 */
const SKILLS_OFF = [
  // 终端快捷键；Kite 会话不弹审批
  'keybindings-help', 'fewer-permission-prompts',
  // 生成 CLAUDE.md，和项目规范冲突：规范里 CLAUDE.md 只有一行 @AGENTS.md
  'init',
  // claude.ai 的云端例行任务
  'schedule',
  // 画图配色、改 Claude Code 自己的设置、启动项目的 App、按间隔重复、写 Workflow 脚本
  'dataviz', 'update-config', 'run', 'loop', 'workflow-authoring',
];

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

export interface RunnerConfig {
  cwd: string;
  nativeId: string;
  title: string;
  /** Kite 给会话的工具（见 tools.ts），每次启动进程时调用。 */
  tools?: () => McpSdkServerConfigWithInstance | undefined;
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
    const idle = this.stopIdle;
    this.stopIdle = null;
    // Stop 之后又来了消息：CLI 会接着开下一轮
    if (idle !== null && this.sentAfterStop) return;
    this.busy = false;
    if (idle) {
      this.setState('closing');
      inbox.close();
    }
    this.on.idle();
  }

  private options(resume: boolean): Options {
    const { cwd, nativeId, title } = this.cfg;
    const tools = this.cfg.tools?.();
    return {
      cwd,
      env: { ...process.env, ...TOOLS_ENV },
      ...(tools ? { mcpServers: { kite: tools } } : {}),
      ...(resume ? { resume: nativeId } : { sessionId: nativeId, title }),
      // 和裸跑 Claude Code 一样：不指定时 SDK 只发一段极简系统提示，没有记忆、git 状态等段落
      systemPrompt: { type: 'preset', preset: 'claude_code' },
      settingSources: SETTING_SOURCES,
      settings: {
        autoMemoryDirectory: join(cwd, '.kite', 'memory'),
        // 会话由 Kite 管，不用 Claude Code 自己的后台会话（claude agents、--bg）
        disableAgentView: true,
        // 从 claude.ai 同步来的 skill、插件和连接器（Gmail、日历等）。经 settings 传入只对这个会话生效，不动本机的文件
        syncClaudeAiSkills: false,
        syncClaudeAiPlugins: false,
        disableClaudeAiConnectors: true,
        skillOverrides: Object.fromEntries(SKILLS_OFF.map((s) => [s, 'off' as const])),
        // Bash 工具的 edit diff：bypassPermissions 下默认开，在 git 仓库里每次调用前后各打一次快照，把命令改了哪些文件
        // 算成 diff，放在 SDK 消息的 tool_use_result.bashEditDiff 里给界面显示，模型看不到。每次串行约 13 条 git、
        // 约 0.2 秒；改动由 Kite 自己的快照记录
        bashEditDiffEnabled: false,
      },
      disallowedTools: DISALLOWED_TOOLS,
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
          this.stopIdle = Array.isArray(s.background_tasks) && s.background_tasks.length === 0
            && Array.isArray(s.session_crons) && s.session_crons.length === 0;
          this.sentAfterStop = false;
          return {};
        }] }],
      },
    };
  }
}
