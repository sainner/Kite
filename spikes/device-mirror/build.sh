#!/bin/sh
# 编译到 /tmp/kite-device-mirror，不进仓库。CoreDevice 是 Xcode 的私有框架，没有接口文件，用 interfaces/ 里手写的声明。
set -e
cd "$(dirname "$0")"
mkdir -p /tmp/kite-device-mirror
PF=/Library/Developer/PrivateFrameworks
swiftc -swift-version 5 -parse-as-library -O -I interfaces \
  -module-cache-path /tmp/kite-device-mirror/module-cache \
  -Xlinker -F"$PF" -Xlinker -framework -Xlinker CoreDevice \
  -Xlinker -F"$PF/CoreDevice.framework/Versions/A/Frameworks" -Xlinker -framework -Xlinker CoreDeviceMediaStreamSupport \
  mirror.swift -o /tmp/kite-device-mirror/mirror
