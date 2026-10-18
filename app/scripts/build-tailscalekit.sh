#!/bin/bash
# 构建 App 内嵌的组网库 TailscaleKit（libtailscale 的 Swift 封装），产物不入库。
# 需要 Go 与 Xcode；输出 app/Vendor/TailscaleKit.xcframework，含 macOS、iOS 与 iOS 模拟器。
# 构建时往 libtailscale 里加 Kite 的源文件（libtailscale-ios-buffers.go）；版本或这个文件变了才重建，没变直接退出，调用方每次都跑它。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
COMMIT=59d4bb82744915815178e0f0776d60026a397ee7
EXTRA="$ROOT/app/scripts/libtailscale-ios-buffers.go"
SOURCE="$ROOT/build/libtailscale"
OUTPUT="$ROOT/app/Vendor/TailscaleKit.xcframework"
STAMP_FILE="$ROOT/app/Vendor/TailscaleKit.stamp"
STAMP="$COMMIT $(shasum -a 256 "$EXTRA" | cut -d' ' -f1)"
if [[ -d "$OUTPUT" && -f "$STAMP_FILE" && "$(cat "$STAMP_FILE")" == "$STAMP" ]]; then exit 0; fi
if [[ ! -d "$SOURCE/.git" ]]; then git clone https://github.com/tailscale/libtailscale "$SOURCE"; fi
git -C "$SOURCE" fetch --depth 1 origin "$COMMIT" 2>/dev/null || true
git -C "$SOURCE" checkout --quiet "$COMMIT"
# 静态库的 make 目标没有依赖，库文件在就不重编，先清掉上次的产物。
git -C "$SOURCE" clean -fdxq
cp "$EXTRA" "$SOURCE/kite_ios_buffers.go"
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
echo "$STAMP" > "$STAMP_FILE"
