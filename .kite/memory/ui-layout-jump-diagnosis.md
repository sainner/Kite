---
name: ui-layout-jump-diagnosis
description: 弹窗或窗口打开时尺寸突变怎么查：启动参数让预览自己打开、日志打各段高度与窗口 resize，自己量；常见原因是初始状态在 onAppear 里才定
metadata:
  node_type: memory
  type: context
  originSessionId: 5062538f-26bf-4ce9-9a1e-8b44d40a4fcc
  modified: 2026-10-17T16:21:01.689Z
---

2026-10-18 新建工作区弹窗在 Mac 上打开时高度跳一下，量一轮就找到原因并修好（该弹窗随后按用户要求整个去掉）。经验：

- 先量后改：临时加启动参数让 Debug 预览自己打开弹窗（`preview-mac.sh --参数` 原样传给 App），用 `Logger(subsystem: "kite.probe")` 打出各段高度的变化和窗口实际的 resize，再用 `/usr/bin/log show --predicate 'subsystem == "kite.probe"'` 读回。zsh 的 `log` 是内建命令，不写全路径什么都读不到。量完删掉探针。
- 当时的原因：默认的项目和工作机在 `onAppear` 里才选上。弹窗已按没选时的内容量过高度、窗口照它打开，选上后多出一行提示，约 0.35 秒后 `CardSheetWindowSize` 把窗口改高。规则已写进 `CardSheet` 的说明：按内容定高的弹窗，影响排版的初始状态在 init 里定。
- 当时预览里开着弹窗，`preview-mac.sh` 请旧实例正常退出没成功；用户关掉弹窗后才退出。是否每次都会被弹窗挡住未核实。

**Why:** 用户要求记下这次修 bug 的经验；凭猜测改样式容易多轮无效。
**How to apply:** 窗口、弹窗、卡片的尺寸跳动或闪动，先照此量出是哪一段、哪一步变的，再改根因；诊断不靠猜，同 [[feedback-ui-workflow]]。
