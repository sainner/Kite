---
name: feedback-xcode-version
description: 打开 Xcode 界面时用 /Applications/Xcode-beta.app（27.2），不用 Xcode.app（27.0）
metadata:
  node_type: memory
  type: feedback
  originSessionId: bcdfc8a6-4617-4230-9a38-7af44db2ecd9
  modified: 2026-10-08T01:51:18.517Z
---

工作机上装了两个 Xcode：`/Applications/Xcode.app` 是 27.0，`/Applications/Xcode-beta.app` 是 27.2。用户用的是 27.2，命令行的 xcode-select 也指向它。

**Why:** 2026-10-08 我用 `open -a Xcode` 打开工程看画布预览，开成了 27.0，用户指出"27.2，你选错了"。
**How to apply:** 需要打开 Xcode 界面（画布预览、调试等）时用 `open -a /Applications/Xcode-beta.app <工程>`，不按名字 `Xcode` 打开。命令行 xcodebuild 走 xcode-select，不用另外指定。
