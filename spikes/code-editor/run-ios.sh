#!/bin/bash
# 编开了优化的 iOS Debug 版装进真机，跑编辑器探针，等它写完报告退出后取回。
#   ./run-ios.sh <设备 ID> normal|big [-editorProbeCheck NO]
# 先按 README 把 EditorProbe.swift 放进 app/Kite/Verification/、打上 KiteApp-hook.diff。装进去的 Debug 版会替换设备上的 Kite。
set -e
repo=$(cd "$(dirname "$0")/../.." && pwd)
out=${SPIKE_OUT:-/tmp/kite-code-editor-spike}
device=$1; file=${2:-normal}
cd "$repo/app"
xcodebuild -project Kite.xcodeproj -scheme Kite -configuration Debug -destination "id=$device" -derivedDataPath "$out/ios" \
  -allowProvisioningUpdates COMPILER_INDEX_STORE_ENABLE=NO SWIFT_OPTIMIZATION_LEVEL=-O GCC_OPTIMIZATION_LEVEL=s \
  SWIFT_COMPILATION_MODE=wholemodule build -quiet
xcrun devicectl device install app --device "$device" "$out/ios/Build/Products/Debug-iphoneos/Kite.app" >/dev/null
rm -f "$out/ios-$file.txt"
xcrun devicectl device process launch --device "$device" --terminate-existing com.sainner.kite -- -editorProbe "$file" "${@:3}" >/dev/null
for _ in $(seq 1 90); do
  sleep 4
  # 报告写完 App 就退出；等进程没了再取，免得取到上一次的
  xcrun devicectl device info processes --device "$device" 2>/dev/null | grep -q "Kite.app/Kite" || break
done
xcrun devicectl device copy from --device "$device" --domain-type appDataContainer --domain-identifier com.sainner.kite \
  --source "Library/Caches/editor-probe-$file.txt" --destination "$out/ios-$file.txt" >/dev/null
cat "$out/ios-$file.txt"
