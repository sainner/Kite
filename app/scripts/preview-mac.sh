#!/bin/bash
# 改界面时的快速预览：增量编译 Mac Debug 版，退出本检出上次打开的预览，再另起一个实例打开新 build。
# 主线和各工作树的 Kite 共用 bundle ID 与登录，按可执行文件路径只请自己这份退出，其他检出的 Kite 照常开着。
# 不为预览另换 bundle ID：新 ID 读不到钥匙串里的 Kite 登录，在工作机上重登会重装并重新入网本机 kited。
# Debug 版不带 kited，直接连本机已安装的服务；交付确认仍用 install.command 整体安装 Release。
# 参数原样传给 App，例如 --dock-preview 打开停靠栏预览。
set -euo pipefail
APP="$(cd "$(dirname "$0")/.." && pwd)"
cd "$APP"
scripts/build-tailscalekit.sh
# 与 .kite/check 用同一组参数，共享增量编译缓存。
ARGS=(-project Kite.xcodeproj -scheme Kite -configuration Debug -destination 'generic/platform=macOS' COMPILER_INDEX_STORE_ENABLE=NO)
xcodebuild "${ARGS[@]}" build -quiet
PRODUCTS=$(xcodebuild "${ARGS[@]}" -showBuildSettings 2>/dev/null | awk -F' = ' '$1 ~ / BUILT_PRODUCTS_DIR$/ { print $2; exit }')
# DerivedData 的目录可能是指向 .noindex 的链接，进程的路径是解析后的：按真实路径找，不然认不出上次开的，每次都多开一个
PRODUCTS=$(cd "$PRODUCTS" && pwd -P)
EXE="^$PRODUCTS/Kite.app/Contents/MacOS/Kite"
# 按进程号请它正常退出，同 bundle ID 的其他实例收不到
for _ in $(seq 40); do
  pids=$(pgrep -f "$EXE" || true)
  [[ -n "$pids" ]] || break
  for pid in $pids; do
    osascript -l JavaScript -e "ObjC.import('AppKit'); \$.NSRunningApplication.runningApplicationWithProcessIdentifier($pid).terminate" >/dev/null
  done
  sleep 0.5
done
if pgrep -qf "$EXE"; then echo '本检出的 Kite 没有退出，请手动退出后重试。' >&2; exit 1; fi
if (( $# )); then open -n "$PRODUCTS/Kite.app" --args "$@"; else open -n "$PRODUCTS/Kite.app"; fi
