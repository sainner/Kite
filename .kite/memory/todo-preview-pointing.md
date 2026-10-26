---
name: todo-preview-pointing
description: 预览的指认：网页画面已实现待手测（iOS 上设备网页视图的坐标待真机核对），协议 25；模拟器与 App 窗口、React 19 行号、onboard 推荐打包插件待做
metadata:
  node_type: memory
  type: todo
  originSessionId: af07ec7b-858f-44c8-bfe2-e62ca8a749fe
  modified: 2026-10-26T10:04:33.922Z
---

**来源：** 2026-10-26 用户定下指认方案：选中那一刻的快照，截图加一行说明放进最近用过的对话的输入框，说明只给必要的几项；先做网页。设计在 [成果查看与位置 · 预览](../../docs/成果查看与位置.md#预览) 与 [实例操作 · 指认](../../docs/实例操作.md#指认)，是现行文档，这里不重复。

**状态：** 网页画面（设备网页视图与工作机上的浏览器）已实现，画面接入加了 point 消息，协议 24 → 25。

**未决：**
- 用户手测 Mac、iPhone、iPad。iOS 上设备网页视图铺到安全区后面，PointingLayer 挂在 PortPreview 上，视图里的点与页面视口坐标是否对得上没在真机核对。
- 指认开着时盖住页面的一层收走了滚轮和拖动，页面不能滚；要不要放行滚动等用户反馈。
- 第二步：模拟器（Xcode 的界面结构带每个控件的位置）与 Mac App 窗口（kite-window 读的无障碍树已带位置），只给文字与无障碍标识。
- 第三步：React 19 用开发服务器的 source map 换算行号；kite-onboard 要不要给网页项目推荐 code-inspector-plugin 这类打包插件，待定。

**完成条件：** 三端手测通过、模拟器与 App 窗口做完后删掉本条；React 19 行号与 onboard 推荐届时另立或并入。
