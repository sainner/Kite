---
name: ui-hit-testing-debugging
description: 界面事件诊断的证据边界与未排除的 simctl 探针风险
metadata:
  type: context
---

合成事件后的画面变化可能混入真实用户输入，需要确认目标收到事件；AppKit/UIKit 的 hitTest 落点也不能单独证明 SwiftUI 内部命中或手势正确。

`timeout 8 xcrun simctl launch --console-pty …` 的探针组合有内核崩溃记录，原因尚未查明，不能视为成熟流程。是否与 console-pty、强杀或并行模拟器有关均未确认，复用前须核对当前系统、诊断日志和启动方式。

只在真实悬停下出现的现象，合成的 `NSEvent` 不触发 SwiftUI 悬停，强制状态也复现不出。2026-10-11 恢复窗口时按钮组被裁，用户指出要鼠标停在停靠栏后，改用后台滚动截图加图层树记录、请用户真实操作一次，才点名是哪一层在裁。这类问题先问清触发条件，再做被动采集。

**Why:** 不可靠输入会造成诊断误判，进程命中结果和真实手势结果属于不同证据。
**How to apply:** 仅在排查事件或逻辑时使用探针并说明目的；视觉验收按 [[feedback-ui-workflow]]，采集与测量方法见 [[performance-diagnosis]]。查明崩溃原因后更新或移除对应限制，不把旧系统观察扩大为所有环境的保证。
