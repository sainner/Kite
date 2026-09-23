/**
 * kited：跑在工作机上的 Kite 后台服务。
 * KITE_HOME（默认 ~/.kite）放数据库、会话工作树、初始化日志；KITE_PORT（默认 5483）是本机 HTTP 端口。
 * 启动 Claude Code 用的是 kited 自己的环境变量，登录、设置、插件都和在终端里裸跑一样。
 */
import { mkdirSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { Bus } from './events.ts';
import { serve } from './http.ts';
import { Kite } from './kite.ts';
import { Store } from './store.ts';

const home = process.env.KITE_HOME ?? join(homedir(), '.kite');
const port = Number(process.env.KITE_PORT ?? 5483);
mkdirSync(home, { recursive: true });

const store = new Store(join(home, 'kite.db'));
const kite = new Kite(store, home, new Bus());
const server = serve(kite, port);
console.log(`kited 在 http://127.0.0.1:${server.port}，数据在 ${home}`);

let stopping = false;
async function stop() {
  if (stopping) return;
  stopping = true;
  await kite.shutdown();
  await server.stop(true);
  store.close();
  process.exit(0);
}
process.on('SIGINT', stop);
process.on('SIGTERM', stop);
