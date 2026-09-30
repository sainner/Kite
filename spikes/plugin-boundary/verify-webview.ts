import { mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { startGateway } from './gateway.ts';

// 大型手动实验：真实 WKWebView、MCP Apps SDK、网关和 Deno 子进程一起运行。
const root = await mkdtemp(join(tmpdir(), 'kite-plugin-webview-'));
const iosDevice = process.argv[2] === '--ios' ? process.argv[3] : undefined;
if (process.argv[2] === '--ios' && !iosDevice) throw new Error('用法：bun verify-webview.ts --ios <模拟器 UDID>');
const bundleID = 'dev.kite.pluginboundaryprobe';
let gateway: Awaited<ReturnType<typeof startGateway>> | undefined;
let bootedByProbe = false;
let installed = false;

async function command(args: string[], env = { ...process.env }, timeoutMs = 90_000) {
  const child = Bun.spawn(args, { cwd: import.meta.dir, stdout: 'pipe', stderr: 'pipe', env });
  let timedOut = false;
  const timeout = setTimeout(() => { timedOut = true; child.kill('SIGKILL'); }, timeoutMs);
  try {
    const [stdout, stderr, code] = await Promise.all([
      new Response(child.stdout).text(), new Response(child.stderr).text(), child.exited,
    ]);
    return { stdout, stderr, code, timedOut };
  } finally {
    clearTimeout(timeout);
  }
}

async function build() {
  if (!iosDevice) {
    const result = await command(['swiftc', '-swift-version', '5', '-framework', 'AppKit', '-framework', 'WebKit',
      join(import.meta.dir, 'Probe.swift'), '-o', join(root, 'Probe')]);
    if (result.code !== 0) throw new Error(`Swift 编译失败：${result.stderr}`);
    return join(root, 'Probe');
  }
  const sdk = (await command(['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path'])).stdout.trim();
  const app = join(root, 'Probe.app');
  await mkdir(app);
  const result = await command(['xcrun', '--sdk', 'iphonesimulator', 'swiftc', '-swift-version', '5',
    '-target', 'arm64-apple-ios27.0-simulator', '-sdk', sdk, '-framework', 'UIKit', '-framework', 'WebKit',
    join(import.meta.dir, 'Probe.swift'), '-o', join(app, 'Probe')]);
  if (result.code !== 0) throw new Error(`iOS Swift 编译失败：${result.stderr}`);
  await writeFile(join(app, 'Info.plist'), `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>${bundleID}</string>
  <key>CFBundleExecutable</key><string>Probe</string>
  <key>CFBundleName</key><string>Probe</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSRequiresIPhoneOS</key><true/>
  <key>MinimumOSVersion</key><string>27.0</string>
  <key>UIDeviceFamily</key><array><integer>1</integer></array>
  <key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
  <key>UIApplicationSceneManifest</key><dict>
    <key>UIApplicationSupportsMultipleScenes</key><false/>
    <key>UISceneConfigurations</key><dict>
      <key>UIWindowSceneSessionRoleApplication</key><array><dict>
        <key>UISceneConfigurationName</key><string>Probe Scene</string>
        <key>UISceneDelegateClassName</key><string>ProbeSceneDelegate</string>
      </dict></array>
    </dict>
  </dict>
</dict></plist>`);
  return app;
}

try {
  const artifact = await build();
  gateway = await startGateway(root);
  let reportText: string;
  let stderr: string;
  let code: number;
  if (!iosDevice) {
    const result = await command([artifact, `${gateway.url}/host`, gateway.token],
      { HOME: root, PATH: '/usr/bin:/bin', TMPDIR: root });
    ({ stdout: reportText, stderr, code } = result);
  } else {
    const devices = await command(['xcrun', 'simctl', 'list', 'devices', '-j']);
    if (devices.code !== 0) throw new Error(devices.stderr);
    const entries = Object.values(JSON.parse(devices.stdout).devices).flat() as any[];
    const device = entries.find(item => item.udid === iosDevice);
    if (!device) throw new Error(`找不到模拟器 ${iosDevice}`);
    if (device.state === 'Shutdown') {
      const boot = await command(['xcrun', 'simctl', 'boot', iosDevice]);
      if (boot.code !== 0) throw new Error(boot.stderr);
      bootedByProbe = true;
      const ready = await command(['xcrun', 'simctl', 'bootstatus', iosDevice, '-b']);
      if (ready.code !== 0) throw new Error(ready.timedOut ? '模拟器启动超时' : ready.stderr);
    }
    const install = await command(['xcrun', 'simctl', 'install', iosDevice, artifact]);
    if (install.code !== 0) throw new Error(install.timedOut ? '模拟器安装探针超时' : install.stderr);
    installed = true;
    const result = await command(['xcrun', 'simctl', 'launch', '--console', iosDevice, bundleID,
      `${gateway.url}/host`, gateway.token], { ...process.env }, 35_000);
    ({ stdout: reportText, stderr, code } = result);
  }
  const line = reportText.split('\n').find(line => line.startsWith('KITE_PLUGIN_PROBE='));
  if (!line) throw new Error(`原生探针未上报：退出码 ${code}；stdout ${reportText}；stderr ${stderr}`);
  const report = JSON.parse(line.slice('KITE_PLUGIN_PROBE='.length));
  console.log(JSON.stringify(report));
  if (code !== 0 || report.pass !== true) throw new Error(`WebView 场景未通过：退出码 ${code}`);
} finally {
  if (iosDevice && installed) {
    await command(['xcrun', 'simctl', 'terminate', iosDevice, bundleID]);
    await command(['xcrun', 'simctl', 'uninstall', iosDevice, bundleID]);
  }
  await gateway?.close();
  if (iosDevice && bootedByProbe) await command(['xcrun', 'simctl', 'shutdown', iosDevice]);
  await rm(root, { recursive: true, force: true });
}
