#!/bin/bash
# 从模块缓存复制 tailscale.com，打上自定义 UDP 监听的补丁，放到 build/tailscale-kite 供 go.mod 的 replace 使用。
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
VERSION=v1.104.0
go mod download "tailscale.com@$VERSION"
SOURCE="$(go env GOMODCACHE)/tailscale.com@$VERSION"
TARGET="$ROOT/build/tailscale-kite"
rm -rf "$TARGET"
cp -R "$SOURCE" "$TARGET"
chmod -R u+w "$TARGET"
patch -d "$TARGET" -p1 < "$HERE/tailscale-packet-listener.patch"
