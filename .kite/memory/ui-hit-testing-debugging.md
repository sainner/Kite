---
name: ui-hit-testing-debugging
description: 点击、悬停、触摸命中问题怎么在本机复现：Mac 进程内合成点击，iPhone 用模拟器探针比 hitTest 落点
metadata:
  node_type: memory
  type: context
  originSessionId: 43afa54c-55a3-4b71-b95e-c3a0ba65565a
  modified: 2026-10-09T06:46:12.736Z
---

2026-10-09 排查停靠栏按钮点不到时的经验，环境为 macOS 27、终端没有辅助功能权限：

- 在 App 进程内用 `NSApp.postEvent` 合成 `leftMouseDown`/`leftMouseUp`，能可靠复现 SwiftUI 的点击命中。临时探针由环境变量开启，用 `app/scripts/preview-mac.sh` 编出 Debug 版运行即可，它直接连已安装的 kited。
- 悬停无法合成。`CGEvent.post` 需要辅助功能权限，没有权限时会静默失败；`CGWarpMouseCursorPosition` 只移动光标、不产生事件。看起来偶尔成功，其实是碰上用户自己在动鼠标，不能当证据。需要悬停数据时，让用户实际悬停，同时用日志记录 `onContinuousHover` 和真实指针位置。
- 窗口内容在 AppKit 层的 `hitTest` 正常，不代表 SwiftUI 内部没有被遮挡。在可疑的几层分别挂悬停记录，就能看出指针下实际收到事件的是哪一层。

2026-10-09 排查 iPhone 账号窗口控制区横滑无效时的经验：本机没有 idb 等触摸合成工具，也不能用辅助功能。用 `swiftc` 按 iOS 模拟器目标编一个最小 UIKit 探针 App（手写 Info.plist、`codesign -s -`），`simctl install` 后 `simctl launch --console-pty` 运行，在里面对几种写法分别调用 `window.hitTest` 并打印落点视图链，就能比出触摸会交给哪一层。命中测试不能证明手势一定触发，交付后仍需用户在真机上试。

**Why:** 当次先用不可靠的真实鼠标实验得出错误结论，绕了几轮。
**How to apply:** 再遇到「某处点不到」时，先用进程内合成点击复现，再用环境变量逐个关掉可疑层做对比。相关协作反馈见 [[feedback-confirm-ui-target]]。
