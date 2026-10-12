#!/bin/sh
# 编译并打开调试 App。产物放在仓库外（默认 /tmp/kite-logo-writing），不留在 spikes 里。
# 直接运行包里的可执行文件而不是 open：读桌面上的 SVG 时沿用终端的文件权限，不会每次重编都弹授权。
# 已经开着的旧实例先退掉，只退本程序；--snapshot 不开窗口，不动开着的那个。
set -e
here=$(cd "$(dirname "$0")" && pwd)
out=${SPIKE_OUT:-/tmp/kite-logo-writing}
bundle="$out/LogoWriting.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"

sdk=$(xcrun --show-sdk-path)
arch=$(uname -m)
xcrun swiftc -parse-as-library -swift-version 6 -O \
  -sdk "$sdk" -target "$arch-apple-macosx26.0" \
  "$here/main.swift" -o "$bundle/Contents/MacOS/LogoWriting"
cp "$here/line-logo-fill.svg" "$bundle/Contents/Resources/line-logo.svg"

cat > "$bundle/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>LogoWriting</string>
  <key>CFBundleIdentifier</key><string>top.sainner.kite.spike.logowriting</string>
  <key>CFBundleName</key><string>Kite 写字 logo</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST

case " $* " in
  *" --snapshot "*) ;;
  *) pkill -f "^$bundle/Contents/MacOS/LogoWriting" 2>/dev/null || true ;;
esac
exec "$bundle/Contents/MacOS/LogoWriting" "$@"
