/**
 * 预览里 Mac App 的窗口（docs/实例操作.md「预览」）：本工作区终端里起的、有窗口的 App。终端扫描端口时一并找出进程树里有窗口的 App，
 * 预览按 App 的路径找它此刻的进程，经 kite-window 只截它的窗口、只向它发输入（见 helper-screen.ts、kite-window.m）。
 */
import { z } from 'zod';
import { systemCommand } from '../system-command.ts';
import { windowHelper } from './helper-screen.ts';

const appSchema = z.object({ pid: z.number().int(), name: z.string(), path: z.string() });
export type AppProcess = z.infer<typeof appSchema>;

/** 辅助程序编译不了（没有 Xcode 命令行工具）时不再每次扫描都去编，kited 重启前都当没有 App。 */
let unavailable = false;

/** 这些进程里有窗口的 App；不是 Mac 或编不出辅助程序时为空。 */
export async function listApps(pids: number[], env: Record<string, string>): Promise<AppProcess[]> {
  if (process.platform !== 'darwin' || unavailable || !pids.length) return [];
  let binary: string;
  try { binary = await windowHelper(env); } catch { unavailable = true; return []; }
  const { stdout } = await systemCommand([binary, 'list', ...pids.map(String)], { env, timeoutMs: 5000 });
  return stdout.split('\n').filter(Boolean).flatMap((line) => {
    try { return [appSchema.parse(JSON.parse(line))]; } catch { return []; }
  });
}
