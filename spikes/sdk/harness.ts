/** 1b、1c 共用：隔离环境、输入流和会话包装。 */
import { query, type Query, type SDKUserMessage } from '@anthropic-ai/claude-agent-sdk';
import { spawn, execSync, type ChildProcess } from 'node:child_process';
import { mkdirSync } from 'node:fs';
import { join } from 'node:path';

/** 只留基础变量，指向假端点；不继承调用方会话的 CLAUDE_* 变量，不读用户设置。 */
export function isolatedEnv(root: string, port: number) {
  const cfgDir = join(root, 'claude-config');
  const home = join(root, 'home');
  mkdirSync(cfgDir, { recursive: true });
  mkdirSync(home, { recursive: true });
  return {
    cfgDir,
    env: {
      PATH: '/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin',
      HOME: home, TMPDIR: process.env.TMPDIR ?? '/tmp', LANG: 'en_US.UTF-8', USER: process.env.USER ?? 'u', SHELL: '/bin/zsh',
      CLAUDE_CONFIG_DIR: cfgDir,
      ANTHROPIC_BASE_URL: `http://127.0.0.1:${port}`,
      ANTHROPIC_API_KEY: 'sk-ant-fake',
      CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC: '1',
    } as Record<string, string>,
  };
}

export class Inbox implements AsyncIterable<SDKUserMessage> {
  private buf: SDKUserMessage[] = [];
  private wake?: () => void;
  private closed = false;
  push(text: string, priority?: 'now' | 'next' | 'later') {
    this.buf.push({ type: 'user', message: { role: 'user', content: text }, parent_tool_use_id: null, ...(priority ? { priority } : {}) });
    this.wake?.();
  }
  close() { this.closed = true; this.wake?.(); }
  async *[Symbol.asyncIterator]() {
    while (true) {
      while (this.buf.length) yield this.buf.shift()!;
      if (this.closed) return;
      await new Promise<void>((r) => (this.wake = r));
      this.wake = undefined;
    }
  }
}

export class Sess {
  inbox = new Inbox();
  msgs: Array<{ at: number; m: any }> = [];
  sessionId?: string;
  child?: ChildProcess;
  error?: unknown;
  ended: Promise<void>;
  q: Query;
  private resultWaiters: Array<(m: any) => void> = [];
  constructor(cwd: string, env: Record<string, string>, extra: Record<string, unknown> = {}) {
    this.q = query({
      prompt: this.inbox,
      options: {
        cwd, env, settingSources: [], allowedTools: ['Bash'],
        stderr: () => {},
        spawnClaudeCodeProcess: (o) => {
          const cp = spawn(o.command, o.args, { cwd: o.cwd, env: o.env as any, stdio: ['pipe', 'pipe', 'pipe'] });
          cp.stderr?.resume();
          this.child = cp;
          return cp as any;
        },
        ...extra,
      },
    });
    this.ended = (async () => {
      try {
        for await (const m of this.q) {
          this.msgs.push({ at: Date.now(), m });
          if ((m as any).session_id) this.sessionId = (m as any).session_id;
          if (m.type === 'result') this.resultWaiters.shift()?.(m);
        }
      } catch (e) { this.error = e; }
    })();
  }
  /** 先登记等待，再投递；返回投递时刻和本条结果的 Promise。 */
  send(text: string, priority?: 'now' | 'next' | 'later') {
    const result = new Promise<any>((r) => this.resultWaiters.push(r));
    const at = Date.now();
    this.inbox.push(text, priority);
    return { at, result };
  }
  /** 下一条 result（不投递消息，比如后台任务唤醒的回合）。 */
  nextResult() { return new Promise<any>((r) => this.resultWaiters.push(r)); }
  async close() { this.inbox.close(); await this.ended; }
  rssKb(): number { return Number(execSync(`ps -o rss= -p ${this.child!.pid}`).toString().trim()); }
}
