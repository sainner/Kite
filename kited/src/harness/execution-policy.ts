/** harness 的初始授权；宿主内部数据始终排除在模型文件和命令工具之外。 */
import { join } from 'node:path';
import { gitTry } from '../git.ts';
import { hostPrivatePaths, workspacePolicy } from '../sandbox.ts';

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
