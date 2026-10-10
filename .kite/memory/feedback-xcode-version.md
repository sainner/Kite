---
name: feedback-xcode-version
description: 装有多个 Xcode 时核对当前工具链，按路径打开用户选定的版本
metadata:
  node_type: memory
  type: feedback
  originSessionId: bcdfc8a6-4617-4230-9a38-7af44db2ecd9
---

装有多个 Xcode 时，打开界面要按路径选择用户正在使用的版本，不按名字猜测。

**Why:** 2026-10-08 机器上同时有正式版和 beta 版，按名字打开了非用户选定的版本。
**How to apply:** 打开 Xcode 前核对当前安装项和有效工具链；命令行可能受 `DEVELOPER_DIR` 或 `xcode-select` 选择影响。有明确选择就沿用，仍有歧义再问用户。不在记忆中固定某次机器上的版本、路径或卸载结果。
