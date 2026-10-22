/**
 * 在这台工作机上为某个项目建工作区之前的环境检查：只读本机状态，不访问模型服务，也不登录。
 * 项目自己的工具链以 setup 的结果为准；凭据引用的可领取性要等 setup 能声明所需引用后再检查。
 * 自动换机挑目标时还看项目声明的环境需求与有没有电池，见 docs/分布式架构.md「执行权」。
 */
import { existsSync, readdirSync, statfsSync } from 'node:fs';
import { arch, release } from 'node:os';
import { dirname, join } from 'node:path';

import type { ApiKey } from './account-data/credentials.ts';
import { vendorOfModel, type ModelVendor } from './agents/models.ts';
import { readSubscriptionCredentials } from './harness/auth.ts';
import { deepseekKey } from './harness/adapters.ts';
import { userHome } from './paths.ts';
import { readClaudeLogin } from './model-accounts.ts';
import type { Checkout, Machine } from './model.ts';
import { systemCommand } from './system-command.ts';
import { pairedDevices } from './preview/devices.ts';

export type LoginStatus = { status: 'ready' } | { status: 'missing' | 'invalid'; message: string };

/** 项目可以为自动换机声明的环境需求：完整的 Xcode，连着的 iPhone 或 iPad。 */
export const HANDOVER_NEEDS = ['xcode', 'iosDevice'] as const;
export type HandoverNeed = typeof HANDOVER_NEEDS[number];

export interface Environment {
  machine: Pick<Machine, 'id' | 'name'>;
  platform: { os: NodeJS.Platform; version: string; arch: string };
  /** 两家订阅在这台工作机上的登录与 DeepSeek 的 API Key；ready 只表示凭据在且未过期，不保证额度或余额可用。 */
  logins: Record<ModelVendor['login'], LoginStatus>;
  /** 剩余空间（字节）：worktrees 是 Kite 放工作树的卷，checkout 是已有检出或将要 clone 到的卷。 */
  disk: { worktrees: number; checkout: number };
  /** 这台工作机上该项目已有的检出；没有时建工作区会先 clone 到数据目录。 */
  checkout: Pick<Checkout, 'id' | 'path'> | null;
  /** 带电池（笔记本）；自动换机有几台合适时优先不带电池的。 */
  battery: boolean;
  /** 问到的换机环境需求在这台工作机上是否满足；没问的不查。 */
  needs: Partial<Record<HandoverNeed, boolean>>;
}

/** 低于这个剩余空间不建工作区。 */
export const MIN_FREE_BYTES = 1024 ** 3;

/** 某个模型在这台工作机上要的登录，按厂商定。 */
export const modelLogin = (environment: Environment, model: string): LoginStatus => environment.logins[vendorOfModel(model).login];
/** 工作树与检出所在的卷都还够用。 */
export const diskEnough = (environment: Environment): boolean => Math.min(environment.disk.worktrees, environment.disk.checkout) >= MIN_FREE_BYTES;

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
  const { code, stdout } = await systemCommand(['/usr/bin/sw_vers', '-productVersion']);
  return code === 0 && stdout.trim() ? `macOS ${stdout.trim()}` : release();
}

/** 有没有电池随硬件不变，只读一次。 */
let battery: Promise<boolean> | undefined;
const hasBattery = (): Promise<boolean> => battery ??= readBattery();

async function readBattery(): Promise<boolean> {
  if (process.platform === 'linux') {
    try { return readdirSync('/sys/class/power_supply').some((name) => name.startsWith('BAT')); } catch { return false; }
  }
  if (process.platform !== 'darwin') return false;
  const { code, stdout } = await systemCommand(['/usr/bin/pmset', '-g', 'batt']);
  return code === 0 && stdout.includes('InternalBattery');
}

/** xcode-select、xcrun 按 HOME 与 DEVELOPER_DIR 找选中的开发者目录。 */
const xcodeEnv = () => ({ PATH: '/usr/bin:/bin', HOME: userHome(), ...(process.env.DEVELOPER_DIR ? { DEVELOPER_DIR: process.env.DEVELOPER_DIR } : {}) });
const xcode = (command: string[], timeoutMs: number) => systemCommand(command, { timeoutMs, env: xcodeEnv() });

/** 选中的开发者目录是完整的 Xcode：只装了命令行工具时没有 xcodebuild。 */
async function xcodeReady(): Promise<boolean> {
  if (process.platform !== 'darwin') return false;
  const { code, stdout } = await xcode(['/usr/bin/xcode-select', '-p'], 5_000);
  return code === 0 && !!stdout.trim() && existsSync(join(stdout.trim(), 'usr', 'bin', 'xcodebuild'));
}

/** 有已配对、此刻连得上（USB 或同一网络）的 iPhone 或 iPad 真机，见 preview/devices.ts。 */
async function iosDeviceReady(): Promise<boolean> {
  if (process.platform !== 'darwin' || !await xcodeReady()) return false;
  return (await pairedDevices(xcodeEnv())).some((device) => device.connected);
}

const needChecks: Record<HandoverNeed, () => Promise<boolean>> = { xcode: xcodeReady, iosDevice: iosDeviceReady };

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

async function deepseekLogin(apiKeys: () => Promise<ApiKey[]>): Promise<LoginStatus> {
  try {
    return await deepseekKey(apiKeys) ? { status: 'ready' } : { status: 'missing', message: 'Kite 账号的凭据里没有 DeepSeek 的 API Key' };
  } catch (error) { return { status: 'invalid', message: `读不到 DeepSeek 的 API Key：${(error as Error).message}` }; }
}

/** checkout 是本机已有的检出，检出都在数据目录的 repos 下。needs 是要查的换机环境需求；apiKeys 是账号里的 API 凭据。 */
export async function readEnvironment(home: string, machine: Machine, checkout: Checkout | undefined, needs: HandoverNeed[],
  apiKeys: () => Promise<ApiKey[]>): Promise<Environment> {
  const [version, chatgpt, claude, deepseek, onBattery, met] = await Promise.all([systemVersion(), chatgptLogin(home), claudeLogin(),
    deepseekLogin(apiKeys), hasBattery(), Promise.all(needs.map((need) => needChecks[need]()))]);
  return {
    machine: { id: machine.id, name: machine.name },
    platform: { os: process.platform, version, arch: arch() },
    logins: { chatgpt, claude, deepseek },
    disk: { worktrees: freeBytes(join(home, 'worktrees')), checkout: freeBytes(join(home, 'repos')) },
    checkout: checkout ? { id: checkout.id, path: checkout.path } : null,
    battery: onBattery,
    needs: Object.fromEntries(needs.map((need, index) => [need, met[index]])),
  };
}
