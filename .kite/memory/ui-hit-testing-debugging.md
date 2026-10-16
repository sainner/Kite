---
name: ui-hit-testing-debugging
description: 界面事件诊断的证据边界、光标被谁改掉的探针做法、simctl 两次内核崩溃（之后不再调用 simctl）、真机现场采集不挂调试器、真机崩溃报告怎么取
metadata:
  node_type: memory
  type: context
  originSessionId: 2b6008b7-bf52-4a23-b577-de6bc7b05c97
  modified: 2026-10-16T03:29:40.503Z
---

合成事件后的画面变化可能混入真实用户输入，需要确认目标收到事件；AppKit/UIKit 的 hitTest 落点也不能单独证明 SwiftUI 内部命中或手势正确。

用 simctl 驱动模拟器时整机内核崩溃过两次，两次的最后一步都是 `simctl launch --console-pty` 起探针再结束它：第一次是 `timeout 8 xcrun simctl launch --console-pty …`；第二次在 2026-10-13 21:19（Kernel data abort，看门狗重启，崩溃报告里是 simctl），之前一小时里同时开着五台模拟器，反复 `simctl ui content_size`、装、启动、结束 App。是 console-pty、强杀还是并行模拟器触发的，没有查清。第二次之后编排者定了不再调用 simctl（编译模拟器目标照常），界面验证改到真机（做法见 [[ios-layout-probe]]）；这是编排者的决定，用户没有直接说。

只在真实悬停下出现的现象，合成的 `NSEvent` 不触发 SwiftUI 悬停，强制状态也复现不出。2026-10-11 恢复窗口时按钮组被裁，用户指出要鼠标停在停靠栏后，改用后台滚动截图加图层树记录、请用户真实操作一次，才点名是哪一层在裁。这类问题先问清触发条件，再做被动采集。

光标被谁改掉这类只在真实悬停下出现的问题，2026-10-16 输入区光标用过一个临时探针，一轮真实操作就定位：Debug 里交换 `NSCursor.set` 和 `NSView.cursorUpdate(with:)` 的实现，记下调用栈、接收者和跟踪区域，用 `os.Logger` 写系统日志，再用 `/usr/bin/log show --predicate 'subsystem == …'` 读（zsh 的 `log` 是内建命令，不带路径读不到）。读日志前先按进程号核对用户测的是本检出的预览：其他工作树的 Kite 预览可能同时开着，那次用户测的就是 local-first 的实例。探针查完就删了，结论写在代码注释里（NativeCursor）。

现场难复现时先做不碰进程的采集：`xcrun devicectl device capture screenshot` 截真机屏、`devicectl device copy from` 取偏好和缓存。2026-10-15 iPhone 侧栏浅底白字时，用 `xcrun lldb --batch` 加 `device process attach --pid` 想读视图层级，进程没有停下（`process interrupt` 报 Process must be launched），lldb 退出后 App 被结束，现场丢失；好在用户知道怎么复现（回主屏幕再进）。没确认能停住、能放开之前，不在用户正开着的 App 上挂调试器。

真机闪退先取崩溃报告：`xcrun devicectl device info files --device <ID> --domain-type systemCrashLogs` 列出，`device copy from --source <文件名>` 取回 `.ips`。SwiftUI 环境里缺 Observable 对象这类断言，报告里只有 `EnvironmentBox.update` → `_assertionFailure` 的栈，没有报错文本和 App 帧；`log collect --device` 要 root，取不到真机日志。2026-10-16 添加窗口闪退是按栈推出机制，再用 `swiftc` 编几十行的 AppKit 小程序复现出同一条 `No Observable object` 报错、验证修法，没让用户再点一次。

**Why:** 不可靠输入会造成诊断误判，进程命中结果和真实手势结果属于不同证据。
**How to apply:** 仅在排查事件或逻辑时使用探针并说明目的；视觉验收按 [[feedback-ui-workflow]]，采集与测量方法见 [[performance-diagnosis]]。查明崩溃原因后更新或移除对应限制，不把旧系统观察扩大为所有环境的保证。
