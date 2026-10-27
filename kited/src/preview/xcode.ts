/**
 * 模拟器的画面与操作用 Xcode 自带的（docs/实例操作.md「模拟器」，实测见 spikes/xcode-device-interaction）：
 * agent 的动作、给模型的截图与界面结构经 Xcode 的设备操作工具（xcrun mcpbridge，MCP 工具 DeviceInteraction*），按模拟器编号开会话；指认按界面结构找控件；
 * 给设备看的帧用 simctl 截全分辨率的屏幕。每个动作 Xcode 做完就截一帧，不另外等画面稳定。
 * Xcode 只认批准过的程序：没批准时建一个占位项目发起批准请求（调用挂着等批准），错误里给出用户要在工作机终端里跑的命令。
 * 会话闲置几分钟会被 Xcode 关掉，用过的会话名短时间内不能再用：每次开会话换一个名字，会话没了就重开。
 */
import { randomUUID } from 'node:crypto';
import { existsSync, mkdirSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { z } from 'zod';
import { KiteError } from '../errors.ts';
import { systemCommand } from '../system-command.ts';
import { sameFrame, type Frame, type PointedElement, type PreviewAction, type Screen } from './screen.ts';

/** 一条工具调用最多等这么久；开会话后第一次截图要等模拟器开机，实测约一分钟。 */
const CALL_TIMEOUT_MS = 3 * 60_000;
/** 动作之后 Xcode 截的那一帧多久之内还算当前画面。 */
const FRESH_MS = 2000;
/** 界面结构给模型的上限。 */
const HIERARCHY_CHARS = 100_000;
/** 指认时 Xcode 没给界面结构，隔这么久再要。 */
const CONTROLS_RETRY_MS = 3000;
const AGENT_NAME = 'Kite';

type Reply = { result?: { content?: Array<{ type: string; text?: string }>; structuredContent?: Record<string, unknown>; isError?: boolean };
  error?: { message: string } };

/** 连着 xcrun mcpbridge 的一条 stdio 通道，JSON-RPC 一行一条。 */
class Bridge {
  private nextId = 0;
  private waiting = new Map<number, { resolve(reply: Reply): void; reject(error: Error): void }>();
  readonly exited: Promise<void>;
  private dead = false;

  constructor(private child: Bun.Subprocess<'pipe', 'pipe', 'ignore'>) {
    void this.read();
    this.exited = child.exited.then(() => {
      this.dead = true;
      for (const { reject } of this.waiting.values()) reject(new KiteError('Xcode 的工具服务断开了', 503));
      this.waiting.clear();
    });
  }

  private async read(): Promise<void> {
    const decoder = new TextDecoder();
    let buffer = '';
    for await (const chunk of this.child.stdout) {
      buffer += decoder.decode(chunk, { stream: true });
      let end;
      while ((end = buffer.indexOf('\n')) >= 0) {
        const line = buffer.slice(0, end).trim();
        buffer = buffer.slice(end + 1);
        if (!line) continue;
        let message: { id?: number } & Reply;
        try { message = JSON.parse(line); } catch { continue; }
        // 没有 id 的是通知（工具清单变了这类），不用
        if (typeof message.id !== 'number') continue;
        const waiter = this.waiting.get(message.id);
        this.waiting.delete(message.id);
        waiter?.resolve(message);
      }
    }
  }

  request(method: string, params?: unknown, timeoutMs = CALL_TIMEOUT_MS): Promise<Reply> {
    if (this.dead) return Promise.reject(new KiteError('Xcode 的工具服务断开了', 503));
    const id = ++this.nextId;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        if (!this.waiting.delete(id)) return;
        reject(new KiteError('Xcode 的工具没有响应', 504));
      }, timeoutMs);
      timer.unref();
      this.waiting.set(id, { resolve: (reply) => { clearTimeout(timer); resolve(reply); }, reject: (error) => { clearTimeout(timer); reject(error); } });
      this.send({ jsonrpc: '2.0', id, method, ...(params === undefined ? {} : { params }) });
    });
  }

  send(message: object): void {
    void this.child.stdin.write(`${JSON.stringify(message)}\n`);
    void this.child.stdin.flush();
  }

  close(): void { this.child.kill(); }
}

/** 一次设备操作的结果：截图（PNG，按点）与界面结构文件，都在 Xcode 的临时目录里。 */
const synthesized = z.object({ screenshotPath: z.string(), hierarchyPath: z.string().optional() }).loose();
const statusSchema = z.object({ permission: z.object({
  pendingAgentApprovals: z.array(z.object({ id: z.string(), subject: z.object({ agent: z.object({ _0: z.object({ name: z.string() }).loose() }).loose() }).loose() }).loose()).optional(),
  pendingFolderApprovals: z.array(z.object({ id: z.string(), subject: z.object({ folder: z.object({ _0: z.object({ subtreeRoot: z.string() }).loose() }).loose() }).loose() }).loose()).optional(),
}).loose() }).loose();

/** Xcode 的设备操作工具，整个 kited 共用一条通道。 */
export class XcodeTools {
  private bridge?: Promise<Bridge>;
  private approving?: Promise<unknown>;

  /** home 下的 xcode/ 放发起批准用的占位项目；env 是跑 xcrun 的环境，显式给出。 */
  constructor(private home: string, private env: Record<string, string>) {}

  private connect(): Promise<Bridge> {
    if (process.platform !== 'darwin') return Promise.reject(new KiteError('只有 Mac 工作机能开 iOS 模拟器', 503));
    if (this.bridge) return this.bridge;
    const connecting = (async () => {
      const child = Bun.spawn(['/usr/bin/xcrun', 'mcpbridge'], { env: this.env, stdin: 'pipe', stdout: 'pipe', stderr: 'ignore' });
      const bridge = new Bridge(child);
      // 断了的、握手没成的丢掉，下次重连；只丢自己这一条，别丢了已经换上的新连接
      void bridge.exited.then(() => { if (this.bridge === connecting) this.bridge = undefined; });
      try {
        const init = await bridge.request('initialize', { protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: AGENT_NAME, version: '1' } }, 60_000);
        if (init.error) throw new KiteError(`Xcode 的工具服务没有连上：${init.error.message}`, 503);
      } catch (error) {
        bridge.close();
        throw error;
      }
      bridge.send({ jsonrpc: '2.0', method: 'notifications/initialized' });
      return bridge;
    })();
    this.bridge = connecting;
    connecting.catch(() => { if (this.bridge === connecting) this.bridge = undefined; });
    return connecting;
  }

  /** 调一个工具，返回结构化的结果；工具报错时抛出它的说明，没批准时说明怎么批准。 */
  async call(name: string, args: Record<string, unknown>): Promise<Record<string, unknown>> {
    const bridge = await this.connect();
    const reply = await bridge.request('tools/call', { name, arguments: args });
    if (reply.error) throw new KiteError(`Xcode 的工具出错：${reply.error.message}`, 503);
    const text = reply.result?.content?.find((item) => item.type === 'text')?.text ?? '';
    if (reply.result?.isError) {
      if (/isn't approved/.test(text)) throw new KiteError(await this.approval(bridge), 403);
      let message = text;
      try { message = String((JSON.parse(text) as { data?: unknown }).data ?? text); } catch {}
      throw new KiteError(`Xcode：${message}`, 409);
    }
    if (reply.result?.structuredContent) return reply.result.structuredContent;
    try { return JSON.parse(text) as Record<string, unknown>; } catch { return { text }; }
  }

  /**
   * 发起批准：打开（第一次是新建）占位项目，这一步向用户要批准，调用挂着等批准，不等它。读出挂起的请求编号，拼成用户要跑的命令；
   * kited 跑在签了名的 bun 上，批准用 --always，一直有效。
   */
  private async approval(bridge: Bridge): Promise<string> {
    const folder = join(this.home, 'xcode');
    const project = join(folder, 'KitePreview', 'KitePreview.xcodeproj');
    if (!this.approving) {
      mkdirSync(folder, { recursive: true });
      this.approving = bridge.request('tools/call', existsSync(project) ? { name: 'XcodeOpenWorkspace', arguments: { path: project } }
        : { name: 'XcodeNewProject', arguments: { templateIdentifier: 'com.apple.dt.unit.singleViewApplication', productName: 'KitePreview', destinationPath: folder } },
      24 * 3_600_000).catch(() => {}).finally(() => { this.approving = undefined; });
    }
    let ids: string[] = [];
    for (let attempt = 0; attempt < 10 && !ids.length; attempt++) {
      await Bun.sleep(300);
      const status = await systemCommand(['/usr/bin/xcrun', 'mcp-server', 'status', '--format', 'json'], { env: this.env, timeoutMs: 10_000 }).catch(() => undefined);
      const parsed = statusSchema.safeParse((() => { try { return JSON.parse(status?.stdout ?? ''); } catch { return undefined; } })());
      if (!parsed.success) continue;
      const { pendingAgentApprovals = [], pendingFolderApprovals = [] } = parsed.data.permission;
      ids = [...pendingAgentApprovals.filter((item) => item.subject.agent._0.name === AGENT_NAME).map((item) => item.id),
        ...pendingFolderApprovals.filter((item) => item.subject.folder._0.subtreeRoot === folder).map((item) => item.id)];
    }
    const commands = ids.map((id) => `sudo xcrun mcp-server approve --always ${id}`).join(' && ');
    return commands ? `Xcode 还没批准 Kite 操作模拟器：在工作机的终端里运行 ${commands}，再重新打开`
      : 'Xcode 还没批准 Kite 操作模拟器：在工作机的终端里运行 xcrun mcp-server status 查看挂起的批准请求，用 sudo xcrun mcp-server approve --always <编号> 批准 Kite 与它的 xcode 文件夹，再重新打开';
  }

  close(): void {
    void this.bridge?.then((bridge) => bridge.close()).catch(() => {});
    this.bridge = undefined;
  }
}

/** simctl 的路径：实时画面每一帧都要起它，只经 xcrun 找一次。 */
let simctlPath: Promise<string> | undefined;
function simctl(env: Record<string, string>): Promise<string> {
  simctlPath ??= systemCommand(['/usr/bin/xcrun', '-f', 'simctl'], { env, timeoutMs: 15_000 }).then(({ code, stdout }) => {
    if (code !== 0 || !stdout.trim()) throw new KiteError('找不到 simctl，需要 Xcode', 503);
    return stdout.trim();
  });
  simctlPath.catch(() => { simctlPath = undefined; });
  return simctlPath;
}

/** 动作换成 Xcode 设备操作的命令；坐标是模拟器屏幕的点。 */
function command(action: PreviewAction, size: { width: number; height: number }): string {
  const n = (value: number) => Math.round(value * 10) / 10;
  const clampX = (x: number) => n(Math.min(Math.max(x, 1), size.width - 1)), clampY = (y: number) => n(Math.min(Math.max(y, 1), size.height - 1));
  switch (action.type) {
    case 'click':
      if (action.button === 'right') throw new KiteError('模拟器没有右键，用长按', 400);
      return action.count === 2 ? `d ${n(action.x)} ${n(action.y)}` : Array.from({ length: action.count ?? 1 }, () => `t ${n(action.x)} ${n(action.y)}`).join(' ');
    case 'drag': return `t ${n(action.from.x)} ${n(action.from.y)} f ${n(action.to.x)} ${n(action.to.y)} 0.3`;
    // 滚动是手指往反方向划：往下看就是从这一点往上划
    case 'scroll': return `t ${n(action.x)} ${n(action.y)} f ${clampX(action.x - action.dx)} ${clampY(action.y - action.dy)} 0.3`;
    case 'long_press': return `t ${n(action.x)} ${n(action.y)} ${action.duration ?? 1}`;
    case 'type': return `sender keyboard kbd ${action.text.replace(/\n/g, '\\u{000A}').replace(/\t/g, '\\u{0009}')}`;
    case 'key': {
      const special: Record<string, string> = { enter: '\\u{000A}', tab: '\\u{0009}' };
      const typed = special[action.key.toLowerCase()];
      if (!typed) throw new KiteError('模拟器上只能按 Enter 和 Tab，没有组合键；文字用 type 输入，别的点界面上的按钮', 400);
      return `sender keyboard kbd ${typed}`;
    }
    case 'pinch': {
      // 两指在这一点两边，从相距 2a 移到相距 2b
      const from = 40, to = Math.min(Math.max(40 * action.scale, 8), Math.min(size.width, size.height) / 2 - 2);
      return `mt [${clampX(action.x - from)} ${n(action.y)}, ${clampX(action.x + from)} ${n(action.y)}] 0.4 [${clampX(action.x - to)} ${n(action.y)}, ${clampX(action.x + to)} ${n(action.y)}] 0.2`;
    }
    case 'home': return 'b h';
    case 'navigate': case 'back': case 'forward': case 'reload': throw new KiteError('模拟器预览没有这个动作', 400);
  }
}

/** 界面结构里的一个控件：种类、文字、无障碍标识与位置（屏幕上的点）。 */
type Control = { tag: string; text?: string; identifier?: string; x: number; y: number; width: number; height: number };

/**
 * 读 Xcode 给的界面结构：一行一个控件，缩进是层级，格式见 IDEDeviceInteraction 自带给模型的说明，如
 * `Button, {{110.0, 205.0}, {30.0, 20.0}}, identifier: 'login', label: 'Login', hitPoint: {125.0, 215.0}`；
 * 没有位置的行（App 的包名、Application 那一行）跳过。文字取 label，没有时依次取 title、value、placeholderValue。
 */
export function parseHierarchy(text: string): Control[] {
  return text.split('\n').flatMap((line) => {
    const frame = /\{\{(-?[\d.]+), (-?[\d.]+)\}, \{([\d.]+), ([\d.]+)\}\}/.exec(line);
    const head = /^\s*(\w+)/.exec(line);
    if (!frame || !head) return [];
    // 带引号的取到后面紧跟逗号或行尾的那个引号，文字里的逗号不算；不带引号的取到逗号
    const field = (key: string) => {
      const match = new RegExp(`\\b${key}: (?:'(.*?)'(?=,|$)|([^,]*))`).exec(line);
      return (match?.[1] ?? match?.[2])?.trim() || undefined;
    };
    const [x, y, width, height] = frame.slice(1).map(Number) as [number, number, number, number];
    const text = field('label') || /^\s*\w+ "(.*?)"/.exec(line)?.[1]?.trim() || field('title') || field('value') || field('placeholderValue');
    // 截到 200 个码元，切开的半个 emoji 去掉：单个的代理项 App 那边的 JSON 解不出来
    return [{ tag: head[1]!, x, y, width, height, identifier: field('identifier'),
      text: text?.slice(0, 200).replace(/[\ud800-\udbff]$/, '') }];
  });
}

/**
 * 画面上这一点最上层有内容的控件：界面结构按画的先后排（父在子前、后面的兄弟盖在前面的上面），盖住这一点的越靠后越在上面。
 * 没有文字、没有标识的容器跳过，按钮里的空容器取到按钮，盖在整屏上的空窗口取到下面的控件；都没有就取最上面的。
 * 按层级深浅挑不行：列表滚到标签栏底下时，被盖住的行里的字比标签栏的按钮深。
 */
export function controlAt(controls: Control[], x: number, y: number): Control | undefined {
  const covering = controls.filter((c) => c.width > 0 && c.height > 0 && x >= c.x && x < c.x + c.width && y >= c.y && y < c.y + c.height);
  return covering.findLast((c) => c.text || c.identifier || !['Other', 'Window', 'Application'].includes(c.tag)) ?? covering.at(-1);
}

/**
 * 一台模拟器的画面：Xcode 的一个设备操作会话。给模型的帧按点，是 Xcode 截的；给设备的帧是 simctl 截的全分辨率屏幕，逻辑尺寸同样按点。
 * 动作做完 Xcode 已经截好一帧，画面算稳定了（settle），紧接着要给模型的那一帧就用它。
 */
export class SimulatorScreen implements Screen {
  private session?: Promise<string>;
  private closed = false;
  /** 屏幕的逻辑尺寸（点），第一次截图时知道。 */
  private size?: { width: number; height: number };
  /** 刚做完的动作 Xcode 截的那一帧，紧接着给模型的那次截图用一次；隔久了不用，画面可能已经变了。 */
  private fresh?: { frame: Frame; at: number };
  /** 指认用的界面结构：指认期间画面停着，悬停时不必每次请 Xcode；做了动作、给设备截的画面变了就作废。 */
  private controls?: Promise<Control[]>;
  /** 上次给设备截的画面，看画面变没变。 */
  private shown?: Uint8Array;

  constructor(private udid: string, private tools: XcodeTools, private env: Record<string, string>) {}

  /** 开会话（没开机的由 Xcode 开机）并截第一帧，知道屏幕尺寸。 */
  async start(): Promise<void> {
    await this.run('');
  }

  private open(): Promise<string> {
    this.session ??= this.tools.call('DeviceInteractionStartSession', { deviceIdentifier: this.udid, sessionIdentifier: `Kite ${this.udid} ${randomUUID().slice(0, 8)}` })
      .then((result) => String(result.interactionSessionKey));
    this.session.catch(() => { this.session = undefined; });
    return this.session;
  }

  /** 做一条命令（空的只截图），Xcode 留下的截图和界面结构交给 read 读；会话被 Xcode 关掉了就重开一次。 */
  private async synthesize<T>(interaction: string, read: (files: z.infer<typeof synthesized>) => T | Promise<T>): Promise<T> {
    if (this.closed) throw new KiteError('模拟器的画面已经关了', 409);
    const call = async () => this.tools.call('DeviceInteractionSynthesize', { interactSessionKey: await this.open(), interactionCommand: interaction });
    const session = this.open();
    let result: Record<string, unknown>;
    try {
      result = await call();
    } catch (error) {
      if (!/Session not found|timed out/i.test((error as Error).message)) throw error;
      // 同时在做的几条一起发现会话没了时只重开一个
      if (this.session === session) this.session = undefined;
      result = await call();
    }
    try {
      return await read(synthesized.parse(result));
    } finally {
      // Xcode 的临时目录里每步留四个文件，读完删掉
      for (const path of Object.values(result)) if (typeof path === 'string' && path.includes('/ActionArtifacts/')) rmSync(path, { force: true });
    }
  }

  /** 做一条命令，返回 Xcode 截的一帧。 */
  private run(interaction: string): Promise<Frame> {
    return this.synthesize(interaction, async (files) => {
      const image = new Bun.Image(readFileSync(files.screenshotPath));
      const metadata = await image.metadata();
      this.size = { width: metadata.width, height: metadata.height };
      return { data: await image.jpeg({ quality: 70 }).bytes(), ...this.size };
    });
  }

  /** 当前的界面结构；Xcode 同时截的图不用，不转码。 */
  private hierarchy(): Promise<string> {
    return this.synthesize('', (files) => files.hierarchyPath ? readFileSync(files.hierarchyPath, 'utf8') : '');
  }

  async capture(forModel = false): Promise<Frame> {
    if (forModel) {
      const fresh = this.fresh;
      this.fresh = undefined;
      return fresh && Date.now() - fresh.at < FRESH_MS ? fresh.frame : await this.run('');
    }
    if (!this.size) await this.run('');
    const file = join(tmpdir(), `kite-simulator-${randomUUID()}.jpg`);
    try {
      const shot = await systemCommand([await simctl(this.env), 'io', this.udid, 'screenshot', '--type=jpeg', file], { env: this.env, timeoutMs: 15_000 });
      if (shot.code !== 0) throw new KiteError('没有截到模拟器的屏幕', 503);
      const data = readFileSync(file);
      // 画面变了界面结构才作废：别的设备实时看着时每截一帧都作废的话，指认几乎每次悬停都要请 Xcode
      if (!this.shown || !sameFrame(data, this.shown)) {
        this.controls = undefined;
        this.shown = data;
      }
      return { data, ...this.size! };
    } finally { rmSync(file, { force: true }); }
  }

  async act(action: PreviewAction): Promise<void> {
    if (!this.size) await this.run('');
    const frame = await this.run(command(action, this.size!));
    // 做完再作废：动作当中悬停取的是动作之前的界面结构
    this.controls = undefined;
    this.fresh = { frame, at: Date.now() };
  }

  async settle(options: { forModel?: boolean }) {
    return { frame: await this.capture(options.forModel), settled: true };
  }

  async inspect(): Promise<string> {
    const hierarchy = await this.hierarchy();
    // 顺带给指认用，紧接着指认时不用再请一次 Xcode；空的不留，指认时自己再要
    const controls = parseHierarchy(hierarchy);
    if (controls.length) this.controls = Promise.resolve(controls);
    return hierarchy.length > HIERARCHY_CHARS ? `${hierarchy.slice(0, HIERARCHY_CHARS)}\n…（界面结构太长，后面截掉了）` : hierarchy;
  }

  async point(x: number, y: number): Promise<PointedElement | null> {
    if (!this.controls) {
      const controls = this.controls = this.hierarchy().then(parseHierarchy, () => []);
      // Xcode 偶尔不给界面结构（说明里说是无障碍的临时问题）：出错、为空的过一会儿再要，不在指针每动一下时都请一次 Xcode
      void controls.then((list) => {
        if (!list.length) setTimeout(() => { if (this.controls === controls) this.controls = undefined; }, CONTROLS_RETRY_MS).unref();
      });
    }
    return controlAt(await this.controls, x, y) ?? null;
  }

  async info() { return {}; }

  alive(): boolean { return !this.closed; }

  async close(): Promise<void> {
    if (this.closed) return;
    this.closed = true;
    const session = await this.session?.catch(() => undefined);
    if (session) await this.tools.call('DeviceInteractionEndSession', { interactionSessionKey: session }).catch(() => {});
  }
}
