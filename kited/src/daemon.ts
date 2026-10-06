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
import { CatalogPublisher } from './catalog-publisher.ts';
import { AccountClient, type AccountLink } from './account-client.ts';
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
  const account = new AccountClient((): AccountLink | undefined => publisher.link());
  const kite = new Kite(store, opts.home, new Bus(), opts, account);
  const publisher: CatalogPublisher = new CatalogPublisher(join(opts.home, 'catalog-publisher.json'), kite);
  // 迁移远程由用户在 App 中操作，工作机定期对照登记表；离线的工作机上线后在下一轮赶上。
  const sync = () => { kite.syncProjects().catch((error: unknown) => console.error(`[项目同步] ${(error as Error).message}`)); };
  const syncTimer = setInterval(sync, PROJECT_SYNC_MS);
  syncTimer.unref();
  sync();
  // kite-net 核验组网身份；随机内部凭据阻止绕过代理伪造同账号请求。
  const proxyToken = crypto.randomUUID();
  const remote = serve(kite, { hostname: '127.0.0.1', port: 0, remote: true, proxyToken });
  const network = new Network({
    dir: join(opts.home, 'tailnet'),
    binary: opts.networkBinary ?? join(import.meta.dir, '../net/bin/kite-net'),
    hostname: `kite-${kite.machine().name.split('.')[0]}`.toLowerCase().replace(/[^a-z0-9-]+/g, '-').replace(/-+$/, '').slice(0, 63),
    port: opts.port || 5483, target: remote.port!, proxyToken,
  });
  const server = serve(kite, { hostname: '127.0.0.1', port: opts.port, network, publisher, accountChanged: sync });
  return {
    url: `http://127.0.0.1:${server.port}`,
    remoteUrl: `http://127.0.0.1:${remote.port}`,
    network,
    kite,
    async stop() {
      clearInterval(syncTimer);
      await publisher.stop();
      await network.stop();
      await kite.shutdown();
      await Promise.all([server.stop(true), remote.stop(true)]);
      store.close();
    },
  };
}
