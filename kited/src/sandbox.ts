/** 工作机共用的沙箱启动适配；策略由宿主决定，每次执行使用独立的上游代理与配置。 */
import { existsSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from 'node:fs';
import { homedir, tmpdir } from 'node:os';
import { dirname, isAbsolute, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import type { SandboxRuntimeConfig } from '@anthropic-ai/sandbox-runtime';
import { within } from './paths.ts';

export interface ExecutionPolicy {
  read: string[];
  write: string[];
  network: string[];
  denyRead?: string[];
  denyWrite?: string[];
}

/** 宿主内部数据不随工作区目录授权暴露给执行代码。 */
export const hostPrivatePaths = (home: string): string[] => ['auth', 'sessions', 'diffs', 'workspaces', 'plugins', 'kite.db', 'kite.db-wal', 'kite.db-shm']
  .map((name) => join(home, name));

/** 环境只携带开发工具的基础设置；认证、代理与运行时注入变量不随模型命令传递。 */
export function commandEnvironment(source: NodeJS.ProcessEnv): NodeJS.ProcessEnv {
  const keys = ['HOME', 'PATH', 'USER', 'LOGNAME', 'SHELL', 'LANG', 'LC_ALL', 'LC_CTYPE', 'TZ', 'TERM',
    'TMPDIR', 'TMP', 'TEMP', 'DEVELOPER_DIR', 'SDKROOT', 'TOOLCHAINS',
    'GIT_AUTHOR_NAME', 'GIT_AUTHOR_EMAIL', 'GIT_COMMITTER_NAME', 'GIT_COMMITTER_EMAIL'];
  return Object.fromEntries(keys.flatMap((key) => source[key] === undefined ? [] : [[key, source[key]]]));
}

function developerDirectory(env: NodeJS.ProcessEnv): string | undefined {
  if (env.DEVELOPER_DIR) return env.DEVELOPER_DIR;
  // xcode-select 的系统链接本身可能被 denyRead 根规则遮住；宿主解析当前选择，保持工具链身份。
  const selected = '/var/select/developer_dir';
  return process.platform === 'darwin' && existsSync(selected) ? realpathSync(selected) : undefined;
}

/** 首期工作区策略：工作树可写，系统工具链可读，网络需宿主另行授权。 */
export function workspacePolicy(cwd: string, env: NodeJS.ProcessEnv): ExecutionPolicy {
  const system = process.platform === 'darwin'
    ? ['/bin', '/sbin', '/usr', '/System', '/Library/Developer', '/Library/Apple', '/Applications/Xcode.app', '/opt/homebrew', '/dev', '/private/etc', '/private/var/select']
    : ['/bin', '/sbin', '/usr', '/lib', '/lib64', '/etc', '/dev', '/proc', '/sys'];
  const tools = [process.execPath, developerDirectory(env), env.SDKROOT].filter((path): path is string => !!path && isAbsolute(path));
  const gitConfigs = env.HOME && isAbsolute(env.HOME) ? [join(env.HOME, '.gitconfig'), join(env.HOME, '.config/git/config')] : [];
  return { read: [...new Set([cwd, ...system.filter(existsSync), ...tools.filter(existsSync), ...gitConfigs].map(canonicalPath))],
    write: [realpathSync(cwd)], network: [] };
}

/** 宿主文件工具也按执行策略检查；已有符号链接按真实目标匹配，尚未创建的文件检查实际父目录。 */
export function assertFileAccess(path: string, kind: 'read' | 'write', policy: ExecutionPolicy): void {
  const target = canonicalPath(path);
  const denied = kind === 'read' ? policy.denyRead : policy.denyWrite;
  if (paths(denied ?? []).some((root) => within(target, root)) || !paths(policy[kind]).some((root) => within(target, root))) {
    throw new Error(`未获准${kind === 'read' ? '读取' : '写入'}此文件：${path}`);
  }
}

export function canonicalPath(path: string): string {
  const absolute = resolve(path);
  let parent = absolute;
  while (!existsSync(parent) && dirname(parent) !== parent) parent = dirname(parent);
  return resolve(realpathSync(parent), absolute.slice(parent.length).replace(/^\//, ''));
}

const quote = (value: string) => `'${value.replaceAll("'", "'\\''")}'`;

function paths(values: string[]): string[] {
  return [...new Set(values.map((value) => {
    // 上游支持 glob；此入口只接收宿主授权的确切路径，不能把文件名解释成授权表达式。
    if (!isAbsolute(value) || /[*?\[\]{}\0\n\r]/.test(value)) throw new Error(`沙箱路径必须是无通配符的绝对路径：${value}`);
    return canonicalPath(value);
  }))];
}

export function prepareSandbox(command: string, options: { cwd: string; env: NodeJS.ProcessEnv; policy: ExecutionPolicy }) {
  if (process.platform !== 'darwin' && process.platform !== 'linux') throw new Error('当前工作机不支持 Kite 沙箱，命令未启动');
  if (!Bun.semver.satisfies(Bun.version, '>=1.4.2')) throw new Error('Kite 沙箱需要 Bun 1.4.2 或更新版本，请使用 kited/node_modules/.bin/bun 启动');
  // macOS 的 Unix socket 路径很短；不能使用可能很长的工作区 TMPDIR 放上游代理 socket。
  const temporaryRoot = process.platform === 'darwin' ? '/private/tmp' : tmpdir();
  const control = realpathSync(mkdtempSync(join(temporaryRoot, 'kite-sbx-')));
  const scratch = realpathSync(mkdtempSync(join(temporaryRoot, 'kite-work-')));
  const dispose = () => { rmSync(control, { recursive: true, force: true }); rmSync(scratch, { recursive: true, force: true }); };
  try {
    const { policy } = options;
    const denyRead = paths(policy.denyRead ?? []);
    const allowRead = paths([...policy.read, scratch]);
    // 上游以更具体的路径规则优先；Kite 的显式禁止必须始终优先，不能由子路径许可重新打开。
    if (allowRead.some((path) => denyRead.some((root) => within(path, root)))) {
      throw new Error('沙箱读取许可与宿主保护目录冲突，命令未启动');
    }
    const config: SandboxRuntimeConfig = {
      filesystem: {
        denyRead: ['/', control, ...denyRead],
        allowRead,
        allowWrite: paths([...policy.write, scratch]),
        // 上游有少量默认可写目录；本入口只开放策略声明和本次执行的临时目录。
        denyWrite: paths([control, '/tmp/claude', '/private/tmp/claude',
          join(options.env.HOME ?? homedir(), '.npm/_logs'), join(options.env.HOME ?? homedir(), '.claude/debug'),
          ...(policy.denyWrite ?? [])]),
      },
      network: { allowedDomains: [...policy.network], deniedDomains: [], strictAllowlist: true, allowLocalBinding: false, allowAllUnixSockets: false },
      allowAppleEvents: false, enableWeakerNetworkIsolation: false, enableWeakerNestedSandbox: false,
    };
    const settings = join(control, 'settings.json');
    const bunfig = join(control, 'bunfig.toml');
    writeFileSync(settings, JSON.stringify(config), { mode: 0o600 });
    writeFileSync(bunfig, '[run]\nshell = "system"\n', { mode: 0o600 });
    const env: NodeJS.ProcessEnv = { ...options.env, TMPDIR: control, TMP: control, TEMP: control };
    // 保留系统 Git 配置的真实来源，同时避开 macOS /etc 链接本身的元数据探测。
    if (process.platform === 'darwin') env.GIT_CONFIG_SYSTEM = canonicalPath('/etc/gitconfig');
    const developer = developerDirectory(options.env);
    if (developer) {
      env.DEVELOPER_DIR = developer;
      // 系统 git 是 xcrun shim，会写固定的系统缓存；直接选择同一 Xcode 的工具，保留用户自定义 PATH 的优先级。
      const binaries = join(developer, 'usr/bin');
      if (existsSync(binaries)) env.PATH = (env.PATH ?? '/usr/bin:/bin').split(':')
        .flatMap((path) => path === '/usr/bin' ? [binaries, path] : [path]).join(':');
    }
    for (const key of Object.keys(env)) {
      if (/^(?:LD_|DYLD_|SRT_)/.test(key) || /^(?:BUN_OPTIONS|NODE_OPTIONS|NODE_PATH|ENV|BASH_ENV)$/i.test(key)
        || /^(?:https?|all|no)_proxy$/i.test(key)) delete env[key];
    }
    // 可信 CLI 在沙箱外初始化代理；用户命令直到进入 OS 沙箱后才由 sh 解释。
    const cli = fileURLToPath(new URL('./sandbox-host.ts', import.meta.url));
    const wrapped = `TMPDIR=${quote(scratch)} TMP=${quote(scratch)} TEMP=${quote(scratch)} exec /bin/sh -c ${quote(command)}`;
    return { executable: process.execPath,
      args: ['run', '--no-env-file', '--no-install', `--config=${bunfig}`, cli, '--settings', settings, '-c', wrapped],
      env, dispose };
  } catch (error) { dispose(); throw error; }
}
