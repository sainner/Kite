#!/bin/bash
# 编开了优化的 Mac Debug 版（探针只编进 Debug），跑编辑器探针，报告打到终端。
#   ./run-mac.sh normal|big [-editorProbeCheck NO]
# 先按 README 把 EditorProbe.swift 放进 app/Kite/Verification/、打上 KiteApp-hook.diff。
set -e
repo=$(cd "$(dirname "$0")/../.." && pwd)
out=${SPIKE_OUT:-/tmp/kite-code-editor-spike}
cd "$repo/app"
ARGS=(-project Kite.xcodeproj -scheme Kite -configuration Debug -destination 'generic/platform=macOS' -derivedDataPath "$out/mac"
      COMPILER_INDEX_STORE_ENABLE=NO SWIFT_OPTIMIZATION_LEVEL=-O GCC_OPTIMIZATION_LEVEL=s SWIFT_COMPILATION_MODE=wholemodule)
xcodebuild "${ARGS[@]}" build -quiet
"$out/mac/Build/Products/Debug/Kite.app/Contents/MacOS/Kite" -editorProbe "${1:-normal}" "${@:2}" 2>/dev/null | grep "editor-probe" | sed 's/^editor-probe: //'
