---
name: ui-hit-testing-debugging
description: 界面事件诊断的证据边界、simctl 两次内核崩溃（之后不再调用 simctl）、真机现场采集不挂调试器
metadata:
  node_type: memory
  type: context
  originSessionId: 2b6008b7-bf52-4a23-b577-de6bc7b05c97
  modified: 2026-10-15T03:23:40.964Z
---

合成事件后的画面变化可能混入真实用户输入，需要确认目标收到事件；AppKit/UIKit 的 hitTest 落点也不能单独证明 SwiftUI 内部命中或手势正确。

用 simctl 驱动模拟器时整机内核崩溃过两次，两次的最后一步都是 `simctl launch --console-pty` 起探针再结束它：第一次是 `timeout 8 xcrun simctl launch --console-pty …`；第二次在 2026-10-13 21:19（Kernel data abort，看门狗重启，崩溃报告里是 simctl），之前一小时里同时开着五台模拟器，反复 `simctl ui content_size`、装、启动、结束 App。是 console-pty、强杀还是并行模拟器触发的，没有查清。第二次之后编排者定了不再调用 simctl（编译模拟器目标照常），界面验证改到真机（做法见 [[ios-layout-probe]]）；这是编排者的决定，用户没有直接说。

只在真实悬停下出现的现象，合成的 `NSEvent` 不触发 SwiftUI 悬停，强制状态也复现不出。2026-10-11 恢复窗口时按钮组被裁，用户指出要鼠标停在停靠栏后，改用后台滚动截图加图层树记录、请用户真实操作一次，才点名是哪一层在裁。这类问题先问清触发条件，再做被动采集。

现场难复现时先做不碰进程的采集：`xcrun devicectl device capture screenshot` 截真机屏、`devicectl device copy from` 取偏好和缓存。2026-10-15 iPhone 侧栏浅底白字时，用 `xcrun lldb --batch` 加 `device process attach --pid` 想读视图层级，进程没有停下（`process interrupt` 报 Process must be launched），lldb 退出后 App 被结束，现场丢失；好在用户知道怎么复现（回主屏幕再进）。没确认能停住、能放开之前，不在用户正开着的 App 上挂调试器。

**Why:** 不可靠输入会造成诊断误判，进程命中结果和真实手势结果属于不同证据。
**How to apply:** 仅在排查事件或逻辑时使用探针并说明目的；视觉验收按 [[feedback-ui-workflow]]，采集与测量方法见 [[performance-diagnosis]]。查明崩溃原因后更新或移除对应限制，不把旧系统观察扩大为所有环境的保证。
