/** 工作机共用的命令执行与进程组检查；命令收齐输出并确认进程组停止后才交还控制。 */
import { spawn } from 'node:child_process';
import { closeSync, mkdirSync, openSync, writeSync } from 'node:fs';
import { randomUUID } from 'node:crypto';
import { createServer, type Server } from 'node:net';
import { join } from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';
import { prepareSandbox, workspacePolicy, type ExecutionPolicy } from './sandbox.ts';
import type { ToolResult } from '../harness/types.ts';
import type { SecretValue } from '../secrets.ts';

/** 名单外主机的放行决定；port 缺省表示上游没给端口。 */
export type NetworkAsk = (target: { host: string; port?: number }, signal: AbortSignal) => Promise<boolean>;

export interface CommandOptions {
  cwd: string;
  logDir: string;
  env: NodeJS.ProcessEnv;
  /** 仅本次进程使用；带凭据的命令输出完全隐藏，不写入日志或发送给观察者。 */
  credentials?: Record<string, SecretValue>;
  /** 宿主已授权的资源范围；未指定时采用当前工作树的基础策略。 */
  policy?: ExecutionPolicy;
  /** 完整命令日志保存在 logDir，回传给模型只留受限尾部。 */
  outputLimit?: number;
  /** 输出已写入日志后通知观察者；不等待界面消费。 */
  onOutput?(text: string, limit: number): void;
  /** 只收标准输出，同样在写入日志之后；monitor 把它的每一行当作事件。 */
  onStdout?(text: string): void;
  /** 进程组登记由宿主保存，恢复时据此确认是否仍有执行。 */
  onProcess?(pid: number, active: boolean): void;
  /** 有它时名单外的主机不直接拒绝，交给它决定；命令结束时仍在问的一并作废。 */
  askNetwork?: NetworkAsk;
  /** 有它时命令可以转到后台：超时、用户插话或一开始就要求时不停进程，交给它接着管，工具立刻返回。带凭据的命令不转。 */
  background?: CommandBackground;
  /** 已获准在沙箱外运行（沙箱外命令或审批放行）：直接以用户身份跑，不加文件与网络限制；带凭据的命令不能出沙箱。 */
  unsandboxed?: boolean;
}

/** 转到后台的命令：进程照跑，输出接着写进日志并交给监听者，结束时 done 给出结果。 */
export interface BackgroundCommand {
  pid: number;
  /** 完整输出的日志文件。 */
  log: string;
  /** 转后台之前的输出，只留尾部。 */
  output: string;
  /** 之后的输出，写进日志后通知。 */
  listen(listener: (text: string) => void): void;
  /** 进程组结束；被停下时 stopped 写原因，确认不了进程组已停止时 unknown。 */
  done: Promise<{ code: number | null; stopped?: string; unknown?: boolean }>;
  /** 停下整个进程组。 */
  stop(reason: string): void;
}

export interface CommandBackground {
  /** 触发时还在跑的命令转后台（用户发来了消息）。 */
  now?: AbortSignal;
  /** 一开始就转后台。 */
  immediately?: boolean;
  /** 接管转到后台的命令，返回告诉模型的说明。 */
  adopt(command: BackgroundCommand): string;
}

/**
 * 沙箱宿主经控制目录里的 socket 问名单外的主机，一行一条 JSON：同一主机在这条命令里只问一次，几台主机依次问。
 * hold 在问的期间挂住命令的超时计时，返回的函数放开。
 */
function askServer(path: string, ask: NetworkAsk, signal: AbortSignal, hold: () => () => void): Promise<Server> {
  const decisions = new Map<string, Promise<boolean>>();
  let queue: Promise<unknown> = Promise.resolve();
  const asking = async (target: { host: string; port?: number }) => {
    if (signal.aborted) return false;
    const release = hold();
    try { return await ask(target, signal); } finally { release(); }
  };
  const decide = (host: string, port?: number) => {
    const key = `${host}:${port ?? ''}`;
    let decision = decisions.get(key);
    if (!decision) {
      decision = queue.then(() => asking({ host, ...(port === undefined ? {} : { port }) })).catch(() => false);
      queue = decision;
      decisions.set(key, decision);
    }
    return decision;
  };
  const server = createServer((socket) => {
    let buffer = '';
    socket.setEncoding('utf8').on('error', () => {}).on('data', (chunk: string) => {
      buffer += chunk;
      for (let end = buffer.indexOf('\n'); end >= 0; end = buffer.indexOf('\n')) {
        let request: { id: unknown; host: unknown; port: unknown };
        try { request = JSON.parse(buffer.slice(0, end)); } catch { socket.destroy(); return; }
        buffer = buffer.slice(end + 1);
        const { id, host, port } = request;
        if (typeof id !== 'number' || typeof host !== 'string' || !(port === null || typeof port === 'number')) { socket.destroy(); return; }
        void decide(host, port ?? undefined).then((allow) => { if (!socket.destroyed) socket.write(`${JSON.stringify({ id, allow })}\n`); });
      }
    });
  });
  return new Promise((resolve, reject) => { server.once('error', reject); server.listen(path, () => resolve(server)); });
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
  const confidential = Object.keys(options.credentials ?? {}).length > 0;
  const limit = options.outputLimit ?? 20_000;
  let tail = '';
  let total = 0;
  let stopped: string | undefined;
  let ioError: unknown;
  let killTimer: ReturnType<typeof setTimeout> | undefined;
  let child;
  let sandbox: ReturnType<typeof prepareSandbox> | undefined;
  let asking: Server | undefined;
  const askingEnded = new AbortController();
  const background = confidential ? undefined : options.background;
  /** 转后台的原因；先到的算。 */
  const moved = Promise.withResolvers<string>();
  let detached = false;
  const listeners: Array<(text: string) => void> = [];
  // 等人回应网络审批的时间不算命令的运行时间：问的期间停下超时计时，问完按剩余时间接着计。
  let remaining = timeout;
  let since = 0;
  let timer: ReturnType<typeof setTimeout> | undefined;
  let held = 0;
  const startTimer = () => {
    since = Date.now();
    const span = timeout >= 1000 ? `${Math.round(timeout / 1000)} 秒` : `${timeout} 毫秒`;
    timer = setTimeout(() => background ? moved.resolve(`命令在 ${span}内没有结束，已转到后台接着运行。`) : stop('命令超时'), remaining);
  };
  const hold = () => {
    if (held++ === 0 && timer) { clearTimeout(timer); timer = undefined; remaining -= Date.now() - since; }
    // 命令结束后才放开的（询问随之作废）不再计时。
    return () => { if (--held === 0 && !stopped && !askingEnded.signal.aborted) startTimer(); };
  };
  try {
    if (options.unsandboxed && confidential) throw new Error('带凭据的命令不能在沙箱外运行');
    sandbox = options.unsandboxed ? { executable: '/bin/sh', args: ['-c', command], env: options.env, askSocket: undefined, dispose: () => {} }
      : prepareSandbox(command, { cwd: options.cwd, env: options.env, policy: options.policy ?? workspacePolicy(options.cwd, options.env),
      credentials: options.credentials, ...(options.askNetwork ? { network: 'ask' as const } : {}) });
    if (sandbox.askSocket) asking = await askServer(sandbox.askSocket, options.askNetwork!, AbortSignal.any([signal, askingEnded.signal]), hold);
    child = spawn(sandbox.executable, sandbox.args, { cwd: options.cwd, env: sandbox.env, detached: true, stdio: ['ignore', 'pipe', 'pipe'] });
  } catch (error) { closeSync(fd); asking?.close(); sandbox?.dispose(); throw error; }
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
    if (confidential) return;
    // 转后台时尾巴已经交给接管方，之后只写日志。
    if (!detached) {
      total += Array.from(part).length;
      tail = Array.from(tail + part).slice(-limit).join('');
    }
    if (ioError) return;
    try {
      const bytes = Buffer.from(part);
      let offset = 0;
      while (offset < bytes.length) {
        const written = writeSync(fd, bytes, offset, bytes.length - offset);
        if (written === 0) throw new Error('命令日志写入失败');
        offset += written;
      }
      if (detached) for (const listener of listeners) listener(part);
      else options.onOutput?.(part, limit);
    } catch (error) { ioError = error; stop('命令输出处理失败'); }
  };
  child.stdout.setEncoding('utf8').on('data', (part: string) => {
    onOutput(part);
    if (!confidential && !ioError && !detached) options.onStdout?.(part);
  });
  child.stderr.setEncoding('utf8').on('data', onOutput);
  const onAbort = () => stop('命令被打断，已经发生的改动未撤销');
  signal.addEventListener('abort', onAbort, { once: true });
  const onMove = () => moved.resolve('用户发来了新消息，命令转到后台接着运行，没有停下。');
  background?.now?.addEventListener('abort', onMove, { once: true });
  if (background?.immediately) moved.resolve('命令已在后台运行。');
  if (!held) startTimer();
  const closed = new Promise<number | null>((resolve) => {
    child.once('error', () => { stopped = '命令进程启动失败'; });
    child.once('exit', () => {
      if (pid && processGroupAlive(pid)) stop('命令退出后仍有后台进程，当前工具已停止这些进程');
    });
    child.once('close', (code) => resolve(code));
  });
  // close 只保证管道关闭；同组进程可能已经重定向输出，仍须检查进程组。
  const settle = async () => {
    if (pid && processGroupAlive(pid)) {
      stop('命令留下后台进程，正在停止');
      const deadline = Date.now() + 600;
      while (processGroupAlive(pid) && Date.now() < deadline) await delay(10);
    }
    return pid !== undefined && processGroupAlive(pid);
  };
  const cleanup = () => {
    clearTimeout(timer);
    if (killTimer) clearTimeout(killTimer);
    signal.removeEventListener('abort', onAbort);
    background?.now?.removeEventListener('abort', onMove);
    askingEnded.abort();
    asking?.close();
    closeSync(fd);
    // 结果未知时保留运行所需目录，避免仍存活的进程使用已经删除或复用的路径。
    if (!pid || !processGroupAlive(pid)) sandbox.dispose();
  };
  /**
   * 转后台：不再计时，不再跟着这次工具调用的打断停下，名单外的主机不再问人（直接拒绝）；进程登记交给接管方，
   * 进程结束后在这里收尾。
   */
  const detach = (reason: string): ToolResult => {
    detached = true;
    clearTimeout(timer);
    timer = undefined;
    signal.removeEventListener('abort', onAbort);
    askingEnded.abort();
    if (pid) options.onProcess?.(pid, false);
    const done = (async () => {
      try {
        const code = await closed;
        const unknown = await settle();
        return { code, ...(stopped ? { stopped } : {}), ...(unknown ? { unknown: true } : {}) };
      } finally { cleanup(); }
    })();
    const message = background!.adopt({ pid: pid!, log, output: tail, listen: (listener) => { listeners.push(listener); }, done, stop });
    return { status: 'success', output: reason + message };
  };
  try {
    if (pid) {
      try { options.onProcess?.(pid, true); }
      catch (error) { ioError = error; stop('进程登记失败'); }
    }
    if (signal.aborted) onAbort();
    const first = await Promise.race([closed.then((code) => ({ code })), moved.promise.then((reason) => ({ reason }))]);
    if ('reason' in first && pid && !stopped && !ioError) return detach(first.reason);
    const code = 'code' in first ? first.code : await closed;
    const alive = await settle();
    if (pid && !alive) options.onProcess?.(pid, false);
    if (ioError && !alive) throw ioError;
    const status = alive ? 'unknown' : stopped || code !== 0 ? 'error' : 'success';
    return {
      status,
      output: [
        alive ? '无法确认进程组已停止，需要人工检查。' : stopped ?? `退出码：${code}`,
        confidential ? '凭据命令的输出已隐藏；标准输出和错误输出不会保存到日志或会话。' : '',
        total > limit ? `（前面省略 ${total - limit} 个字符）` : '', tail,
        confidential ? '' : `完整日志：${log}`,
      ].filter(Boolean).join('\n'),
    };
  } finally {
    if (!detached) cleanup();
  }
}
