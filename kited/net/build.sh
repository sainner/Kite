#!/bin/bash
# 构建 kite-net：先把 tailscale.com 打上自定义 UDP 监听的补丁（受管网络通道要用），再编译到 bin/kite-net。
# 打过补丁的副本放在仓库的 build/tailscale-kite，版本或补丁变了才重建；go.mod 用 replace 指向它。
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
cd "$HERE"
VERSION=$(awk '$1 == "require" && $2 == "tailscale.com" { print $3 } $1 == "tailscale.com" { print $2 }' go.mod | head -1)
PATCH="$HERE/tailscale-packet-listener.patch"
TARGET="$ROOT/build/tailscale-kite"
STAMP="$VERSION $(shasum -a 256 "$PATCH" | cut -d' ' -f1)"
if [[ ! -f "$TARGET/.kite-patch" || "$(cat "$TARGET/.kite-patch")" != "$STAMP" ]]; then
  GOFLAGS=-mod=mod go mod download "tailscale.com@$VERSION"
  SOURCE="$(go env GOMODCACHE)/tailscale.com@$VERSION"
  rm -rf "$TARGET"
  mkdir -p "$(dirname "$TARGET")"
  cp -R "$SOURCE" "$TARGET"
  chmod -R u+w "$TARGET"
  patch -s -d "$TARGET" -p1 < "$PATCH"
  echo "$STAMP" > "$TARGET/.kite-patch"
fi
go build -trimpath -o "${1:-$HERE/bin/kite-net}" .
