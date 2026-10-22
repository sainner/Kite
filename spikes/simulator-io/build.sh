#!/bin/sh
# 编译 simio，产物放在仓库外。
set -e
out="${SIMIO_OUT:-/tmp/kite-simio}"
mkdir -p "$out"
clang -fobjc-arc -O2 -Wall -Wno-unused-function \
  -framework Foundation -framework CoreGraphics -framework ImageIO -framework IOSurface -framework UniformTypeIdentifiers \
  "$(dirname "$0")/simio.m" -o "$out/simio"
echo "$out/simio"
