/**
 * 宿主为工作区开的 iOS 模拟器（docs/实例操作.md「模拟器」）：每个工作区每个型号一台，建在默认设备集里，名字是「Kite 工作区名 型号」，
 * 与用户自己的模拟器分开；编号记在 kite.db 的 workspace_simulators，只由这里增删。目标用到模拟器时起之前才建（不启动），
 * 编号经 KITE_SIMULATOR 交给脚本，脚本自己启动、安装和打开 App。没有实例在跑、也没人看一阵后关机，工作区交接、冻结时关机，归档时删掉。
 * 画面与操作经 Xcode 自带的工具，见 xcode.ts。
 */
import { KiteError } from '../errors.ts';
import type { Store } from '../store.ts';
import { systemCommand } from '../system-command.ts';
import type { DeviceCandidate } from './devices.ts';
import type { Screen } from './screen.ts';
import { SimulatorScreen, XcodeTools } from './xcode.ts';

/** 没有预览在看、也没有实例在用这么久，关掉模拟器。 */
const IDLE_SHUTDOWN_MS = 30 * 60_000;
/** 可建的型号随 Xcode 更新才变，查一次留这么久。 */
const MODELS_TTL_MS = 10 * 60_000;

export interface SimulatorsHost {
  store: Store;
  /** Kite 目录：发起 Xcode 批准用的占位项目放在它的 xcode/ 下。 */
  home: string;
  /** 跑 xcrun 用的环境，显式给出。 */
  env: Record<string, string>;
}

interface Booted {
  /** 正在看的画面数，加上跑着、用它的预览进程数（见 hold）：都没有了才计闲置。 */
  users: number;
  screen?: Promise<SimulatorScreen>;
  idle?: ReturnType<typeof setTimeout>;
}

type Runtime = { identifier: string; platform: string; version: string; isAvailable: boolean;
  supportedDeviceTypes?: Array<{ identifier: string; name: string; productFamily?: string }> };
type Model = { name: string; type: string; family: string; runtime: string };

export class Simulators {
  /** 按模拟器编号记的画面与闲置计时。 */
  private booted = new Map<string, Booted>();
  /** 正在建的：同一工作区的同一型号同时要时只建一台。 */
  private creating = new Map<string, Promise<string>>();
  private catalog?: { at: number; models: Promise<Model[]> };
  private tools: XcodeTools;

  constructor(private host: SimulatorsHost) {
    this.tools = new XcodeTools(host.home, host.env);
  }

  private async xcrun(args: string[], timeoutMs = 60_000): Promise<{ code: number; stdout: string }> {
    if (process.platform !== 'darwin') throw new KiteError('只有 Mac 工作机能开 iOS 模拟器', 503);
    try { return await systemCommand(['/usr/bin/xcrun', 'simctl', ...args], { env: this.host.env, timeoutMs }); }
    catch (error) { throw new KiteError(`simctl 没有运行：${(error as Error).message}`, 503); }
  }

  /** 最新的 iOS 运行时支持的 iPhone 与 iPad 型号，各按新到旧；不是 Mac、没装运行时时为空。 */
  private models(): Promise<Model[]> {
    if (this.catalog && Date.now() - this.catalog.at < MODELS_TTL_MS) return this.catalog.models;
    const models = (async () => {
      if (process.platform !== 'darwin') return [];
      const listed = await this.xcrun(['list', 'runtimes', '-j', 'available']).catch(() => undefined);
      const runtime = (JSON.parse(listed?.stdout || '{"runtimes":[]}') as { runtimes: Runtime[] }).runtimes
        .filter((candidate) => candidate.platform === 'iOS' && candidate.isAvailable)
        .sort((a, b) => b.version.localeCompare(a.version, undefined, { numeric: true }))[0];
      const types = (runtime?.supportedDeviceTypes ?? []).filter((type) => type.productFamily === 'iPhone' || type.productFamily === 'iPad');
      return types.map((type) => ({ name: type.name, type: type.identifier, family: type.productFamily!, runtime: runtime!.identifier }));
    })();
    this.catalog = { at: Date.now(), models };
    models.catch(() => { this.catalog = undefined; });
    return models;
  }

  /** 设备候选里的模拟器型号，iPhone 在前。 */
  async candidates(): Promise<Array<Extract<DeviceCandidate, { kind: 'simulator' }>>> {
    const models = await this.models();
    return [...models.filter((model) => model.family === 'iPhone'), ...models.filter((model) => model.family === 'iPad')]
      .map((model) => ({ kind: 'simulator' as const, model: model.name, family: model.family }));
  }

  /** 没给设备时用的型号：最新的运行时支持的最新一款 iPhone。 */
  async defaultModel(): Promise<string> {
    const model = (await this.models()).find((candidate) => candidate.family === 'iPhone');
    if (!model) throw new KiteError('这台工作机没有装 iOS 模拟器运行时，先在 Xcode 的设置里下载一个', 503);
    return model.name;
  }

  /** 工作区这个型号的模拟器，没有（或已被删掉）就建一台。不启动。 */
  ensure(workspaceId: string, model: string): Promise<string> {
    const key = `${workspaceId}\n${model}`;
    const existing = this.creating.get(key);
    if (existing) return existing;
    const task = (async () => {
      const saved = this.host.store.workspaceSimulator(workspaceId, model);
      // 画面开着的就还在，不必再问 simctl
      if (saved && (this.booted.get(saved)?.screen || await this.exists(saved))) return saved;
      const choice = (await this.models()).find((candidate) => candidate.name === model);
      if (!choice) throw new KiteError(`这台工作机建不了 ${model} 的模拟器`, 404);
      const name = this.host.store.workspace(workspaceId)?.name ?? workspaceId;
      const created = await this.xcrun(['create', `Kite ${name} ${model}`, choice.type, choice.runtime]);
      const udid = created.stdout.trim();
      if (created.code !== 0 || !udid) throw new KiteError('模拟器没有建成', 503);
      this.host.store.setWorkspaceSimulator(workspaceId, model, udid);
      return udid;
    })().finally(() => this.creating.delete(key));
    this.creating.set(key, task);
    return task;
  }

  private async exists(udid: string): Promise<boolean> {
    const listed = await this.xcrun(['list', 'devices', '-j']);
    const devices = Object.values((JSON.parse(listed.stdout || '{"devices":{}}') as { devices: Record<string, Array<{ udid: string }>> }).devices).flat();
    return devices.some((device) => device.udid === udid);
  }

  /** 模拟器里正在跑的 App（launchctl 里的 UIKitApplication 标签）；没开机时为空。目标起来后据此判断 App 到了前台。 */
  async launchedApps(udid: string): Promise<string[]> {
    const listed = await this.xcrun(['spawn', udid, 'launchctl', 'list'], 10_000).catch(() => undefined);
    if (!listed || listed.code !== 0) return [];
    return listed.stdout.split('\n').map((line) => line.trim().split(/\s+/).at(-1) ?? '').filter((label) => label.startsWith('UIKitApplication:'));
  }

  /** 预览要看这台模拟器：开 Xcode 的设备操作会话（没开机的由它开机）；几个预览共用一个会话。close 是这个预览不看了。 */
  async acquire(udid: string): Promise<Screen> {
    let entry = this.booted.get(udid);
    if (!entry) { entry = { users: 0 }; this.booted.set(udid, entry); }
    clearTimeout(entry.idle);
    entry.users++;
    const current = entry;
    try {
      if (!current.screen) {
        const screen = new SimulatorScreen(udid, this.tools, this.host.env);
        current.screen = screen.start().then(() => screen);
      }
      const screen = await current.screen;
      let released = false;
      // 每个预览一个外壳：关掉只是不看了，最后一个不看时开始计闲置
      return { ...bind(screen), close: async () => { if (!released) { released = true; this.release(udid, current); } } };
    } catch (error) {
      current.screen = undefined;
      this.release(udid, current);
      throw error;
    }
  }

  /** 预览的进程用着这台模拟器（目标起了）：跑着期间不因没人看而关机，进程结束时 release。 */
  hold(udid: string): void {
    let entry = this.booted.get(udid);
    if (!entry) { entry = { users: 0 }; this.booted.set(udid, entry); }
    clearTimeout(entry.idle);
    entry.users++;
  }

  release(udid: string, entry = this.booted.get(udid)): void {
    if (!entry || --entry.users > 0) return;
    clearTimeout(entry.idle);
    entry.idle = setTimeout(() => {
      if (this.booted.get(udid) === entry && entry.users <= 0) void this.shutdownOne(udid);
    }, IDLE_SHUTDOWN_MS);
    entry.idle.unref();
  }

  /** 关掉一台：画面断开，模拟器关机，编号留着。 */
  private async shutdownOne(udid: string): Promise<void> {
    const entry = this.booted.get(udid);
    this.booted.delete(udid);
    if (entry) clearTimeout(entry.idle);
    await (await entry?.screen?.catch(() => undefined))?.close().catch(() => {});
    await this.xcrun(['shutdown', udid]).catch(() => {});
  }

  /** 工作区交接、冻结时关掉它的模拟器。 */
  async shutdown(workspaceId: string): Promise<void> {
    await Promise.all(this.host.store.workspaceSimulators(workspaceId).map(({ udid }) => this.shutdownOne(udid)));
  }

  /**
   * 工作区归档或随项目删掉：删掉它的模拟器和编号（之前已随工作区关机，见 shutdown）。编号只在这里删：
   * 流转回来时工作区的记录整个换掉，这张表不动，模拟器接着用。
   */
  async remove(workspaceId: string): Promise<void> {
    for (const { udid } of this.host.store.workspaceSimulators(workspaceId)) {
      await this.xcrun(['delete', udid]).catch(() => {});
      this.host.store.deleteWorkspaceSimulator(workspaceId, udid);
    }
  }

  async close(): Promise<void> {
    // kited 退出时只断开画面，模拟器留着开机，重启后接着用；闲置的下次启动后按需关
    await Promise.all([...this.booted.values()].map(async (entry) => {
      clearTimeout(entry.idle);
      await (await entry.screen?.catch(() => undefined))?.close().catch(() => {});
    }));
    this.booted.clear();
    this.tools.close();
  }
}

/** 把共享画面的方法绑到它自己身上，外壳替换 close。 */
const bind = (screen: SimulatorScreen): Screen => ({
  capture: (forModel) => screen.capture(forModel), act: (action) => screen.act(action), inspect: () => screen.inspect(), point: (x, y) => screen.point(x, y),
  info: () => screen.info(), alive: () => screen.alive(), close: () => screen.close(), settle: (options) => screen.settle(options),
});
