#!/bin/bash
# 样式迭代只编译共享 UI；独立缓存、签名和 App，不替换正式 Kite。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
DERIVED="$ROOT/build/preview-derived"
DESTINATION="$ROOT/build/preview"
SECONDS=0

mkdir -p "$DESTINATION"
xcodebuild -project "$ROOT/app/Preview/KitePreview.xcodeproj" -scheme KitePreview \
  -configuration Release -destination 'generic/platform=macOS' -derivedDataPath "$DERIVED" \
  build -quiet

STAGING="$(mktemp -d "$DESTINATION/.install.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
/usr/bin/ditto "$DERIVED/Build/Products/Release/KitePreview.app" "$STAGING/KitePreview.app"
/usr/bin/codesign --verify --deep --strict "$STAGING/KitePreview.app"

# 只关闭上一次轻量预览，正常 Kite 窗口保持运行。
/usr/bin/osascript -e 'if application id "com.sainner.kite.preview" is running then tell application id "com.sainner.kite.preview" to quit'
# quit 返回时进程可能还在退出，等它结束后再替换和重开，避免 Launch Services 返回 -600。
for ((attempt = 0; attempt < 100; attempt++)); do
  if ! /usr/bin/pgrep -x KitePreview >/dev/null; then break; fi
  sleep 0.1
done
if /usr/bin/pgrep -x KitePreview >/dev/null; then
  echo "旧预览尚未退出，请关闭后重试。" >&2
  exit 1
fi
if [ -d "$DESTINATION/KitePreview.app" ]; then
  mv "$DESTINATION/KitePreview.app" "$STAGING/previous.app"
fi
if ! mv "$STAGING/KitePreview.app" "$DESTINATION/KitePreview.app"; then
  if [ -d "$STAGING/previous.app" ]; then mv "$STAGING/previous.app" "$DESTINATION/KitePreview.app"; fi
  exit 1
fi
/usr/bin/open -n "$DESTINATION/KitePreview.app"
echo "轻量预览已打开（Release），本次构建与打开共 ${SECONDS} 秒。"
