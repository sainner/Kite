/**
 * 终端插件 kite.terminal：一个实例一个进程，进程归工作机。实例的 lifetime 是 process：进程运行中独立存续，
 * 关掉窗口照跑，在停靠栏是没有窗口的小头像；进程结束后没有窗口就回收，有窗口的留到关掉最后一个窗口。
 * 进程有两种：用户开的终端是用户的登录 shell，跑在 PTY 里，不加沙箱，相当于登录到这台工作机，起始目录是工作区目录；
 * 代理的 shell 命令超时、用户插话或模型要求时转到后台，由这里接管，仍在代理的沙箱里、只有输出没有输入，结束时通知那个代理。
 * 无头终端（@xterm/headless）跟着输出维护一份画面，设备接入时先发当前画面再推后续输出；PTY 的尺寸跟最近输入的那台设备。
 * 进程归 kited：kited 退出时终端随之结束，重启后不再拉起，只把上次留下的进程组停掉。
 * 运行中的终端定时从自己的进程树探测正在监听的端口，写进实例状态，本机全部运行中终端的端口合起来交给组网转发，
 * 供各设备的网页视图打开（docs/成果查看与位置.md「运行中的网页」）。
 * WebSocket 协议：接入地址可带 cols、rows，先按这台设备的尺寸调整再出画面；服务端先发 {type:'snapshot', data, cols, rows, phase, ...}，
 * 之后二进制帧是输出，{type:'size'} 是尺寸换了，{type:'exit'} 是进程结束；客户端二进制帧是输入，{type:'resize', cols, rows} 报自己放得下的尺寸。
 */
import { closeSync, existsSync, fstatSync, mkdirSync, openSync, readFileSync, readSync, rmSync, writeFileSync } from 'node:fs';
import { randomUUID } from 'node:crypto';
import { userInfo } from 'node:os';
import { connect } from 'node:net';
import { join } from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';
import type { ServerWebSocket } from 'bun';
import { Terminal as Mirror } from '@xterm/headless';
import { SerializeAddon } from '@xterm/addon-serialize';
import { z } from 'zod';
import { KiteError } from '../errors.ts';
import { processGroupAlive, type BackgroundCommand } from '../execution/command.ts';
import { commandEnvironment } from '../execution/sandbox.ts';
import { assembleContext, bindContext, sceneValues } from '../harness/context/assembler.ts';
import type { ContextDefinition, ContextValues } from '../harness/context/types.ts';
import type { PluginInstance } from '../model.ts';
import type { Store } from '../store.ts';
import { systemCommand } from '../system-command.ts';
import { terminalState, type TerminalState } from './state.ts';

export const terminalDefinitionId = 'kite.terminal';

export const terminalExitContextDefinition: ContextDefinition = {
  version: 2, id: 'kite.terminal-exit', title: '后台命令结束', scene: 'terminal.exit',
  blocks: [
    { type: 'paragraph', id: 'result', title: '结果', parts: [
      { type: 'text', text: '你转到后台的命令「' }, { type: 'variable', name: 'terminal.title' },
      { type: 'text', text: '」（终端 ' }, { type: 'variable', name: 'terminal.id' }, { type: 'text', text: '）已结束：' },
      { type: 'variable', name: 'terminal.result' }, { type: 'text', text: '。输出的末尾：\n' }, { type: 'variable', name: 'terminal.output' },
    ] },
    { type: 'paragraph', id: 'guidance', title: '处理方式', parts: [{ type: 'text',
      text: '按结果决定要不要接着做。终端没有窗口时随即回收，之后读不到它，以这里的输出为准。' }] },
  ],
};

/** 转到后台的命令在实例配置里记下命令与完整日志的位置。 */
const configSchema = z.object({ command: z.string(), log: z.string() }).strict();
const terminalConfig = (instance: Pick<PluginInstance, 'config'>) =>
  instance.config.terminal === undefined ? undefined : configSchema.parse(instance.config.terminal);

const sizeSchema = z.object({ cols: z.number().int().min(2).max(1000), rows: z.number().int().min(1).max(1000) }).strict();
type Size = z.infer<typeof sizeSchema>;
const controlSchema = sizeSchema.extend({ type: z.literal('resize') }).strict();
/** 接入地址里的 cols、rows；缺一个或不合法就当没给。 */
export function requestedSize(params: URLSearchParams): Size | undefined {
  const parsed = sizeSchema.safeParse({ cols: Number(params.get('cols')), rows: Number(params.get('rows')) });
  return parsed.success ? parsed.data : undefined;
}

/** 一台设备接在一个终端上的 WebSocket；size 是这台设备的窗口放得下的尺寸，发过 resize 或接入时带了才有。 */
export interface TerminalSocket {
  kind: 'terminal';
  instanceId: string;
  size?: Size;
}
type Socket = ServerWebSocket<TerminalSocket>;

export interface TerminalsHost {
  store: Store;
  home: string;
  env: NodeJS.ProcessEnv;
  /** 在工作区的控制队列里执行。 */
  run<T>(workspaceId: string, action: () => Promise<T>): Promise<T>;
  /** 实例增删或状态变了：工作区聚合变了。 */
  changed(workspaceId: string): void;
  /** 回收实例：撤回指向它的授权、删掉实例和会话目录。调用时已在控制队列里，且确认没有窗口。 */
  collect(instance: PluginInstance): void;
  /** 投给代理的 Kite 来源输入；同一 ID 重复送达只去重。 */
  deliver(threadId: string, text: string, inputId: string): Promise<unknown>;
  template(): ContextDefinition;
  /** 代理线程的公共变量。 */
  variables(threadId: string): ContextValues;
  /** 本机全部运行中终端监听的端口，整组替换给组网转发；组网没开时什么也不做。 */
  forward(ports: number[]): void;
  /** 起 shell 的命令，测试换成 /bin/sh；默认是用户的登录 shell。 */
  shell?: string[];
  /** 探测监听端口的间隔，测试里缩短；默认 PORT_SCAN_MS。 */
  portScanMs?: number;
}

const SCROLLBACK = 3000;
/** 进程退出后等 PTY 读完剩下输出的时间；后台子进程拿着 PTY 不放时不再等。 */
const DRAIN_MS = 300;
const STOP_GRACE_MS = 1000;
/** 结束通知里带的输出末尾。 */
const TAIL_CHARS = 3000;
/** terminal_read 一次最多从日志末尾读这么多。 */
const READ_WINDOW = 4 * 1024 * 1024;
const NOTIFY_RETRY_MS = 30_000;
const PORT_SCAN_MS = 2000;
/** 一个端口开头连着试这么多次 HTTP；还不像网页的之后每隔 HTTP_RETRY_SCANS 次扫描（约半分钟）再试，不一直去敲数据库这类服务。 */
const HTTP_PROBES = 5;
const HTTP_RETRY_SCANS = 15;

/** 终端里跑的进程。命令没有输入，也不跟着 PTY 尺寸走。 */
interface Child {
  pid: number;
  write?(data: Uint8Array): void;
  resize?(size: Size): void;
  /** 进程结束、输出读完、同组残留停掉之后给出结果。 */
  done: Promise<{ exitCode: number | null; signal?: string; reason?: string }>;
}

class Session {
  readonly mirror: Mirror;
  private readonly serializer = new SerializeAddon();
  private readonly sockets = new Set<Socket>();
  /** 正在接入的设备：画面发出去之前到的输出先存着，发完画面接着发。 */
  private readonly attaching = new Map<Socket, Uint8Array[]>();
  /** 决定 PTY 尺寸的设备：最近一次输入或接入的那台。 */
  private owner?: Socket;
  private readonly done = Promise.withResolvers<void>();
  size: Size = { cols: 80, rows: 24 };
  child?: Child;
  ended?: TerminalState;
  /** 停止时记下原因，退出后写进状态。 */
  reason?: string;
  /** 结束时要不要通知启动它的代理：代理自己停下的不通知。 */
  notify = true;
  /** 最近的输出，结束通知里用。 */
  recent = '';
  /** 进程树正在监听的端口 → 能不能用 HTTP 打开。 */
  ports = new Map<number, boolean>();
  /** 每个端口扫描过几次，用来定 HTTP 探测的间隔。 */
  probes = new Map<number, number>();
  /** 进程树里各作业所在的进程组（交互 shell 开着作业控制，每个作业各在一组），端口扫描和停止时更新；shell 退出后它们就脱离了进程树。 */
  groups = new Set<number>();

  constructor() {
    this.mirror = new Mirror({ ...this.size, scrollback: SCROLLBACK, allowProposedApi: true });
    this.mirror.loadAddon(this.serializer);
  }

  get finished(): Promise<void> { return this.done.promise; }

  output(data: Uint8Array): void {
    this.mirror.write(data);
    for (const socket of this.sockets) socket.send(data);
    for (const pending of this.attaching.values()) pending.push(data);
  }

  /** 无头终端处理完此刻之前的输出后序列化：之后到的输出排在后面，正好接着画面发。 */
  screen(): Promise<string> {
    return new Promise((resolve) => this.mirror.write(new Uint8Array(0), () => resolve(this.serializer.serialize())));
  }
  /** 画面和回滚里的文字，一行一项。 */
  lines(): Promise<string[]> {
    return new Promise((resolve) => this.mirror.write(new Uint8Array(0), () => {
      const buffer = this.mirror.buffer.active;
      const lines: string[] = [];
      for (let y = 0; y < buffer.length; y++) lines.push(buffer.getLine(y)?.translateToString(true) ?? '');
      while (lines.length && !lines.at(-1)) lines.pop();
      resolve(lines);
    }));
  }

  attach(socket: Socket): void {
    // 带着尺寸接入的设备先成为尺寸归属者，画面按它的尺寸出，免得到了设备上再折行。
    if (socket.data.size && !this.ended) {
      this.owner = socket;
      this.resize(socket.data.size);
    }
    const pending: Uint8Array[] = [];
    this.attaching.set(socket, pending);
    void this.screen().then((data) => {
      if (!this.attaching.delete(socket)) return;
      socket.send(JSON.stringify({ type: 'snapshot', data, ...this.size, ...(this.ended ?? { phase: 'running' }) }));
      for (const chunk of pending) socket.send(chunk);
      this.sockets.add(socket);
      if (!this.ended) this.owner = socket;
    });
  }
  detach(socket: Socket): void {
    this.attaching.delete(socket);
    this.sockets.delete(socket);
    if (this.owner !== socket) return;
    this.owner = [...this.sockets].at(-1);
    if (this.owner?.data.size) this.resize(this.owner.data.size);
  }
  input(socket: Socket, data: Uint8Array): void {
    if (this.ended || !this.child?.write) return;
    if (this.owner !== socket) {
      this.owner = socket;
      if (socket.data.size) this.resize(socket.data.size);
    }
    this.child.write(data);
  }
  requestSize(socket: Socket, size: Size): void {
    socket.data.size = size;
    if (this.owner && this.owner !== socket) return;
    this.owner = socket;
    this.resize(size);
  }
  private resize(size: Size): void {
    if (this.ended || (size.cols === this.size.cols && size.rows === this.size.rows)) return;
    this.size = size;
    this.child?.resize?.(size);
    this.mirror.resize(size.cols, size.rows);
    const message = JSON.stringify({ type: 'size', ...size });
    for (const socket of this.sockets) socket.send(message);
  }
  finish(state: TerminalState): void {
    this.ended = state;
    const message = JSON.stringify({ type: 'exit', ...state });
    for (const socket of this.sockets) socket.send(message);
    this.done.resolve();
  }
}

/** 命令输出是管道里的文字：单独的换行在终端里补成回车换行。 */
const terminalText = (text: string) => new TextEncoder().encode(text.replace(/\r?\n/g, '\r\n'));

export class Terminals {
  private sessions = new Map<string, Session>();
  private stopping = new Map<string, Promise<void>>();
  private closed = false;
  private scanTimer?: ReturnType<typeof setInterval>;
  private scanning?: Promise<void>;

  constructor(private host: TerminalsHost) {}

  /** 进程是否还在跑；process 实例据此决定关掉最后一个窗口时回不回收。 */
  running(id: string): boolean {
    const session = this.sessions.get(id);
    return !!session && !session.ended;
  }

  private directory(id: string) { return join(this.host.home, 'sessions', id); }
  private marker(id: string) { return join(this.directory(id), 'terminal-process.json'); }
  private screenFile(id: string) { return join(this.directory(id), 'terminal-screen.txt'); }
  private track(id: string, pid: number) {
    mkdirSync(this.directory(id), { recursive: true });
    writeFileSync(this.marker(id), JSON.stringify({ pid }), { mode: 0o600 });
  }

  /** 新实例刚入库就起 shell；起不来记为结束，窗口里看得到原因。 */
  start(instance: PluginInstance): void {
    if (this.closed) throw new KiteError('kited 正在关闭', 503);
    const workspace = this.host.store.workspace(instance.workspaceId);
    if (!workspace || workspace.status !== 'open') throw new KiteError('工作区尚未打开', 409);
    const session = new Session();
    const shell = this.host.shell ?? [userInfo().shell || '/bin/zsh', '-l'];
    const env = { ...commandEnvironment(this.host.env), SHELL: shell[0], TERM: 'xterm-256color', COLORTERM: 'truecolor',
      TERM_PROGRAM: 'Kite', LANG: this.host.env.LANG ?? 'en_US.UTF-8' };
    const eof = Promise.withResolvers<void>();
    let child;
    try {
      child = Bun.spawn(shell, { cwd: workspace.cwd, env, terminal: {
        ...session.size, data: (_, data) => session.output(data), exit: () => eof.resolve(),
      } });
    } catch (error) {
      this.save(instance.id, { phase: 'exited', exitCode: null, reason: `终端启动失败：${(error as Error).message}`, endedAt: Date.now() });
      return;
    }
    const { pid, terminal } = child;
    session.child = {
      pid, write: (data) => terminal?.write(data), resize: ({ cols, rows }) => terminal?.resize(cols, rows),
      done: child.exited.then(async () => {
        await Promise.race([eof.promise, delay(DRAIN_MS)]);
        // shell 退出后同组和记下的作业进程组里还活着的（后台任务）一并停掉，免得没有归属的进程留在工作机上。
        for (const group of [pid, ...session.groups]) if (processGroupAlive(group)) { try { process.kill(-group, 'SIGKILL'); } catch {} }
        terminal?.close();
        return { exitCode: child.exitCode, ...(child.signalCode ? { signal: child.signalCode } : {}) };
      }),
    };
    this.sessions.set(instance.id, session);
    this.track(instance.id, pid);
    this.save(instance.id, { phase: 'running' });
    void this.exited(instance.id, session);
    this.watchPorts();
  }

  /**
   * 接管代理 shell 工具转到后台的命令：建一个没有窗口的终端实例，来源记为这次工具调用，返回告诉模型的说明。
   * 工作区不再打开（正在交接或归档）时不接管，停下命令。
   */
  adopt(ownerId: string, command: BackgroundCommand, info: { description: string; command: string; turnId?: string; callId?: string }): string {
    const owner = this.host.store.instance(ownerId);
    const workspace = owner && this.host.store.workspace(owner.workspaceId);
    if (this.closed || !owner || owner.status !== 'open' || workspace?.status !== 'open') {
      command.stop('工作区不再在这台工作机上打开');
      return '但工作区已不在这台工作机上打开，命令已停下。';
    }
    const instance: PluginInstance = { id: randomUUID(), workspaceId: owner.workspaceId, definitionId: terminalDefinitionId,
      title: info.description.trim().slice(0, 60), config: { terminal: { command: info.command, log: command.log } },
      state: { terminal: { phase: 'running' } }, presentation: 'background', status: 'open', createdAt: Date.now(),
      origin: { instanceId: ownerId, operationId: `${info.turnId ?? ''}:${info.callId ?? randomUUID()}`,
        ...(info.turnId ? { turnId: info.turnId } : {}), ...(info.callId ? { callId: info.callId } : {}) } };
    const session = new Session();
    const feed = (text: string) => {
      session.recent = (session.recent + text).slice(-TAIL_CHARS);
      session.output(terminalText(text));
    };
    feed(command.output);
    command.listen(feed);
    session.child = { pid: command.pid,
      done: command.done.then(({ code, stopped, unknown }) => ({ exitCode: code,
        ...(unknown ? { reason: '无法确认进程组已停止，需要人工检查' } : stopped ? { reason: stopped } : {}) })) };
    this.host.store.addPluginInstance(instance);
    this.sessions.set(instance.id, session);
    this.track(instance.id, command.pid);
    this.host.changed(owner.workspaceId);
    void this.exited(instance.id, session);
    this.watchPorts();
    return `后台终端的实例 ID 是 ${instance.id}，结束时会通知你；要看中途的输出用 terminal_read，不再需要时用 terminal_stop。`;
  }

  private async exited(id: string, session: Session): Promise<void> {
    const result = await session.child!.done;
    const reason = session.reason ?? result.reason;
    const state: TerminalState = { phase: 'exited', exitCode: result.exitCode, ...(result.signal ? { signal: result.signal } : {}),
      ...(reason ? { reason } : {}), endedAt: Date.now() };
    try { writeFileSync(this.screenFile(id), await session.screen(), { mode: 0o600 }); } catch {}
    rmSync(this.marker(id), { force: true });
    session.finish(state);
    this.forwardAll();
    const instance = this.host.store.instance(id);
    if (!instance) { this.sessions.delete(id); return; }
    this.save(id, state);
    if (session.notify && instance.origin && terminalConfig(instance)) {
      // 模板或变量出错时通知发不出，回收照常进行。
      try { this.notify(instance, state, session.recent); }
      catch (error) { console.error(`[终端] ${id} 的结束通知没有发出：${(error as Error).message}`); }
    }
    if (!this.closed) await this.collectIfWindowless(instance.workspaceId, id);
  }

  /** 告诉启动它的代理命令结束了；代理归档了就不送。投递失败稍后用同一 ID 补送几次。 */
  private notify(instance: PluginInstance, state: TerminalState, output: string): void {
    const target = instance.origin!.instanceId;
    const result = state.reason ?? (state.signal ? `被信号 ${state.signal} 停下` : `退出码 ${state.exitCode ?? '未知'}`);
    const text = assembleContext(bindContext(this.host.template(), { ...this.host.variables(target), ...sceneValues<'terminal.exit'>({
      'terminal.title': instance.title, 'terminal.id': instance.id, 'terminal.result': result,
      'terminal.output': output.trim() || '（没有输出）',
    }) })).instructions;
    const send = async (attempt: number): Promise<void> => {
      if (this.closed || this.host.store.instance(target)?.status !== 'open') return;
      try { await this.host.deliver(target, text, `terminal:${instance.id}:exit`); }
      catch (error) {
        console.error(`[终端] 通知 ${target} 失败：${(error as Error).message}`);
        if (attempt < 3) setTimeout(() => { void send(attempt + 1); }, NOTIFY_RETRY_MS).unref();
      }
    };
    void send(1);
  }

  /** 进程结束且没有窗口的实例回收；在控制队列里核对，和关窗口的回收不会重复。 */
  private collectIfWindowless(workspaceId: string, id: string): Promise<void> {
    return this.host.run(workspaceId, async () => {
      const instance = this.host.store.instance(id);
      if (!instance || this.running(id) || this.host.store.windows(workspaceId).some((w) => w.target.instanceId === id)) return;
      this.host.collect(instance);
      this.host.changed(workspaceId);
    }).catch((error) => { console.error(`[终端] 回收 ${id} 失败：${(error as Error).message}`); });
  }

  /** 回收实例时丢掉内存里的会话；进程还在跑时不能回收。 */
  forget(id: string): void {
    if (this.running(id)) throw new KiteError('终端还在运行', 409);
    this.sessions.delete(id);
  }

  /**
   * 停下终端：先挂断，等不到退出再停整个进程组；等到退出记进状态才返回。
   * quiet 是启动它的代理自己停的，结束时不再通知它。
   */
  stop(id: string, reason: string, quiet = false): Promise<void> {
    const session = this.sessions.get(id);
    if (!session?.child || session.ended) return Promise.resolve();
    if (quiet) session.notify = false;
    const existing = this.stopping.get(id);
    if (existing) return existing;
    session.reason = reason;
    const { pid } = session.child;
    const signal = (name: NodeJS.Signals) => { for (const group of [pid, ...session.groups]) try { process.kill(-group, name); } catch {} };
    const finished = session.finished.then(() => true);
    const within = (ms: number) => Promise.race([finished, delay(ms).then(() => false)]);
    const stopping = (async () => {
      // 作业各在自己的进程组：发信号前从进程树里找全，shell 一退出它们就脱离进程树了。
      const table = await processTable().catch(() => undefined);
      if (table) for (const group of treeGroups(pid, table)) session.groups.add(group);
      signal('SIGHUP');
      if (!await within(STOP_GRACE_MS)) {
        signal('SIGTERM');
        if (!await within(STOP_GRACE_MS / 2)) signal('SIGKILL');
      }
      await session.finished;
    })().finally(() => this.stopping.delete(id));
    this.stopping.set(id, stopping);
    return stopping;
  }

  /** 有运行中的终端就每隔一会儿扫一遍端口；都结束了停下。 */
  private watchPorts(): void {
    if (this.scanTimer || this.closed) return;
    this.scanTimer = setInterval(() => {
      this.scanning ??= this.scanPorts().catch((error) => { console.error(`[终端] 探测端口失败：${(error as Error).message}`); })
        .finally(() => { this.scanning = undefined; });
    }, this.host.portScanMs ?? PORT_SCAN_MS);
    this.scanTimer.unref();
  }

  /** 从每个运行中终端的进程树里找出正在监听的端口，变了写进状态，再把合起来的端口交给组网转发。 */
  private async scanPorts(): Promise<void> {
    const live = () => [...this.sessions].filter(([id]) => this.running(id));
    if (!live().length) {
      clearInterval(this.scanTimer);
      this.scanTimer = undefined;
      this.forwardAll();
      return;
    }
    const { table, ports } = await listening();
    for (const [id, session] of live()) {
      session.groups = treeGroups(session.child!.pid, table);
      const found = new Set<number>();
      for (const pid of descendants(session.child!.pid, table.children)) for (const port of ports.get(pid) ?? []) found.add(port);
      const next = new Map<number, boolean>();
      for (const port of [...found].sort((a, b) => a - b)) {
        const scans = (session.probes.get(port) ?? 0) + 1;
        session.probes.set(port, scans);
        let http = session.ports.get(port) === true;
        // 开头几次扫描都试；还不像网页的之后隔一阵再试，冷启动要编译很久的开发服务器晚些也认得出来。
        if (!http && (scans <= HTTP_PROBES || scans % HTTP_RETRY_SCANS === 0)) http = await speaksHttp(port);
        next.set(port, http);
      }
      for (const port of session.probes.keys()) if (!found.has(port)) session.probes.delete(port);
      if (!this.running(id) || [...next].join() === [...session.ports].join()) continue;
      session.ports = next;
      this.update(id, (state) => ({ ...state, ports: [...next].map(([port, http]) => ({ port, http })) }));
    }
    this.forwardAll();
  }

  /** 本机全部运行中终端监听的端口；kited 启动或组网开起来时也调一次。 */
  forwardAll(): void {
    this.host.forward([...this.sessions].filter(([id]) => this.running(id)).flatMap(([, session]) => [...session.ports.keys()]));
  }

  /** 网页视图选端口，跨设备共享；只能选正在监听的端口，null 换回默认。 */
  selectPort(id: string, port: number | null): { port: number | null } {
    const session = this.sessions.get(id);
    if (!session || !this.running(id)) throw new KiteError('终端已经结束', 409);
    if (port !== null && !session.ports.has(port)) throw new KiteError(`终端没有在监听端口 ${port}`, 409);
    this.update(id, ({ port: _previous, ...state }) => ({ ...state, ...(port === null ? {} : { port }) }));
    return { port };
  }

  /** 这个代理转到后台、还在跑的命令。 */
  owned(agentId: string): string[] {
    return [...this.sessions.keys()].filter((id) => this.running(id) && this.host.store.instance(id)?.origin?.instanceId === agentId);
  }

  /** 代理归档时停下它转到后台的命令，没人接收结束通知了。 */
  async stopOwned(agentId: string, reason: string): Promise<void> {
    await Promise.all(this.owned(agentId).map((id) => this.stop(id, reason, true)));
  }

  /** 工作区交接、冻结或归档前停下它的终端。 */
  async closeWorkspace(workspaceId: string, reason: string): Promise<void> {
    const ids = [...this.sessions.keys()].filter((id) => this.host.store.instance(id)?.workspaceId === workspaceId);
    await Promise.all(ids.map((id) => this.stop(id, reason)));
  }

  async close(): Promise<void> {
    this.closed = true;
    clearInterval(this.scanTimer);
    await Promise.all([...this.sessions.keys()].map((id) => this.stop(id, '工作机已关闭，终端已结束')));
  }

  /**
   * 启动时核对：上次还在跑的终端已经随 kited 结束，留下的进程组停掉，记为结束。终端这时都不在运行，没有窗口的一律回收，
   * 包括正常关闭时停下、来不及回收的。调用时控制队列里还没有别的工作，直接回收。
   */
  recover(): void {
    for (const workspace of this.host.store.workspaces()) {
      for (const instance of this.host.store.instances(workspace.id)) {
        if (instance.definitionId !== terminalDefinitionId) continue;
        if (terminalState(instance)?.phase !== 'exited') {
          this.killLeftover(instance.id);
          this.save(instance.id, { phase: 'exited', exitCode: null, reason: '工作机重启，终端已结束', endedAt: Date.now() });
        }
        if (!this.host.store.windows(workspace.id).some((w) => w.target.instanceId === instance.id)) this.host.collect(instance);
      }
    }
  }

  private killLeftover(id: string): void {
    const file = this.marker(id);
    if (!existsSync(file)) return;
    try {
      const { pid } = z.object({ pid: z.number().int().min(2) }).parse(JSON.parse(readFileSync(file, 'utf8')));
      if (processGroupAlive(pid)) process.kill(-pid, 'SIGKILL');
    } catch {}
    rmSync(file, { force: true });
  }

  private save(id: string, state: TerminalState): void {
    const instance = this.host.store.instance(id);
    if (!instance) return;
    this.host.store.setInstanceState(id, { ...instance.state, terminal: state });
    this.host.changed(instance.workspaceId);
  }
  private update(id: string, change: (state: TerminalState) => TerminalState): void {
    const instance = this.host.store.instance(id);
    const state = instance && terminalState(instance);
    if (state) this.save(id, change(state));
  }

  /**
   * terminal.read：按行读输出。转到后台的命令读完整日志，shell 读画面和回滚里的文字；
   * 不给 offset 时读最后 limit 行。
   */
  async read(id: string, offset: number | undefined, limit: number) {
    const instance = this.host.store.instance(id);
    if (!instance) throw new KiteError('没有这个终端', 404);
    const config = terminalConfig(instance);
    const session = this.sessions.get(id);
    let lines: string[];
    if (config) lines = readTail(config.log).split('\n');
    else lines = session ? await session.lines() : [];
    if (lines.at(-1) === '') lines.pop();
    const total = lines.length;
    const start = offset ?? Math.max(1, total - limit + 1);
    const end = Math.min(start - 1 + limit, total);
    return { instanceId: id, title: instance.title, ...(config ? { command: config.command } : {}),
      ...(terminalState(instance) ?? { phase: 'exited' as const }),
      text: lines.slice(start - 1, end).join('\n'), offset: start, totalLines: total, nextOffset: end < total ? end + 1 : null };
  }

  /** WebSocket 升级前核对：实例存在、是终端、所在工作区打开着。 */
  check(id: string): void {
    const instance = this.host.store.instance(id);
    if (!instance || instance.definitionId !== terminalDefinitionId) throw new KiteError('没有这个终端', 404);
    if (this.host.store.workspace(instance.workspaceId)?.status !== 'open') throw new KiteError('工作区尚未打开', 409);
  }

  attach(socket: Socket): void {
    const id = socket.data.instanceId;
    const session = this.sessions.get(id);
    if (session) { session.attach(socket); return; }
    // 工作机重启前结束的终端只剩存下的最后画面。
    const instance = this.host.store.instance(id);
    let data = '';
    try { data = readFileSync(this.screenFile(id), 'utf8'); } catch {}
    socket.send(JSON.stringify({ type: 'snapshot', data, cols: 80, rows: 24,
      ...(instance && terminalState(instance)) ?? { phase: 'exited', exitCode: null } }));
  }

  receive(socket: Socket, message: string | Buffer): void {
    const session = this.sessions.get(socket.data.instanceId);
    if (!session) return;
    if (typeof message !== 'string') { session.input(socket, message); return; }
    const parsed = controlSchema.safeParse((() => { try { return JSON.parse(message); } catch { return undefined; } })());
    if (!parsed.success) { socket.close(1003, '终端控制消息无效'); return; }
    session.requestSize(socket, { cols: parsed.data.cols, rows: parsed.data.rows });
  }

  detach(socket: Socket): void {
    this.sessions.get(socket.data.instanceId)?.detach(socket);
  }
}

const capture = async (command: string[]) => (await systemCommand(command, { env: { PATH: '/usr/sbin:/usr/bin:/bin', LANG: 'C' } })).stdout;

interface ProcessTable { children: Map<number, number[]>; groups: Map<number, number> }

/** 进程的父子关系与各自所在的进程组。 */
async function processTable(): Promise<ProcessTable> {
  const children = new Map<number, number[]>(), groups = new Map<number, number>();
  for (const line of (await capture(['ps', '-Ao', 'pid=,ppid=,pgid='])).split('\n')) {
    const [pid, parent, group] = line.trim().split(/\s+/).map(Number);
    if (!pid || parent === undefined || Number.isNaN(parent)) continue;
    children.set(parent, [...children.get(parent) ?? [], pid]);
    if (group) groups.set(pid, group);
  }
  return { children, groups };
}

/** root 的进程树占了哪些进程组；kited 自己所在的组不算。 */
function treeGroups(root: number, { children, groups }: ProcessTable): Set<number> {
  const found = new Set([...descendants(root, children)].flatMap((pid) => groups.get(pid) ?? []));
  found.delete(groups.get(process.pid) ?? -1);
  return found;
}

/** 进程表，以及每个进程正在监听的 TCP 端口。lsof 没找到监听时输出为空。 */
async function listening(): Promise<{ table: ProcessTable; ports: Map<number, Set<number>> }> {
  const [table, open] = await Promise.all([processTable(), capture(['lsof', '-nP', '-iTCP', '-sTCP:LISTEN', '-Fpn'])]);
  const ports = new Map<number, Set<number>>();
  let pid = 0;
  for (const line of open.split('\n')) {
    if (line.startsWith('p')) pid = Number(line.slice(1));
    else if (line.startsWith('n') && pid) {
      const port = Number(line.slice(line.lastIndexOf(':') + 1));
      if (Number.isInteger(port) && port > 0) ports.set(pid, (ports.get(pid) ?? new Set()).add(port));
    }
  }
  return { table, ports };
}

function descendants(root: number, children: Map<number, number[]>): Set<number> {
  const found = new Set([root]);
  for (const pid of found) for (const child of children.get(pid) ?? []) found.add(child);
  return found;
}

/** 端口上是不是 HTTP 服务：直接连本机回环发一个 HEAD，看回的是不是 HTTP 响应；不经代理。 */
async function speaksHttp(port: number): Promise<boolean> {
  for (const host of ['127.0.0.1', '::1']) {
    const answer = await new Promise<boolean | undefined>((resolve) => {
      const socket = connect({ host, port, timeout: 800 });
      const done = (value: boolean | undefined) => { socket.destroy(); resolve(value); };
      socket.once('connect', () => socket.write(`HEAD / HTTP/1.1\r\nHost: localhost:${port}\r\nConnection: close\r\n\r\n`));
      socket.once('data', (data) => done(String(data).startsWith('HTTP/')));
      socket.once('timeout', () => done(false));
      socket.once('error', () => done(undefined));
      socket.once('end', () => done(false));
    });
    if (answer !== undefined) return answer;
  }
  return false;
}

/** 日志太大时只读末尾 READ_WINDOW 字节，从第一个完整行开始。 */
function readTail(path: string): string {
  let fd: number;
  try { fd = openSync(path, 'r'); } catch { return ''; }
  try {
    const size = fstatSync(fd).size;
    const length = Math.min(size, READ_WINDOW);
    const buffer = Buffer.alloc(length);
    readSync(fd, buffer, 0, length, size - length);
    const text = buffer.toString('utf8');
    return size > length ? text.slice(text.indexOf('\n') + 1) : text;
  } finally { closeSync(fd); }
}
