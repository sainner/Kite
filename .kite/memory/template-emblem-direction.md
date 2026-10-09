---
name: template-emblem-direction
description: 新会话空白页铺满模板专属的 AI 生成点阵签名动画；形式、可编辑性、生成时机与铺放范围由用户拍板
metadata:
  type: decision
---

2026-10-09 用户嫌新会话中间只有标题和按钮太乏味，提出每个上下文模板对应一个 AI 生成、可铺满窗口的点阵动画。用户在方案里确认四项（均为推荐项）：

- 形式用一行数学表达式（参考 tixy.land），App 每帧逐格求值，不让模型画逐帧字符画。
- 模板编辑器里可预览、手改表达式与颜色形状，也可「重新生成」。
- 模板保存后自动生成；手改过的不被自动替换，只有重新生成会覆盖。
- 动画铺满会话窗口的整块内容区，标题压在中间（模板选择后来移到标题栏副标题，见 [[window-header-information]]），背后图案收弱。同日用户追加要求连标题栏和输入区后面也铺上：标题栏一带稍收弱，玻璃输入区不收弱。

**Why:** 用户要求界面更生动，且延续「上下文可编辑」的方向（[[prompt-composition-direction]]），生成走常驻 ChatGPT 轻任务（[[light-task-direction]]）。
**How to apply:** 契约与接口见 docs/kited.md「模板点阵签名」；颜色只用参考色板字母，遵守 [[visual-style-direction]]。调整空白页或签名时不退回静态按钮或固定字符画。
