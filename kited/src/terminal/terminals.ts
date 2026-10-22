/**
 * 终端插件 kite.terminal：一个实例一个进程，进程归工作机。实例的 lifetime 是 process：进程运行中独立存续，
 * 关掉窗口照跑，在停靠栏是没有窗口的小头像；进程结束后没有窗口就回收，有窗口的留到关掉窗口；随 kited 重启结束的连窗口一起回收。
 * 进程有三种：用户开的终端是用户的登录 shell，跑在 PTY 里，不加沙箱，相当于登录到这台工作机，起始目录是工作区目录，
 * 新建时可以带一条命令（对话里代码块的「在终端中执行」），shell 起好后像粘贴那样打进去执行；
 * 代理的 shell 命令超时、用户插话或模型要求时转到后台，由这里接管，仍在代理的沙箱里、只有输出没有输入，结束时通知那个代理；
 * 项目的预置脚本（见 scripts.ts）同用户开的终端一样跑在 PTY 里、不加沙箱，环境变量 PORT 是分给它的端口段，工作区有模拟器时 KITE_SIMULATOR 是它的编号，
 * 同一工作区的同一脚本只跑一份。
 * 无头终端（@xterm/headless）跟着输出维护一份画面，设备接入时先发当前画面再推后续输出；PTY 的尺寸跟最近输入的那台设备。
 * 进程归 kited：kited 退出时终端随之结束，重启后不再拉起，只把上次留下的进程组停掉。
 * 运行中的终端定时从自己的进程树探测正在监听的端口，写进实例状态，本机全部运行中终端的端口合起来交给组网转发，
 * 供各设备的网页预览打开（docs/成果查看与位置.md「运行中的网页」）。
 * WebSocket 协议：接入地址可带 cols、rows，先按这台设备的尺寸调整再出画面；服务端先发 {type:'snapshot', data, cols, rows, phase, ...}，
 * 之后二进制帧是输出，{type:'size'} 是尺寸换了，{type:'exit'} 是进程结束；客户端二进制帧是输入，{type:'resize', cols, rows} 报自己放得下的尺寸。
 */
import { closeSync, existsSync, fstatSync, mkdirSync, openSync, readFileSync, readSync, rmSync, writeFileSync } from 'node:fs';
import { randomUUID } from 'node:crypto';
import { userInfo } from 'node:os';
import { connect } from 'node:net';
import { basename, join } from 'node:path';
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
import type { InputNotice } from '../harness/types.ts';
import { numberedTitle, type PluginInstance } from '../model.ts';
import type { Store } from '../store.ts';
import { systemCommand } from '../system-command.ts';
import { allocateScriptPorts, SCRIPTS_DIR, type Script } from './scripts.ts';
import { terminalState, type TerminalState } from './state.ts';

export const terminalDefinitionId = 'kite.terminal';

export const terminalExitContextDefinition: ContextDefinition = {
  version: 2, id: 'kite.terminal-exit', title: '后台命令结束', scene: 'terminal.exit',
  blocks: [
    { type: 'paragraph', id: 'result', title: '结果', parts: [
      { type: 'text', text: '你在后台运行的「' }, { type: 'variable', name: 'terminal.title' },
      { type: 'text', text: '」（终端 ' }, { type: 'variable', name: 'terminal.id' }, { type: 'text', text: '）已结束：' },
      { type: 'variable', name: 'terminal.result' }, { type: 'text', text: '。输出的末尾：\n' }, { type: 'variable', name: 'terminal.output' },
    ] },
    { type: 'paragraph', id: 'guidance', title: '处理方式', parts: [{ type: 'text',
      text: '终端没有窗口时随即回收，之后读不到它，以这里的输出为准。' }] },
  ],
};

/** 实例配置：转到后台的命令记下命令与完整日志的位置，预置脚本的终端记下脚本名；用户开的终端没有。 */
const configSchema = z.union([z.object({ command: z.string(), log: z.string() }).strict(), z.object({ script: z.string() }).strict()]);
const terminalConfig = (instance: Pick<PluginInstance, 'config'>) =>
  instance.config.terminal === undefined ? undefined : configSchema.parse(instance.config.terminal);
const scriptName = (instance: Pick<PluginInstance, 'config'>) => {
  const config = terminalConfig(instance);
  return config && 'script' in config ? config.script : undefined;
};
/** 代理的 shell 转到后台的命令：跑在那个代理的沙箱里。 */
const adoptedCommand = (instance: Pick<PluginInstance, 'config'>) => {
  const config = terminalConfig(instance);
  return config && 'command' in config ? config : undefined;
};

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
  deliver(threadId: string, text: string, inputId: string, notice: InputNotice): Promise<unknown>;
  template(): ContextDefinition;
  /** 代理线程的公共变量。 */
  variables(threadId: string): ContextValues;
  /** 本机全部运行中终端监听的端口，整组替换给组网转发；组网没开时什么也不做。 */
  forward(ports: number[]): void;
  /** 预置脚本起之前的准备：用到工作区模拟器的先建好（见 preview/simulators.ts）。 */
  prepareScript(workspaceId: string, script: Script): Promise<void>;
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
/** 带命令新建时等 shell 起好：不开括号粘贴的 shell 以启动输出停下这么久为准；最多等 READY_MS。 */
const SETTLE_MS = 200;
const READY_MS = 10_000;
/** 行编辑器开始读输入时打开括号粘贴的 shell：等到它打开才算起好，只看输出停下会赶在插件加载的空当里打进去。 */
const BRACKETED_SHELLS = new Set(['zsh', 'fish']);
/** 一个端口开头连着试这么多次 HTTP；还不像网页的之后每隔 HTTP_RETRY_SCANS 次扫描（约半分钟）再试，不一直去敲数据库这类服务。 */
const HTTP_PROBES = 5;
const HTTP_RETRY_SCANS = 15;
/** terminal.run 最多等这么久：开发服务器多半在这之前能响应，构建、安装这类脚本到时先返回，退出时再通知。 */
const RUN_WAIT_MS = 30_000;
/** 结束通知和 terminal.run 结果里，PTY 里跑的进程带画面与回滚的最后这么多行。 */
const TAIL_LINES = 40;

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
  /** terminal.run 正在等它：这期间结束的，结果随调用交给代理，不再发结束通知。 */
  reported = false;
  /** 转到后台的命令最近的输出原文，见 tail。 */
  recent = '';
  /** 最近一次输出的时间，带命令新建时据此等 shell 起好。 */
  outputAt = 0;
  /** 进程树正在监听的端口 → 能不能用 HTTP 打开，变了用 setPorts 换。 */
  ports = new Map<number, boolean>();
  private portsChange = Promise.withResolvers<void>();
  /** 每个端口扫描过几次，用来定 HTTP 探测的间隔。 */
  probes = new Map<number, number>();
  /** 进程树里各作业所在的进程组（交互 shell 开着作业控制，每个作业各在一组），端口扫描和停止时更新；shell 退出后它们就脱离了进程树。 */
  groups = new Set<number>();

  /** 所在的工作区，按工作区找端口时不必查库。 */
  constructor(readonly workspaceId: string) {
    this.mirror = new Mirror({ ...this.size, scrollback: SCROLLBACK, allowProposedApi: true });
    this.mirror.loadAddon(this.serializer);
  }

  get finished(): Promise<void> { return this.done.promise; }
  /** 下一次端口变化时兑现，terminal.run 据此等端口。 */
  get portsChanged(): Promise<void> { return this.portsChange.promise; }
  setPorts(ports: Map<number, boolean>): void {
    this.ports = ports;
    this.portsChange.resolve();
    this.portsChange = Promise.withResolvers();
  }

  output(data: Uint8Array): void {
    this.outputAt = Date.now();
    this.mirror.write(data);
    for (const socket of this.sockets) socket.send(data);
    for (const pending of this.attaching.values()) pending.push(data);
  }

  /**
   * 无头终端处理完此刻之前的输出后马上读：在写入回调里同步读，等 Promise 回来时无头终端可能已经接着处理了之后的输出。
   * 之后到的输出排在后面，所以画面正好接着发。
   */
  private flushed<T>(read: () => T): Promise<T> {
    return new Promise((resolve) => this.mirror.write(new Uint8Array(0), () => resolve(read())));
  }
  screen(): Promise<string> {
    return this.flushed(() => this.serializer.serialize());
  }
  /** 输出的末尾：转到后台的命令取原文，PTY 里跑的取画面与回滚的最后几行。 */
  async tail(): Promise<string> {
    return this.recent || (await this.lines()).slice(-TAIL_LINES).join('\n').slice(-TAIL_CHARS);
  }
  /** 画面和回滚里的文字，一行一项。 */
  lines(): Promise<string[]> {
    return this.flushed(() => {
      const buffer = this.mirror.buffer.active;
      const lines: string[] = [];
      for (let y = 0; y < buffer.length; y++) lines.push(buffer.getLine(y)?.translateToString(true) ?? '');
      while (lines.length && !lines.at(-1)) lines.pop();
      return lines;
    });
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
  /**
   * 带命令新建：等 shell 起好再像终端粘贴那样打进去，shell 接管终端之前打进去的字会被回显两遍。会开括号粘贴的 shell 等它打开，
   * 别的等启动输出停下；打的时候开着括号粘贴就整段包起来，制表符、换行不触发补全和执行，最后回车一次。
   */
  async type(text: string, bracketedShell: boolean): Promise<void> {
    const deadline = Date.now() + READY_MS;
    const ready = () => this.mirror.modes.bracketedPasteMode || (!bracketedShell && this.outputAt > 0 && Date.now() - this.outputAt >= SETTLE_MS);
    while (!this.ended && Date.now() < deadline && !ready()) await delay(50);
    const body = text.replace(/\r?\n/g, '\r');
    await this.flushed(() => {
      if (this.ended) return;
      this.child?.write?.(new TextEncoder().encode(this.mirror.modes.bracketedPasteMode ? `\x1b[200~${body}\x1b[201~\r` : `${body}\r`));
    });
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

/** 用户的登录 shell。zsh 交互时默认把 # 开头的行当命令，代码块常带注释，打开 interactivecomments（bash 默认就开着）。 */
function loginShell(): string[] {
  const shell = userInfo().shell || '/bin/zsh';
  return basename(shell) === 'zsh' ? [shell, '-l', '-o', 'interactivecomments'] : [shell, '-l'];
}

/** 经用户的登录 shell 运行预置脚本，环境与用户开的终端一致；exec 换成脚本本身，进程就是脚本。fish 取参数的写法不同。 */
const scriptCommand = (shell: string[], path: string) =>
  basename(shell[0]!) === 'fish' ? [...shell, '-c', 'exec $argv[1]', path] : [...shell, '-c', 'exec "$1"', 'kite-script', path];

/** 命令输出是管道里的文字：单独的换行在终端里补成回车换行。 */
const terminalText = (text: string) => new TextEncoder().encode(text.replace(/\r?\n/g, '\r\n'));

export class Terminals {
  private sessions = new Map<string, Session>();
  private stopping = new Map<string, Promise<void>>();
  private closed = false;
  private scanTimer?: ReturnType<typeof setInterval>;
  private scanning?: Promise<void>;

  constructor(private host: TerminalsHost) {}

  /** 进程是否还在跑；process 实例据此决定关掉窗口时回不回收。 */
  running(id: string): boolean {
    const session = this.sessions.get(id);
    return !!session && !session.ended;
  }

  /** 还在跑的终端与后台命令有几个；自动更新等它们结束才换版。 */
  active(): number {
    return [...this.sessions.keys()].filter((id) => this.running(id)).length;
  }

  private directory(id: string) { return join(this.host.home, 'sessions', id); }
  private marker(id: string) { return join(this.directory(id), 'terminal-process.json'); }
  private screenFile(id: string) { return join(this.directory(id), 'terminal-screen.txt'); }
  private track(id: string, pid: number) {
    mkdirSync(this.directory(id), { recursive: true });
    writeFileSync(this.marker(id), JSON.stringify({ pid }), { mode: 0o600 });
  }

  /**
   * 新实例刚入库就起 shell；起不来记为结束，窗口里看得到原因。带命令的等 shell 起好再打进去。
   * 以预置脚本起的（配置见 scriptConfig）经登录 shell 直接运行脚本，PORT 是分给它的端口段的第一个，KITE_SIMULATOR 是工作区模拟器的编号，
   * 脚本退出终端就结束。
   */
  start(instance: PluginInstance, command?: string): void {
    if (this.closed) throw new KiteError('kited 正在关闭', 503);
    const workspace = this.host.store.workspace(instance.workspaceId);
    if (!workspace || workspace.status !== 'open') throw new KiteError('工作区尚未打开', 409);
    const session = new Session(instance.workspaceId);
    const shell = this.host.shell ?? loginShell();
    const script = scriptName(instance);
    const simulator = script && this.host.store.workspaceSimulator(instance.workspaceId);
    const env = { ...commandEnvironment(this.host.env), SHELL: shell[0], TERM: 'xterm-256color', COLORTERM: 'truecolor',
      TERM_PROGRAM: 'Kite', LANG: this.host.env.LANG ?? 'en_US.UTF-8',
      ...(script ? { PORT: String(this.host.store.scriptPort(instance.workspaceId, script)) } : {}),
      ...(simulator ? { KITE_SIMULATOR: simulator } : {}) };
    const eof = Promise.withResolvers<void>();
    let child;
    try {
      child = Bun.spawn(script ? scriptCommand(shell, join(workspace.cwd, SCRIPTS_DIR, script)) : shell, { cwd: workspace.cwd, env, terminal: {
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
    if (command) void session.type(command, BRACKETED_SHELLS.has(basename(shell[0]!)));
  }

  /** 以预置脚本起的终端的实例配置；先给工作区的这个脚本分好端口段、建好要用的模拟器，start 时经环境变量交给脚本。 */
  async scriptConfig(workspaceId: string, script: Script): Promise<PluginInstance['config']> {
    await allocateScriptPorts(this.host.store, workspaceId, script.name);
    await this.host.prepareScript(workspaceId, script);
    return { terminal: { script: script.name } };
  }

  /** 工作区里这个预置脚本正在跑的终端。 */
  scriptInstance(workspaceId: string, name: string): string | undefined {
    return [...this.sessions.keys()].find((id) => {
      if (!this.running(id)) return false;
      const instance = this.host.store.instance(id);
      return instance?.workspaceId === workspaceId && scriptName(instance) === name;
    });
  }

  /**
   * terminal.run：起预置脚本，建一个没有窗口的终端实例，来源是调用方（界面起的没有）；审批由调用方先做完。
   * 同一脚本已经在跑时返回那个，restart 时先停掉再起；脚本在核对内容（与主线比对或经审批）之后又改了的不起。
   * 新起的限时等到有能用 HTTP 打开的端口或脚本退出，返回进程状态、端口段与输出末尾；等的期间退出的不再发结束通知，结果里已经有了。
   */
  async runScript(workspaceId: string, script: Script, options: { restart?: boolean; origin?: PluginInstance['origin'] }, signal?: AbortSignal) {
    const { instance, reused } = await this.host.run(workspaceId, async () => {
      const running = this.scriptInstance(workspaceId, script.name);
      if (running && !options.restart) return { instance: this.host.store.instance(running)!, reused: true };
      if (running) await this.stop(running, '预置脚本重新运行', true);
      const config = await this.scriptConfig(workspaceId, script);
      if (readFileSync(script.path, 'utf8') !== script.content) throw new KiteError(`预置脚本「${script.name}」刚刚又改了，重新运行一次`, 409);
      const instance: PluginInstance = { id: randomUUID(), workspaceId, definitionId: terminalDefinitionId, title: script.name, config, state: {},
        presentation: 'background', status: 'open', createdAt: Date.now(), origin: options.origin };
      this.host.store.addPluginInstance(instance);
      this.start(instance);
      return { instance, reused: false };
    });
    const session = this.sessions.get(instance.id);
    if (session && !reused) {
      session.reported = true;
      // 到时限或调用取消时兑现 over；等完撤掉定时器。
      const settled = new AbortController();
      const over = delay(RUN_WAIT_MS, 'over' as const, { signal: signal ? AbortSignal.any([signal, settled.signal]) : settled.signal })
        .catch(() => 'over' as const);
      while (!session.ended && ![...session.ports.values()].some(Boolean)) {
        if (await Promise.race([session.finished, session.portsChanged, over]) === 'over') break;
      }
      settled.abort();
      if (!session.ended) session.reported = false;
    }
    // 没有窗口的终端退出后随即回收，库里可能已经没有它了，状态取会话里的。
    const current = this.host.store.instance(instance.id) ?? instance;
    const state = session?.ended ?? terminalState(current) ?? { phase: 'exited' as const };
    return { instanceId: instance.id, title: current.title, script: script.name, reused,
      assignedPort: this.host.store.scriptPort(workspaceId, script.name)!, ...state, text: session ? await session.tail() : '' };
  }

  /**
   * 接管代理 shell 工具转到后台的命令：建一个没有窗口的终端实例，来源记为这次工具调用，返回告诉模型的说明。
   * 工作区不再打开（正在交接或归档）时不接管，停下命令。
   */
  adopt(ownerId: string, command: BackgroundCommand, info: { command: string; turnId?: string; callId?: string }): string {
    const owner = this.host.store.instance(ownerId);
    const workspace = owner && this.host.store.workspace(owner.workspaceId);
    if (this.closed || !owner || owner.status !== 'open' || workspace?.status !== 'open') {
      command.stop('工作区不再在这台工作机上打开');
      return '但工作区已不在这台工作机上打开，命令已停下。';
    }
    // 名字只用来在停靠栏和窗口上认出是哪个，同用户开的「终端 N」编号；不用 shell 的 description，它常写成申请出沙箱的理由，太长
    const title = numberedTitle('进程', this.host.store.instances(owner.workspaceId).map((instance) => instance.title));
    const instance: PluginInstance = { id: randomUUID(), workspaceId: owner.workspaceId, definitionId: terminalDefinitionId,
      title, config: { terminal: { command: info.command, log: command.log } },
      state: { terminal: { phase: 'running' } }, presentation: 'background', status: 'open', createdAt: Date.now(),
      origin: { instanceId: ownerId, operationId: `${info.turnId ?? ''}:${info.callId ?? randomUUID()}`,
        ...(info.turnId ? { turnId: info.turnId } : {}), ...(info.callId ? { callId: info.callId } : {}) } };
    const session = new Session(owner.workspaceId);
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
    // 工作机关闭时停下的不记结束：下次启动按还在运行认出是被重启结束的，连窗口一起回收（见 recover）
    if (!this.closed) this.save(id, state);
    // 有来源的是代理转到后台的命令或起的预置脚本；用户开的终端没有。
    if (session.notify && !session.reported && instance.origin) {
      const output = await session.tail();
      // 模板或变量出错时通知发不出，回收照常进行。
      try { this.notify(instance, state, output); }
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
    const notice = { kind: 'terminal.exit', subject: instance.title, title: `${instance.title} 结束了：${result}` } as const;
    const send = async (attempt: number): Promise<void> => {
      if (this.closed || this.host.store.instance(target)?.status !== 'open') return;
      try { await this.host.deliver(target, text, `terminal:${instance.id}:exit`, notice); }
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
      session.setPorts(next);
      this.update(id, (state) => ({ ...state, ports: [...next].map(([port, http]) => ({ port, http })) }));
    }
    this.forwardAll();
  }

  /** 本机全部运行中终端监听的端口；kited 启动或组网开起来时也调一次。 */
  forwardAll(): void {
    this.host.forward([...this.sessions].filter(([id]) => this.running(id)).flatMap(([, session]) => [...session.ports.keys()]));
  }

  /** 工作区里运行中终端此刻监听的端口：网页预览只能看这些，工作机上的浏览器也只放行到这些端口。 */
  workspacePorts(workspaceId: string): number[] {
    return [...new Set([...this.sessions].filter(([id, session]) => session.workspaceId === workspaceId && this.running(id))
      .flatMap(([, session]) => [...session.ports.keys()]))].sort((a, b) => a - b);
  }

  /** 这个代理转到后台、还在跑的命令；它起的预置脚本不在沙箱里，属于工作区，不算。 */
  owned(agentId: string): string[] {
    return [...this.sessions.keys()].filter((id) => {
      if (!this.running(id)) return false;
      const instance = this.host.store.instance(id);
      return instance?.origin?.instanceId === agentId && !!adoptedCommand(instance);
    });
  }

  /** 代理归档时停下它转到后台的命令，没人接收结束通知了；它起的预置脚本照跑。 */
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
   * 启动时核对：上次还在跑的终端已经随 kited 结束（正常关闭时停下的也按还在跑记着，见 exited），留下的进程组停掉，
   * 连窗口一起回收，进程没了，窗口留着也接不回来。之前就自己结束了的照旧：没有窗口的回收，有窗口的留着看最后的画面。
   * 调用时控制队列里还没有别的工作，直接回收。
   */
  recover(): void {
    for (const workspace of this.host.store.workspaces()) {
      const windows = this.host.store.windows(workspace.id);
      for (const instance of this.host.store.instances(workspace.id)) {
        if (instance.definitionId !== terminalDefinitionId) continue;
        const killed = terminalState(instance)?.phase !== 'exited';
        if (killed) this.killLeftover(instance.id);
        const window = windows.find((w) => w.target.instanceId === instance.id);
        if (window && !killed) continue;
        this.host.store.transaction(() => {
          if (window) this.host.store.closeWindow(window.id);
          this.host.collect(instance);
        });
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

  /** list 里的一项：标题、命令（转到后台的才有）或预置脚本名与进程状态，不读输出。 */
  describe(instance: PluginInstance) {
    const config = terminalConfig(instance);
    return { instanceId: instance.id, title: instance.title, ...(config && 'command' in config ? { command: config.command } : config),
      ...(terminalState(instance) ?? { phase: 'exited' as const }) };
  }

  /**
   * terminal.read：按行读输出。转到后台的命令读完整日志，shell 和预置脚本读画面和回滚里的文字；
   * 不给 offset 时读最后 limit 行。
   */
  async read(id: string, offset: number | undefined, limit: number) {
    const instance = this.host.store.instance(id);
    if (!instance) throw new KiteError('没有这个终端', 404);
    const command = adoptedCommand(instance);
    const session = this.sessions.get(id);
    let lines: string[];
    if (command) lines = readTail(command.log).split('\n');
    else lines = session ? await session.lines() : [];
    if (lines.at(-1) === '') lines.pop();
    const total = lines.length;
    const start = offset ?? Math.max(1, total - limit + 1);
    const end = Math.min(start - 1 + limit, total);
    return { ...this.describe(instance), text: lines.slice(start - 1, end).join('\n'), offset: start, totalLines: total, nextOffset: end < total ? end + 1 : null };
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
