#!/bin/bash
# 源码入口；固定运行时只下载到构建目录，不修改用户的 Bun 或 shell 配置。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
MODE=install
SERVICE_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --package) MODE=package ;;
    --service-only) SERVICE_ONLY=1 ;;
    --help|-h)
      echo '用法：./install.command [--package] [--service-only]'
      echo '默认构建并安装 Mac App 和后台服务；--package 只生成安装包；--service-only 只处理后台服务。'
      exit 0 ;;
    *) echo "未知参数：$arg" >&2; exit 1 ;;
  esac
done
[[ "$(uname -s)" == Darwin ]] || { echo '此安装入口仅支持 macOS。' >&2; exit 1; }
[[ "$(id -u)" != 0 ]] || { echo '请用当前登录用户运行，不要使用 sudo。' >&2; exit 1; }
if [[ "$SERVICE_ONLY" == 0 ]]; then
  xcodebuild -version >/dev/null || { echo '打包 App 需要完整 Xcode，请先完成 Xcode 的首次启动。' >&2; exit 1; }
fi
VERSION=$(/usr/bin/plutil -extract devDependencies.bun raw -o - "$ROOT/kited/package.json")
BUN="$ROOT/kited/node_modules/.bin/bun"
if [[ ! -x "$BUN" ]] || [[ "$("$BUN" --version 2>/dev/null)" != "$VERSION" ]]; then
  ARCH=$(uname -m)
  [[ "$ARCH" == arm64 ]] && ARCH=aarch64
  [[ "$ARCH" == x86_64 ]] && ARCH=x64
  case "$ARCH" in aarch64|x64) ;; *) echo "不支持的架构：$ARCH" >&2; exit 1 ;; esac
  CACHE="$ROOT/build/tools/bun-$VERSION-$ARCH"
  BUN="$CACHE/bun"
  if [[ ! -x "$BUN" ]] || [[ "$("$BUN" --version 2>/dev/null)" != "$VERSION" ]]; then
    mkdir -p "$ROOT/build/tools"
    STAGE=$(mktemp -d "$ROOT/build/tools/bun.XXXXXX")
    trap 'RESULT=$?; rm -rf "$STAGE"; exit "$RESULT"' EXIT
    URL="https://github.com/oven-sh/bun/releases/download/bun-v$VERSION"
    ASSET="bun-darwin-$ARCH.zip"
    echo "下载 Bun ${VERSION}…"
    /usr/bin/curl --fail --location --retry 3 "$URL/$ASSET" -o "$STAGE/$ASSET"
    /usr/bin/curl --fail --location --retry 3 "$URL/SHASUMS256.txt" -o "$STAGE/SHASUMS256.txt"
    (cd "$STAGE"; /usr/bin/awk -v name="$ASSET" '$2 == name || $2 == "*" name { print; found=1 } END { if (!found) exit 1 }' SHASUMS256.txt > selected.sha256; /usr/bin/shasum -a 256 -c selected.sha256)
    /usr/bin/ditto -x -k "$STAGE/$ASSET" "$STAGE/extracted"
    mkdir -p "$CACHE"
    cp "$STAGE/extracted/bun-darwin-$ARCH/bun" "$BUN"
    chmod +x "$BUN"
    rm -rf "$STAGE"
    trap - EXIT
  fi
fi
cd "$ROOT/kited"
"$BUN" install --frozen-lockfile --ignore-scripts
# bun npm 包的 postinstall 默认找 node；通过上游的 --bun 入口完成引导，无需额外安装 Node。
PROJECT_BUN="$ROOT/kited/node_modules/.bin/bun"
if [[ ! -x "$PROJECT_BUN" ]] || [[ "$("$PROJECT_BUN" --version 2>/dev/null)" != "$VERSION" ]]; then
  (cd "$ROOT/kited/node_modules/bun"; "$BUN" run --bun postinstall)
fi
exec "$PROJECT_BUN" run --no-env-file scripts/package-macos.ts "$MODE" "$SERVICE_ONLY"
