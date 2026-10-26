---
name: todo-preview-pointing
description: 预览的指认：网页、模拟器与 App 窗口已实现待手测，开关在控制区最右边；模拟器界面结构的真实格式待核对；React 19 行号、onboard 推荐打包插件待做
metadata:
  node_type: memory
  type: todo
  originSessionId: af07ec7b-858f-44c8-bfe2-e62ca8a749fe
  modified: 2026-10-26T10:04:33.922Z
---

**来源：** 2026-10-26 用户定下指认方案：选中那一刻的快照，截图加一行说明放进最近用过的对话的输入框，说明只给必要的几项；先做网页。设计在 [成果查看与位置 · 预览](../../docs/成果查看与位置.md#预览) 与 [实例操作 · 指认](../../docs/实例操作.md#指认)，是现行文档，这里不重复。

**状态：** 网页画面（设备网页视图与工作机上的浏览器）已实现，画面接入加了 point 消息，协议 24 → 25。模拟器与 Mac App 窗口同日实现，走同一条 point，协议号不变。

**未决：**
- 用户手测 Mac、iPhone、iPad。10-26 网页视图改为只占标题栏与控制区之间（WebPreview），PointingLayer 与网页视图是同一块，原先 iOS 上铺到安全区后面、坐标可能错位的顾虑随之没了；iPhone 上键盘升着时网页底边不动，那时指认的框会落在键盘后面。
- 指认开着时盖住页面的一层收走了滚轮和拖动，页面不能滚；要不要放行滚动等用户反馈。
- 模拟器的界面结构是按 Xcode 的 IDEDeviceInteraction 组件里自带给模型的说明（`strings` 读出来的样例）写的解析，没拿真实输出核对过；手测时指不准、框错位，先对一份真实的 hierarchy 文件。App 窗口用系统的按点取无障碍元素，也没实测过。
- 第三步：React 19 用开发服务器的 source map 换算行号；kite-onboard 要不要给网页项目推荐 code-inspector-plugin 这类打包插件，待定。

**完成条件：** 三端手测通过、模拟器与 App 窗口指得准后删掉本条；React 19 行号与 onboard 推荐届时另立或并入。
