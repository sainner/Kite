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
  /** 组网控制服务器，省略时用 Tailscale 官方服务。 */
  controlURL?: string;
}

export function startDaemon(opts: DaemonOptions): Daemon {
  mkdirSync(opts.home, { recursive: true });
  const store = new Store(join(opts.home, 'kite.db'));
  const kite = new Kite(store, opts.home, new Bus(), opts);
  // 远程监听只绑回环地址，由 kite-net 从组网转发进来；它只认配对令牌。
  const remote = serve(kite, { hostname: '127.0.0.1', port: 0, remote: true });
  const network = new Network({
    dir: join(opts.home, 'tailnet'),
    binary: opts.networkBinary ?? join(import.meta.dir, '../net/bin/kite-net'),
    hostname: `kite-${kite.machine().name.split('.')[0]}`.toLowerCase().replace(/[^a-z0-9-]+/g, '-').replace(/-+$/, '').slice(0, 63),
    port: opts.port || 5483, target: remote.port!, controlURL: opts.controlURL,
  });
  const server = serve(kite, { hostname: '127.0.0.1', port: opts.port, network });
  return {
    url: `http://127.0.0.1:${server.port}`,
    remoteUrl: `http://127.0.0.1:${remote.port}`,
    network,
    kite,
    async stop() {
      await network.stop();
      await kite.shutdown();
      await Promise.all([server.stop(true), remote.stop(true)]);
      store.close();
    },
  };
}
