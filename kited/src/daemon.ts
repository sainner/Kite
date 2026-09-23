/**
 * 启动一个 kited：打开数据库，接上会话编排和 HTTP 接口。main.ts 用它，测试也在本进程里用它。
 * Claude Code 子进程继承本进程的环境变量。
 */
import { mkdirSync } from 'node:fs';
import { join } from 'node:path';
import { Bus } from './events.ts';
import { serve } from './http.ts';
import { Kite } from './kite.ts';
import { Store } from './store.ts';

export interface Daemon {
  url: string;
  kite: Kite;
  /** 关掉所有 Claude Code 进程和 HTTP 服务，关闭数据库。 */
  stop(): Promise<void>;
}

export function startDaemon(opts: { home: string; port: number }): Daemon {
  mkdirSync(opts.home, { recursive: true });
  const store = new Store(join(opts.home, 'kite.db'));
  const kite = new Kite(store, opts.home, new Bus());
  const server = serve(kite, opts.port);
  return {
    url: `http://127.0.0.1:${server.port}`,
    kite,
    async stop() {
      await kite.shutdown();
      await server.stop(true);
      store.close();
    },
  };
}
