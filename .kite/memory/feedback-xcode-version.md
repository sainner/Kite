---
name: feedback-xcode-version
description: 装有多个 Xcode 时按路径打开用户在用的那个；2026-10-10 起只剩 Xcode.app（27.1）
metadata:
  node_type: memory
  type: feedback
  originSessionId: bcdfc8a6-4617-4230-9a38-7af44db2ecd9
  modified: 2026-10-10T06:41:01.246Z
---

装有多个 Xcode 时，打开 Xcode 界面要按路径选用户在用的版本，不能按名字 `open -a Xcode` 打开。2026-10-10 核对时，工作机上只剩 `/Applications/Xcode.app`（27.1），`xcode-select` 也指向它；之前的 `Xcode-beta.app`（27.2）已不在。

**Why:** 2026-10-08 机器上同时有 Xcode.app（27.0）和 Xcode-beta.app（27.2），我按名字打开了 27.0，用户指出用的是 27.2。
**How to apply:** 打开 Xcode 界面（画布预览、调试等）前先 `ls -d /Applications/Xcode*.app` 看装了哪些；只有一个就直接用，有多个就用 `xcode-select -p` 指向的那个，或者问用户。命令行 xcodebuild 走 xcode-select，不用另外指定。
