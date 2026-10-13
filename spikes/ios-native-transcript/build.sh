#!/bin/sh
# 编译实验 App、装进 iOS 模拟器、按项跑完取回报告。产物在仓库外（默认 /tmp/kite-ios-native-spike），不留在 spikes 里。
#   ./build.sh v1|v2|v3 [模拟器 UDID]   不给 UDID 用已启动的第一台
# App 的共用量高协议 app/Kite/UI/TextKitMeasuring.swift 直接编进来，V1 的文本视图遵循它。
set -e
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
test=${1:-v1}
device=${2:-$(xcrun simctl list devices booted | awk -F'[()]' '/Booted/ { print $2; exit }')}
out=${SPIKE_OUT:-/tmp/kite-ios-native-spike}
bundle="$out/IOSNativeTranscript.app"
id=top.sainner.kite.spike.ios-native-transcript
mkdir -p "$bundle"

xcrun --sdk iphonesimulator swiftc -parse-as-library -swift-version 6 -default-isolation MainActor -O \
  -sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" -target arm64-apple-ios26.0-simulator \
  "$repo/app/Kite/UI/TextKitMeasuring.swift" \
  "$here/App.swift" "$here/V1Viewport.swift" "$here/V2Geometry.swift" "$here/V3Edges.swift" \
  -o "$bundle/IOSNativeTranscript"

cat > "$bundle/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>IOSNativeTranscript</string>
  <key>CFBundleIdentifier</key><string>$id</string>
  <key>CFBundleName</key><string>IOSNativeTranscript</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>MinimumOSVersion</key><string>26.0</string>
  <key>UIDeviceFamily</key><array><integer>1</integer><integer>2</integer></array>
  <key>UILaunchScreen</key><dict/>
  <key>UIApplicationSceneManifest</key><dict><key>UIApplicationSupportsMultipleScenes</key><false/></dict>
  <key>CADisableMinimumFrameDurationOnPhone</key><true/>
  <key>UISupportedInterfaceOrientations</key><array><string>UIInterfaceOrientationPortrait</string></array>
  <key>UISupportedInterfaceOrientations~ipad</key><array><string>UIInterfaceOrientationPortrait</string><string>UIInterfaceOrientationLandscapeLeft</string><string>UIInterfaceOrientationLandscapeRight</string></array>
</dict></plist>
PLIST
codesign --force --sign - "$bundle" >/dev/null 2>&1

xcrun simctl terminate "$device" "$id" >/dev/null 2>&1 || true
xcrun simctl install "$device" "$bundle"
data=$(xcrun simctl get_app_container "$device" "$id" data)
rm -f "$data/tmp/done-$test" "$data/tmp/report-$test.txt" "$data"/tmp/shoot-* "$data"/tmp/shot-* "$data"/tmp/*.png
mkdir -p "$out/reports"
xcrun simctl launch "$device" "$id" -test "$test" >/dev/null
# App 要截屏时写 shoot-<名字>，这边用 simctl 拍下整屏（含系统的滚动软边、键盘），再写 shot-<名字> 放行
i=0
while [ ! -f "$data/tmp/done-$test" ] && [ $i -lt 600 ]; do
  for request in "$data"/tmp/shoot-*; do
    [ -f "$request" ] || continue
    name=${request##*/shoot-}
    [ -f "$data/tmp/shot-$name" ] && continue
    xcrun simctl io "$device" screenshot "$out/reports/$test-$name.png" >/dev/null 2>&1
    touch "$data/tmp/shot-$name"
  done
  sleep 0.2
  i=$((i + 1))
done
cp "$data/tmp/report-$test.txt" "$out/reports/" 2>/dev/null || { echo "没等到报告"; exit 1; }
for f in "$data"/tmp/*.png; do [ -f "$f" ] && cp "$f" "$out/reports/"; done
cat "$out/reports/report-$test.txt"
