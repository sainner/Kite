/**
 * check 工具：跑会话工作树里的 .kite/check（契约见 kite-onboard skill）。
 * 怎么跑由这里定，项目的检查命令只管查什么、怎么报：
 * - KITE_BASE：取会话分支和主线的分叉点，会话里已经提交的改动也算进受影响的范围；
 * - KITE_LOG_DIR：每次检查一个日志目录，按会话留在 Kite 的目录里，App 能找到；
 * - 排队：一台机器上一次只跑一个检查；
 * - 结果发成 check 事件。
 */
import { tool } from '@anthropic-ai/claude-agent-sdk';
import { spawn } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { existsSync, mkdirSync } from 'node:fs';
import { join } from 'node:path';
import { z } from 'zod';
import { gitTry, revParse } from './git.ts';
import type { ToolContext } from './tools.ts';

const CHECK_TIMEOUT_MS = 10 * 60_000;
/** 检查命令本该只输出结论；万一刷屏只留结尾，失败项和日志路径通常在那里。 */
const OUTPUT_MAX = 20_000;

export interface CheckResult {
  /** 退出码为 0。 */
  ok: boolean;
  /** 退出码；超时或被停下时为 null。 */
  code: number | null;
  /** 是否跑了全量（给检查命令传了 --all）。 */
  all: boolean;
  /** 传给检查命令的 KITE_BASE；没传时为 null。 */
  base: string | null;
  /** 检查命令运行的秒数，不含排队。 */
  seconds: number;
  /** 排队等了多少秒。 */
  waited: number;
  /** 传给检查命令的 KITE_LOG_DIR；没给时为 null。 */
  logDir: string | null;
  /** stdout 和 stderr 合在一起，太长时只留结尾。 */
  output: string;
  stopped?: 'timeout' | 'aborted';
}

const scriptOf = (worktree: string) => join(worktree, '.kite', 'check');

export function hasCheck(worktree: string): boolean {
  return existsSync(scriptOf(worktree));
}

/** 会话分支和主线（主文件夹当前的 HEAD）的分叉点。 */
async function forkPoint(main: string, worktree: string): Promise<string | null> {
  const tip = await revParse(main, 'HEAD');
  if (!tip) return null;
  const r = await gitTry(worktree, ['merge-base', 'HEAD', tip]);
  return r.code === 0 ? r.stdout.trim() : null;
}

/*
 * 排队：检查按耗时预算判定，两个同时跑会互相拖慢、误报超时（实测两次全量同时跑都超了），所以一台机器上一次只跑一个。
 * 预算把一次全量限在十几秒，排在后面最多等这么久，不会像 Pigeon 那样被几分钟的检查堵住。
 * 一台机器只有一个 kited，进程内排队就够了；agent 绕开工具在 Bash 里跑的不排队。
 */
let queue: Promise<void> = Promise.resolve();

/** 排到了返回放行函数；排队时 signal 触发返回 null，排在后面的照常往前走。 */
async function takeTurn(signal?: AbortSignal): Promise<(() => void) | null> {
  let release!: () => void;
  const done = new Promise<void>((r) => (release = r));
  const ahead = queue;
  queue = ahead.then(() => done);
  let onAbort = () => {};
  const aborted = new Promise<null>((r) => { onAbort = () => r(null); });
  if (signal?.aborted) onAbort();
  signal?.addEventListener('abort', onAbort, { once: true });
  const turn = await Promise.race([ahead.then(() => release), aborted]);
  signal?.removeEventListener('abort', onAbort);
  if (!turn) release();
  return turn;
}

/** 停掉整个进程组：检查命令常是 sh 包一层再起测试进程，只停最外层会留下子孙。 */
function killGroup(pid: number): void {
  try { process.kill(-pid, 'SIGTERM'); } catch {}
  setTimeout(() => { try { process.kill(-pid, 'SIGKILL'); } catch {} }, 3000).unref();
}

type RunOptions = { main: string; worktree: string; all?: boolean; signal?: AbortSignal; timeoutMs?: number; logDir?: string };

export async function runCheck(o: RunOptions): Promise<CheckResult> {
  const queued = performance.now();
  const release = await takeTurn(o.signal);
  const waited = Math.round(performance.now() - queued) / 1000;
  if (!release) {
    return { ok: false, code: null, all: o.all ?? false, base: null, seconds: 0, waited, logDir: o.logDir ?? null, output: '', stopped: 'aborted' };
  }
  try {
    return { ...(await run(o)), waited };
  } finally {
    release();
  }
}

async function run(o: RunOptions): Promise<Omit<CheckResult, 'waited'>> {
  const all = o.all ?? false;
  // 排到了才算：排队时主线可能又往前走了
  const base = await forkPoint(o.main, o.worktree);
  const env = { ...process.env };
  delete env.KITE_BASE;
  delete env.KITE_LOG_DIR;
  if (base) env.KITE_BASE = base;
  if (o.logDir) {
    mkdirSync(o.logDir, { recursive: true });
    env.KITE_LOG_DIR = o.logDir;
  }
  const started = performance.now();
  // detached：自成一个进程组，停的时候连子孙一起停
  const p = spawn(scriptOf(o.worktree), all ? ['--all'] : [], { cwd: o.worktree, env, detached: true, stdio: ['ignore', 'pipe', 'pipe'] });

  let output = '';
  let dropped = 0;
  const take = (d: Buffer | string) => {
    output += d.toString();
    if (output.length > 2 * OUTPUT_MAX) { dropped += output.length - OUTPUT_MAX; output = output.slice(-OUTPUT_MAX); }
  };
  p.stdout.on('data', take);
  p.stderr.on('data', take);

  let stopped: CheckResult['stopped'];
  const stop = (why: 'timeout' | 'aborted') => {
    if (stopped || p.exitCode !== null || p.signalCode !== null || !p.pid) return;
    stopped = why;
    killGroup(p.pid);
  };
  const timer = setTimeout(() => stop('timeout'), o.timeoutMs ?? CHECK_TIMEOUT_MS);
  const onAbort = () => stop('aborted');
  o.signal?.addEventListener('abort', onAbort, { once: true });
  if (o.signal?.aborted) onAbort();

  const exit = await new Promise<number | null>((resolve) => {
    p.once('error', (e) => { take(`启动 .kite/check 失败：${e.message}\n`); resolve(126); });
    p.once('close', (code) => resolve(code));
  });
  clearTimeout(timer);
  o.signal?.removeEventListener('abort', onAbort);

  if (dropped || output.length > OUTPUT_MAX) {
    dropped += Math.max(0, output.length - OUTPUT_MAX);
    output = `（前面省略了 ${dropped} 个字符）\n${output.slice(-OUTPUT_MAX)}`;
  }
  const code = stopped ? null : exit;
  return {
    ok: code === 0, code, all, base,
    seconds: Math.round(performance.now() - started) / 1000,
    logDir: o.logDir ?? null,
    output, ...(stopped ? { stopped } : {}),
  };
}

/** 送回模型的文字：检查命令自己的输出，停下或没输出时补一句。 */
function report(r: CheckResult): string {
  const out = r.output.trim();
  if (r.stopped === 'aborted') return '检查被打断。';
  const text = r.stopped === 'timeout' ? ['检查超时，已停止。', out].filter(Boolean).join('\n')
    : out || (r.ok ? '检查通过。' : `检查没通过，退出码 ${r.code}，没有输出。`);
  return r.waited >= 1 ? `${text}\n（排队等了 ${Math.round(r.waited)} 秒，别的检查在跑）` : text;
}

export function checkTool(o: ToolContext) {
  return tool(
    'check',
    '跑项目的检查（.kite/check），判断这个项目改坏了没有；代码项目通常是类型检查加受改动影响的测试。改完用它确认，通过才算完成。'
      + '受影响的范围按这个会话相对主线的全部改动算，提交过的也算；在 Bash 里直接跑 .kite/check 只看还没提交的改动。',
    { all: z.boolean().optional().describe('跑全部测试，不只是受影响的') },
    async ({ all }, extra) => {
      const logDir = join(o.checkLogs, `${new Date().toISOString().replace(/[:.]/g, '-')}-${randomUUID().slice(0, 4)}`);
      const r = await runCheck({ main: o.main, worktree: o.worktree, all, logDir, signal: (extra as { signal?: AbortSignal }).signal });
      o.onCheck(r);
      return { content: [{ type: 'text', text: report(r) }], ...(r.ok ? {} : { isError: true }) };
    },
  );
}
