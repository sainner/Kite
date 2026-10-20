/** macOS 本地安装包：源码、生产依赖和 Bun 保持原目录关系，供沙箱与 SDK 的子进程使用。 */
import { chmodSync, copyFileSync, cpSync, existsSync, mkdirSync, mkdtempSync, renameSync, rmSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { buildPluginHost } from './build-plugin-web.ts';
import { buildOf, listFiles, unlisted } from '../src/update/files.ts';
import { PROTOCOL } from '../src/version.ts';
import pkg from '../package.json';

const root = resolve(import.meta.dir, '../..');
const build = join(root, 'build');
const serviceOnly = process.argv[3] === '1';
const mode = process.argv[2];

async function run(command: string[], cwd = root): Promise<void> {
  const child = Bun.spawn(command, { cwd, env: process.env, stdout: 'inherit', stderr: 'inherit' });
  if (await child.exited !== 0) throw new Error(`命令失败：${command[0]}`);
}

/** 代理的 shell 说明写着可用 rg 搜索，工作机不一定装了；固定版本与校验和，下载一次缓存在 build/tools。 */
const ripgrep = { version: '15.2.0', sha256: {
  arm64: '3750b2e93f37e0c692657da574d7019a101c0084da05a790c83fd335bad973e4',
  x64: 'af7825fcc69a2afc7a7aea55fc9af90e26421d8f20fe59df32e233c0b8a231c1' } as Record<string, string> };

async function ripgrepBinary(): Promise<string> {
  const expected = ripgrep.sha256[process.arch];
  if (!expected) throw new Error(`没有 ${process.arch} 架构的 ripgrep`);
  const name = `ripgrep-${ripgrep.version}-${process.arch === 'arm64' ? 'aarch64' : 'x86_64'}-apple-darwin`;
  const tools = join(build, 'tools');
  const cached = join(tools, name, 'rg');
  if (existsSync(cached)) return cached;
  console.log(`下载 ripgrep ${ripgrep.version}…`);
  const response = await fetch(`https://github.com/BurntSushi/ripgrep/releases/download/${ripgrep.version}/${name}.tar.gz`);
  if (!response.ok) throw new Error(`下载 ripgrep 失败：HTTP ${response.status}`);
  const archive = new Uint8Array(await response.arrayBuffer());
  if (new Bun.CryptoHasher('sha256').update(archive).digest('hex') !== expected) throw new Error('ripgrep 校验和不符');
  mkdirSync(tools, { recursive: true });
  const stage = mkdtempSync(join(tools, 'ripgrep.'));
  try {
    writeFileSync(join(stage, 'archive.tar.gz'), archive);
    await run(['/usr/bin/tar', '-xzf', join(stage, 'archive.tar.gz'), '-C', stage, `${name}/rg`]);
    renameSync(join(stage, name), join(tools, name));
  } finally { rmSync(stage, { recursive: true, force: true }); }
  return cached;
}

async function gitOutput(command: string[]): Promise<string> {
  const child = Bun.spawn(command, { cwd: root, env: process.env, stdout: 'pipe', stderr: 'inherit' });
  const [text, code] = await Promise.all([new Response(child.stdout).text(), child.exited]);
  if (code !== 0) throw new Error(`命令失败：${command[0]}`);
  return text.trim();
}

async function main(): Promise<void> {
  if (process.platform !== 'darwin' || !['install', 'package'].includes(mode ?? '')) throw new Error('请从 install.command 或 package-mac.command 运行');
  if (Bun.version !== pkg.devDependencies.bun) throw new Error(`打包需要 Bun ${pkg.devDependencies.bun}`);
  mkdirSync(build, { recursive: true });
  const name = `${serviceOnly ? 'kited' : 'Kite'}-macOS-${process.arch}`;
  const temporary = mkdtempSync(join(build, '.package-'));
  const bundle = join(temporary, name);
  const runtime = join(bundle, 'runtime');
  const kited = join(runtime, 'kited');
  try {
    console.log('准备独立运行目录…');
    mkdirSync(join(runtime, 'bin'), { recursive: true });
    mkdirSync(join(kited, 'scripts'), { recursive: true });
    copyFileSync(process.execPath, join(runtime, 'bin/bun'));
    chmodSync(join(runtime, 'bin/bun'), 0o755);
    copyFileSync(await ripgrepBinary(), join(runtime, 'bin/rg'));
    chmodSync(join(runtime, 'bin/rg'), 0o755);
    cpSync(join(root, 'kited/src'), join(kited, 'src'), { recursive: true });
    cpSync(join(root, 'shared'), join(runtime, 'shared'), { recursive: true });
    const templates = '.claude/skills/kite-onboard/templates';
    mkdirSync(join(runtime, templates), { recursive: true });
    for (const file of ['gitignore', 'gitattributes']) copyFileSync(join(root, templates, file), join(runtime, templates, file));
    for (const file of ['package.json', 'bun.lock']) copyFileSync(join(root, 'kited', file), join(kited, file));
    copyFileSync(join(import.meta.dir, 'install-macos.ts'), join(kited, 'scripts/install-macos.ts'));
    writeFileSync(join(kited, 'bunfig.toml'), '[run]\nshell = "system"\n');
    console.log('构建组网程序 kite-net…');
    if (!Bun.which('go')) throw new Error('构建组网程序需要 Go，请先安装（如 brew install go）');
    // 构建脚本先给 tailscale 打上受管网络通道要用的补丁。
    await run([join(root, 'kited/net/build.sh'), join(kited, 'net/bin/kite-net')], join(root, 'kited/net'));
    await run([process.execPath, 'install', '--production', '--frozen-lockfile', '--ignore-scripts'], kited);
    // 在独立目录加载入口依赖，尽早发现仓库外模板或运行资源漏装；不启动服务或读取用户数据库。
    await run([join(runtime, 'bin/bun'), '--no-env-file', '--no-install', '-e', 'await import("./src/daemon.ts")'], kited);

    if (!serviceOnly) {
      console.log('构建 Mac Release App…');
      await Bun.write(join(root, 'app/Kite/Resources/Generated/PluginHost.html'), await buildPluginHost());
      await run([join(root, 'app/scripts/build-tailscalekit.sh')]);
      const derived = join(build, 'macos-derived');
      await run(['xcodebuild', '-project', join(root, 'app/Kite.xcodeproj'), '-scheme', 'Kite',
        '-configuration', 'Release', '-destination', 'generic/platform=macOS', '-derivedDataPath', derived,
        '-onlyUsePackageVersionsFromResolvedFile', 'build', '-quiet', `ARCHS=${process.arch === 'arm64' ? 'arm64' : 'x86_64'}`,
        'ONLY_ACTIVE_ARCH=NO', 'COMPILER_INDEX_STORE_ENABLE=NO', 'CODE_SIGN_STYLE=Manual',
        'CODE_SIGN_IDENTITY=-', 'DEVELOPMENT_TEAM=', 'KITE_PREVIEW_FLAGS=']);
      await run(['/usr/bin/ditto', join(derived, 'Build/Products/Release/Kite.app'), join(bundle, 'Kite.app')]);
      await run(['/usr/bin/codesign', '--verify', '--deep', '--strict', join(bundle, 'Kite.app')]);
    }
    console.log('生成文件清单…');
    const files = await listFiles(runtime, unlisted);
    const buildId = buildOf(files);
    const commit = await gitOutput(['git', 'rev-parse', '--short=12', 'HEAD']) + (await gitOutput(['git', 'status', '--porcelain']) ? '-dirty' : '');
    writeFileSync(join(runtime, 'files.json'), JSON.stringify(files));
    writeFileSync(join(runtime, 'manifest.json'), JSON.stringify({ platform: 'darwin', arch: process.arch,
      bun: Bun.version, builtAt: new Date().toISOString(), build: buildId, protocol: PROTOCOL, commit }, null, 2) + '\n');
    if (!serviceOnly) {
      const resources = join(bundle, 'Kite.app/Contents/Resources/Service');
      mkdirSync(resources, { recursive: true });
      renameSync(runtime, join(resources, 'runtime'));
      await run(['/usr/bin/codesign', '--force', '--deep', '--sign', '-', join(bundle, 'Kite.app')]);
      await run(['/usr/bin/codesign', '--verify', '--deep', '--strict', join(bundle, 'Kite.app')]);
      // 自动更新按文件清单在工作机之间传运行目录，签名不能改动其中的文件。
      if (buildOf(await listFiles(join(resources, 'runtime'), unlisted)) !== buildId) throw new Error('签名改动了运行目录里的文件');
    }
    writeFileSync(join(bundle, '安装.command'), serviceOnly ? `#!/bin/bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
exec "$HERE/runtime/bin/bun" run --no-env-file --no-install "$HERE/runtime/kited/scripts/install-macos.ts" install
` : `#!/bin/bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
DESTINATION="\${KITE_APPLICATIONS_DIR:-$HOME/Applications}"
mkdir -p "$DESTINATION"
if /bin/ps -axo command= | /usr/bin/grep -F "$DESTINATION/Kite.app/Contents/MacOS/Kite" | /usr/bin/grep -v grep >/dev/null; then
  echo "请先退出 Kite App，再重新安装。"
  exit 1
fi
/usr/bin/codesign --verify --deep --strict "$HERE/Kite.app"
STAGING="$(mktemp -d "$DESTINATION/.kite-install.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
/usr/bin/ditto "$HERE/Kite.app" "$STAGING/Kite.app"
/usr/bin/codesign --verify --deep --strict "$STAGING/Kite.app"
if [ -e "$DESTINATION/Kite.app" ]; then mv "$DESTINATION/Kite.app" "$STAGING/previous.app"; fi
if ! mv "$STAGING/Kite.app" "$DESTINATION/Kite.app"; then
  if [ -e "$STAGING/previous.app" ] && ! mv "$STAGING/previous.app" "$DESTINATION/Kite.app"; then
    trap - EXIT
    echo "恢复旧 App 失败，已保留备份：$STAGING/previous.app"
  fi
  exit 1
fi
echo "Kite App 已安装；首次配置选择本机执行时会安装 kited。"
if [ "\${KITE_NO_OPEN:-0}" != "1" ]; then /usr/bin/open "$DESTINATION/Kite.app"; fi
`, { mode: 0o755 });
    writeFileSync(join(bundle, '安装说明.txt'), `Kite 本地安装包（${process.arch}）

解压后双击「安装.command」，${serviceOnly ? '安装当前用户的 kited 后台服务' : '安装 ~/Applications/Kite.app；登录后选择本机执行才会安装 kited，仅远程控制不会安装服务'}。
需要 macOS ${serviceOnly ? '及 Git' : '26 或更新版本及 Git'}，不需要安装 Bun${serviceOnly ? '' : '或完整 Xcode'}。缺少 Git 时先运行 xcode-select --install。
安装后可移走此目录。重复运行安装器可升级；数据与登录保留在 ~/.kite。
~/.local/bin/kite-service 提供 status、start、stop、restart 和 uninstall。卸载保留数据与登录。
首次使用模型还需按项目文档在此工作机完成设备登录。

这是本地开发安装包，App 使用临时签名，尚未进行 Developer ID 签名与 Apple 公证。
跨机器分发时系统可能阻止打开；正式分发前需补充签名与公证，不要关闭系统安全检查。
`);
    const output = join(build, name);
    const archive = join(build, `${name}.zip`);
    const archiveStage = join(temporary, `${name}.zip`);
    console.log('生成安装压缩包…');
    await run(['/usr/bin/ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', bundle, archiveStage]);
    if (existsSync(output)) rmSync(output, { recursive: true });
    renameSync(bundle, output);
    renameSync(archiveStage, archive);
    console.log(`安装目录：${output}\n安装压缩包：${archive}`);
    if (mode === 'install') await run([join(output, '安装.command')]);
  } finally { rmSync(temporary, { recursive: true, force: true }); }
}

await main().catch((error: unknown) => { console.error(`打包失败：${String(error)}`); process.exitCode = 1; });
