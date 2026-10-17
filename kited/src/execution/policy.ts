/** Agent 的初始执行授权；宿主内部数据始终排除在模型文件和命令工具之外。 */
import { join } from 'node:path';
import { gitTry } from '../workspace/git.ts';
import { applyExecutionGrants, effectiveExecution, type ExecutionChanges, type ProjectExecution } from './grants.ts';
import { hostPrivatePaths, workspacePolicy, type ExecutionPolicy } from './sandbox.ts';

export async function harnessPolicy(options: {
  cwd: string;
  env: NodeJS.ProcessEnv;
  home: string;
  /** kited 已登记的主仓库，用它解析 Git 元数据，不能相信工作树内被改写的 .git 指针。 */
  repository?: string;
  authFile?: string;
}) {
  const policy = workspacePolicy(options.cwd, options.env);
  const protectedPaths = hostPrivatePaths(options.home);
  if (options.authFile) protectedPaths.push(options.authFile);
  const metadata = await gitTry(options.repository ?? options.cwd, ['rev-parse', '--path-format=absolute', '--git-common-dir']);
  if (metadata.code === 0) policy.read.push(metadata.stdout.trim());
  // Git 元数据只读；快照与采纳继续由可信宿主执行。
  return { ...policy, denyRead: protectedPaths,
    denyWrite: [...protectedPaths, join(options.cwd, '.git'), ...(metadata.code === 0 ? [metadata.stdout.trim()] : [])] };
}

/**
 * 代理的执行策略：基础策略（harnessPolicy）加上实例与项目合成的执行授权。宿主写进工作区的密钥文件（secretFiles 是工作区里的相对路径）
 * 对代理只读：沙箱不许写，patch 拒绝并提示改用密钥请求。
 */
export function agentPolicy(base: ExecutionPolicy, cwd: string, changes: ExecutionChanges, project: ProjectExecution | undefined,
  secretFiles: string[]): ExecutionPolicy {
  const policy = applyExecutionGrants(base, cwd, effectiveExecution(changes, project));
  if (!secretFiles.length) return policy;
  const files = secretFiles.map((path) => join(cwd, path));
  return { ...policy, denyWrite: [...policy.denyWrite ?? [], ...files], secretFiles: files };
}
