---
name: text-container-direction
description: 对话正文的文本容器方向：每条回复一个 TextKit 2 文本视图、代码块表格作附件、两端同一管线、复制出 Markdown 原文，外观必须与现状一致
metadata:
  type: decision
---

2026-10-11 用户决定对话正文改用统一的 TextKit 2 文本容器：

- 选择范围做到一条回复内、含跨代码块和表格；消息之间不连选，整段对话单一文本视图不做。
- 每条回复一个文本视图，代码块、表格作附件视图嵌入；选区跨过它们时，复制出按选区范围从源文本重建的 Markdown 原文。
- Mac 的用户消息气泡和工具结果里的小字正文一起进同一套属性串构建，与 iPhone 共用。
- 外观必须与现状一致：字体、行距、块距、行内代码背景、引用竖线、列表缩进、链接图标、气泡样式都是用户反复调过的，换容器不是重新设计（用户 2026-10-11 明确）。
- 分步落地：先在 spikes 里验证 Mac 上 NSTextView 的跨段选择、链接点击、右键操作栏、上浮动画与高度自适应；再把 Mac 散文块改成 NSTextView 共用属性串构建，退掉 Text.LayoutKey 的逐帧背景；最后每条回复一个文本视图嵌入附件。

**Why:** Mac 上每个 Markdown 块是独立的 SwiftUI Text，系统不支持跨 Text 选择，连两个段落都选不到一起；iPhone 散文已合成一个 UITextView，但在代码块处断开。近期的性能修补也都聚在平台文本视图这一层。自定义 TextRenderer 在可选中的 Text 上只从 macOS 27 SDK 起生效，部署目标是 macOS 26，不可用。
**How to apply:** 动对话正文、Markdown 排版或文字选择时按这个方向做，不再给 SwiftUI Text 加补丁；每一步交付前与现有界面逐项对照外观，验收按 [[feedback-ui-workflow]]，性能验证按 [[performance-diagnosis]]。
