import { copyFile, mkdir, mkdtemp, readFile, rm, symlink, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { command as runCommand } from './command.ts';
import { pluginWebProbeSource } from '../fixtures/plugin-web-probe-source.ts';

// 手动层：编译生产 PluginWebBridge，使用真实 WKWebView 和 MCP Apps SDK；不截图。
if (process.platform !== 'darwin') throw new Error('WKWebView 手动探针须在 macOS 运行');
const args = process.argv.slice(2);
const iosDevice = args[0] === '--ios' ? args[1] : undefined;
if (args.length !== 0 && (args.length !== 2 || !iosDevice)) {
  throw new Error('用法：bun test/manual/verify-plugin-web.ts [--ios <模拟器 UDID>]');
}
const projectRoot = resolve(import.meta.dir, '..', '..', '..');
const command = (args: string[], timeoutMs: number) => runCommand(args, projectRoot, timeoutMs);
const temporary = await mkdtemp(join(tmpdir(), 'kite-plugin-web-'));
const bundleID = 'dev.kite.pluginwebprobe';
let bootedByProbe = false;
let installed = false;
let networkRequests = 0;
const network = Bun.serve({
  hostname: '127.0.0.1', port: 0,
  fetch(request, server) {
    networkRequests += 1;
    const path = new URL(request.url).pathname;
    if (path === '/socket' && server.upgrade(request)) return;
    if (path === '/pixel') {
      return new Response(Buffer.from('R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7', 'base64'), {
        headers: { 'content-type': 'image/gif', 'access-control-allow-origin': '*' },
      });
    }
    return new Response('reachable', { headers: { 'access-control-allow-origin': '*' } });
  },
  websocket: { message() {} },
});

async function build(fixture: string) {
  const production = join(projectRoot, 'app', 'Kite', 'Plugins', 'PluginWebBridge.swift');
  const probe = join(projectRoot, 'kited', 'test', 'manual', 'PluginWebProbe.swift');
  const transcript = join(projectRoot, 'app', 'Kite', 'Conversation', 'Transcript.swift');
  const jsonCodable = join(temporary, 'JSONCodable.swift');
  await writeFile(jsonCodable, `import Foundation\n\n${
    declaration(await readFile(join(projectRoot, 'app', 'Kite', 'Application', 'KitedClient.swift'), 'utf8'), 'extension JSON: Codable')
  }\n`);
  if (!iosDevice) {
    const executable = join(temporary, 'PluginWebProbe');
    await command(['swiftc', '-swift-version', '5', '-framework', 'AppKit', '-framework', 'WebKit',
      production, transcript, jsonCodable, probe, '-o', executable], 60_000);
    return executable;
  }
  const sdk = (await command(['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path'], 20_000)).trim();
  const app = join(temporary, 'PluginWebProbe.app');
  await mkdir(app);
  const arch = process.arch === 'arm64' ? 'arm64' : 'x86_64';
  await command(['xcrun', '--sdk', 'iphonesimulator', 'swiftc', '-swift-version', '5',
    '-target', `${arch}-apple-ios17.0-simulator`, '-sdk', sdk, '-framework', 'UIKit', '-framework', 'WebKit',
    production, transcript, jsonCodable, probe, '-o', join(app, 'PluginWebProbe')], 60_000);
  await copyFile(join(projectRoot, 'app', 'Kite', 'Resources', 'Generated', 'PluginHost.html'), join(app, 'PluginHost.html'));
  await copyFile(fixture, join(app, 'fixture.html'));
  await writeFile(join(app, 'Info.plist'), `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>${bundleID}</string>
  <key>CFBundleExecutable</key><string>PluginWebProbe</string>
  <key>CFBundleName</key><string>PluginWebProbe</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSRequiresIPhoneOS</key><true/>
  <key>MinimumOSVersion</key><string>17.0</string>
  <key>UIDeviceFamily</key><array><integer>1</integer><integer>2</integer></array>
  <key>NSAppTransportSecurity</key><dict>
    <key>NSAllowsArbitraryLoads</key><true/>
    <key>NSAllowsArbitraryLoadsInWebContent</key><true/>
    <key>NSAllowsLocalNetworking</key><true/>
  </dict>
  <key>UIApplicationSceneManifest</key><dict>
    <key>UIApplicationSupportsMultipleScenes</key><false/>
    <key>UISceneConfigurations</key><dict>
      <key>UIWindowSceneSessionRoleApplication</key><array><dict>
        <key>UISceneConfigurationName</key><string>Probe</string>
        <key>UISceneDelegateClassName</key><string>PluginWebProbeSceneDelegate</string>
      </dict></array>
    </dict>
  </dict>
</dict></plist>`);
  return app;
}

// 提取真实 JSON Codable 声明，Mac 与 iOS 探针都使用生产序列化规则。
function declaration(source: string, signature: string): string {
  const start = source.indexOf(signature);
  if (start < 0 || source.indexOf(signature, start + 1) >= 0) throw new Error(`Swift 声明不唯一：${signature}`);
  const open = source.indexOf('{', start);
  let depth = 0;
  for (let index = open; index < source.length; index++) {
    if (source[index] === '{') depth++;
    if (source[index] === '}' && --depth === 0) return source.slice(start, index + 1);
  }
  throw new Error(`Swift 声明未闭合：${signature}`);
}

async function runProbe(artifact: string, fixture: string) {
  if (!iosDevice) {
    return command([artifact, join(projectRoot, 'app', 'Kite', 'Resources', 'Generated', 'PluginHost.html'), fixture], 25_000);
  }
  const devices = JSON.parse(await command(['xcrun', 'simctl', 'list', 'devices', '-j'], 20_000)) as {
    devices: Record<string, { udid: string; state: string; isAvailable: boolean }[]>;
  };
  const device = Object.values(devices.devices).flat().find((device) => device.udid === iosDevice);
  if (!device?.isAvailable) throw new Error(`找不到可用模拟器 ${iosDevice}`);
  if (device.state === 'Shutdown') {
    await command(['xcrun', 'simctl', 'boot', iosDevice], 20_000);
    bootedByProbe = true;
    await command(['xcrun', 'simctl', 'bootstatus', iosDevice, '-b'], 90_000);
  }
  await command(['xcrun', 'simctl', 'install', iosDevice, artifact], 90_000);
  installed = true;
  return command(['xcrun', 'simctl', 'launch', '--console', iosDevice, bundleID], 30_000);
}

try {
  await mkdir(join(temporary, 'fixture'));
  await symlink(join(projectRoot, 'kited', 'node_modules'), join(temporary, 'fixture', 'node_modules'));
  const entry = join(temporary, 'fixture', 'app.ts');
  await writeFile(entry, pluginWebProbeSource.replace('__PROBE_NETWORK_URL__', JSON.stringify(network.url.origin)));
  const built = await Bun.build({ entrypoints: [entry], target: 'browser', format: 'iife', minify: true });
  if (!built.success || built.outputs.length !== 1) throw new Error(`探针 SDK 打包失败：${built.logs.join('\n')}`);
  const script = (await built.outputs[0]!.text()).replaceAll('</script', '<\\/script');
  const fixture = join(temporary, 'fixture.html');
  await writeFile(fixture, `<!doctype html><html><head><meta charset="utf-8"></head><body><script>${script}</script></body></html>`);
  const artifact = await build(fixture);
  const stdout = await runProbe(artifact, fixture);
  const prefix = 'KITE_PLUGIN_WEB_PROBE=';
  const line = stdout.split('\n').find((value) => value.startsWith(prefix));
  if (!line) throw new Error(`原生探针未上报：${stdout}`);
  const report = JSON.parse(line.slice(prefix.length)) as Record<string, unknown>;
  report.platform = iosDevice ? 'ios-simulator' : 'macos';
  report.networkRequests = networkRequests;
  console.log(JSON.stringify(report));
  if (report.pass !== true || networkRequests !== 0) throw new Error('WKWebView 隔离或生命周期探针未通过');
} finally {
  if (iosDevice && installed) {
    // 探针成功退出后 terminate 会报进程不存在；卸载仍须完成。
    await command(['xcrun', 'simctl', 'terminate', iosDevice, bundleID], 15_000).catch(() => {});
    await command(['xcrun', 'simctl', 'uninstall', iosDevice, bundleID], 20_000);
  }
  await network.stop(true);
  if (iosDevice && bootedByProbe) await command(['xcrun', 'simctl', 'shutdown', iosDevice], 20_000);
  await rm(temporary, { recursive: true, force: true });
}
