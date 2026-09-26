/** 终端 harness 的同步命令工具：收齐输出并确认进程组停止后才交还控制。 */
import { spawn } from 'node:child_process';
import { closeSync, mkdirSync, openSync, writeSync } from 'node:fs';
import { randomUUID } from 'node:crypto';
import { join } from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';
import type { ToolResult } from './types.ts';

export interface CommandOptions {
  cwd: string;
  logDir: string;
  env: NodeJS.ProcessEnv;
  /** 完整命令日志保存在 logDir，回传给模型只留受限尾部。 */
  outputLimit?: number;
  /** 进程组登记由宿主保存，恢复时据此确认是否仍有执行。 */
  onProcess?(pid: number, active: boolean): void;
}

export function processGroupAlive(pid: number): boolean {
  try { process.kill(-pid, 0); return true; }
  catch (error) { return (error as NodeJS.ErrnoException).code !== 'ESRCH'; }
}

export async function runCommand(command: string, timeout: number, signal: AbortSignal, options: CommandOptions): Promise<ToolResult> {
  signal.throwIfAborted();
  mkdirSync(options.logDir, { recursive: true });
  const log = join(options.logDir, `${randomUUID()}.log`);
  const fd = openSync(log, 'wx', 0o600);
  const limit = options.outputLimit ?? 20_000;
  let tail = '';
  let total = 0;
  let stopped: string | undefined;
  let ioError: unknown;
  let killTimer: ReturnType<typeof setTimeout> | undefined;
  let child;
  try {
    child = spawn('/bin/sh', ['-c', command], { cwd: options.cwd, env: options.env, detached: true, stdio: ['ignore', 'pipe', 'pipe'] });
  } catch (error) { closeSync(fd); throw error; }
  const pid = child.pid;
  const stop = (reason: string) => {
    stopped ??= reason;
    if (!pid || killTimer) return;
    try { process.kill(-pid, 'SIGTERM'); } catch {}
    killTimer = setTimeout(() => {
      if (processGroupAlive(pid)) { try { process.kill(-pid, 'SIGKILL'); } catch {} }
    }, 200);
  };
  const onOutput = (part: string) => {
    total += part.length;
    tail = limit > 0 && part.length >= limit ? part.slice(-limit) : (tail + part).slice(-limit);
    if (ioError) return;
    try {
      const bytes = Buffer.from(part);
      let offset = 0;
      while (offset < bytes.length) {
        const written = writeSync(fd, bytes, offset, bytes.length - offset);
        if (written === 0) throw new Error('命令日志写入失败');
        offset += written;
      }
    } catch (error) { ioError = error; stop('命令日志写入失败'); }
  };
  child.stdout.setEncoding('utf8').on('data', onOutput);
  child.stderr.setEncoding('utf8').on('data', onOutput);
  const onAbort = () => stop('命令被打断，已经发生的改动未撤销');
  signal.addEventListener('abort', onAbort, { once: true });
  const timer = setTimeout(() => stop('命令超时'), timeout);
  const closed = new Promise<number | null>((resolve) => {
    child.once('error', () => { stopped = '命令进程启动失败'; });
    child.once('exit', () => {
      if (pid && processGroupAlive(pid)) stop('命令退出后仍有后台进程，当前工具已停止这些进程');
    });
    child.once('close', (code) => resolve(code));
  });
  try {
    if (pid) {
      try { options.onProcess?.(pid, true); }
      catch (error) { ioError = error; stop('进程登记失败'); }
    }
    if (signal.aborted) onAbort();
    const code = await closed;
    // close 只保证管道关闭；同组进程可能已经重定向输出，仍须检查进程组。
    if (pid && processGroupAlive(pid)) {
      stop('命令留下后台进程，正在停止');
      const deadline = Date.now() + 600;
      while (processGroupAlive(pid) && Date.now() < deadline) await delay(10);
    }
    const alive = pid !== undefined && processGroupAlive(pid);
    if (pid && !alive) options.onProcess?.(pid, false);
    if (ioError && !alive) throw ioError;
    const status = alive ? 'unknown' : stopped || code !== 0 ? 'error' : 'success';
    return {
      status,
      output: [
        alive ? '无法确认进程组已停止，需要人工检查。' : stopped ?? `退出码：${code}`,
        total > limit ? `（前面省略 ${total - limit} 个字符）` : '', tail,
        `完整日志：${log}`,
      ].filter(Boolean).join('\n'),
    };
  } finally {
    clearTimeout(timer);
    if (killTimer) clearTimeout(killTimer);
    signal.removeEventListener('abort', onAbort);
    closeSync(fd);
  }
}
