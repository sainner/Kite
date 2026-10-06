/** 用户级安装与 launchd 管理；数据目录不参与替换或卸载。 */
import { copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, renameSync, rmSync, writeFileSync } from 'node:fs';
import { homedir, userInfo } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { createServer } from 'node:net';

interface Installation {
  root: string;
  home: string;
  port: number;
  /** 自建组网控制服务器（如 headscale）；省略时用 Tailscale 官方服务。 */
  controlURL?: string;
  label: string;
  plist: string;
  logs: string;
  bin: string;
  app?: string;
}

const command = process.argv[2] ?? 'status';
const root = resolve(process.env.KITE_INSTALL_ROOT ?? join(homedir(), 'Library/Application Support/Kite'));
const receipt = join(root, 'install.json');
const runtime = join(root, 'runtime');
const domain = `gui/${process.getuid!()}`;
const marker = '# Kite 安装器管理';
const quote = (value: string) => `'${value.replaceAll("'", "'\\''")}'`;

async function run(args: string[], allowFailure = false): Promise<string> {
  const child = Bun.spawn(args, { env: process.env, stdout: 'pipe', stderr: 'pipe' });
  const [out, error, code] = await Promise.all([new Response(child.stdout).text(), new Response(child.stderr).text(), child.exited]);
  if (code !== 0 && !allowFailure) throw new Error(`${args[0]} 失败：${error.trim() || out.trim()}`);
  return code === 0 ? out : '';
}

const saved = (): Installation | undefined => existsSync(receipt) ? JSON.parse(readFileSync(receipt, 'utf8')) as Installation : undefined;
const loaded = async (c: Installation): Promise<boolean> => !!await run(['/bin/launchctl', 'print', `${domain}/${c.label}`], true);

function plist(c: Installation): string {
  const xml = (value: string): string => value.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;').replaceAll("'", '&apos;');
  const string = (value: string): string => `<string>${xml(value)}</string>`;
  // launchd 不读取 shell 配置，也不保存发起安装的终端中的凭据或代理。
  const env = { HOME: homedir(), USER: userInfo().username, LOGNAME: userInfo().username, SHELL: '/bin/zsh', LANG: 'en_US.UTF-8',
    PATH: [join(runtime, 'bin'), join(homedir(), '.local/bin'), join(homedir(), '.bun/bin'), '/opt/homebrew/bin', '/opt/homebrew/sbin',
      '/usr/local/bin', '/usr/bin', '/bin', '/usr/sbin', '/sbin'].join(':'), KITE_HOME: c.home, KITE_PORT: String(c.port),
    ...(c.controlURL ? { KITE_CONTROL_URL: c.controlURL } : {}) };
  return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key>${string(c.label)}
<key>ProgramArguments</key><array>${[join(runtime, 'bin/bun'), 'run', '--no-env-file', '--no-install', join(runtime, 'kited/src/main.ts')].map(string).join('')}</array>
<key>WorkingDirectory</key>${string(join(runtime, 'kited'))}
<key>EnvironmentVariables</key><dict>${Object.entries(env).map(([key, value]) => `<key>${key}</key>${string(value)}`).join('')}</dict>
<key>RunAtLoad</key><true/><key>KeepAlive</key><true/>
<key>ThrottleInterval</key><integer>10</integer><key>ExitTimeOut</key><integer>30</integer>
<key>StandardOutPath</key>${string(join(c.logs, 'kited.log'))}
<key>StandardErrorPath</key>${string(join(c.logs, 'kited.error.log'))}
</dict></plist>\n`;
}

async function portFree(port: number): Promise<void> {
  await new Promise<void>((ok, fail) => {
    const server = createServer();
    server.once('error', () => fail(new Error(`端口 ${port} 已被占用，请停止占用它的进程或设置 KITE_PORT。`)));
    server.listen(port, '127.0.0.1', () => server.close((error) => error ? fail(error) : ok()));
  });
}

async function stop(c: Installation): Promise<void> {
  const state = await run(['/bin/launchctl', 'print', `${domain}/${c.label}`], true);
  if (!state) return;
  const pid = Number(state.match(/\n\s*pid = (\d+)/)?.[1]);
  await run(['/bin/launchctl', 'bootout', `${domain}/${c.label}`]);
  // bootout 与进程退出是两个时刻；旧进程完成收尾前不能替换其运行文件或复用端口。
  if (pid) {
    const deadline = Date.now() + 35_000;
    while (Date.now() < deadline) {
      try { process.kill(pid, 0); } catch { return; }
      await Bun.sleep(100);
    }
    throw new Error(`旧服务进程 ${pid} 尚未退出，请核查后重试。`);
  }
}

async function start(c: Installation): Promise<void> {
  if (!await loaded(c)) {
    await portFree(c.port);
    await run(['/bin/launchctl', 'enable', `${domain}/${c.label}`]);
    await run(['/bin/launchctl', 'bootstrap', domain, c.plist]);
  }
  const deadline = Date.now() + 15_000;
  while (Date.now() < deadline) {
    try {
      const response = await fetch(`http://127.0.0.1:${c.port}/machine`, { signal: AbortSignal.timeout(750) });
      const machine = await response.json() as { id?: string };
      if (response.ok && machine.id && await loaded(c)) return;
    } catch { /* launchd 异步拉起进程，等 HTTP 接口可用后才报告成功。 */ }
    await Bun.sleep(150);
  }
  throw new Error(`后台服务未就绪，请查看 ${join(c.logs, 'kited.error.log')}`);
}

function launcher(c: Installation, service: boolean): string {
  return `#!/bin/sh\n${marker}\nexport KITE_INSTALL_ROOT=${quote(c.root)}\nexport KITE_HOME=${quote(c.home)}\nexport KITE_PORT=${quote(String(c.port))}\nexec ${quote(join(runtime, 'bin/bun'))} run --no-env-file --no-install ${quote(join(runtime, service ? 'kited/scripts/install-macos.ts' : 'kited/src/cli.ts'))} "$@"\n`;
}

async function install(): Promise<void> {
  const source = resolve(import.meta.dir, '../..');
  if (source === runtime) throw new Error('升级请重新运行新安装包中的「安装.command」。');
  const manifest = JSON.parse(readFileSync(join(source, 'manifest.json'), 'utf8')) as { platform: string; arch: string; bun: string; app: boolean };
  if (manifest.platform !== process.platform || manifest.arch !== process.arch || manifest.bun !== Bun.version) throw new Error('安装包与当前平台、架构或运行时不匹配。');
  if (manifest.app && Number((await run(['/usr/bin/sw_vers', '-productVersion'])).split('.')[0]) < 26) throw new Error('Kite App 需要 macOS 26 或更新版本。');
  if (!await run(['/usr/bin/xcrun', '--find', 'git'], true)) throw new Error('请先运行 xcode-select --install 安装 Git 和命令行工具，再重新安装。');
  const old = saved();
  const label = old?.label ?? process.env.KITE_SERVICE_LABEL ?? 'com.sainner.kited';
  if (!/^[A-Za-z0-9.-]+$/.test(label)) throw new Error('服务标识只能包含字母、数字、点和短横线。');
  const c: Installation = { root,
    home: resolve(process.env.KITE_HOME ?? old?.home ?? join(homedir(), '.kite')),
    port: Number(process.env.KITE_PORT ?? old?.port ?? 5483), label,
    // 设为空字符串可改回 Tailscale 官方服务。
    controlURL: (process.env.KITE_CONTROL_URL ?? old?.controlURL)?.trim() || undefined,
    plist: old?.plist ?? join(resolve(process.env.KITE_LAUNCH_AGENTS_DIR ?? join(homedir(), 'Library/LaunchAgents')), `${label}.plist`),
    logs: old?.logs ?? resolve(process.env.KITE_LOG_DIR ?? join(homedir(), 'Library/Logs/Kite')),
    bin: old?.bin ?? resolve(process.env.KITE_BIN_DIR ?? join(homedir(), '.local/bin')),
    app: manifest.app ? old?.app ?? join(resolve(process.env.KITE_APPLICATIONS_DIR ?? join(homedir(), 'Applications')), 'Kite.app') : old?.app };
  if (!Number.isInteger(c.port) || c.port < 1 || c.port > 65535) throw new Error('KITE_PORT 必须是 1～65535 的端口号。');
  if (c.home === root || c.home.startsWith(root + '/')) throw new Error('数据目录必须位于安装目录之外，以免升级或卸载影响数据。');
  for (const file of ['kite', 'kite-service']) {
    const path = join(c.bin, file);
    if (existsSync(path) && !readFileSync(path, 'utf8').includes(marker)) throw new Error(`已有其他命令占用 ${path}，请用 KITE_BIN_DIR 指定安装位置。`);
  }
  if (manifest.app && c.app && existsSync(c.app)) {
    const processes = await run(['/bin/ps', '-axo', 'command=']);
    if (processes.split('\n').some((line) => line.startsWith(join(c.app!, 'Contents/MacOS/Kite')))) throw new Error('请先退出已安装的 Kite App，再重新安装。');
  }
  for (const path of [root, dirname(c.plist), c.logs, c.bin, c.home]) mkdirSync(path, { recursive: true });
  const stage = mkdtempSync(join(root, '.install-'));
  const previousPlist = existsSync(c.plist) ? readFileSync(c.plist) : undefined;
  const previousReceipt = existsSync(receipt) ? readFileSync(receipt) : undefined;
  const previousCommands = new Map(['kite', 'kite-service'].map((name) => {
    const path = join(c.bin, name); return [path, existsSync(path) ? readFileSync(path) : undefined] as const;
  }));
  const wasLoaded = await loaded(c);
  let stopped = false;
  let runtimeMoved = false;
  let appMoved = false;
  let appStage: string | undefined;
  let preserveStage = false;
  try {
    console.log('复制运行文件…');
    await run(['/usr/bin/ditto', source, join(stage, 'runtime')]);
    if (manifest.app && c.app) {
      mkdirSync(dirname(c.app), { recursive: true });
      appStage = mkdtempSync(join(dirname(c.app), '.kite-install-'));
      await run(['/usr/bin/ditto', join(dirname(source), 'Kite.app'), join(appStage, 'Kite.app')]);
      await run(['/usr/bin/codesign', '--verify', '--deep', '--strict', join(appStage, 'Kite.app')]);
    }
    writeFileSync(join(stage, 'service.plist'), plist(c), { mode: 0o644 });
    await run(['/usr/bin/plutil', '-lint', join(stage, 'service.plist')]);
    console.log('安装后台服务…');
    await stop(c);
    stopped = true;
    await portFree(c.port);
    if (existsSync(runtime)) renameSync(runtime, join(stage, 'previous-runtime'));
    runtimeMoved = true;
    renameSync(join(stage, 'runtime'), runtime);
    if (appStage && c.app) {
      if (existsSync(c.app)) renameSync(c.app, join(appStage, 'previous.app'));
      appMoved = true;
      renameSync(join(appStage, 'Kite.app'), c.app);
    }
    copyFileSync(join(stage, 'service.plist'), c.plist);
    await start(c);
    for (const name of ['kite', 'kite-service']) writeFileSync(join(c.bin, name), launcher(c, name === 'kite-service'), { mode: 0o755 });
    writeFileSync(receipt, JSON.stringify(c, null, 2) + '\n', { mode: 0o600 });
  } catch (error) {
    try {
      if (stopped) {
        await stop(c);
        if (runtimeMoved) {
          rmSync(runtime, { recursive: true, force: true });
          if (existsSync(join(stage, 'previous-runtime'))) renameSync(join(stage, 'previous-runtime'), runtime);
        }
        if (appMoved && c.app && appStage) {
          rmSync(c.app, { recursive: true, force: true });
          if (existsSync(join(appStage, 'previous.app'))) renameSync(join(appStage, 'previous.app'), c.app);
        }
        if (previousPlist) writeFileSync(c.plist, previousPlist); else rmSync(c.plist, { force: true });
        if (previousReceipt) writeFileSync(receipt, previousReceipt); else rmSync(receipt, { force: true });
        for (const [path, content] of previousCommands) {
          if (content) writeFileSync(path, content, { mode: 0o755 }); else rmSync(path, { force: true });
        }
        if (wasLoaded && previousPlist) await run(['/bin/launchctl', 'bootstrap', domain, c.plist]);
      }
    } catch (rollbackError) {
      preserveStage = true;
      throw new Error(`安装失败：${String(error)}；回退未完成：${String(rollbackError)}。保留的安装备份：${stage}${appStage ? `、${appStage}` : ''}`);
    }
    throw error;
  } finally {
    if (!preserveStage) {
      rmSync(stage, { recursive: true, force: true });
      if (appStage) rmSync(appStage, { recursive: true, force: true });
    }
  }
  console.log(`安装完成：http://127.0.0.1:${c.port}，远程设备先用 kite net up 开启组网\n数据：${c.home}\n管理：${join(c.bin, 'kite-service')} status\n日志：${c.logs}`);
  if (!(process.env.PATH ?? '').split(':').includes(c.bin)) console.log(`命令目录尚未加入 PATH，可使用完整路径，或在 shell 配置中加入：export PATH=${quote(c.bin)}:"$PATH"`);
  if (!existsSync(join(c.home, 'auth/chatgpt/auth.json'))) console.log('首次使用模型还需设备登录，见项目 docs/kited.md 的「终端试用」。');
  if (manifest.app && c.app && process.env.KITE_NO_OPEN !== '1') await run(['/usr/bin/open', c.app]);
}

async function main(): Promise<void> {
  if (process.platform !== 'darwin' || process.getuid!() === 0) throw new Error('请在 macOS 中使用当前登录用户运行，不要使用 sudo。');
  if (command === 'install') { await install(); return; }
  if (['--help', '-h', 'help'].includes(command)) {
    console.log('用法：kite-service status | start | stop | restart | uninstall\n卸载只移除安装文件、App 和登录自启；保留数据与登录。'); return;
  }
  if (!['status', 'start', 'stop', 'restart', 'uninstall'].includes(command)) throw new Error(`未知命令：${command}`);
  const c = saved();
  if (!c) throw new Error('没有找到安装记录，请先运行安装包中的「安装.command」。');
  if (command === 'status') {
    console.log(await loaded(c) ? await run(['/bin/launchctl', 'print', `${domain}/${c.label}`]) : '后台服务已停止。'); return;
  }
  if (command !== 'start') await stop(c);
  if (command === 'start' || command === 'restart') { await start(c); console.log(`服务已就绪：http://127.0.0.1:${c.port}`); }
  if (command === 'stop') console.log('后台服务已停止；登录后仍会自动启动。');
  if (command === 'uninstall') {
    if (c.app && existsSync(c.app)) {
      const processes = await run(['/bin/ps', '-axo', 'command=']);
      if (processes.split('\n').some((line) => line.startsWith(join(c.app!, 'Contents/MacOS/Kite')))) throw new Error('请退出 Kite App 后重新卸载；后台服务已停止。');
      rmSync(c.app, { recursive: true });
    }
    rmSync(c.plist, { force: true });
    for (const name of ['kite', 'kite-service']) {
      const path = join(c.bin, name);
      if (existsSync(path) && readFileSync(path, 'utf8').includes(marker)) rmSync(path);
    }
    rmSync(runtime, { recursive: true, force: true });
    rmSync(receipt);
    console.log(`已卸载；数据与登录保留在 ${c.home}，日志保留在 ${c.logs}。`);
  }
}

// 双击两次安装器或同时重启、升级时，只允许一个操作修改安装文件。
const mutating = ['install', 'start', 'stop', 'restart', 'uninstall'].includes(command);
let locked = false;
const lock = join(root, '.install-lock');
try {
  if (mutating) {
    mkdirSync(root, { recursive: true });
    try { mkdirSync(lock); locked = true; }
    catch { throw new Error(`另一个安装或服务操作正在运行；若上次操作异常退出，请核查后移除 ${lock}。`); }
  }
  await main();
} catch (error) { console.error(`操作失败：${String(error)}`); process.exitCode = 1; }
finally { if (locked) rmSync(lock, { recursive: true }); }
