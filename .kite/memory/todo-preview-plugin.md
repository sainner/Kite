---
name: todo-preview-plugin
description: 预览插件（网页从终端移入、工作机上的浏览器、模拟器、Mac App 窗口、逐帧点按、agent 的 computer use）已决定未实现；docs 不收的界面细节与参照
metadata:
  node_type: memory
  type: todo
  originSessionId: 1fd0107c-f8bf-4003-bdfa-77630176dfbc
  modified: 2026-10-21T14:45:56.950Z
---

**来源：** 2026-10-21 讨论终端的预置脚本时延伸出来，用户决定做；同日又定下网页从终端的视图移进来，跑归终端、看归预览；网页还能选在工作机上的 Chrome、Firefox、WebKit、Safari 里看。设计已写进 [成果查看与位置 · 预览](../../docs/成果查看与位置.md#预览) 与 [实例操作 · 预览](../../docs/实例操作.md#预览)，待定项在前者的「待定」里。顺序：预置脚本，然后把网页移过来并做模拟器和后台浏览器（实时、逐帧、agent 工具一起），最后 Mac App 窗口、Safari 与分发包。

**参照：** Claude Code 桌面版的 iOS 模拟器面板（2026-07 公测，文档 https://code.claude.com/docs/en/desktop-ios-simulator）：每个会话一台模拟器，实时画面可点，Claude 能点按、截图，只限本机会话，不碰真机；它是桌面 App 自己的功能，SDK 与命令行用不上。

docs 不收、实现时要照做的界面细节（讨论时已认可）：
- 逐帧模式在画面上标出刚点的位置，等待稳定时显示等待中，让人知道为什么点不动。
- 默认只发稳定后一帧，想看动画切实时画面，不默认录一段视频（慢链路上视频比单帧大一个量级）。
- 拖动、滑动在松手时作为一个动作发出；长按、捏合另给按钮。

**完成条件：** 预览插件按 docs 实现并经用户在 Mac、iPhone、iPad 上手测，删掉本条。
