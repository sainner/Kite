---
name: feedback-confirm-ui-target
description: 同名控件的位置可能有歧义，排查前先结合用户描述确认目标
metadata:
  node_type: memory
  type: feedback
  originSessionId: 43afa54c-55a3-4b71-b95e-c3a0ba65565a
---

用户口中的「侧边栏」可能指左侧导航，也可能指右侧停靠栏；两处都有添加按钮，名称本身不足以定位。

**Why:** 2026-10-09 曾因默认理解为左侧栏而排查错位置。
**How to apply:** 先结合相邻元素与触发条件确认目标，仍有歧义再简短询问。事件诊断的证据限制见 [[ui-hit-testing-debugging]]。
