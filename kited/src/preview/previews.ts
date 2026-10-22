/**
 * 预览插件 kite.preview（docs/实例操作.md「预览」）：一个实例是一个要看的对象，网页（本工作区的一个端口）或模拟器（宿主为工作区开的那台）。
 * 实例随窗口回收；agent 用 preview_open 开的没有窗口，由它关闭，或随它归档、工作区关闭回收。
 * 网页在设备自己的网页视图里看时（device，默认）工作机不参与，设备经端口转发打开；agent 操作这样的预览时，宿主在工作机的 WebKit 里另开同一个地址，
 * 与设备上的页面不共享状态。在工作机上的浏览器里看时，人和 agent 操作同一个页面。模拟器的画面人和 agent 看的是同一块屏幕。
 * 工作机上的画面（浏览器页面或模拟器）有人看或 agent 要用时才开，闲置一阵关掉，再要时重开。
 * WebSocket 协议：接入地址带 width、height（设备窗口放得下的逻辑尺寸，网页视口跟着最近操作的那台）、mode（live 或 step）；
 * 服务端发 {type:'state', phase, ...}（phase 为 waiting 没选端口、starting、ready、failed）；{type:'frame', width, height, settled?, point?}
 * 之后紧跟一条二进制消息是这一帧的 JPEG；{type:'waiting'} 是开始等画面稳定，{type:'dropped'} 是等的期间收到的输入丢弃了。
 * 客户端发 {type:'resize', width, height}、{type:'mode', mode}、{type:'frame'}（要一帧当前画面）、{type:'action', action, wait}：
 * wait 为真（逐帧）时做完等画面稳定再给一帧，等的期间别人的逐帧输入丢弃、不排队；实时模式下画面变了就发，不等。
 */
import { randomUUID } from 'node:crypto';
import type { ServerWebSocket } from 'bun';
import { z } from 'zod';
import { KiteError } from '../errors.ts';
import { numberedTitle, type PluginInstance } from '../model.ts';
import type { Store } from '../store.ts';
import { modelImage } from '../workspace/documents.ts';
import { Browsers } from './browsers.ts';
import { actionSchema, sameFrame, settle, SETTLE, type Frame, type PreviewAction, type Screen, type ScreenInfo, type SettleTiming } from './screen.ts';
import { previewConfig, previewDefinitionId, previewState, type PreviewBrowser, type PreviewKind, type PreviewSpec, type PreviewState, type WorkstationBrowser } from './state.ts';

export interface PreviewSocket {
  kind: 'preview';
  instanceId: string;
  size?: { width: number; height: number };
  live: boolean;
}
type Socket = ServerWebSocket<PreviewSocket>;

/** 宿主为工作区开的模拟器：acquire 得到它的屏幕，屏幕的 close 是这个预览不用了，模拟器本身归工作区。 */
export interface SimulatorScreens {
  acquire(workspaceId: string): Promise<Screen>;
}

export interface PreviewsHost {
  store: Store;
  /** 起浏览器用的环境，显式给出。 */
  env: Record<string, string>;
  run<T>(workspaceId: string, action: () => Promise<T>): Promise<T>;
  changed(workspaceId: string): void;
  /** 回收实例；调用时已在控制队列里，且确认没有窗口。 */
  collect(instance: PluginInstance): void;
  /** 本工作区运行中终端此刻监听的端口。 */
  ports(workspaceId: string): number[];
  simulators: SimulatorScreens;
  /** 测试里缩短等画面稳定的节奏，默认见 screen.ts 的 SETTLE。 */
  settle?: SettleTiming;
}

const sizeSchema = z.object({ width: z.number().int().min(200).max(4096), height: z.number().int().min(200).max(4096) }).strict();
const messageSchema = z.discriminatedUnion('type', [
  sizeSchema.extend({ type: z.literal('resize') }).strict(),
  z.object({ type: z.literal('mode'), mode: z.enum(['live', 'step']) }).strict(),
  z.object({ type: z.literal('frame') }).strict(),
  z.object({ type: z.literal('action'), action: actionSchema, wait: z.boolean().optional() }).strict(),
]);
/** 接入地址里的 width、height、mode；尺寸缺一个或不合法就当没给，mode 默认逐帧。 */
export function previewParams(params: URLSearchParams): Pick<PreviewSocket, 'size' | 'live'> {
  const size = sizeSchema.safeParse({ width: Number(params.get('width')), height: Number(params.get('height')) });
  return { ...(size.success ? { size: size.data } : {}), live: params.get('mode') === 'live' };
}

type Size = { width: number; height: number };
type FrameExtra = { settled?: boolean; point?: { x: number; y: number } };
/** 网页视口的默认尺寸：只有 agent 在用、还没有设备接入时。 */
const DEFAULT_SIZE: Size = { width: 1280, height: 800 };
/**
 * 给模型的截图收在 Claude 不再自己缩小的范围里（长边 1568、约 115 万像素），比 modelImage 的通用上限紧：
 * 厂商再缩一次的话，模型照它看到的图给的坐标就和返回的 width、height 对不上了。
 */
const MODEL_IMAGE = { edge: 1568, pixels: 1_150_000 };
/** 实时画面多久截一次、变了才发。 */
const LIVE_MS = 120;
/** 设备读得慢、积压超过这么多时跳过实时帧，等它读完。 */
const LIVE_BACKLOG = 512 * 1024;
/** 没人看、agent 也没在用这么久，关掉工作机上的画面。 */
const IDLE_MS = 10 * 60_000;

class Session {
  screen?: Screen;
  opening?: Promise<Screen>;
  /** 画面是哪种：工作机上的浏览器，或模拟器。换了就重开。 */
  target?: WorkstationBrowser | 'simulator';
  error?: string;
  readonly viewers = new Set<Socket>();
  /** 决定网页视口尺寸的设备：最近一次操作的那台，没人操作过时是第一台接入的。 */
  owner?: Socket;
  /** 网页视口此刻的尺寸；模拟器没有。 */
  viewport?: Size;
  /** 最近给模型截图时的视口：之后视口变了，模型照那张截图给的坐标就不准了。 */
  modelViewport?: Size;
  /** agent 开预览时要先打开的路径，开画面时用一次。 */
  startPath?: string;
  /** 动作一个接一个做。 */
  queue: Promise<unknown> = Promise.resolve();
  /** 正在等画面稳定：这期间逐帧的输入丢弃。 */
  settling = false;
  /** 最近发给所有在看的设备的一帧，实时画面据此判断变没变。 */
  last?: Frame;
  info: ScreenInfo = {};
  usedAt = Date.now();
  live?: ReturnType<typeof setInterval>;
  capturing = false;
  /** 最近给模型的截图比画面的逻辑尺寸缩小了多少：模型照截图给的坐标乘上它换回来。 */
  modelScale = 1;
}

const sameSize = (a?: Size, b?: Size) => a?.width === b?.width && a?.height === b?.height;
const pointed = (action: PreviewAction) => 'x' in action || action.type === 'drag';

/** 模型照缩小过的截图给的坐标换回画面的逻辑尺寸；滚动的距离本来就按逻辑尺寸算，不换。 */
function toScreen(action: PreviewAction, scale: number): PreviewAction {
  if (scale === 1) return action;
  const at = (point: { x: number; y: number }) => ({ x: point.x * scale, y: point.y * scale });
  switch (action.type) {
    case 'click': case 'long_press': case 'pinch': case 'scroll': return { ...action, ...at(action) };
    case 'drag': return { ...action, from: at(action.from), to: at(action.to) };
    default: return action;
  }
}

export class Previews {
  private sessions = new Map<string, Session>();
  private browsers: Browsers;
  private closed = false;
  private idleTimer: ReturnType<typeof setInterval>;
  private timing: SettleTiming;

  constructor(private host: PreviewsHost) {
    this.browsers = new Browsers(host.env);
    this.timing = host.settle ?? SETTLE;
    this.idleTimer = setInterval(() => this.closeIdle(), 60_000);
    this.idleTimer.unref();
  }

  /** 新实例的标题：网页 N、模拟器 N。 */
  title(workspaceId: string, kind: PreviewKind): string {
    return numberedTitle(kind === 'web' ? '网页' : '模拟器', this.host.store.instances(workspaceId).map((instance) => instance.title));
  }

  /** 新建预览的配置与状态；网页带的端口须是本工作区运行中终端监听的。 */
  initial(workspaceId: string, spec: PreviewSpec): Pick<PluginInstance, 'config' | 'state'> {
    if (spec.kind === 'simulator') return { config: { preview: { kind: 'simulator' } }, state: {} };
    if (spec.port !== undefined) this.checkPort(workspaceId, spec.port);
    const state: PreviewState = { ...(spec.port !== undefined ? { port: spec.port } : {}), ...(spec.browser && spec.browser !== 'device' ? { browser: spec.browser } : {}) };
    return { config: { preview: { kind: 'web' } }, state: { preview: state } };
  }

  private checkPort(workspaceId: string, port: number): void {
    if (!this.host.ports(workspaceId).includes(port)) throw new KiteError(`localhost:${port} 不是这个工作区里运行中的终端在监听的端口`, 409);
  }

  /** 改网页看的端口或在哪看，各设备共用；端口须正在被本工作区的终端监听，null 是不选。工作机上已开着页面的，换端口在原页面里打开，换浏览器重开。 */
  async select(id: string, change: { port?: number | null; browser?: PreviewBrowser }): Promise<PreviewState> {
    const instance = this.instance(id);
    if (previewConfig(instance).kind !== 'web') throw new KiteError('只有网页预览能选端口和浏览器', 400);
    if (typeof change.port === 'number') this.checkPort(instance.workspaceId, change.port);
    const current = previewState(instance);
    const port = change.port === undefined ? current.port : change.port ?? undefined;
    const browser = change.browser === undefined ? current.browser : change.browser === 'device' ? undefined : change.browser;
    const next: PreviewState = { ...(port !== undefined ? { port } : {}), ...(browser ? { browser } : {}) };
    this.host.store.setInstanceState(id, { ...instance.state, preview: next });
    this.host.changed(instance.workspaceId);
    const session = this.sessions.get(id);
    if (session) {
      // 换了在哪看（含换回设备自己的网页视图）就关掉工作机上的页面；还在开的不等它，开好时发现换了自己关掉（见 ensure）
      if (browser !== current.browser || port === undefined || (port !== current.port && !session.screen)) await this.shut(session, false);
      else if (port !== current.port) await session.screen?.retarget?.(port);
      if (session.viewers.size && browser) void this.ensure(id).catch(() => {});
      this.broadcastState(id, session);
    }
    return next;
  }

  /** 画面用哪个：模拟器，或网页选的浏览器；在设备上看的网页，agent 操作时用 WebKit，与设备上的内核一致。 */
  private target(state: PreviewState, kind: PreviewKind = 'web'): WorkstationBrowser | 'simulator' {
    return kind === 'simulator' ? 'simulator' : state.browser ?? 'webkit';
  }

  private instance(id: string): PluginInstance {
    const instance = this.host.store.instance(id);
    if (!instance || instance.definitionId !== previewDefinitionId) throw new KiteError('没有这个预览', 404);
    return instance;
  }

  private session(id: string): Session {
    let session = this.sessions.get(id);
    if (!session) { session = new Session(); this.sessions.set(id, session); }
    return session;
  }

  /** 工作机上的画面，没开就开；几个调用同时要时只开一次。 */
  private ensure(id: string): Promise<Screen> {
    if (this.closed) return Promise.reject(new KiteError('kited 正在关闭', 503));
    const session = this.session(id);
    session.usedAt = Date.now();
    // 浏览器崩了、模拟器关了：丢掉重开
    if (session.screen && !session.screen.alive()) { void session.screen.close().catch(() => {}); session.screen = session.target = session.last = session.viewport = undefined; }
    if (session.screen) return Promise.resolve(session.screen);
    if (session.opening) return session.opening;
    const instance = this.instance(id);
    const { kind } = previewConfig(instance);
    const state = previewState(instance);
    const target = this.target(state, kind);
    const size = target === 'simulator' ? undefined : session.owner?.data.size ?? DEFAULT_SIZE;
    const path = session.startPath;
    session.startPath = undefined;
    const opening = (async () => {
      if (this.host.store.workspace(instance.workspaceId)?.status !== 'open') throw new KiteError('工作区尚未打开', 409);
      if (!size) return this.host.simulators.acquire(instance.workspaceId);
      if (state.port === undefined) throw new KiteError('网页预览还没选端口', 409);
      return this.browsers.open(target as WorkstationBrowser, { url: `http://localhost:${state.port}/`, path, ...size });
    })();
    session.opening = opening;
    session.target = target;
    session.error = undefined;
    this.broadcastState(id, session);
    opening.then(async (screen) => {
      if (this.sessions.get(id) !== session || session.opening !== opening) { await screen.close(); return; }
      session.screen = screen;
      session.opening = undefined;
      session.viewport = size;
      session.info = await screen.info().catch(() => ({}));
      this.broadcastState(id, session);
      this.watchLive(id, session);
      if (!session.viewers.size) return;
      const frame = await screen.capture().catch(() => undefined);
      if (frame) this.broadcastFrame(session, frame);
    }, (error: unknown) => {
      if (session.opening !== opening) return;
      session.opening = undefined;
      session.target = undefined;
      session.error = (error as Error).message;
      this.broadcastState(id, session);
    });
    return opening;
  }

  /**
   * 关掉工作机上的画面，会话留着（设备还接着）。还在开的默认等开好再关，工作区关闭、kited 退出后不留下开着的画面；
   * waitOpening 为假时不等，开好时发现已经换了，由 ensure 关掉。
   */
  private async shut(session: Session, waitOpening = true): Promise<void> {
    clearInterval(session.live);
    session.live = undefined;
    const screen = session.screen ?? (waitOpening ? await session.opening?.catch(() => undefined) : undefined);
    session.screen = session.opening = session.target = session.last = session.viewport = undefined;
    session.info = {};
    await screen?.close().catch(() => {});
  }

  /** 动作一个接一个做。 */
  private queued<T>(session: Session, run: () => Promise<T>): Promise<T> {
    const task = session.queue.then(run, run);
    session.queue = task.catch(() => {});
    return task;
  }

  /** 这台设备成为视口尺寸的归属者：网页视口换成它的窗口尺寸，换了就给在看的设备都发一帧，返回换没换。 */
  private async own(session: Session, socket: Socket): Promise<boolean> {
    session.owner = socket;
    const size = socket.data.size, screen = session.screen;
    if (!size || !screen?.resize || sameSize(session.viewport, size)) return false;
    await screen.resize(size.width, size.height);
    session.viewport = size;
    this.broadcastFrame(session, await screen.capture());
    return true;
  }

  /**
   * 做一个动作；wait 时等画面稳定，把这一帧发给所有在看的设备，标出点在哪。返回稳定后的一帧与是否等到了稳定。
   * 失败了告诉所有在看的设备：它们都收到了开始等的 waiting，不说就一直停在等待。
   */
  private perform(id: string, action: PreviewAction, wait: boolean, signal?: AbortSignal) {
    const session = this.session(id);
    return this.queued(session, async () => {
      try {
        const screen = await this.ensure(id);
        session.usedAt = Date.now();
        if (wait) {
          session.settling = true;
          this.broadcast(session, { type: 'waiting' });
        }
        await screen.act(action);
        if (!wait) return undefined;
        // 没有设备在看（agent 自己开的预览）时按给模型的尺寸截着等
        const result = await settle(screen, this.timing, { signal, afterAction: true, forModel: !session.viewers.size });
        session.info = await screen.info().catch(() => session.info);
        this.broadcastState(id, session);
        const point = 'x' in action ? { x: action.x, y: action.y } : action.type === 'drag' ? action.to : undefined;
        this.broadcastFrame(session, result.frame, { settled: result.settled, ...(point ? { point } : {}) });
        return result;
      } catch (error) {
        this.broadcast(session, { type: 'error', message: (error as Error).message });
        throw error;
      } finally { session.settling = false; }
    });
  }

  // ---- agent 的操作 ----

  /** agent 开一个没有窗口的预览，开好画面、等稳定后返回第一帧。 */
  async open(workspaceId: string, spec: { kind: PreviewKind; port?: number; path?: string; browser?: WorkstationBrowser },
    origin: NonNullable<PluginInstance['origin']>, signal?: AbortSignal) {
    if (spec.kind === 'web' && spec.port === undefined) throw new KiteError('网页预览要写 port', 400);
    if (spec.kind === 'simulator' && (spec.port ?? spec.path ?? spec.browser) !== undefined) throw new KiteError('模拟器预览不带 port、path 和 browser', 400);
    const instance = await this.host.run(workspaceId, async () => {
      if (this.host.store.workspace(workspaceId)?.status !== 'open') throw new KiteError('工作区尚未打开', 409);
      const instance: PluginInstance = { id: randomUUID(), workspaceId, definitionId: previewDefinitionId, title: this.title(workspaceId, spec.kind),
        ...this.initial(workspaceId, spec.kind === 'web' ? { kind: 'web', port: spec.port, browser: spec.browser ?? 'webkit' } : { kind: 'simulator' }),
        presentation: 'background', status: 'open', createdAt: Date.now(), origin };
      this.host.store.addPluginInstance(instance);
      this.host.changed(workspaceId);
      return instance;
    });
    try {
      // 页面直接开到这个路径，不先开首页
      if (spec.path) this.session(instance.id).startPath = spec.path;
      return await this.observe(instance.id, signal);
    } catch (error) {
      await this.closePreview(instance.id).catch(() => {});
      throw error;
    }
  }

  /** agent 做一个动作，等画面稳定后返回新的一帧；screenshot 只截一帧，wait 等一段时间再截。坐标照最近一次给它的截图。 */
  async act(id: string, action: PreviewAction | { type: 'screenshot' } | { type: 'wait'; seconds: number }, signal?: AbortSignal) {
    if (action.type === 'wait') await Bun.sleep(action.seconds * 1000);
    const session = this.session(id);
    if (action.type !== 'screenshot' && action.type !== 'wait' && pointed(action) && session.modelViewport && !sameSize(session.modelViewport, session.viewport)) {
      throw new KiteError('预览的画面尺寸变了（有人在设备上打开或操作了它），先用 screenshot 看一眼，照新截图给坐标', 409);
    }
    const done = action.type === 'screenshot' || action.type === 'wait' ? undefined
      : await this.perform(id, toScreen(action, session.modelScale), true, signal);
    return this.observe(id, signal, done?.settled);
  }

  /**
   * 当前画面给模型：等稳定（动作刚等过的不再等），按逻辑尺寸截一帧，带上地址与标题。超过给模型的图片上限（见 documents.ts 的 modelImage）时缩小，
   * 返回的 width、height 是截图的尺寸，模型照它给坐标，act 里换回逻辑尺寸。
   */
  private async observe(id: string, signal?: AbortSignal, settledAlready?: boolean) {
    const screen = await this.ensure(id);
    const session = this.session(id);
    const settling = settledAlready === undefined ? await settle(screen, this.timing, { signal, forModel: true }) : undefined;
    const frame = settling?.frame ?? await screen.capture(true);
    const image = await modelImage(frame.data, undefined, MODEL_IMAGE);
    session.modelScale = frame.width / image.width;
    session.modelViewport = session.viewport;
    session.info = await screen.info().catch(() => session.info);
    return { ...this.describe(this.instance(id)), ...session.info, width: image.width, height: image.height, settled: settling?.settled ?? settledAlready!,
      images: [image.image] };
  }

  async inspect(id: string): Promise<{ text: string }> {
    const screen = await this.ensure(id);
    return { text: await screen.inspect() };
  }

  /** list 里的一项。 */
  describe(instance: PluginInstance) {
    const { kind } = previewConfig(instance);
    const state = previewState(instance);
    return { instanceId: instance.id, title: instance.title, kind, ...(kind === 'web' ? { port: state.port ?? null, browser: state.browser ?? 'device' } : {}) };
  }

  // ---- 生命周期 ----

  /** 实例回收时关掉它的画面、断开在看的设备。 */
  forget(id: string): void {
    const session = this.sessions.get(id);
    if (!session) return;
    this.sessions.delete(id);
    for (const socket of session.viewers) socket.close(1000, '预览已关闭');
    void this.shut(session);
  }

  /** 代理归档时回收它开的、没有窗口的预览；有窗口的留给在看的人。 */
  async closeOwned(agentId: string): Promise<void> {
    const owned = this.host.store.instances(this.host.store.instance(agentId)?.workspaceId ?? '')
      .filter((instance) => instance.definitionId === previewDefinitionId && instance.origin?.instanceId === agentId);
    for (const instance of owned) if (!this.windowed(instance)) this.collectNow(instance);
  }

  /** 工作区交接、冻结或归档前关掉它的画面；没有窗口的预览回收。调用时已在控制队列里。 */
  async closeWorkspace(workspaceId: string): Promise<void> {
    for (const instance of this.host.store.instances(workspaceId)) {
      if (instance.definitionId !== previewDefinitionId) continue;
      if (!this.windowed(instance)) { this.collectNow(instance); continue; }
      const session = this.sessions.get(instance.id);
      if (session) await this.shut(session);
    }
  }

  /** 启动时回收上次 agent 开的、没有窗口的预览：画面随 kited 结束了。调用时控制队列里还没有别的工作。 */
  recover(): void {
    for (const workspace of this.host.store.workspaces()) {
      for (const instance of this.host.store.instances(workspace.id)) {
        if (instance.definitionId === previewDefinitionId && !this.windowed(instance)) this.host.collect(instance);
      }
    }
  }

  async close(): Promise<void> {
    this.closed = true;
    clearInterval(this.idleTimer);
    await Promise.all([...this.sessions.values()].map((session) => this.shut(session)));
    await this.browsers.close();
  }

  private windowed(instance: PluginInstance): boolean {
    return this.host.store.windows(instance.workspaceId).some((window) => window.target.instanceId === instance.id);
  }

  private collectNow(instance: PluginInstance): void {
    this.host.collect(instance);
    this.host.changed(instance.workspaceId);
  }

  private closeIdle(): void {
    for (const session of this.sessions.values()) {
      if ((session.screen || session.opening) && !session.viewers.size && Date.now() - session.usedAt > IDLE_MS) void this.shut(session);
    }
  }

  // ---- 设备接入 ----

  /** WebSocket 升级前核对：实例存在、是预览、所在工作区打开着。 */
  check(id: string): void {
    const instance = this.instance(id);
    if (this.host.store.workspace(instance.workspaceId)?.status !== 'open') throw new KiteError('工作区尚未打开', 409);
  }

  attach(socket: Socket): void {
    const id = socket.data.instanceId;
    const session = this.session(id);
    session.viewers.add(socket);
    // 只是打开来看不抢视口：已有归属者（或 agent 正照着截图操作）时尺寸不变，这台操作了才换成它的
    if (socket.data.size && !session.owner) session.owner = socket;
    const instance = this.host.store.instance(id);
    const state = instance && previewState(instance);
    // 在设备上看的网页不经工作机，没选端口的等选好
    if (!instance || (previewConfig(instance).kind === 'web' && (state?.browser === undefined || state.port === undefined))) {
      this.sendState(socket, id, session);
      return;
    }
    const screen = session.screen;
    if (screen) {
      this.sendState(socket, id, session);
      void (async () => {
        const resized = session.owner === socket && await this.queued(session, () => this.own(session, socket));
        this.watchLive(id, session);
        if (!resized) await this.sendFrame(socket, session);
      })().catch(() => {});
      return;
    }
    // 新开的由 ensure 把状态和开好后的第一帧发给所有在看的设备；已经在开的只补发一次状态
    if (session.opening) this.sendState(socket, id, session);
    void this.ensure(id).catch(() => {});
  }

  receive(socket: Socket, message: string | Buffer): void {
    const id = socket.data.instanceId;
    const session = this.sessions.get(id);
    if (!session) return;
    const parsed = typeof message === 'string' ? messageSchema.safeParse((() => { try { return JSON.parse(message); } catch { return undefined; } })()) : undefined;
    if (!parsed?.success) { socket.close(1003, '预览控制消息无效'); return; }
    const data = parsed.data;
    switch (data.type) {
      case 'resize':
        socket.data.size = { width: data.width, height: data.height };
        if (!session.owner || session.owner === socket) void this.queued(session, () => this.own(session, socket)).catch(() => {});
        return;
      case 'mode':
        socket.data.live = data.mode === 'live';
        this.watchLive(id, session);
        if (!socket.data.live) void this.sendFrame(socket, session);
        return;
      case 'frame':
        void this.sendFrame(socket, session);
        return;
      case 'action': {
        if (data.wait && session.settling) { socket.send(JSON.stringify({ type: 'dropped' })); return; }
        // 失败已由 perform 告诉所有在看的设备
        this.perform(id, data.action, data.wait ?? false).catch(() => {});
        // 操作的设备成为视口尺寸的归属者：坐标是照它看到的画面给的，先做完这个动作，再换成它的窗口尺寸
        if (session.owner !== socket) void this.queued(session, () => this.own(session, socket)).catch(() => {});
        return;
      }
    }
  }

  detach(socket: Socket): void {
    const session = this.sessions.get(socket.data.instanceId);
    if (!session) return;
    session.viewers.delete(socket);
    if (session.owner === socket) session.owner = [...session.viewers].at(-1);
    session.usedAt = Date.now();
    this.watchLive(socket.data.instanceId, session);
  }

  /** 有设备在看实时画面时定时截，变了才发给它们；没有了停下。 */
  private watchLive(id: string, session: Session): void {
    const wanted = !!session.screen && [...session.viewers].some((socket) => socket.data.live);
    if (!wanted) { clearInterval(session.live); session.live = undefined; return; }
    if (session.live) return;
    let ticks = 0;
    session.live = setInterval(() => {
      const screen = session.screen;
      if (!screen || session.capturing) return;
      session.capturing = true;
      void (async () => {
        try {
          const frame = await screen.capture();
          // 地址和标题约一秒查一次
          if (++ticks % 8 === 0) {
            const info = await screen.info().catch(() => session.info);
            if (info.url !== session.info.url || info.pageTitle !== session.info.pageTitle) { session.info = info; this.broadcastState(id, session); }
          }
          if (session.last && sameFrame(frame.data, session.last.data)) return;
          session.last = frame;
          for (const socket of session.viewers) {
            if (socket.data.live && socket.getBufferedAmount() < LIVE_BACKLOG) this.deliver(socket, frame);
          }
        } catch {} finally { session.capturing = false; }
      })();
    }, LIVE_MS);
    session.live.unref();
  }

  /** 截当前画面只发给这台设备；不算发给了大家，实时画面照常比较（见 broadcastFrame）。 */
  private async sendFrame(socket: Socket, session: Session): Promise<void> {
    if (!session.screen) return;
    try { this.deliver(socket, await session.screen.capture()); } catch {}
  }

  /** 发一帧给所有在看的设备，记下来，实时画面据此判断变没变。 */
  private broadcastFrame(session: Session, frame: Frame, extra: FrameExtra = {}): void {
    if (!session.viewers.size) return;
    session.last = frame;
    for (const socket of session.viewers) this.deliver(socket, frame, extra);
  }

  /** 发一帧：先发说明，紧跟着发 JPEG。 */
  private deliver(socket: Socket, frame: Frame, extra: FrameExtra = {}): void {
    if (socket.readyState !== 1) return;
    socket.send(JSON.stringify({ type: 'frame', width: frame.width, height: frame.height, ...extra }));
    socket.send(frame.data);
  }

  private stateMessage(id: string, session: Session) {
    const instance = this.host.store.instance(id);
    const kind = instance ? previewConfig(instance).kind : 'web';
    const state = instance ? previewState(instance) : {};
    const phase = session.screen ? 'ready' : session.opening ? 'starting' : session.error ? 'failed'
      : kind === 'web' && state.port === undefined ? 'waiting' : 'starting';
    return { type: 'state', phase, ...(session.error ? { error: session.error } : {}), ...session.info };
  }

  private sendState(socket: Socket, id: string, session: Session): void {
    if (socket.readyState === 1) socket.send(JSON.stringify(this.stateMessage(id, session)));
  }

  private broadcastState(id: string, session: Session): void {
    if (session.viewers.size) this.broadcast(session, this.stateMessage(id, session));
  }

  private broadcast(session: Session, message: object): void {
    const text = JSON.stringify(message);
    for (const socket of session.viewers) if (socket.readyState === 1) socket.send(text);
  }

  /** 关闭预览：回收实例连同它的窗口，画面随之关掉（见 forget）。 */
  async closePreview(id: string): Promise<void> {
    const instance = this.instance(id);
    await this.host.run(instance.workspaceId, async () => {
      const current = this.host.store.instance(id);
      if (!current) return;
      for (const window of this.host.store.windows(instance.workspaceId)) if (window.target.instanceId === id) this.host.store.closeWindow(window.id);
      this.host.collect(current);
      this.host.changed(instance.workspaceId);
    });
  }
}
