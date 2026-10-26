/** Agent 的初始执行授权；宿主内部数据始终排除在模型文件和命令工具之外。 */
import { join } from 'node:path';
import { matchesDomainPatternWithPort } from '@anthropic-ai/sandbox-runtime/dist/sandbox/domain-pattern.js';
import { gitTry } from '../workspace/git.ts';
import { applyExecutionGrants, effectiveExecution, type ExecutionChanges, type ProjectExecution } from './grants.ts';
import { exactPath, hostPrivatePaths, workspacePolicy, type ExecutionPolicy } from './sandbox.ts';

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
 * 再放行工作目录以外的只读位置：skill 的文件夹（SkillCatalog 的 readable），代理要能读里面的文件、跑里面的脚本；检查日志（见 check.ts）。
 * 路径里带通配字符的沙箱不收，跳过：那个位置读不到，别的工具照常能用。
 */
export function withReads(policy: ExecutionPolicy, readable: string[]): ExecutionPolicy {
  return { ...policy, read: [...policy.read, ...readable.filter(exactPath)] };
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

/**
 * 不经沙箱代理、由宿主代为联网的工具（web_fetch）对照网络许可，口径与沙箱代理相同：项目禁止的拒绝，许可里的放行，其余按审批模式问。
 * 上游的判断（filterNetworkRequest）没有导出，匹配规则用它的。
 */
export function networkVerdict(policy: ExecutionPolicy, host: string, port: number): 'denied' | 'allowed' | 'ask' {
  const matches = (patterns: readonly string[]) => patterns.some((pattern) => matchesDomainPatternWithPort(host, port, pattern));
  if (matches(policy.deniedNetwork ?? [])) return 'denied';
  return matches(policy.network) ? 'allowed' : 'ask';
}
