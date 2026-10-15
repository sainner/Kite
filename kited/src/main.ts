/**
 * kited：跑在工作机上的 Kite 后台服务。
 * KITE_HOME（默认 ~/.kite）放数据库、会话工作树、初始化日志；KITE_PORT（默认 5483）是本机 HTTP 端口。
 * KITE_GITHUB_CLIENT_ID 换掉绑定 GitHub 用的 OAuth App 客户端 ID，默认是 Kite 自己的。
 * 组网用 Tailscale 登录（App 首次配置时，或 kite net up 给出的登录地址），随后可用 kite net 管理开关。
 * 新会话默认使用 harness 与 Kite 独立授权的 ChatGPT 凭据，旧会话保留各自的 runtime。
 */
import { homedir } from 'node:os';
import { join } from 'node:path';
import { startDaemon } from './daemon.ts';

const home = process.env.KITE_HOME ?? join(homedir(), '.kite');
// 安装版 macOS 服务把凭据密钥放登录钥匙串（安装脚本设 KITE_KEYCHAIN），开发与测试放数据目录。
const daemon = startDaemon({ home, port: Number(process.env.KITE_PORT ?? 5483), keychain: process.platform === 'darwin' && process.env.KITE_KEYCHAIN === '1' });
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
