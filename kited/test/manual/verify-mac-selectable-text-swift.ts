/**
 * 手动原生合同：Mac 对话正文的 NSTextView（TextKit 2）——跨段选区与复制、嵌套列表里行内代码背景的位置、按宽度量高、
 * 流式追加只补末尾、链接点击到 openURL、滚动裁切视口、屏外附件恢复，以及 Lazy 新行首次部分露出/裁切中改宽的屏幕像素。真实的 SelectableMarkdown、MacSelectableTextView、ProseTextCoordinator、TextKitDecorations、PlatformText
 * 连同 Theme、Markdown、InlineCode、ReferenceViews 一起编进 .app 包；颜色资源用 actool 编成 Assets.car，Theme 的颜色才是真值。
 * 运行：bun kited/test/manual/verify-mac-selectable-text-swift.ts [app/Kite 目录的替代路径]
 * 第一个参数可指定一份 app/Kite 的副本（含 UI/、Files/ 和 Assets.xcassets），用来编译保留的回归快照或做判别力核验。
 * 前七个场景离屏，第八个使用屏上测试窗口；需要解锁的图形会话和可用的本窗口截图权限。
 * 不计入快测预算，不启动或操作 Kite App，不碰用户的剪贴板。
 */
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { command } from './command.ts';

const root = mkdtempSync(join(tmpdir(), 'mac-selectable-text-contract-'));
try {
  const compiler = await command(['xcrun', '--find', 'swiftc'], root);
  const sdk = await command(['xcrun', '--show-sdk-path'], root);
  const architecture = await command(['uname', '-m'], root);
  const app = process.argv[2] ?? join(import.meta.dir, '..', '..', '..', 'app', 'Kite');
  const contents = join(root, 'MacSelectableTextContract.app', 'Contents');
  mkdirSync(join(contents, 'MacOS'), { recursive: true });
  mkdirSync(join(contents, 'Resources'), { recursive: true });
  const executable = join(contents, 'MacOS', 'MacSelectableTextContract');
  await command([
    compiler, '-parse-as-library', '-swift-version', '6', '-default-isolation', 'MainActor',
    '-sdk', sdk, '-target', `${architecture}-apple-macosx26.0`,
    join(app, 'UI', 'SelectableMarkdown.swift'),
    join(app, 'UI', 'MacSelectableTextView.swift'),
    join(app, 'UI', 'ProseTextCoordinator.swift'),
    join(app, 'UI', 'TextKitDecorations.swift'),
    join(app, 'UI', 'BlockAttachment.swift'),
    join(app, 'UI', 'BlockCard.swift'),
    join(app, 'UI', 'TextSourceMap.swift'),
    join(app, 'UI', 'PlatformText.swift'),
    join(app, 'UI', 'Theme.swift'),
    join(app, 'UI', 'InterfaceMode.swift'),
    join(app, 'UI', 'InlineCode.swift'),
    join(app, 'UI', 'Markdown.swift'),
    join(app, 'Files', 'ReferenceViews.swift'),
    join(app, 'Files', 'ResourceReference.swift'),
    join(import.meta.dir, 'MacSelectableTextVerify.swift'),
    '-o', executable,
  ], root, 180_000);
  // Color("CodeBackground") 这类从主包的 Assets.car 解析，没有就是透明，代码底色量不到
  await command([
    'xcrun', 'actool', join(app, 'Assets.xcassets'), '--compile', join(contents, 'Resources'),
    '--platform', 'macosx', '--minimum-deployment-target', '26.0', '--output-format', 'human-readable-text',
  ], root, 120_000);
  writeFileSync(join(contents, 'Info.plist'), `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>MacSelectableTextContract</string>
  <key>CFBundleIdentifier</key><string>top.sainner.kite.contract.selectable-text</string>
  <key>CFBundleName</key><string>MacSelectableTextContract</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSAccentColorName</key><string>AccentColor</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
`);
  console.log(await command([executable], root, 90_000));
} finally {
  rmSync(root, { recursive: true, force: true });
}
