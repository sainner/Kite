#!/bin/bash
# 改界面时的快速预览：增量编译 Mac Debug 版，退出正在运行的 Kite 后打开新 build。
# Debug 版不带 kited，直接连本机已安装的服务；交付确认仍用 install.command 整体安装 Release。
# 参数原样传给 App，例如 --dock-preview 打开停靠栏预览。
set -euo pipefail
APP="$(cd "$(dirname "$0")/.." && pwd)"
cd "$APP"
[[ -d Vendor/TailscaleKit.xcframework ]] || scripts/build-tailscalekit.sh
# 与 .kite/check 用同一组参数，共享增量编译缓存。
ARGS=(-project Kite.xcodeproj -scheme Kite -configuration Debug -destination 'generic/platform=macOS' COMPILER_INDEX_STORE_ENABLE=NO)
xcodebuild "${ARGS[@]}" build -quiet
PRODUCTS=$(xcodebuild "${ARGS[@]}" -showBuildSettings 2>/dev/null | awk -F' = ' '$1 ~ / BUILT_PRODUCTS_DIR$/ { print $2; exit }')
for _ in $(seq 40); do
  pgrep -xq Kite || break
  osascript -e 'tell application id "com.sainner.kite" to quit' >/dev/null
  sleep 0.5
done
if pgrep -xq Kite; then echo '旧的 Kite 没有退出，请手动退出后重试。' >&2; exit 1; fi
if (( $# )); then open "$PRODUCTS/Kite.app" --args "$@"; else open "$PRODUCTS/Kite.app"; fi
