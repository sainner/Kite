/** 只编排官方登录工具；凭据由工具保存在当前工作机，界面不接触令牌。 */
import { spawn, type ChildProcessWithoutNullStreams } from 'node:child_process';
import { mkdirSync } from 'node:fs';
import { join } from 'node:path';
import { KiteError } from './errors.ts';

export type SubscriptionProvider = 'chatgpt' | 'claude';
export interface LoginSnapshot {
  id: string;
  provider: SubscriptionProvider;
  status: 'starting' | 'waiting' | 'complete' | 'failed' | 'cancelled' | 'expired';
  url?: string;
  userCode?: string;
  acceptsCode: boolean;
  message?: string;
  expiresAt: number;
}
interface Options {
  command?: (provider: SubscriptionProvider) => Promise<string[]>;
  env?: NodeJS.ProcessEnv;
  timeoutMs?: number;
}
interface Flow {
  snapshot: LoginSnapshot;
  child?: ChildProcessWithoutNullStreams;
  done?: Promise<void>;
  timer?: ReturnType<typeof setTimeout>;
  output: string;
  running: boolean;
}
const active = (flow: Flow) => flow.snapshot.status === 'starting' || flow.snapshot.status === 'waiting';

async function command(provider: SubscriptionProvider): Promise<string[]> {
  if (provider === 'claude') {
    try {
      const path = Bun.resolveSync(`@anthropic-ai/claude-agent-sdk-${process.platform}-${process.arch}/claude`, import.meta.dir);
      return [path, 'auth', 'login', '--claudeai'];
    } catch { throw new KiteError('工作机缺少 Claude 登录工具，请重新安装 kited。'); }
  }
  // 先验证命令可执行，避免 PATH 中残留的 npm 启动器挡住已安装的官方工具。
  const candidates = [Bun.which('codex'),
    ...(process.platform === 'darwin' ? ['/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex',
      '/Applications/Codex.app/Contents/Resources/codex'] : [])];
  for (const path of candidates) {
    if (!path) continue;
    try {
      const probe = Bun.spawn([path, '--version'], { env: process.env, stdout: 'ignore', stderr: 'ignore', timeout: 5000 });
      if (await probe.exited === 0) return [path, '-c', 'cli_auth_credentials_store="file"', 'login', '--device-auth'];
    } catch { /* 尝试下一个已安装的官方工具。 */ }
  }
  throw new KiteError('工作机未找到可用的 Codex 登录工具，请先安装 Codex CLI。');
}

export class SubscriptionLogins {
  private flows = new Map<string, Flow>();
  private closed = false;
  private cancelled = new Map<string, number>();
  constructor(private home: string, private options: Options = {}) {}

  start(provider: SubscriptionProvider, id: string): LoginSnapshot {
    if (this.closed) throw new KiteError('服务正在关闭', 503);
    for (const [key, until] of this.cancelled) if (until < Date.now()) this.cancelled.delete(key);
    if (this.cancelled.has(id)) return { id, provider, status: 'cancelled', acceptsCode: false, expiresAt: Date.now() / 1000 };
    const prior = this.flows.get(id);
    if (prior) {
      if (prior.snapshot.provider !== provider) throw new KiteError('登录请求不匹配', 409);
      return { ...prior.snapshot };
    }
    for (const [key, flow] of this.flows) {
      if ((active(flow) || flow.running) && flow.snapshot.provider === provider) throw new KiteError('这个订阅已有正在进行的登录，请先关闭原登录窗口。', 409);
      if (!active(flow) && !flow.running && flow.snapshot.expiresAt * 1000 < Date.now()) this.flows.delete(key);
    }
    const lifetime = this.options.timeoutMs ?? 10 * 60_000;
    const flow: Flow = { snapshot: { id, provider, status: 'starting', acceptsCode: false,
      expiresAt: (Date.now() + lifetime) / 1000 }, output: '', running: true };
    this.flows.set(id, flow);
    flow.timer = setTimeout(() => { void this.stop(flow, 'expired'); }, lifetime);
    flow.timer.unref();
    flow.done = this.run(flow);
    return { ...flow.snapshot };
  }

  get(id: string): LoginSnapshot { return { ...this.flow(id).snapshot }; }

  submit(id: string, code: string): void {
    const flow = this.flow(id);
    if (flow.snapshot.provider !== 'claude' || flow.snapshot.status !== 'waiting' || !flow.snapshot.acceptsCode || !flow.child) {
      throw new KiteError('这个登录流程不接受授权码', 409);
    }
    if (!code.trim() || code.length > 4096 || /[\r\n\x00-\x1f\x7f]/.test(code)) throw new KiteError('授权码格式无效');
    flow.child.stdin.write(`${code.trim()}\n`);
    flow.snapshot.acceptsCode = false;
  }

  async cancel(id: string): Promise<void> {
    const flow = this.flows.get(id);
    if (!flow) this.cancelled.set(id, Date.now() + 10 * 60_000);
    if (flow && active(flow)) await this.stop(flow, 'cancelled');
  }

  async close(): Promise<void> {
    this.closed = true;
    await Promise.all([...this.flows.values()].map(async (flow) => {
      if (active(flow)) await this.stop(flow, 'cancelled');
      await flow.done;
    }));
  }

  private flow(id: string): Flow {
    const flow = this.flows.get(id);
    if (!flow) throw new KiteError('登录已结束或服务已重启，请重新登录。', 404);
    return flow;
  }

  private finish(flow: Flow, status: LoginSnapshot['status'], message?: string): void {
    if (!active(flow)) return;
    clearTimeout(flow.timer);
    Object.assign(flow.snapshot, { status, message, acceptsCode: false, url: undefined, userCode: undefined });
    flow.output = '';
  }

  private async stop(flow: Flow, status: 'cancelled' | 'expired'): Promise<void> {
    this.finish(flow, status, status === 'expired' ? '登录已超时，请重新开始。' : undefined);
    const child = flow.child;
    if (child?.pid) {
      try { process.kill(-child.pid, 'SIGTERM'); } catch { /* 已退出。 */ }
      const timer = setTimeout(() => { try { process.kill(-child.pid!, 'SIGKILL'); } catch {} }, 200);
      await flow.done;
      clearTimeout(timer);
    }
  }

  private consume(flow: Flow, chunk: string): void {
    if (!active(flow)) return;
    // 不保存原始输出到日志，也不把工具输出直接返回给 App。
    flow.output = (flow.output + chunk).replace(/\x1b\[[0-?]*[ -/]*[@-~]/g, '').slice(-32_768);
    const completeLines = flow.output.slice(0, flow.output.lastIndexOf('\n') + 1);
    for (const match of completeLines.matchAll(/https:\/\/[^\s<>"\x1b]+/g)) {
      try {
        const url = new URL(match[0]);
        const valid = flow.snapshot.provider === 'chatgpt'
          ? url.hostname === 'auth.openai.com' && url.pathname === '/codex/device'
          : ['claude.ai', 'claude.com', 'platform.claude.com', 'console.anthropic.com'].includes(url.hostname) && /\/oauth\/authorize$/.test(url.pathname);
        if (valid && !url.username && !url.password && !flow.snapshot.url) {
          flow.snapshot.url = url.href;
          flow.snapshot.status = 'waiting';
          flow.snapshot.acceptsCode = flow.snapshot.provider === 'claude';
        }
      } catch { /* 不完整的一段地址等待下个输出块。 */ }
    }
    if (flow.snapshot.provider === 'chatgpt') {
      const code = /(?:^|\n)\s*([A-Z0-9]{4}-[A-Z0-9]{4,5})\s*(?:\n|$)/.exec(flow.output);
      if (code) flow.snapshot.userCode = code[1];
    }
  }

  private async run(flow: Flow): Promise<void> {
    try {
      const argv = await (this.options.command ?? command)(flow.snapshot.provider);
      if (!active(flow)) return;
      const env: NodeJS.ProcessEnv = { ...(this.options.env ?? process.env), BROWSER: '/usr/bin/false' };
      const directory = join(this.home, 'auth', flow.snapshot.provider);
      mkdirSync(directory, { recursive: true, mode: 0o700 });
      if (flow.snapshot.provider === 'chatgpt') env.CODEX_HOME = directory;
      delete env.CLAUDECODE;
      if (flow.snapshot.provider === 'claude' && env.CLAUDE_CODE_OAUTH_TOKEN) {
        throw new KiteError('这台工作机通过环境变量提供 Claude 授权，请先移除该配置再使用订阅登录。');
      }
      const child = spawn(argv[0]!, argv.slice(1), { env, cwd: directory, detached: true, stdio: ['pipe', 'pipe', 'pipe'] });
      flow.child = child;
      child.stdin.on('error', () => {});
      child.stdout.setEncoding('utf8').on('data', (chunk: string) => this.consume(flow, chunk));
      child.stderr.setEncoding('utf8').on('data', (chunk: string) => this.consume(flow, chunk));
      await new Promise<void>((resolve) => {
        child.once('error', () => { this.finish(flow, 'failed', '无法启动登录工具，请检查工作机安装。'); resolve(); });
        child.once('close', (code) => {
          this.finish(flow, code === 0 ? 'complete' : 'failed', code === 0 ? undefined : '登录未完成，请重新尝试。');
          resolve();
        });
      });
    } catch (error) {
      this.finish(flow, 'failed', error instanceof KiteError ? error.message : '无法启动订阅登录，请检查工作机配置。');
    } finally { flow.running = false; }
  }
}
