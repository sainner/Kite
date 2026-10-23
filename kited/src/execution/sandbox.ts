/** 工作机共用的沙箱启动适配；策略由宿主决定，每次执行使用独立的上游代理与配置。 */
import { existsSync, mkdtempSync, realpathSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { homedir, tmpdir } from 'node:os';
import { basename, dirname, isAbsolute, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import type { SandboxRuntimeConfig } from '@anthropic-ai/sandbox-runtime';
import { within } from '../paths.ts';
import { secretEnvironmentName, type SecretValue } from '../secrets.ts';

export interface ExecutionPolicy {
  read: string[];
  write: string[];
  network: string[];
  denyRead?: string[];
  denyWrite?: string[];
  /** 项目禁止的主机：名单里有也不放行，也不问人。 */
  deniedNetwork?: string[];
  /** 宿主按项目密钥写进工作区的文件（绝对路径），已在 denyWrite 里；patch 据此提示改用密钥请求。 */
  secretFiles?: string[];
}

/** 宿主内部数据不随工作区目录授权暴露给执行代码。 */
export const hostPrivatePaths = (home: string): string[] => ['auth', 'sessions', 'diffs', 'attachments', 'workspaces', 'plugins', 'mcp', 'kite.db', 'kite.db-wal', 'kite.db-shm']
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

/** 凭据按专用变量交给命令：text 是值本身，file 写成 dir 里只有本人可读的文件，变量是它的路径。 */
export function secretEnvironment(credentials: Record<string, SecretValue>, dir: string): NodeJS.ProcessEnv {
  const env: NodeJS.ProcessEnv = {};
  for (const [key, credential] of Object.entries(credentials)) {
    // 专用变量前缀避免凭据改写 PATH、运行时加载选项或沙箱代理设置。
    if (!secretEnvironmentName.safeParse(key).success) throw new Error('凭据环境变量名称无效');
    if (credential.kind === 'file') {
      const path = join(dir, key);
      writeFileSync(path, credential.value, { mode: 0o600, flag: 'wx' });
      env[key] = path;
    } else env[key] = credential.value;
  }
  return env;
}

/** 上游把带这些字符的路径当成 glob 或无法表达；宿主授权的只能是确切路径。 */
const globCharacters = /[*?\[\]{}\0\n\r]/;

/** 首期工作区策略：工作树可写，系统工具链可读，网络需宿主另行授权。 */
export function workspacePolicy(cwd: string, env: NodeJS.ProcessEnv): ExecutionPolicy {
  const system = process.platform === 'darwin'
    ? ['/bin', '/sbin', '/usr', '/System', '/Library/Developer', '/Library/Apple', '/Applications/Xcode.app', '/opt/homebrew', '/dev', '/private/etc', '/private/var/select']
    : ['/bin', '/sbin', '/usr', '/lib', '/lib64', '/etc', '/dev', '/proc', '/sys'];
  // 安装包把 rg 与 Bun 放在同一个 bin 里，见 kited/scripts/package-macos.ts；从源码运行时没有，靠系统装的。
  const tools = [process.execPath, join(dirname(process.execPath), 'rg'), developerDirectory(env), env.SDKROOT]
    .filter((path): path is string => !!path && isAbsolute(path) && existsSync(path));
  // 工具与 git 配置是顺带放行的，真实位置带通配符时上游写不出确切规则（见 paths()），略过，不让每条命令都起不来。
  const extras = [...tools, ...gitGlobalFiles(env)].map(canonicalPath).filter((path) => !globCharacters.test(path));
  return { read: [...new Set([...[cwd, ...system.filter(existsSync)].map(canonicalPath), ...extras])],
    write: [realpathSync(cwd)], network: [] };
}

/** 按 HOME 记下全局配置的修改时间与读出的文件，配置没变就不再起 git。 */
const gitFiles = new Map<string, { key: string; files: string[] }>();

/**
 * git 读的全局配置、忽略与属性文件；读不到时每条命令都报警告，全局忽略规则也不生效。忽略与属性文件除了 ~/.config/git 下的默认位置，
 * 还有全局配置里 core.excludesFile、core.attributesFile 指定的（常见 ~/.gitignore_global）。只放行这几个文件，同目录的 credentials 不放行。
 */
function gitGlobalFiles(env: NodeJS.ProcessEnv): string[] {
  const home = env.HOME;
  if (!home || !isAbsolute(home)) return [];
  const configs = ['.gitconfig', '.config/git/config'].map((name) => join(home, name));
  const defaults = [...configs, ...['.config/git/ignore', '.config/git/attributes'].map((name) => join(home, name))];
  const git = Bun.which('git', { PATH: env.PATH ?? '' });
  if (!git) return defaults;
  const key = [git, ...configs.map((path) => statSync(path, { throwIfNoEntry: false })?.mtimeMs ?? '')].join('\0');
  const cached = gitFiles.get(home);
  if (cached?.key === key) return cached.files;
  // 沙箱里的环境不带 XDG_CONFIG_HOME（见 commandEnvironment），这里也只给 HOME 与 PATH，读的是同一份全局配置；git 负责展开 ~。
  const result = Bun.spawnSync([git, 'config', '--global', '--type=path', '--null', '--get-regexp', '^core\\.(excludesfile|attributesfile)$'],
    { env: { HOME: home, PATH: env.PATH ?? '' }, stdin: 'ignore', stdout: 'pipe', stderr: 'ignore' });
  // 每项是「键\n值\0」；相对路径 git 按命令所在的目录解释，不放行。
  const configured = result.exitCode === 0 ? result.stdout.toString().split('\0').flatMap((entry) => {
    const value = entry.slice(entry.indexOf('\n') + 1);
    return entry.includes('\n') && isAbsolute(value) ? [value] : [];
  }) : [];
  const files = [...defaults, ...configured];
  gitFiles.set(home, { key, files });
  return files;
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

/** 沙箱收的路径：上游支持 glob，此入口只接收宿主授权的确切路径，不能把文件名解释成授权表达式。 */
export const exactPath = (value: string): boolean => isAbsolute(value) && !globCharacters.test(value);

function paths(values: string[]): string[] {
  return [...new Set(values.map((value) => {
    if (!exactPath(value)) throw new Error(`沙箱路径必须是无通配符的绝对路径：${value}`);
    // 交给上游的是解析软链接后的真实位置，它带通配符同样会被当成 glob：整棵子树放行变成只匹配一层，还匹配上同一模式的兄弟目录。
    const path = canonicalPath(value);
    if (globCharacters.test(path)) throw new Error(`沙箱路径的真实位置不能带通配符：${value} 指向 ${path}`);
    return path;
  }))];
}

/**
 * 放行路径的各级上级目录，每个只匹配目录本身。上游只给上级目录元数据，从 / 起逐级 openat 的程序（Python 的 dir_fd 遍历等）
 * 第一级就被拒；Seatbelt 分不开打开目录与列目录，放开后命令能列出这些目录里的名字，仍读不到其中的文件。
 * 确切路径上游按整棵子树放行，只能写成 glob，把一个字符写成字符类，上游转成整串匹配的正则。Seatbelt 的正则按字节匹配，
 * 字符类里只能放单字节字符，中文、emoji 放进去就匹配不上；所以括住名字前的分隔符（/Users/x[/]项目）。顶层目录前只有根的 /，
 * 括起来就不是绝对路径了，改括名字里最后一个 ASCII 字母或数字（/User[s]）；没有这样的字符就略过这一级：
 * macOS 的根目录在只读的系统卷上，顶层的名字由系统给出。paths() 已排除真实位置带通配符的路径。
 */
function ancestorDirectories(roots: string[]): string[] {
  const found = new Set<string>();
  for (const root of roots) {
    for (let dir = dirname(root); dir !== '/'; dir = dirname(dir)) {
      const parent = dirname(dir);
      if (parent !== '/') {
        found.add(`${parent}[/]${basename(dir)}`);
        continue;
      }
      const at = dir.search(/[A-Za-z0-9][^A-Za-z0-9]*$/);
      if (at > 0) found.add(`${dir.slice(0, at)}[${dir[at]}]${dir.slice(at + 1)}`);
    }
  }
  return [...found];
}

/**
 * network 决定名单外的主机：缺省一律拒绝；open 一律放行（项目级网络授权落地前的 .kite/setup、全放行模式）；
 * ask 逐个问宿主，宿主在返回的 askSocket 上监听，须在启动命令前开好。
 */
export function prepareSandbox(command: string, options: { cwd: string; env: NodeJS.ProcessEnv; policy: ExecutionPolicy; credentials?: Record<string, SecretValue>; network?: 'open' | 'ask' }) {
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
        // macOS 的 /etc 是指向 /private/etc 的符号链接，拒绝区域里的链接上游连元数据都不给，经 /etc 的路径就打不开：
        // 解析 localhost 时 mDNSResponder 连不上，系统退回读 /etc/hosts，也读不到，vite、vitest 一启动就失败。
        // 确切路径会被上游解析成真实目标，只能写成只匹配链接本身的 glob。
        allowRead: [...allowRead, ...(process.platform === 'darwin' ? ['/et[c]', ...ancestorDirectories(allowRead)] : [])],
        allowWrite: paths([...policy.write, scratch]),
        // 上游有少量默认可写目录；本入口只开放策略声明和本次执行的临时目录。
        denyWrite: paths([control, '/tmp/claude', '/private/tmp/claude',
          join(options.env.HOME ?? homedir(), '.npm/_logs'), join(options.env.HOME ?? homedir(), '.claude/debug'),
          ...(policy.denyWrite ?? [])]),
      },
      network: { allowedDomains: [...policy.network], deniedDomains: [...policy.deniedNetwork ?? []], strictAllowlist: !options.network, allowLocalBinding: false, allowAllUnixSockets: false },
      allowAppleEvents: false, enableWeakerNetworkIsolation: false, enableWeakerNestedSandbox: false,
    };
    const settings = join(control, 'settings.json');
    const bunfig = join(control, 'bunfig.toml');
    writeFileSync(settings, JSON.stringify(config), { mode: 0o600 });
    writeFileSync(bunfig, '[run]\nshell = "system"\n', { mode: 0o600 });
    const env: NodeJS.ProcessEnv = { ...options.env, TMPDIR: control, TMP: control, TEMP: control };
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
    Object.assign(env, secretEnvironment(options.credentials ?? {}, scratch));
    // 可信 CLI 在沙箱外初始化代理；用户命令直到进入 OS 沙箱后才由 sh 解释。
    const cli = fileURLToPath(new URL(options.network ? './sandbox-callback-host.ts' : './sandbox-host.ts', import.meta.url));
    const wrapped = `TMPDIR=${quote(scratch)} TMP=${quote(scratch)} TEMP=${quote(scratch)} exec /bin/sh -c ${quote(command)}`;
    // 控制目录对命令不可读写，询问通道放在这里，命令连不上它。
    const askSocket = options.network === 'ask' ? join(control, 'ask.sock') : undefined;
    return { executable: process.execPath,
      args: ['run', '--no-env-file', '--no-install', `--config=${bunfig}`, cli, '--settings', settings, ...(askSocket ? ['--ask', askSocket] : []), '-c', wrapped],
      env, askSocket, dispose };
  } catch (error) { dispose(); throw error; }
}
