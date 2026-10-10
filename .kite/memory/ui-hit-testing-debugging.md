---
name: ui-hit-testing-debugging
description: 界面事件诊断的证据限制与一次尚未查明的 simctl 内核崩溃记录
metadata:
  node_type: memory
  type: context
  originSessionId: 43afa54c-55a3-4b71-b95e-c3a0ba65565a
---

2026-10-09 在 macOS 27、终端没有辅助功能权限的条件下排查命中问题，留下两项诊断限制：

- 移动光标或发送事件后看似生效，可能混入用户自己的操作；需要确认目标确实收到事件，不能凭画面变化认定合成输入成功。
- AppKit/UIKit 的 hitTest 落点不能独自证明 SwiftUI 内部的命中或手势行为正确。

同日 22:12 与 22:15，运行 `timeout 8 xcrun simctl launch --console-pty …` 探针时两次发生内核 panic；当时系统为 macOS 27.2 26B5101f，panic 记录中的进程均为 simctl。尚未确认是 console-pty、强杀还是并行模拟器导致，也没有验证替代启动方式安全。原始日志入口：`/Library/Logs/DiagnosticReports/Retired/panic-full-*.panic`。

**Why:** 当次把不可靠输入当作证据导致误判；内核崩溃的原因仍未解决，不能把同一探针命令当成熟流程复用。
**How to apply:** 仅在排查逻辑或事件路由时使用这些背景，并先说明测量目的；视觉验收按 [[user-previews-ui]] 交用户。遇到相同 simctl 环境先核对日志与系统版本，查明前避免复用上述组合；解决后更新或删除这条事故记录。
