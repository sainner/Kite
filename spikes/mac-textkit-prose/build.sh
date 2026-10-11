#!/bin/sh
# 编译并运行实验。产物放在仓库外（默认 /tmp/kite-textkit-spike），不留在 spikes 里。
#   ./build.sh --auto <日志目录>    自动跑完七件事，report.txt 和截图写到日志目录
#   ./build.sh                      手动模式，窗口顶上有按钮
# 真实的 App 源文件直接编进来（Theme/Metrics、MarkdownView、ReferenceLabel、InlineCode），缺的类型由 Stubs.swift 补；
# 颜色资源用 actool 从 app/Kite/Assets.xcassets 编成 Assets.car 放进 .app 包，Color("CodeBackground") 这类才解析得出来。
set -e
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
app="$repo/app/Kite"
out=${SPIKE_OUT:-/tmp/kite-textkit-spike}
bundle="$out/MacTextKitProse.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"

sdk=$(xcrun --show-sdk-path)
arch=$(uname -m)
xcrun swiftc -parse-as-library -swift-version 6 -default-isolation MainActor -O \
  -sdk "$sdk" -target "$arch-apple-macosx26.0" \
  "$app/UI/Theme.swift" "$app/UI/InterfaceMode.swift" "$app/UI/InlineCode.swift" "$app/UI/Markdown.swift" \
  "$app/UI/ControlPointer.swift" "$app/Files/ReferenceViews.swift" "$app/Files/ResourceReference.swift" \
  "$here/Stubs.swift" "$here/ProseTextView.swift" "$here/main.swift" \
  -o "$bundle/Contents/MacOS/MacTextKitProse"

xcrun actool "$app/Assets.xcassets" --compile "$bundle/Contents/Resources" --platform macosx \
  --minimum-deployment-target 26.0 --output-format human-readable-text >/dev/null

cat > "$bundle/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>MacTextKitProse</string>
  <key>CFBundleIdentifier</key><string>top.sainner.kite.spike.textkit</string>
  <key>CFBundleName</key><string>MacTextKitProse</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSAccentColorName</key><string>AccentColor</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST

exec "$bundle/Contents/MacOS/MacTextKitProse" "$@"
