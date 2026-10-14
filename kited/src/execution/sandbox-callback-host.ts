/**
 * 与 sandbox-host 相同的文件系统隔离，但名单外的主机交给放行回调：上游只在注册了回调时才不直接拒绝名单外的主机，
 * 它的 CLI 不注册回调，所以这里照 CLI 的启动与收尾自己接一遍。不带 --ask 时一律放行（项目级网络授权落地前的
 * .kite/setup、全放行模式）；带 --ask 时经宿主在控制目录里开的 Unix socket 逐个询问，一行一条 JSON。
 * 本机地址在问之前就拒掉，见 local。
 */
import { spawn, type ChildProcess } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { BlockList, createConnection, isIP } from 'node:net';
import { networkInterfaces } from 'node:os';
import { SandboxManager, SandboxRuntimeConfigSchema, type SandboxAskCallback } from '@anthropic-ai/sandbox-runtime';

const args = process.argv.slice(2);
const [flag, settings] = args;
const ask = args[2] === '--ask' ? args[3] : undefined;
const [commandFlag, command] = args.slice(ask === undefined ? 2 : 4);
if (flag !== '--settings' || !settings || commandFlag !== '-c' || command === undefined) {
  console.error('用法：sandbox-callback-host --settings <配置> [--ask <socket>] -c <命令>');
  process.exit(1);
}
const dependencies = await SandboxManager.checkDependenciesAsync();
const problems = [...dependencies.errors, ...dependencies.warnings];
if (problems.length) {
  console.error(`沙箱依赖不可用，命令未启动：${problems.join('；')}`);
  process.exit(1);
}

const localAddresses = new BlockList();
for (const [network, prefix] of [['127.0.0.0', 8], ['0.0.0.0', 8], ['169.254.0.0', 16]] as const) localAddresses.addSubnet(network, prefix, 'ipv4');
for (const [network, prefix] of [['::1', 128], ['::', 128], ['fe80::', 10]] as const) localAddresses.addSubnet(network, prefix, 'ipv6');
for (const entry of Object.values(networkInterfaces()).flat()) {
  // 链路本地地址可能带 %接口 后缀，网段已整体覆盖；个别解析不了的跳过，回环与固定网段仍然生效。
  if (entry) try { localAddresses.addAddress(entry.address.split('%')[0]!, entry.family === 'IPv4' ? 'ipv4' : 'ipv6'); } catch { /* 跳过 */ }
}

/**
 * 回环、未指定、链路本地与本机自己的地址：kited 的本机接口只监听回环、信任回环客户端，不能经回调放行。
 * 上游的解析地址检查只管主机名，IP 字面量与 localhost 这类名字原样放过，所以在这里先拒；数字形式的 IPv4 先规范化。
 */
function local(host: string): boolean {
  const name = host.toLowerCase().replace(/^\[|\]$/g, '');
  if (name === 'localhost' || name.endsWith('.localhost')) return true;
  let address = name;
  try { address = new URL(`http://${isIP(name) === 6 ? `[${name}]` : name}`).hostname.replace(/^\[|\]$/g, ''); } catch { /* 解析不了的交给上游拒绝。 */ }
  const mapped = /^::ffff:(\d+\.\d+\.\d+\.\d+)$/.exec(address)?.[1];
  if (mapped) address = mapped;
  const family = isIP(address);
  return family !== 0 && localAddresses.check(address, family === 4 ? 'ipv4' : 'ipv6');
}

/** 宿主的回答按请求 ID 对上；连接断开后一律拒绝。 */
function asker(path: string): SandboxAskCallback {
  const socket = createConnection(path);
  const pending = new Map<number, (allow: boolean) => void>();
  let closed = false;
  let buffer = '';
  let next = 0;
  socket.setEncoding('utf8').on('data', (chunk: string) => {
    buffer += chunk;
    for (let end = buffer.indexOf('\n'); end >= 0; end = buffer.indexOf('\n')) {
      const { id, allow } = JSON.parse(buffer.slice(0, end)) as { id: number; allow: boolean };
      buffer = buffer.slice(end + 1);
      pending.get(id)?.(allow === true);
      pending.delete(id);
    }
  });
  const close = () => {
    closed = true;
    for (const resolve of pending.values()) resolve(false);
    pending.clear();
  };
  socket.on('error', close).on('close', close);
  socket.unref();
  return ({ host, port }) => {
    if (closed) return Promise.resolve(false);
    const id = next++;
    return new Promise((resolve) => {
      pending.set(id, resolve);
      socket.write(`${JSON.stringify({ id, host, port: port ?? null })}\n`);
    });
  };
}

let child: ChildProcess | undefined;
try {
  const config = SandboxRuntimeConfigSchema.parse(JSON.parse(readFileSync(settings, 'utf8')));
  const decide = ask === undefined ? async () => true : asker(ask);
  await SandboxManager.initialize(config, async (target) => !local(target.host) && decide(target));
  child = spawn(await SandboxManager.wrapWithSandbox(command), { shell: true, stdio: 'inherit' });
} catch (error) {
  console.error(`沙箱启动失败，命令未启动：${error instanceof Error ? error.message : String(error)}`);
  process.exit(1);
}
child.on('exit', (code, signal) => {
  SandboxManager.cleanupAfterCommand();
  if (signal) process.exit(signal === 'SIGINT' || signal === 'SIGTERM' ? 0 : 1);
  process.exit(code ?? 0);
});
child.on('error', (error) => {
  console.error(`命令启动失败：${error.message}`);
  process.exit(1);
});
process.on('SIGINT', () => child?.kill('SIGINT'));
process.on('SIGTERM', () => child?.kill('SIGTERM'));
