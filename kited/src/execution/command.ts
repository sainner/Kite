/** 工作机共用的命令执行与进程组检查；命令收齐输出并确认进程组停止后才交还控制。 */
import { spawn } from 'node:child_process';
import { closeSync, mkdirSync, mkdtempSync, openSync, rmSync, writeSync } from 'node:fs';
import { randomUUID } from 'node:crypto';
import { createServer, type Server } from 'node:net';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';
import { z } from 'zod';
import { prepareSandbox, secretEnvironment, workspacePolicy, type ExecutionPolicy } from './sandbox.ts';
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
  /** 进程组登记由宿主保存，恢复时据此确认是否仍有执行；started 是起进程的时刻，登记时一并存下，见 ProcessGroup。 */
  onProcess?(pid: number, active: boolean, started: number): void;
  /** 有它时名单外的主机不直接拒绝，交给它决定；命令结束时仍在问的一并作废。 */
  askNetwork?: NetworkAsk;
  /** 有它时命令可以转到后台：超时、用户插话或一开始就要求时不停进程，交给它接着管，工具立刻返回。带凭据的命令不转。 */
  background?: CommandBackground;
  /** 已获准在沙箱外运行（沙箱外命令或审批放行）：直接以用户身份跑，不加文件与网络限制；凭据照样交给命令。 */
  unsandboxed?: boolean;
}

/** 转到后台的命令：进程照跑，输出接着写进日志并交给监听者，结束时 done 给出结果。 */
export interface BackgroundCommand {
  pid: number;
  /** 起进程的时刻，接管方登记进程组时一并存下，见 ProcessGroup。 */
  started: number;
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

/** 沙箱外以用户身份直接跑；file 类凭据放进只有本人可读的临时目录，同沙箱里一样在进程组结束后删掉。 */
function unsandboxed(command: string, env: NodeJS.ProcessEnv, credentials: Record<string, SecretValue>) {
  const run = { executable: '/bin/sh', args: ['-c', command], env, askSocket: undefined };
  if (!Object.keys(credentials).length) return { ...run, dispose: () => {} };
  const dir = mkdtempSync(join(tmpdir(), 'kite-secret-'));
  const dispose = () => rmSync(dir, { recursive: true, force: true });
  try { return { ...run, env: { ...env, ...secretEnvironment(credentials, dir) }, dispose }; }
  catch (error) { dispose(); throw error; }
}

export function processAlive(pid: number): boolean {
  try { process.kill(pid, 0); return true; }
  catch (error) { return (error as NodeJS.ErrnoException).code !== 'ESRCH'; }
}

export function processGroupAlive(pid: number): boolean { return processAlive(-pid); }

/**
 * 登记下来的命令进程组：组长的 pid（也是组号）与 kited 起它的时刻（毫秒）。kited 异常退出后再打开时，
 * 这个号可能已经给了别的进程，停之前凭启动时刻核对还是不是这一组。
 */
export const processGroupSchema = z.object({ pid: z.number().int().min(2), started: z.number().int().nonnegative() });
export const processGroupsSchema = z.array(processGroupSchema);
export type ProcessGroup = z.infer<typeof processGroupSchema>;

/** ps 的启动时刻只到秒，再加上起进程本身的耗时；同一个 pid 在这么短的时间里退出又被复用不会发生。 */
const START_TOLERANCE = 2_000;
const MONTHS = 'JanFebMarAprMayJunJulAugSepOctNovDec';

/** 各 pid 的进程启动时刻（毫秒）；不在的不列。ps 没跑成时为 undefined。同步跑，插件状态这类同步的调用方也要用。 */
function processStarts(pids: number[]): Map<number, number> | undefined {
  let stdout: string;
  // 带上 kited 自己：它一定在，输出里没有它就是 ps 没跑成，不能当作这些进程都不在了。
  try {
    stdout = Bun.spawnSync(['ps', '-o', 'pid=,lstart=', '-p', [process.pid, ...pids].join(',')],
      { env: { PATH: '/usr/bin:/bin', LC_ALL: 'C', TZ: 'UTC' }, stdin: 'ignore', stdout: 'pipe', stderr: 'ignore', timeout: 5_000 }).stdout.toString();
  } catch { return undefined; }
  const starts = new Map<number, number>();
  for (const line of stdout.split('\n')) {
    // lstart 形如 Sat Oct 24 10:38:04 2026，按 UTC 给出。
    const match = /^\s*(\d+)\s+\w+\s+(\w{3})\s+(\d+)\s+(\d+):(\d+):(\d+)\s+(\d+)\s*$/.exec(line);
    const month = match ? MONTHS.indexOf(match[2]!) : -1;
    if (!match || month % 3 !== 0) continue;
    const [year, day, hour, minute, second] = [7, 3, 4, 5, 6].map((index) => Number(match[index]));
    starts.set(Number(match[1]), Date.UTC(year!, month / 3, day, hour, minute, second));
  }
  return starts.has(process.pid) ? starts : undefined;
}

/** 组里还有 kited 能发信号的进程；全是别的用户的（EPERM）不会是 Kite 起的，也停不了，同不在一样看。 */
function groupSignalable(pid: number): boolean {
  try { process.kill(-pid, 0); return true; } catch { return false; }
}

/**
 * 登记的进程组里眼下还在、仍是 Kite 起的那些；ps 没跑成、确认不了时为 undefined。组长还在的按启动时刻核对，
 * 对不上的是复用了这个 pid 的别的进程。组长已经退出、组里还有进程的算：组在时这个号不会分给新进程，除非原来的组
 * 整个结束后有新进程拿到它当了组长又先退出，ps 分辨不出这种情况。
 */
export function ownedProcessGroups(groups: ProcessGroup[]): ProcessGroup[] | undefined {
  const present = groups.filter((group) => groupSignalable(group.pid));
  if (!present.length) return [];
  const starts = processStarts(present.map((group) => group.pid));
  if (!starts) return undefined;
  return present.filter(({ pid, started }) => {
    const start = starts.get(pid);
    return start === undefined || Math.abs(start - started) <= START_TOLERANCE;
  });
}

/**
 * 会话登记的命令进程组：kited 退出时它们不跟着退出，打开会话时先停掉。只停核对过仍是 Kite 起的（见 ownedProcessGroups），
 * 返回停不掉的，留在登记里下次再停；不在了的、不是这一组的都不再返回。ps 没跑成时一个都不停，还在的原样返回。
 */
export async function stopProcessGroups(groups: ProcessGroup[]): Promise<ProcessGroup[]> {
  const ours = ownedProcessGroups(groups);
  if (!ours) return groups.filter((group) => groupSignalable(group.pid));
  for (const { pid } of ours) { try { process.kill(-pid, 'SIGKILL'); } catch {} }
  const alive = () => ours.filter((group) => groupSignalable(group.pid));
  const deadline = Date.now() + 1000;
  while (alive().length && Date.now() < deadline) await delay(20);
  return alive();
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
    sandbox = options.unsandboxed ? unsandboxed(command, options.env, options.credentials ?? {})
      : prepareSandbox(command, { cwd: options.cwd, env: options.env, policy: options.policy ?? workspacePolicy(options.cwd, options.env),
      credentials: options.credentials, ...(options.askNetwork ? { network: 'ask' as const } : {}) });
    if (sandbox.askSocket) asking = await askServer(sandbox.askSocket, options.askNetwork!, AbortSignal.any([signal, askingEnded.signal]), hold);
    child = spawn(sandbox.executable, sandbox.args, { cwd: options.cwd, env: sandbox.env, detached: true, stdio: ['ignore', 'pipe', 'pipe'] });
  } catch (error) { closeSync(fd); asking?.close(); sandbox?.dispose(); throw error; }
  const pid = child.pid;
  const started = Date.now();
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
    if (pid) options.onProcess?.(pid, false, started);
    const done = (async () => {
      try {
        const code = await closed;
        const unknown = await settle();
        return { code, ...(stopped ? { stopped } : {}), ...(unknown ? { unknown: true } : {}) };
      } finally { cleanup(); }
    })();
    const message = background!.adopt({ pid: pid!, started, log, output: tail, listen: (listener) => { listeners.push(listener); }, done, stop });
    return { status: 'success', output: reason + message };
  };
  try {
    if (pid) {
      try { options.onProcess?.(pid, true, started); }
      catch (error) { ioError = error; stop('进程登记失败'); }
    }
    if (signal.aborted) onAbort();
    const first = await Promise.race([closed.then((code) => ({ code })), moved.promise.then((reason) => ({ reason }))]);
    if ('reason' in first && pid && !stopped && !ioError) return detach(first.reason);
    const code = 'code' in first ? first.code : await closed;
    const alive = await settle();
    if (pid && !alive) options.onProcess?.(pid, false, started);
    if (ioError && !alive) throw ioError;
    const status = alive ? 'unknown' : stopped || code !== 0 ? 'error' : 'success';
    return {
      status,
      output: [
        alive ? '命令结束后进程组没能停下，可能还在运行。' : stopped ?? `退出码：${code}`,
        confidential ? '凭据命令的输出已隐藏；标准输出和错误输出不会保存到日志或会话。' : '',
        total > limit ? `（前面省略 ${total - limit} 个字符）` : '', tail,
        confidential ? '' : `完整日志：${log}`,
      ].filter(Boolean).join('\n'),
    };
  } finally {
    if (!detached) cleanup();
  }
}
