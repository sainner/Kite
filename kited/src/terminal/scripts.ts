/**
 * 预置脚本（docs/实例操作.md「预置脚本」）：项目 .kite/scripts/ 下的可执行文件，文件名就是脚本名，由终端在 PTY 里运行，不加沙箱。
 * 清单不进工具定义，每次调用时在工作区的工作树里找；代理起的与这台工作机检出主线上的同名文件一致才直接运行，否则经审批，
 * 「允许并记住」按内容记在代理实例上。每个工作区的每个脚本分一段端口，第一个经 PORT 交给脚本。
 */
import { accessSync, constants, readdirSync, readFileSync, statSync } from 'node:fs';
import { connect } from 'node:net';
import { join } from 'node:path';
import { z } from 'zod';
import { KiteError } from '../errors.ts';
import type { Checkout, PluginInstance } from '../model.ts';
import type { Store } from '../store.ts';
import { gitTry } from '../workspace/git.ts';
import { mainBranch } from '../workspace/mainline.ts';

export const SCRIPTS_DIR = '.kite/scripts';
/** 一段端口的个数。分配范围避开常见的开发端口（3000、5173、8080 这类）和 macOS 的临时端口（49152 起）。 */
const PORT_BLOCK = 10;
const PORT_FIRST = 41000, PORT_END = 49000;

const isFile = (path: string) => { try { return statSync(path).isFile(); } catch { return false; } };

/** 工作树里现有的预置脚本，按名字排；以点开头的和目录不算。 */
export function listScripts(cwd: string): string[] {
  let names: string[];
  try { names = readdirSync(join(cwd, SCRIPTS_DIR)); } catch { return []; }
  return names.filter((name) => !name.startsWith('.') && isFile(join(cwd, SCRIPTS_DIR, name))).sort();
}

export interface Script { name: string; path: string; content: string }

/** 按名字找预置脚本并读出内容；找不到时错误里列出现有的，不可执行时说明怎么改。 */
export function findScript(cwd: string, name: string): Script {
  const available = listScripts(cwd);
  if (!available.includes(name)) {
    throw new KiteError(available.length ? `没有预置脚本「${name}」，现有：${available.join('、')}`
      : `没有预置脚本「${name}」：工作区的 ${SCRIPTS_DIR}/ 下还没有脚本`, 404);
  }
  const path = join(cwd, SCRIPTS_DIR, name);
  try { accessSync(path, constants.X_OK); }
  catch { throw new KiteError(`预置脚本「${name}」不可执行，先 chmod +x ${SCRIPTS_DIR}/${name}`, 409); }
  return { name, path, content: readFileSync(path, 'utf8') };
}

/** 这台工作机检出主线上的同名脚本；主线上没有（或检出不在分支上）时为 null。 */
export async function mainlineScript(checkout: Pick<Checkout, 'path'>, name: string): Promise<string | null> {
  try {
    const result = await gitTry(checkout.path, ['show', `refs/heads/${await mainBranch(checkout)}:${SCRIPTS_DIR}/${name}`]);
    return result.code === 0 ? result.stdout : null;
  } catch { return null; }
}

/** 代理实例上「允许并记住」过的脚本内容的摘要（contentHash）。 */
export const trustedScripts = (instance: Pick<PluginInstance, 'config'>): string[] =>
  z.array(z.string()).catch([]).parse(instance.config.trustedScripts);

/** 端口上有没有程序在监听：连得上本机回环（127.0.0.1 或 ::1）就算占着。 */
function occupied(port: number): Promise<boolean> {
  const attempt = (host: string) => new Promise<boolean>((resolve) => {
    const socket = connect({ host, port, timeout: 500 });
    const done = (value: boolean) => { socket.destroy(); resolve(value); };
    socket.once('connect', () => done(true));
    socket.once('timeout', () => done(false));
    socket.once('error', () => done(false));
  });
  return Promise.all([attempt('127.0.0.1'), attempt('::1')]).then((results) => results.some(Boolean));
}
const blockFree = async (first: number) =>
  !(await Promise.all(Array.from({ length: PORT_BLOCK }, (_, i) => occupied(first + i)))).some(Boolean);

let allocating: Promise<unknown> = Promise.resolve();

/**
 * 工作区的这个脚本的端口段，返回第一个端口：分过且没被别的程序占着就用原来那段，否则从还没分出去的段里找一段空着的记下。
 * 几个工作区同时起脚本时依次分，不会分到同一段。
 */
export function allocateScriptPorts(store: Pick<Store, 'scriptPort' | 'scriptPorts' | 'setScriptPort'>, workspaceId: string, name: string): Promise<number> {
  const next = allocating.then(async () => {
    const saved = store.scriptPort(workspaceId, name);
    if (saved !== undefined && await blockFree(saved)) return saved;
    const taken = new Set(store.scriptPorts());
    for (let first = PORT_FIRST; first + PORT_BLOCK <= PORT_END; first += PORT_BLOCK) {
      if (taken.has(first) || !await blockFree(first)) continue;
      store.setScriptPort(workspaceId, name, first);
      return first;
    }
    throw new KiteError('没有空闲的端口段可以分给预置脚本', 503);
  });
  allocating = next.catch(() => {});
  return next;
}
