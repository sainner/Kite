---
name: ui-hit-testing-debugging
description: Mac App 点击、悬停命中问题怎么在本机复现：进程内合成点击可靠，悬停无法合成
metadata:
  node_type: memory
  type: context
  originSessionId: 43afa54c-55a3-4b71-b95e-c3a0ba65565a
  modified: 2026-10-09T02:40:02.426Z
---

2026-10-09 排查停靠栏按钮点不到时的经验，环境为 macOS 27、终端没有辅助功能权限：

- 在 App 进程内用 `NSApp.postEvent` 合成 `leftMouseDown`/`leftMouseUp`，能可靠复现 SwiftUI 的点击命中。临时探针由环境变量开启，用 `./package-mac.command` 打包，直接运行包里的二进制。直接运行 Xcode 编译产物会缺少内置的 kited。
- 悬停无法合成。`CGEvent.post` 需要辅助功能权限，没有权限时会静默失败；`CGWarpMouseCursorPosition` 只移动光标、不产生事件。看起来偶尔成功，其实是碰上用户自己在动鼠标，不能当证据。需要悬停数据时，让用户实际悬停，同时用日志记录 `onContinuousHover` 和真实指针位置。
- 窗口内容在 AppKit 层的 `hitTest` 正常，不代表 SwiftUI 内部没有被遮挡。在可疑的几层分别挂悬停记录，就能看出指针下实际收到事件的是哪一层。

**Why:** 当次先用不可靠的真实鼠标实验得出错误结论，绕了几轮。
**How to apply:** 再遇到「某处点不到」时，先用进程内合成点击复现，再用环境变量逐个关掉可疑层做对比。相关协作反馈见 [[feedback-confirm-ui-target]]。
