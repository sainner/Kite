/** 每次执行独立启动，保留上游 CLI 的代理和生命周期管理，但不接受隔离能力降级。 */
import { SandboxManager } from '@anthropic-ai/sandbox-runtime';

const dependencies = await SandboxManager.checkDependenciesAsync();
const problems = [...dependencies.errors, ...dependencies.warnings];
if (problems.length) {
  console.error(`沙箱依赖不可用，命令未启动：${problems.join('；')}`);
  process.exit(1);
}
await import(new URL('./cli.js', import.meta.resolve('@anthropic-ai/sandbox-runtime')).href);
