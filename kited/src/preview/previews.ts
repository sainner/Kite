/**
 * 预览插件 kite.preview（docs/实例操作.md「预览」）：一个实例是一种目标（.kite/preview/ 下的脚本，见 targets.ts）跑起来的全部进程加画面。
 * 进程由终端插件托管（terminal/terminals.ts），实例随进程存续：进程自己结束后标为已结束、留到用户关闭，用户或 agent 停下即关闭、随之回收。同一工作区的同一目标与设备只跑一份。
 * 画面的种类由进程产生什么决定（state.preview.screen）：进程树里开着窗口的 Mac App、目标用的模拟器、能用 HTTP 打开的端口，都没有就只有输出。
 * 网页在设备自己的网页视图里看时（browser 为 device，默认）工作机不参与，设备经端口转发打开；agent 操作这样的预览时，宿主在工作机的 WebKit 里另开同一个地址，
 * 与设备上的页面不共享状态。在工作机上的浏览器里看时，人和 agent 操作同一个页面。模拟器和 App 窗口人和 agent 看的是同一块屏幕。
 * 并排视图的每一格是工作机上的一个页面，按 {浏览器, 视口尺寸} 区分；agent 的 preview_action 带同样的浏览器与尺寸时操作的就是那一格。
 * 工作机上的画面（浏览器页面、模拟器或 App 窗口）有人看或 agent 要用时才开，闲置一阵关掉，再要时重开。
 * WebSocket 协议：接入地址带 width、height（设备窗口放得下的逻辑尺寸，画面视图的网页视口跟着最近操作的那台）、mode（live 或 step），
 * 并排的一格另带 browser、viewportWidth、viewportHeight；
 * 服务端发 {type:'state', phase, screen, ...}（phase 为 waiting 进程还没产生画面、starting、ready、failed）；{type:'frame', width, height, settled?, point?}
 * 之后紧跟一条二进制消息是这一帧的 JPEG；{type:'waiting'} 是开始等画面稳定，{type:'dropped'} 是等的期间收到的输入丢弃了。
 * 客户端发 {type:'resize', width, height}、{type:'mode', mode}、{type:'frame'}（要一帧当前画面）、{type:'action', action, wait}：
 * wait 为真（逐帧）时做完等画面稳定再给一帧，等的期间别人的逐帧输入丢弃、不排队；实时模式下画面变了就发，不等。
 * 指认时客户端发 {type:'point', x, y}，只回它 {type:'element', x, y, element}，element 是指认的结果（见 screen.ts 的 PointedElement），没有时为 null。
 */
import { randomUUID } from 'node:crypto';
import type { ServerWebSocket } from 'bun';
import { z } from 'zod';
import { KiteError } from '../errors.ts';
import type { PluginInstance } from '../model.ts';
import type { Store } from '../store.ts';
import type { Terminals } from '../terminal/terminals.ts';
import { modelImage } from '../workspace/documents.ts';
import { bundleResponse } from './app-bundles.ts';
import { Browsers } from './browsers.ts';
import { checkDevice, pairedDevices, type DeviceCandidate, type PreviewDevice } from './devices.ts';
import { openWindowScreen } from './helper-screen.ts';
import { actionSchema, sameFrame, settleScreen, SETTLE, type Frame, type PreviewAction, type Screen, type ScreenInfo, type SettleTiming } from './screen.ts';
import type { Simulators } from './simulators.ts';
import { previewConfig, previewDefinitionId, previewState, viewportEdge, workstationBrowsers, type PreviewBrowser, type PreviewScreen, type PreviewSpec, type PreviewState,
  type WorkstationBrowser } from './state.ts';
import { allocateTargetPorts, findTarget, listTargets, portKey, type Target } from './targets.ts';

type Size = { width: number; height: number };
/** 并排视图的一格：工作机上的哪个浏览器、视口多大。 */
export type Cell = { browser: WorkstationBrowser } & Size;

export interface PreviewSocket {
  kind: 'preview';
  instanceId: string;
  size?: Size;
  live: boolean;
  /** 并排视图的一格；没有时是画面视图。 */
  cell?: Cell;
}
type Socket = ServerWebSocket<PreviewSocket>;

export interface PreviewsHost {
  store: Store;
  /** 起浏览器、xcrun 用的环境，显式给出。 */
  env: Record<string, string>;
  run<T>(workspaceId: string, action: () => Promise<T>): Promise<T>;
  changed(workspaceId: string): void;
  terminals: Pick<Terminals, 'start' | 'stop' | 'running' | 'ports' | 'apps' | 'waitUntil' | 'tail' | 'processState'>;
  simulators: Pick<Simulators, 'acquire' | 'ensure' | 'defaultModel' | 'candidates' | 'launchedApps' | 'hold' | 'release'>;
  /** 测试里缩短等画面稳定的节奏，默认见 screen.ts 的 SETTLE。 */
  settle?: SettleTiming;
}

const sizeSchema = z.object({ width: viewportEdge, height: viewportEdge }).strict();
const messageSchema = z.discriminatedUnion('type', [
  sizeSchema.extend({ type: z.literal('resize') }).strict(),
  z.object({ type: z.literal('mode'), mode: z.enum(['live', 'step']) }).strict(),
  z.object({ type: z.literal('frame') }).strict(),
  z.object({ type: z.literal('action'), action: actionSchema, wait: z.boolean().optional() }).strict(),
  z.object({ type: z.literal('point'), x: z.number().min(0), y: z.number().min(0) }).strict(),
]);
/** 接入地址里的 width、height、mode 与并排的一格；尺寸缺一个或不合法就当没给，mode 默认逐帧，格子的浏览器或视口不合法就当画面视图。 */
export function previewParams(params: URLSearchParams): Pick<PreviewSocket, 'size' | 'live' | 'cell'> {
  const size = sizeSchema.safeParse({ width: Number(params.get('width')), height: Number(params.get('height')) });
  const browser = z.enum(workstationBrowsers).safeParse(params.get('browser'));
  const viewport = sizeSchema.safeParse({ width: Number(params.get('viewportWidth')), height: Number(params.get('viewportHeight')) });
  return { ...(size.success ? { size: size.data } : {}), live: params.get('mode') === 'live',
    ...(browser.success && viewport.success ? { cell: { browser: browser.data, ...viewport.data } } : {}) };
}

type FrameExtra = { settled?: boolean; point?: { x: number; y: number } };
/** 网页视口的默认尺寸：只有 agent 在用、还没有设备接入时，或 agent 指定了浏览器没给尺寸时。 */
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
/** preview_open 最多等这么久：开发服务器多半在这之前能响应，构建、安装慢的到时先返回，退出时再通知。 */
const OPEN_WAIT_MS = 30_000;
/** 等模拟器里的 App 到前台时多久问一次。 */
const LAUNCH_POLL_MS = 1000;
/** 新建预览时列的配对过的真机多久重新问一次 devicectl。 */
const PAIRED_TTL_MS = 15_000;

/** 一个画面：画面视图，或并排视图的一格。 */
class View {
  screen?: Screen;
  opening?: Promise<Screen>;
  /** 开的是什么（见 sourceKey）：实例的画面换了就关掉重开。 */
  source?: string;
  error?: string;
  readonly viewers = new Set<Socket>();
  /** 决定网页视口尺寸的设备：最近一次操作的那台，没人操作过时是第一台接入的。并排的格子视口固定，没有。 */
  owner?: Socket;
  /** 网页视口此刻的尺寸；模拟器和 App 窗口没有。 */
  viewport?: Size;
  /** 最近给模型截图时的视口：之后视口变了，模型照那张截图给的坐标就不准了。 */
  modelViewport?: Size;
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

  constructor(readonly instanceId: string, readonly cell?: Cell) {}
}

const viewKey = (instanceId: string, cell?: Cell) => cell ? `${instanceId}|${cell.browser}|${cell.width}x${cell.height}` : instanceId;
const sameSize = (a?: Size, b?: Size) => a?.width === b?.width && a?.height === b?.height;
const pointed = (action: PreviewAction) => 'x' in action || action.type === 'drag';
const sameDevice = (a?: PreviewDevice, b?: PreviewDevice) => JSON.stringify(a ?? null) === JSON.stringify(b ?? null);

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

/** 找好的目标与设备：补全了默认型号的配置、脚本，以及设备候选里的那台（真机带名字）。 */
export interface Resolved { spec: PreviewSpec; target: Target; device?: DeviceCandidate }
/** 起一个目标要的东西：脚本、补全后的配置、交给脚本的环境变量与新实例的名字。 */
export interface Launch { target: Target; spec: PreviewSpec; env: Record<string, string>; title: string }

/** 画面开的是什么：工作机上的浏览器与端口、模拟器、App 的路径。 */
type Source = { kind: 'web'; browser: WorkstationBrowser; port: number } | { kind: 'simulator'; udid: string } | { kind: 'app'; path: string };
const sourceKey = (source?: Source) => source && JSON.stringify(source);

export class Previews {
  private views = new Map<string, View>();
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

  // ---- 目标与设备 ----

  /**
   * 新建窗口里列的：本工作区的目标，与设备候选（模拟器型号、配对过的真机）。devicectl 列一次要一两秒，新建窗口每次打开都来取，
   * 配对过的真机留 PAIRED_TTL_MS；起目标时选的真机另外现查（见 resolve）。
   */
  async targets(workspaceId: string): Promise<{ targets: string[]; devices: DeviceCandidate[] }> {
    const cwd = this.workspace(workspaceId).cwd;
    if (!this.paired || Date.now() - this.paired.at > PAIRED_TTL_MS) {
      const devices = pairedDevices(this.host.env);
      this.paired = { at: Date.now(), devices };
    }
    const [simulators, physical] = await Promise.all([this.host.simulators.candidates().catch(() => []), this.paired.devices]);
    return { targets: listTargets(cwd), devices: [...simulators, ...physical] };
  }

  private paired?: { at: number; devices: ReturnType<typeof pairedDevices> };

  private workspace(workspaceId: string) {
    const workspace = this.host.store.workspace(workspaceId);
    if (!workspace || workspace.status !== 'open') throw new KiteError('工作区尚未打开', 409);
    return workspace;
  }

  /**
   * 找目标、核对设备：找不到时错误里列出现有的目标或可选的设备。目标写到 KITE_SIMULATOR 又没给设备时，设备补成默认型号的模拟器。
   * 返回补全后的配置、脚本与设备（真机带名字，审批卡片上用）。不建模拟器、不分端口；选真机时才问 devicectl。
   */
  async resolve(workspaceId: string, spec: PreviewSpec): Promise<Resolved> {
    const target = findTarget(this.workspace(workspaceId).cwd, spec.target);
    const usesSimulator = target.content.includes('KITE_SIMULATOR');
    // 目标用不到的设备不算（新建窗口里选的设备对列出的每个目标都带着）：网页目标选了模拟器也照网页起
    if (spec.device && ('simulator' in spec.device ? usesSimulator : target.content.includes('KITE_DEVICE'))) {
      const candidates = 'simulator' in spec.device ? await this.host.simulators.candidates() : await pairedDevices(this.host.env);
      return { spec, target, device: checkDevice(spec.device, candidates) };
    }
    if (!usesSimulator) return { spec: { target: spec.target }, target };
    return { spec: { target: spec.target, device: { simulator: await this.host.simulators.defaultModel() } }, target };
  }

  /** 本工作区里同一目标与设备的实例（运行中或已结束、还没回收的）。 */
  find(workspaceId: string, spec: PreviewSpec): PluginInstance | undefined {
    return this.host.store.instances(workspaceId).find((instance) => {
      if (instance.definitionId !== previewDefinitionId || instance.status !== 'open') return false;
      const config = previewConfig(instance);
      return config.target === spec.target && sameDevice(config.device, spec.device);
    });
  }

  /**
   * 起之前：给工作区的这个目标分好端口段、建好要用的模拟器（不启动），环境变量交给脚本；新实例的名字是目标名，带设备的加上型号或设备名。
   * 新实例的配置是补全后的 spec，状态由进程起来后算（见 processChanged）。
   */
  async prepare(workspaceId: string, resolved: Resolved): Promise<Launch> {
    const { spec, target, device } = resolved;
    const port = await allocateTargetPorts(this.host.store, workspaceId, portKey(spec));
    const env: Record<string, string> = { PORT: String(port) };
    if (spec.device && 'simulator' in spec.device) env.KITE_SIMULATOR = await this.host.simulators.ensure(workspaceId, spec.device.simulator);
    if (spec.device && 'physical' in spec.device) env.KITE_DEVICE = spec.device.physical;
    const deviceName = !spec.device ? undefined : 'simulator' in spec.device ? spec.device.simulator : device?.kind === 'physical' ? device.name : spec.device.physical;
    return { target, spec, env, title: deviceName ? `${target.name} · ${deviceName}` : target.name };
  }

  /**
   * 实例已经入库：在它上面起目标的进程。重新起时用同一个实例，脚本在核对内容（与主线比对或经审批）之后又改了的不起。
   * 用到的模拟器在进程跑着期间不因没人看而关机（见 processChanged 里放开）。
   */
  start(instance: PluginInstance, launch: Launch, notify?: string): void {
    this.host.terminals.start(instance, { target: { path: launch.target.path, env: launch.env, ...(notify ? { notify } : {}) } });
    const udid = launch.env.KITE_SIMULATOR;
    // 起不来的（已经记成结束）不拿着模拟器
    if (udid && this.host.terminals.running(instance.id) && !this.holding.has(instance.id)) {
      this.holding.set(instance.id, udid);
      this.host.simulators.hold(udid);
    }
  }

  /** 进程跑着、拿着模拟器不让它闲置关机的实例 → 模拟器编号。 */
  private holding = new Map<string, string>();

  private letGo(id: string): void {
    const udid = this.holding.get(id);
    if (!udid) return;
    this.holding.delete(id);
    this.host.simulators.release(udid);
  }

  /** 实例用的那台模拟器；不用模拟器、还没建的为 undefined。 */
  private simulatorOf(instance: PluginInstance): string | undefined {
    const { device } = previewConfig(instance);
    return device && 'simulator' in device ? this.host.store.workspaceSimulator(instance.workspaceId, device.simulator) : undefined;
  }

  // ---- 画面跟着进程走 ----

  /** 画面的种类按进程此刻产生什么算：App 窗口、模拟器、网页，都没有是 none；几种同时出现时按这个顺序取。 */
  private screenOf(instance: PluginInstance): Omit<PreviewState, 'browser'> {
    const current = previewState(instance);
    const apps = this.host.terminals.apps(instance.id);
    if (apps.length) return { screen: 'app', app: apps.find((app) => app.path === current.app)?.path ?? apps[0]!.path };
    const config = previewConfig(instance);
    if (config.device && 'simulator' in config.device) return { screen: 'simulator' };
    const http = this.host.terminals.ports(instance.id).filter((port) => port.http).map((port) => port.port);
    const assigned = this.host.store.targetPort(instance.workspaceId, portKey(config));
    if (http.length) return { screen: 'web', port: assigned !== undefined && http.includes(assigned) ? assigned : http[0]! };
    return { screen: 'none' };
  }

  /** 实例的进程状态、端口或 App 变了：画面换了就写进状态，关掉不再对的工作机画面，有人在看的重开；进程结束了放开模拟器。 */
  processChanged(id: string): void {
    const instance = this.host.store.instance(id);
    if (!instance || instance.definitionId !== previewDefinitionId) return;
    const current = previewState(instance);
    const next: PreviewState = { ...this.screenOf(instance), ...(current.browser ? { browser: current.browser } : {}) };
    if (JSON.stringify(next) !== JSON.stringify(current)) {
      this.host.store.setInstanceState(id, { ...instance.state, preview: next });
      this.host.changed(instance.workspaceId);
    }
    if (!this.host.terminals.running(id)) this.letGo(id);
    this.refresh(id);
  }

  /** 实例的各个画面：开的已经不是现在该开的就关掉，有人在看的照新的重开，状态发给在看的设备。 */
  private refresh(id: string): void {
    for (const view of this.viewsOf(id)) {
      // 按 agent 的算法比：为 agent 另开的 WebKit 页面在设备上看的网页里也还是对的
      if (view.source && view.source !== sourceKey(this.sourceOf(view, true))) void this.shut(view, false);
      view.error = undefined;
      if (view.viewers.size && !view.screen && !view.opening && this.sourceOf(view)) void this.ensure(view).catch(() => {});
      this.broadcastState(view);
    }
  }

  private viewsOf(id: string): View[] {
    return [...this.views.values()].filter((view) => view.instanceId === id);
  }

  /** 这个画面此刻该开什么；画面视图在设备上看的网页（agent 要用时除外）、还没有画面时为 undefined。 */
  private sourceOf(view: View, forAgent = false): Source | undefined {
    const instance = this.host.store.instance(view.instanceId);
    if (!instance) return undefined;
    const state = previewState(instance);
    switch (state.screen) {
      case 'web': {
        // 在设备上看的网页，agent 操作时用 WebKit，与设备上的内核一致
        const browser = view.cell?.browser ?? state.browser ?? (forAgent ? 'webkit' : undefined);
        return browser && state.port !== undefined ? { kind: 'web', browser, port: state.port } : undefined;
      }
      case 'simulator': {
        const udid = this.simulatorOf(instance);
        return !view.cell && udid ? { kind: 'simulator', udid } : undefined;
      }
      case 'app': return !view.cell && state.app ? { kind: 'app', path: state.app } : undefined;
      case 'none': return undefined;
    }
  }

  // ---- 工作机上的画面 ----

  private instance(id: string): PluginInstance {
    const instance = this.host.store.instance(id);
    if (!instance || instance.definitionId !== previewDefinitionId) throw new KiteError('没有这个预览', 404);
    return instance;
  }

  private view(id: string, cell?: Cell): View {
    const key = viewKey(id, cell);
    let view = this.views.get(key);
    if (!view) { view = new View(id, cell); this.views.set(key, view); }
    return view;
  }

  /** agent 要操作的画面：带了浏览器或尺寸的是并排的那一格，没带的是画面视图。只有网页画面有格子。 */
  private agentView(id: string, target: { browser?: WorkstationBrowser; width?: number; height?: number } = {}): View {
    const state = previewState(this.instance(id));
    const sized = target.width !== undefined || target.height !== undefined;
    // 只写了画面视图正在用的浏览器，就是画面视图
    if (!sized && (target.browser === undefined || target.browser === state.browser)) return this.view(id);
    if (state.screen !== 'web') throw new KiteError('只有网页画面能指定浏览器与尺寸', 400);
    return this.view(id, { browser: target.browser ?? state.browser ?? 'webkit', width: target.width ?? DEFAULT_SIZE.width, height: target.height ?? DEFAULT_SIZE.height });
  }

  /** 工作机上的画面，没开就开；几个调用同时要时只开一次。forAgent 时在设备上看的网页也在工作机的 WebKit 里开。 */
  private ensure(view: View, forAgent = false): Promise<Screen> {
    if (this.closed) return Promise.reject(new KiteError('kited 正在关闭', 503));
    view.usedAt = Date.now();
    // 浏览器崩了、模拟器关了、App 退出了：丢掉重开
    if (view.screen && !view.screen.alive()) { void view.screen.close().catch(() => {}); view.screen = view.source = view.last = view.viewport = undefined; }
    if (view.screen) return Promise.resolve(view.screen);
    if (view.opening) return view.opening;
    const instance = this.instance(view.instanceId);
    const state = previewState(instance);
    const source = this.sourceOf(view, forAgent);
    if (!source) {
      return Promise.reject(new KiteError(this.host.terminals.running(instance.id) ? '预览还没有画面：进程还没开出网页端口、模拟器里的 App 或 App 窗口'
        : '预览的进程已经结束，没有画面；用 preview_open 带 restart 重新起', 409));
    }
    const size = view.cell ?? (state.screen === 'web' ? view.owner?.data.size ?? DEFAULT_SIZE : undefined);
    const opening = (async () => {
      this.workspace(instance.workspaceId);
      switch (source.kind) {
        case 'simulator': return this.host.simulators.acquire(source.udid);
        case 'app': {
          const app = this.host.terminals.apps(instance.id).find((candidate) => candidate.path === source.path);
          if (!app) throw new KiteError(`${source.path.split('/').at(-1)} 现在没有开着窗口`, 409);
          return openWindowScreen(app.pid, this.host.env);
        }
        case 'web': return this.browsers.open(source.browser, { url: `http://localhost:${source.port}/`, ...size! });
      }
    })();
    view.opening = opening;
    view.source = sourceKey(source);
    view.error = undefined;
    this.broadcastState(view);
    opening.then(async (screen) => {
      if (this.views.get(viewKey(view.instanceId, view.cell)) !== view || view.opening !== opening) { await screen.close(); return; }
      view.screen = screen;
      view.opening = undefined;
      view.viewport = size;
      view.info = await screen.info().catch(() => ({}));
      this.broadcastState(view);
      this.watchLive(view);
      if (!view.viewers.size) return;
      const frame = await screen.capture().catch(() => undefined);
      if (frame) this.broadcastFrame(view, frame);
    }, (error: unknown) => {
      if (view.opening !== opening) return;
      view.opening = undefined;
      view.source = undefined;
      view.error = (error as Error).message;
      this.broadcastState(view);
    });
    return opening;
  }

  /**
   * 关掉工作机上的画面，画面对象留着（设备还接着）。还在开的默认等开好再关，工作区关闭、kited 退出后不留下开着的画面；
   * waitOpening 为假时不等，开好时发现已经换了，由 ensure 关掉。
   */
  private async shut(view: View, waitOpening = true): Promise<void> {
    clearInterval(view.live);
    view.live = undefined;
    const screen = view.screen ?? (waitOpening ? await view.opening?.catch(() => undefined) : undefined);
    view.screen = view.opening = view.source = view.last = view.viewport = undefined;
    view.info = {};
    await screen?.close().catch(() => {});
  }

  /** 动作一个接一个做。 */
  private queued<T>(view: View, run: () => Promise<T>): Promise<T> {
    const task = view.queue.then(run, run);
    view.queue = task.catch(() => {});
    return task;
  }

  /** 这台设备成为视口尺寸的归属者：网页视口换成它的窗口尺寸，换了就给在看的设备都发一帧，返回换没换。格子的视口固定。 */
  private async own(view: View, socket: Socket): Promise<boolean> {
    if (view.cell) return false;
    view.owner = socket;
    const size = socket.data.size, screen = view.screen;
    if (!size || !screen?.resize || sameSize(view.viewport, size)) return false;
    await screen.resize(size.width, size.height);
    view.viewport = size;
    this.broadcastFrame(view, await screen.capture());
    return true;
  }

  /**
   * 做一个动作；wait 时等画面稳定，把这一帧发给所有在看的设备，标出点在哪。返回稳定后的一帧与是否等到了稳定。
   * 失败了告诉所有在看的设备：它们都收到了开始等的 waiting，不说就一直停在等待。
   */
  private perform(view: View, action: PreviewAction, wait: boolean, options: { signal?: AbortSignal; forAgent?: boolean } = {}) {
    return this.queued(view, async () => {
      try {
        const screen = await this.ensure(view, options.forAgent);
        view.usedAt = Date.now();
        if (wait) {
          view.settling = true;
          this.broadcast(view, { type: 'waiting' });
        }
        await screen.act(action);
        if (!wait) return undefined;
        // 没有设备在看（只有 agent 在用）时按给模型的尺寸截着等
        const forModel = !view.viewers.size;
        const result = { ...await settleScreen(screen, this.timing, { signal: options.signal, afterAction: true, forModel }), forModel };
        view.info = await screen.info().catch(() => view.info);
        this.broadcastState(view);
        const point = 'x' in action ? { x: action.x, y: action.y } : action.type === 'drag' ? action.to : undefined;
        this.broadcastFrame(view, result.frame, { settled: result.settled, ...(point ? { point } : {}) });
        return result;
      } catch (error) {
        this.broadcast(view, { type: 'error', message: (error as Error).message });
        throw error;
      } finally { view.settling = false; }
    });
  }

  // ---- agent 的操作 ----

  /**
   * preview_open：起目标（审批由调用方先做完，checked 为真；看到已经在跑而没核对的，到这里发现已经结束了不起，让 agent 再调一次）。
   * 同一目标与设备已经在跑时返回那个，restart 时先停掉再在同一个实例里起；已经结束、还没回收的实例接着用，结束时通知这次起它的 agent。
   * 新起的限时等到画面就绪或进程退出，返回进程状态、端口段与输出末尾，有画面的另带稳定后的一帧。
   */
  async open(workspaceId: string, resolved: Resolved, options: { restart?: boolean; checked: boolean },
    origin: NonNullable<PluginInstance['origin']>, signal?: AbortSignal) {
    let launched: string | undefined;
    const { instance, reused } = await this.host.run(workspaceId, async () => {
      this.workspace(workspaceId);
      const existing = this.find(workspaceId, resolved.spec);
      const running = existing && this.host.terminals.running(existing.id);
      if (existing && running && !options.restart) return { instance: existing, reused: true };
      if (!options.checked) throw new KiteError(`目标「${resolved.target.name}」刚刚结束了，再调用一次 preview_open 起它`, 409);
      if (existing && running) await this.host.terminals.stop(existing.id, '预览重新运行', { quiet: true, keep: true });
      const launch = await this.prepare(workspaceId, resolved);
      if (findTarget(this.workspace(workspaceId).cwd, resolved.target.name).content !== resolved.target.content) {
        throw new KiteError(`目标「${resolved.target.name}」刚刚又改了，重新起一次`, 409);
      }
      const instance: PluginInstance = existing ?? { id: randomUUID(), workspaceId, definitionId: previewDefinitionId, title: launch.title,
        config: { preview: launch.spec }, state: {}, view: 'screen', status: 'open', createdAt: Date.now(), origin };
      if (!existing) this.host.store.addInstance(instance);
      launched = launch.env.KITE_SIMULATOR;
      if (launched) this.launchedBefore.set(instance.id, new Set(await this.host.simulators.launchedApps(launched)));
      this.start(instance, launch, origin.instanceId);
      this.host.changed(workspaceId);
      return { instance, reused: false };
    });
    // 等待期间用户可能关掉了实例，状态与输出取等待时拿着的会话里的
    const waited = reused ? { state: this.host.terminals.processState(instance.id), text: await this.host.terminals.tail(instance.id) }
      : await this.host.terminals.waitUntil(instance.id, () => this.ready(instance.id), { ms: OPEN_WAIT_MS, ...(launched ? { pollMs: LAUNCH_POLL_MS } : {}), signal });
    this.launchedBefore.delete(instance.id);
    const current = this.host.store.instance(instance.id);
    const result = { ...this.describe(current ?? instance), ...waited.state, reused, text: waited.text };
    if (!current || result.screen === 'none') return result;
    try { return { ...result, ...await this.observe(this.view(instance.id), signal) }; }
    catch { return result; }
  }

  /** 新起的模拟器目标开之前模拟器里已经在跑的 App：之后多出来的就是目标打开的。 */
  private launchedBefore = new Map<string, Set<string>>();

  /** 画面就绪：网页端口能用 HTTP 打开、App 开出了窗口、模拟器里目标打开的 App 到了前台。 */
  private async ready(id: string): Promise<boolean> {
    const instance = this.host.store.instance(id);
    if (!instance) return true;
    const state = previewState(instance);
    if (state.screen === 'app' || state.screen === 'web') return true;
    const { device } = previewConfig(instance);
    if (state.screen !== 'simulator' || !device || !('simulator' in device)) return false;
    const udid = this.host.store.workspaceSimulator(instance.workspaceId, device.simulator);
    if (!udid) return false;
    const before = this.launchedBefore.get(id) ?? new Set();
    return (await this.host.simulators.launchedApps(udid)).some((label) => !before.has(label));
  }

  /** agent 做一个动作，等画面稳定后返回新的一帧；screenshot 只截一帧，wait 等一段时间再截。坐标照最近一次给它的截图。 */
  async act(id: string, action: PreviewAction | { type: 'screenshot' } | { type: 'wait'; seconds: number },
    target: { browser?: WorkstationBrowser; width?: number; height?: number } = {}, signal?: AbortSignal) {
    if (action.type === 'wait') await Bun.sleep(action.seconds * 1000);
    const view = this.agentView(id, target);
    if (action.type !== 'screenshot' && action.type !== 'wait' && pointed(action) && view.modelViewport && !sameSize(view.modelViewport, view.viewport)) {
      throw new KiteError('预览的画面尺寸变了（有人在设备上打开或操作了它），先用 screenshot 看一眼，照新截图给坐标', 409);
    }
    const done = action.type === 'screenshot' || action.type === 'wait' ? undefined
      : await this.perform(view, toScreen(action, view.modelScale), true, { signal, forAgent: true });
    return { ...this.describe(this.instance(id)), ...await this.observe(view, signal, done) };
  }

  /**
   * 当前画面给模型：等稳定（动作刚等过的不再等，等到的那一帧是按给模型的尺寸截的就直接用），按逻辑尺寸截一帧，带上地址与标题。
   * 超过给模型的图片上限（见 documents.ts 的 modelImage）时缩小，返回的 width、height 是截图的尺寸，模型照它给坐标，act 里换回逻辑尺寸。
   */
  private async observe(view: View, signal?: AbortSignal, done?: { frame: Frame; settled: boolean; forModel: boolean }) {
    const screen = await this.ensure(view, true);
    const settling = done ?? { ...await settleScreen(screen, this.timing, { signal, forModel: true }), forModel: true };
    const frame = settling.forModel ? settling.frame : await screen.capture(true);
    const image = await modelImage(frame.data, undefined, MODEL_IMAGE);
    view.modelScale = frame.width / image.width;
    view.modelViewport = view.viewport;
    view.info = await screen.info().catch(() => view.info);
    return { ...view.info, ...(view.cell ? { browser: view.cell.browser } : {}), width: image.width, height: image.height,
      settled: settling.settled, images: [image.image] };
  }

  /** App 窗口里那个 App 的分发包，给另一台 Mac 装上直接用（见 app-bundles.ts）。 */
  bundle(id: string): Response {
    const state = previewState(this.instance(id));
    if (state.screen !== 'app' || !state.app) throw new KiteError('只有开着 App 窗口的预览能打包', 409);
    return bundleResponse(state.app);
  }

  async inspect(id: string, target: { browser?: WorkstationBrowser; width?: number; height?: number } = {}): Promise<{ text: string }> {
    const screen = await this.ensure(this.agentView(id, target), true);
    return { text: await screen.inspect() };
  }

  /** 改网页在哪看，各设备共用；工作机上已开着页面的换浏览器重开。 */
  select(id: string, browser: PreviewBrowser): { browser?: WorkstationBrowser } {
    const instance = this.instance(id);
    const { browser: _, ...rest } = previewState(instance);
    const chosen = browser === 'device' ? undefined : browser;
    this.host.store.setInstanceState(id, { ...instance.state, preview: { ...rest, ...(chosen ? { browser: chosen } : {}) } });
    this.host.changed(instance.workspaceId);
    this.refresh(id);
    return chosen ? { browser: chosen } : {};
  }

  /** list 里的一项：目标、设备、画面种类与主端口、在哪看、App，分给目标的端口段与进程状态。 */
  describe(instance: PluginInstance) {
    const config = previewConfig(instance);
    const { target, device } = config;
    const state = previewState(instance);
    const assignedPort = this.host.store.targetPort(instance.workspaceId, portKey(config));
    return { instanceId: instance.id, title: instance.title, target, device: device ?? null, screen: state.screen,
      ...(state.screen === 'web' ? { port: state.port, browser: state.browser ?? 'device' } : {}), ...(state.screen === 'app' ? { app: state.app } : {}),
      ...(assignedPort !== undefined ? { assignedPort } : {}), ...this.host.terminals.processState(instance.id) };
  }

  // ---- 生命周期 ----

  /** 实例回收时关掉它的画面、断开在看的设备。 */
  forget(id: string): void {
    this.launchedBefore.delete(id);
    this.letGo(id);
    for (const view of this.viewsOf(id)) {
      this.views.delete(viewKey(view.instanceId, view.cell));
      for (const socket of view.viewers) socket.close(1000, '预览已关闭');
      void this.shut(view);
    }
  }

  /** 工作区交接、冻结或归档前关掉它的画面；进程由终端插件停下。调用时已在控制队列里。 */
  async closeWorkspace(workspaceId: string): Promise<void> {
    const ids = new Set(this.host.store.instances(workspaceId).filter((instance) => instance.definitionId === previewDefinitionId).map((instance) => instance.id));
    await Promise.all([...this.views.values()].filter((view) => ids.has(view.instanceId)).map((view) => this.shut(view)));
  }

  async close(): Promise<void> {
    this.closed = true;
    clearInterval(this.idleTimer);
    await Promise.all([...this.views.values()].map((view) => this.shut(view)));
    await this.browsers.close();
  }

  private closeIdle(): void {
    for (const view of this.views.values()) {
      if ((view.screen || view.opening) && !view.viewers.size && Date.now() - view.usedAt > IDLE_MS) void this.shut(view);
    }
  }

  // ---- 设备接入 ----

  /** WebSocket 升级前核对：实例存在、是预览、所在工作区打开着。 */
  check(id: string): void {
    const instance = this.instance(id);
    this.workspace(instance.workspaceId);
  }

  attach(socket: Socket): void {
    const view = this.view(socket.data.instanceId, socket.data.cell);
    view.viewers.add(socket);
    // 只是打开来看不抢视口：已有归属者（或 agent 正照着截图操作）时尺寸不变，这台操作了才换成它的
    if (socket.data.size && !view.owner && !view.cell) view.owner = socket;
    // 在设备上看的网页不经工作机，还没有画面的等进程产生
    if (!this.sourceOf(view)) { this.sendState(socket, view); return; }
    const screen = view.screen;
    if (screen) {
      this.sendState(socket, view);
      void (async () => {
        const resized = view.owner === socket && await this.queued(view, () => this.own(view, socket));
        this.watchLive(view);
        if (!resized) await this.sendFrame(socket, view);
      })().catch(() => {});
      return;
    }
    // 新开的由 ensure 把状态和开好后的第一帧发给所有在看的设备；已经在开的只补发一次状态
    if (view.opening) this.sendState(socket, view);
    void this.ensure(view).catch(() => {});
  }

  receive(socket: Socket, message: string | Buffer): void {
    const view = this.views.get(viewKey(socket.data.instanceId, socket.data.cell));
    if (!view) return;
    const parsed = typeof message === 'string' ? messageSchema.safeParse((() => { try { return JSON.parse(message); } catch { return undefined; } })()) : undefined;
    if (!parsed?.success) { socket.close(1003, '预览控制消息无效'); return; }
    const data = parsed.data;
    switch (data.type) {
      case 'resize':
        socket.data.size = { width: data.width, height: data.height };
        if (!view.owner || view.owner === socket) void this.queued(view, () => this.own(view, socket)).catch(() => {});
        return;
      case 'mode':
        socket.data.live = data.mode === 'live';
        this.watchLive(view);
        if (!socket.data.live) void this.sendFrame(socket, view);
        return;
      case 'frame':
        void this.sendFrame(socket, view);
        return;
      case 'action': {
        if (data.wait && view.settling) { socket.send(JSON.stringify({ type: 'dropped' })); return; }
        // 失败已由 perform 告诉所有在看的设备
        this.perform(view, data.action, data.wait ?? false).catch(() => {});
        // 操作的设备成为视口尺寸的归属者：坐标是照它看到的画面给的，先做完这个动作，再换成它的窗口尺寸
        if (view.owner !== socket) void this.queued(view, () => this.own(view, socket)).catch(() => {});
        return;
      }
      case 'point': {
        // 只读页面，不进动作的队列；结果只回问的那台设备
        const { x, y } = data;
        void (async () => {
          const element = await view.screen?.point?.(x, y).catch(() => null) ?? null;
          if (socket.readyState === 1) socket.send(JSON.stringify({ type: 'element', x, y, element }));
        })();
        return;
      }
    }
  }

  detach(socket: Socket): void {
    const view = this.views.get(viewKey(socket.data.instanceId, socket.data.cell));
    if (!view) return;
    view.viewers.delete(socket);
    if (view.owner === socket) view.owner = view.cell ? undefined : [...view.viewers].at(-1);
    view.usedAt = Date.now();
    this.watchLive(view);
  }

  /** 有设备在看实时画面时定时截，变了才发给它们；没有了停下。 */
  private watchLive(view: View): void {
    const wanted = !!view.screen && [...view.viewers].some((socket) => socket.data.live);
    if (!wanted) { clearInterval(view.live); view.live = undefined; return; }
    if (view.live) return;
    let ticks = 0;
    view.live = setInterval(() => {
      const screen = view.screen;
      if (!screen || view.capturing) return;
      view.capturing = true;
      void (async () => {
        try {
          const frame = await screen.capture();
          // 地址和标题约一秒查一次
          if (++ticks % 8 === 0) {
            const info = await screen.info().catch(() => view.info);
            if (info.url !== view.info.url || info.pageTitle !== view.info.pageTitle) { view.info = info; this.broadcastState(view); }
          }
          if (view.last && sameFrame(frame.data, view.last.data)) return;
          view.last = frame;
          for (const socket of view.viewers) {
            if (socket.data.live && socket.getBufferedAmount() < LIVE_BACKLOG) this.deliver(socket, frame);
          }
        } catch {} finally { view.capturing = false; }
      })();
    }, LIVE_MS);
    view.live.unref();
  }

  /** 截当前画面只发给这台设备；不算发给了大家，实时画面照常比较（见 broadcastFrame）。 */
  private async sendFrame(socket: Socket, view: View): Promise<void> {
    if (!view.screen) return;
    try { this.deliver(socket, await view.screen.capture()); } catch {}
  }

  /** 发一帧给所有在看的设备，记下来，实时画面据此判断变没变。 */
  private broadcastFrame(view: View, frame: Frame, extra: FrameExtra = {}): void {
    if (!view.viewers.size) return;
    view.last = frame;
    for (const socket of view.viewers) this.deliver(socket, frame, extra);
  }

  /** 发一帧：先发说明，紧跟着发 JPEG。 */
  private deliver(socket: Socket, frame: Frame, extra: FrameExtra = {}): void {
    if (socket.readyState !== 1) return;
    socket.send(JSON.stringify({ type: 'frame', width: frame.width, height: frame.height, ...extra }));
    socket.send(frame.data);
  }

  private stateMessage(view: View) {
    const instance = this.host.store.instance(view.instanceId);
    const screen: PreviewScreen = instance ? previewState(instance).screen : 'none';
    const phase = view.screen ? 'ready' : view.opening ? 'starting' : view.error ? 'failed' : this.sourceOf(view) ? 'starting' : 'waiting';
    return { type: 'state', phase, screen, ...(view.error ? { error: view.error } : {}), ...view.info };
  }

  private sendState(socket: Socket, view: View): void {
    if (socket.readyState === 1) socket.send(JSON.stringify(this.stateMessage(view)));
  }

  private broadcastState(view: View): void {
    if (view.viewers.size) this.broadcast(view, this.stateMessage(view));
  }

  private broadcast(view: View, message: object): void {
    const text = JSON.stringify(message);
    for (const socket of view.viewers) if (socket.readyState === 1) socket.send(text);
  }
}
