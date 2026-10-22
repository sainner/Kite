/**
 * 宿主为工作区开的 iOS 模拟器（docs/实例操作.md「预览」）：每个工作区一台，建在默认设备集里，名字是「Kite 工作区名」，与用户自己的模拟器分开；
 * 编号记在 kite.db 的 workspace_simulators，只由这里增删。预置脚本里写到 KITE_SIMULATOR 的，起的时候才建（不启动），编号经这个环境变量交给脚本，
 * 脚本自己启动、安装和打开 App；模拟器预览要看时宿主无界面启动它（不开 Simulator.app）。没人看、闲置一阵后关机，
 * 工作区交接、冻结时关机，归档时删掉。画面与输入经 kite-sim 小程序，见 simulator-screen.ts。
 */
import { KiteError } from '../errors.ts';
import type { Store } from '../store.ts';
import { systemCommand } from '../system-command.ts';
import type { SimulatorScreens } from './previews.ts';
import type { Screen } from './screen.ts';
import { openSimulatorScreen, type SimulatorScreen } from './simulator-screen.ts';

/** 没有预览在看这么久，关掉模拟器。 */
const IDLE_SHUTDOWN_MS = 30 * 60_000;
const BOOT_TIMEOUT_MS = 5 * 60_000;

export interface SimulatorsHost {
  store: Store;
  /** 跑 xcrun、kite-sim 用的环境，显式给出。 */
  env: Record<string, string>;
}

interface Booted {
  udid: string;
  /** 正在看的预览数。 */
  users: number;
  screen?: Promise<SimulatorScreen>;
  idle?: ReturnType<typeof setTimeout>;
}

export class Simulators implements SimulatorScreens {
  private booted = new Map<string, Booted>();
  /** 正在建的：同一工作区同时要时只建一台。 */
  private creating = new Map<string, Promise<string>>();

  constructor(private host: SimulatorsHost) {}

  private async xcrun(args: string[], timeoutMs = 60_000): Promise<{ code: number; stdout: string }> {
    if (process.platform !== 'darwin') throw new KiteError('只有 Mac 工作机能开 iOS 模拟器', 503);
    try { return await systemCommand(['/usr/bin/xcrun', 'simctl', ...args], { env: this.host.env, timeoutMs }); }
    catch (error) { throw new KiteError(`simctl 没有运行：${(error as Error).message}`, 503); }
  }

  /** 工作区的模拟器，没有（或已被删掉）就建一台：最新的 iOS 运行时，它支持的最新一款 iPhone。不启动。 */
  ensure(workspaceId: string): Promise<string> {
    const existing = this.creating.get(workspaceId);
    if (existing) return existing;
    const task = (async () => {
      const saved = this.host.store.workspaceSimulator(workspaceId);
      // 画面开着的就还在，不必再问 simctl
      const booted = this.booted.get(workspaceId);
      if (saved && ((booted?.udid === saved && booted.screen) || await this.exists(saved))) return saved;
      const runtimes = await this.xcrun(['list', 'runtimes', '-j', 'available']);
      type Runtime = { identifier: string; platform: string; version: string; isAvailable: boolean;
        supportedDeviceTypes?: Array<{ identifier: string; name: string; productFamily?: string }> };
      const parsed = (JSON.parse(runtimes.stdout || '{"runtimes":[]}') as { runtimes: Runtime[] }).runtimes
        .filter((runtime) => runtime.platform === 'iOS' && runtime.isAvailable)
        .sort((a, b) => b.version.localeCompare(a.version, undefined, { numeric: true }));
      // 支持的机型按新到旧排
      const choice = parsed.flatMap((runtime) => (runtime.supportedDeviceTypes ?? []).filter((type) => type.productFamily === 'iPhone')
        .slice(0, 1).map((type) => ({ runtime: runtime.identifier, type: type.identifier })))[0];
      if (!choice) throw new KiteError('这台工作机没有装 iOS 模拟器运行时，先在 Xcode 的设置里下载一个', 503);
      const name = this.host.store.workspace(workspaceId)?.name ?? workspaceId;
      const created = await this.xcrun(['create', `Kite ${name}`, choice.type, choice.runtime]);
      const udid = created.stdout.trim();
      if (created.code !== 0 || !udid) throw new KiteError('模拟器没有建成', 503);
      this.host.store.setWorkspaceSimulator(workspaceId, udid);
      return udid;
    })().finally(() => this.creating.delete(workspaceId));
    this.creating.set(workspaceId, task);
    return task;
  }

  private async exists(udid: string): Promise<boolean> {
    const listed = await this.xcrun(['list', 'devices', '-j']);
    const devices = Object.values((JSON.parse(listed.stdout || '{"devices":{}}') as { devices: Record<string, Array<{ udid: string }>> }).devices).flat();
    return devices.some((device) => device.udid === udid);
  }

  /** 预置脚本起之前：脚本里写到 KITE_SIMULATOR 的，工作区还没有模拟器就建一台，编号由终端经这个环境变量交给脚本。 */
  async prepareScript(workspaceId: string, content: string): Promise<void> {
    if (content.includes('KITE_SIMULATOR')) await this.ensure(workspaceId);
  }

  /** 预览要看工作区的模拟器：建好、无界面启动、开画面；几个预览共用一个画面。close 是这个预览不看了。 */
  async acquire(workspaceId: string): Promise<Screen> {
    const udid = await this.ensure(workspaceId);
    let entry = this.booted.get(workspaceId);
    if (!entry || entry.udid !== udid) { entry = { udid, users: 0 }; this.booted.set(workspaceId, entry); }
    clearTimeout(entry.idle);
    entry.users++;
    const current = entry;
    try {
      if (!current.screen) {
        const opening = this.boot(udid).then(() => openSimulatorScreen(udid, this.host.env));
        current.screen = opening;
        // 模拟器被关掉、删掉时画面断了，下次再要重新启动、重开
        void opening.then((screen) => screen.exited).then(() => { if (current.screen === opening) current.screen = undefined; }, () => {});
      }
      const screen = await current.screen;
      let released = false;
      // 每个预览一个外壳：关掉只是不看了，最后一个不看时开始计闲置
      return { ...bind(screen), close: async () => { if (!released) { released = true; this.release(workspaceId, current); } } };
    } catch (error) {
      current.screen = undefined;
      this.release(workspaceId, current);
      throw error;
    }
  }

  private async boot(udid: string): Promise<void> {
    // bootstatus -b：没启动就启动，等到系统起好；已经启动着直接返回
    const booted = await this.xcrun(['bootstatus', udid, '-b'], BOOT_TIMEOUT_MS);
    if (booted.code !== 0) throw new KiteError('模拟器没有启动起来', 503);
  }

  private release(workspaceId: string, entry: Booted): void {
    if (--entry.users > 0) return;
    entry.idle = setTimeout(() => {
      if (this.booted.get(workspaceId) !== entry || entry.users > 0) return;
      void this.shutdown(workspaceId);
    }, IDLE_SHUTDOWN_MS);
    entry.idle.unref();
  }

  /** 关掉工作区的模拟器：画面断开，模拟器关机，编号留着。 */
  async shutdown(workspaceId: string): Promise<void> {
    const entry = this.booted.get(workspaceId);
    this.booted.delete(workspaceId);
    if (entry) clearTimeout(entry.idle);
    await (await entry?.screen?.catch(() => undefined))?.close().catch(() => {});
    const udid = entry?.udid ?? this.host.store.workspaceSimulator(workspaceId);
    if (udid) await this.xcrun(['shutdown', udid]).catch(() => {});
  }

  /**
   * 工作区归档或随项目删掉：删掉这台模拟器和它的编号（之前已随工作区关机，见 shutdown）。编号只在这里删：
   * 流转回来时工作区的记录整个换掉，这张表不动，模拟器接着用。
   */
  async remove(workspaceId: string): Promise<void> {
    const udid = this.host.store.workspaceSimulator(workspaceId);
    if (!udid) return;
    await this.xcrun(['delete', udid]).catch(() => {});
    this.host.store.deleteWorkspaceSimulator(workspaceId);
  }

  async close(): Promise<void> {
    // kited 退出时只断开画面，模拟器留着开机，重启后接着用；闲置的下次启动后按需关
    await Promise.all([...this.booted.values()].map(async (entry) => {
      clearTimeout(entry.idle);
      await (await entry.screen?.catch(() => undefined))?.close().catch(() => {});
    }));
    this.booted.clear();
  }
}

/** 把共享画面的方法绑到它自己身上，外壳替换 close。 */
const bind = (screen: SimulatorScreen): Screen => ({
  capture: (forModel) => screen.capture(forModel), act: (action) => screen.act(action), inspect: () => screen.inspect(),
  info: () => screen.info(), alive: () => screen.alive(), close: () => screen.close(),
});
