/**
 * 启动一个 kited：打开数据库，接上会话编排和 HTTP 接口。main.ts 用它，测试也在本进程里用它。
 * 执行后端由会话自身的 runtime 决定。
 */
import { mkdirSync } from 'node:fs';
import { join } from 'node:path';
import { Bus } from './events.ts';
import { serve } from './http.ts';
import { Kite } from './kite.ts';
import { Network } from './network.ts';
import { Store } from './store.ts';
import type { RuntimeOptions } from './runtime.ts';

const PROJECT_SYNC_MS = 5 * 60_000;

export interface Daemon {
  url: string;
  /** 远程监听的回环地址，kite-net 把组网连接转到这里。 */
  remoteUrl: string;
  network: Network;
  kite: Kite;
  /** 停止准备和运行中的会话、HTTP 服务，再关闭数据库。 */
  stop(): Promise<void>;
}

export interface DaemonOptions extends RuntimeOptions {
  home: string;
  port: number;
  /** kite-net 可执行文件；默认用 kited/net/bin 中构建出的那个。 */
  networkBinary?: string;
}

export function startDaemon(opts: DaemonOptions): Daemon {
  mkdirSync(opts.home, { recursive: true });
  const store = new Store(join(opts.home, 'kite.db'));
  const kite = new Kite(store, opts.home, new Bus(), opts);
  // 项目登记表随账号级数据同步，工作机定期对照：改了远程的检出跟上，没有远程的项目从别的工作机快进主线；离线的上线后在下一轮赶上。
  // 执行权随项目同步一起核对：别的机器已接管的工作区在这里冻结。
  const sync = () => kite.syncProjects().catch((error: unknown) => console.error(`[项目同步] ${(error as Error).message}`))
    .then(() => kite.syncLeases());
  const syncTimer = setInterval(() => void sync(), PROJECT_SYNC_MS);
  syncTimer.unref();
  void sync();
  // kite-net 核验组网身份；随机内部凭据阻止绕过代理伪造同账号请求。
  const proxyToken = crypto.randomUUID();
  /** 最近一次有预告的离开：登出、重启、关机时 SIGTERM 跟着预告来，停服务之前等它交完。 */
  let departure: Promise<void> | undefined;
  const remote = serve(kite, { hostname: '127.0.0.1', port: 0, remote: true, proxyToken });
  const network = new Network({
    dir: join(opts.home, 'tailnet'),
    binary: opts.networkBinary ?? join(import.meta.dir, '../net/bin/kite-net'),
    hostname: `kite-${kite.machine().name.split('.')[0]}`.toLowerCase().replace(/[^a-z0-9-]+/g, '-').replace(/-+$/, '').slice(0, 63),
    port: opts.port || 5483, target: remote.port!, proxyToken,
    // 系统给睡眠留的时间约 30 秒，kite-net 最多等 25 秒；登出、重启、关机时 launchd 发 SIGTERM 后最多等 30 秒（安装的 ExitTimeOut），
    // stop 先等交接收尾。交接都在 20 秒内收尾。
    power: { leaving: () => departure = kite.leaving(Date.now() + 20_000), returned: () => void kite.returned() },
  });
  const server = serve(kite, { hostname: '127.0.0.1', port: opts.port, network });
  kite.listening({ url: `http://127.0.0.1:${server.port}`, network });
  kite.startAccountData();
  // 上次被 kited 退出打断的会话接着做；Line 的 monitor 读汇总时等它们都打开（见 Kite.summary）。
  void kite.continueInterrupted();
  kite.openPendingIdle();
  kite.monitor.start();
  kite.monitors.reconcile();
  return {
    url: `http://127.0.0.1:${server.port}`,
    remoteUrl: `http://127.0.0.1:${remote.port}`,
    network,
    kite,
    async stop() {
      clearInterval(syncTimer);
      await departure?.catch(() => {});
      // 组网在会话停下之后再停：回合里调用别的工作机（如 Line 的工具）经 kite-net，先停会让这些调用报错。
      try { await kite.shutdown(); } finally { await network.stop(); }
      await Promise.all([server.stop(true), remote.stop(true)]);
      store.close();
    },
  };
}
