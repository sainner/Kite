import { homedir } from 'node:os';
import { isAbsolute, join, relative, sep } from 'node:path';

/** 用户主目录取进程环境里的 HOME：Bun 的 os.homedir() 不随运行中改过的 HOME 变化，测试的隔离环境靠它。 */
export const userHome = (): string => process.env.HOME || homedir();

/** 项目在这台工作机的检出：<home>/repos/<项目>.git，Kite 自己的裸仓库。 */
export const checkoutPath = (home: string, projectId: string): string => join(home, 'repos', `${projectId}.git`);

/** 工作区的工作树：<home>/worktrees/<项目>/<工作区>。新建和流转还原都放这里。 */
export const worktreePath = (home: string, projectId: string, workspaceId: string): string => join(home, 'worktrees', projectId, workspaceId);

/** 工作区 setup 的日志。 */
export const setupLogPath = (home: string, workspaceId: string): string => join(home, 'workspaces', workspaceId, 'setup.log');

/** 文件树里的相对路径：不含绝对路径、空段、. 或 ..；符号链接由调用方另行检查。 */
export function safePath(path: string): boolean {
  return !!path && !path.startsWith('/') && !path.split('/').some((part) => part === '' || part === '.' || part === '..');
}

/** path 在 root 里面，或就是 root；调用方负责解析符号链接。 */
export function within(path: string, root: string): boolean {
  const r = relative(root, path);
  // 只认 .. 这一段本身：「..data」这样的名字是 root 里面的文件夹。
  return r === '' || (r !== '..' && !r.startsWith(`..${sep}`) && !isAbsolute(r));
}
