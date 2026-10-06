#!/bin/bash
# 构建 App 内嵌的组网库 TailscaleKit（libtailscale 的 Swift 封装），产物不入库。
# 需要 Go 与 Xcode；输出 app/Vendor/TailscaleKit.xcframework，含 macOS、iOS 与 iOS 模拟器。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
COMMIT=59d4bb82744915815178e0f0776d60026a397ee7
SOURCE="$ROOT/build/libtailscale"
OUTPUT="$ROOT/app/Vendor/TailscaleKit.xcframework"
if [[ ! -d "$SOURCE/.git" ]]; then git clone https://github.com/tailscale/libtailscale "$SOURCE"; fi
git -C "$SOURCE" fetch --depth 1 origin "$COMMIT" 2>/dev/null || true
git -C "$SOURCE" checkout --quiet "$COMMIT"
cd "$SOURCE/swift"
make macos ios-sim ios
PRODUCTS="$SOURCE/swift/build/Build/Products"
rm -rf "$OUTPUT"
mkdir -p "$(dirname "$OUTPUT")"
xcodebuild -create-xcframework \
  -framework "$PRODUCTS/Release/TailscaleKit.framework" \
  -framework "$PRODUCTS/Release-iphoneos/TailscaleKit.framework" \
  -framework "$PRODUCTS/Release-iphonesimulator/TailscaleKit.framework" \
  -output "$OUTPUT"
