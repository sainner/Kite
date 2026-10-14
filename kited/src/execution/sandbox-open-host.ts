/**
 * 与 sandbox-host 相同的文件系统隔离，但名单外的主机一律放行：上游只在注册了放行回调时才不拒绝名单外的主机，
 * 它的 CLI 不注册回调，所以这里照 CLI 的启动与收尾自己接一遍。用于项目级网络授权落地之前的 .kite/setup；
 * 回环、本机地址与云元数据等仍由上游的解析地址检查拦下。
 */
import { spawn, type ChildProcess } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { SandboxManager, SandboxRuntimeConfigSchema } from '@anthropic-ai/sandbox-runtime';

const [flag, settings, commandFlag, command] = process.argv.slice(2);
if (flag !== '--settings' || !settings || commandFlag !== '-c' || command === undefined) {
  console.error('用法：sandbox-open-host --settings <配置> -c <命令>');
  process.exit(1);
}
const dependencies = await SandboxManager.checkDependenciesAsync();
const problems = [...dependencies.errors, ...dependencies.warnings];
if (problems.length) {
  console.error(`沙箱依赖不可用，命令未启动：${problems.join('；')}`);
  process.exit(1);
}
let child: ChildProcess | undefined;
try {
  const config = SandboxRuntimeConfigSchema.parse(JSON.parse(readFileSync(settings, 'utf8')));
  await SandboxManager.initialize(config, async () => true);
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
