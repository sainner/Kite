/**
 * 跑项目自己的脚本（.kite/setup、.kite/check）。脚本自成一个进程组：这类脚本常是 sh 包一层再起别的进程，
 * 超时或被打断时只停最外层，子孙会留在工作树里接着跑，所以连整个进程组一起停。
 */
import { spawn } from 'node:child_process';
import { basename } from 'node:path';

export interface ScriptOptions {
  args?: string[];
  cwd: string;
  /** 一律显式传：测试里换掉的隔离环境要带到子进程。 */
  env: NodeJS.ProcessEnv;
  timeoutMs: number;
  signal?: AbortSignal;
  /** stdout 和 stderr 合在一起，按到达的先后。 */
  onOutput(text: string): void;
}

export interface ScriptResult {
  /** 退出码；超时或被停下时为 null。 */
  code: number | null;
  stopped?: 'timeout' | 'aborted';
  /** 运行的秒数。 */
  seconds: number;
}

/** 停掉整个进程组：先 SIGTERM，3 秒后还在就 SIGKILL。 */
function killGroup(pid: number): void {
  try { process.kill(-pid, 'SIGTERM'); } catch {}
  setTimeout(() => { try { process.kill(-pid, 'SIGKILL'); } catch {} }, 3000).unref();
}

export async function runScript(file: string, o: ScriptOptions): Promise<ScriptResult> {
  const started = performance.now();
  // detached：自成一个进程组，停的时候连子孙一起停
  const p = spawn(file, o.args ?? [], { cwd: o.cwd, env: o.env, detached: true, stdio: ['ignore', 'pipe', 'pipe'] });
  // 按字符解码，多字节字符跨两块数据时不会断成乱码
  p.stdout.setEncoding('utf8').on('data', o.onOutput);
  p.stderr.setEncoding('utf8').on('data', o.onOutput);

  let stopped: ScriptResult['stopped'];
  const stop = (why: 'timeout' | 'aborted') => {
    if (stopped || p.exitCode !== null || p.signalCode !== null || !p.pid) return;
    stopped = why;
    killGroup(p.pid);
  };
  const timer = setTimeout(() => stop('timeout'), o.timeoutMs);
  const onAbort = () => stop('aborted');
  o.signal?.addEventListener('abort', onAbort, { once: true });
  if (o.signal?.aborted) onAbort();

  const exit = await new Promise<number | null>((resolve) => {
    p.once('error', (e) => { o.onOutput(`启动 ${basename(file)} 失败：${e.message}\n`); resolve(126); });
    p.once('close', (code) => resolve(code));
  });
  clearTimeout(timer);
  o.signal?.removeEventListener('abort', onAbort);
  return { code: stopped ? null : exit, ...(stopped ? { stopped } : {}), seconds: Math.round(performance.now() - started) / 1000 };
}
