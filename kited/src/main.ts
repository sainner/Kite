/**
 * kited：跑在工作机上的 Kite 后台服务。
 * KITE_HOME（默认 ~/.kite）放数据库、会话工作树、初始化日志；KITE_PORT（默认 5483）是本机 HTTP 端口。
 * 启动 Claude Code 用的是 kited 自己的环境变量，登录、设置、插件都和在终端里裸跑一样。
 */
import { homedir } from 'node:os';
import { join } from 'node:path';
import { startDaemon } from './daemon.ts';

const home = process.env.KITE_HOME ?? join(homedir(), '.kite');
const daemon = startDaemon({ home, port: Number(process.env.KITE_PORT ?? 5483) });
console.log(`kited 在 ${daemon.url}，数据在 ${home}`);

let stopping = false;
async function stop() {
  if (stopping) return;
  stopping = true;
  try {
    await daemon.stop();
  } catch (e) {
    // 信号处理不会等这个 Promise，出错要自己接住，否则成了没人处理的拒绝
    console.error(`kited 停止时出错：${(e as Error).message}`);
    process.exit(1);
  }
  process.exit(0);
}
process.on('SIGINT', () => void stop());
process.on('SIGTERM', () => void stop());
