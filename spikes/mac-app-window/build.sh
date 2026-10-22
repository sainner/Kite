#!/bin/sh
# 编译靶子 App 和探针，产物放在 /tmp/kite-appwin，不进仓库。
set -e
cd "$(dirname "$0")"
mkdir -p /tmp/kite-appwin
clang -fobjc-arc -O2 -framework AppKit target.m -o /tmp/kite-appwin/target
clang -fobjc-arc -O2 -framework AppKit -framework ApplicationServices -framework ScreenCaptureKit -framework ImageIO -framework UniformTypeIdentifiers probe.m -o /tmp/kite-appwin/probe
