/**
 * 在这台工作机上为某个项目建工作区之前的环境检查：只读本机状态，不访问模型服务，也不登录。
 * 项目自己的工具链以 setup 的结果为准；凭据引用的可领取性要等 setup 能声明所需引用后再检查。
 */
import { existsSync, statfsSync } from 'node:fs';
import { arch, release } from 'node:os';
import { dirname, join } from 'node:path';
import { defaultClonePath, userHome } from './paths.ts';
import { readSubscriptionCredentials } from './harness/auth.ts';
import { readClaudeLogin } from './model-accounts.ts';
import type { Checkout, Machine } from './model.ts';

export type LoginStatus = { status: 'ready' } | { status: 'missing' | 'invalid'; message: string };

export interface Environment {
  machine: Pick<Machine, 'id' | 'name'>;
  platform: { os: NodeJS.Platform; version: string; arch: string };
  /** 两家订阅在这台工作机上的登录；ready 只表示凭据在且未过期，不保证额度可用。 */
  logins: { chatgpt: LoginStatus; claude: LoginStatus };
  /** 剩余空间（字节）：worktrees 是 Kite 放工作树的卷，checkout 是已有检出或将要 clone 到的卷。 */
  disk: { worktrees: number; checkout: number };
  /** 这台工作机上该项目已有的检出；没有时建工作区会先 clone 到 clonePath。 */
  checkout: Pick<Checkout, 'id' | 'path'> | null;
  clonePath?: string;
}

/** 低于这个剩余空间不建工作区。 */
export const MIN_FREE_BYTES = 1024 ** 3;

function freeBytes(path: string): number {
  let existing = path;
  while (!existsSync(existing) && dirname(existing) !== existing) existing = dirname(existing);
  const stats = statfsSync(existing);
  return stats.bavail * stats.bsize;
}

/** 系统版本在进程生命期里不变，只读一次。 */
let version: Promise<string> | undefined;
const systemVersion = (): Promise<string> => version ??= readSystemVersion();

async function readSystemVersion(): Promise<string> {
  if (process.platform !== 'darwin') return release();
  const child = Bun.spawn(['/usr/bin/sw_vers', '-productVersion'], { env: { PATH: '/usr/bin:/bin' }, stdout: 'pipe', stderr: 'ignore' });
  const text = (await new Response(child.stdout).text()).trim();
  return (await child.exited) === 0 && text ? `macOS ${text}` : release();
}

async function chatgptLogin(home: string): Promise<LoginStatus> {
  const file = join(home, 'auth', 'chatgpt', 'auth.json');
  if (!existsSync(file)) return { status: 'missing', message: 'ChatGPT 尚未在这台工作机登录' };
  try { await readSubscriptionCredentials(file); return { status: 'ready' }; }
  catch (error) { return { status: 'invalid', message: (error as Error).message }; }
}

async function claudeLogin(): Promise<LoginStatus> {
  try {
    return await readClaudeLogin() ? { status: 'ready' } : { status: 'missing', message: 'Claude 尚未在这台工作机登录' };
  } catch (error) { return { status: 'invalid', message: (error as Error).message }; }
}

/** checkout 是本机已有的检出；没有时 remote 是项目的归一化远程，用来算默认 clone 位置。 */
export async function readEnvironment(home: string, machine: Machine, checkout: Checkout | undefined, remote?: string): Promise<Environment> {
  const clonePath = checkout ? undefined : remote ? defaultClonePath(remote) : undefined;
  const [version, chatgpt, claude] = await Promise.all([systemVersion(), chatgptLogin(home), claudeLogin()]);
  return {
    machine: { id: machine.id, name: machine.name },
    platform: { os: process.platform, version, arch: arch() },
    logins: { chatgpt, claude },
    disk: { worktrees: freeBytes(join(home, 'worktrees')), checkout: freeBytes(checkout?.path ?? clonePath ?? userHome()) },
    checkout: checkout ? { id: checkout.id, path: checkout.path } : null,
    ...(clonePath ? { clonePath } : {}),
  };
}
