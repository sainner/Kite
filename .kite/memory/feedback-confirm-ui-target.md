---
name: feedback-confirm-ui-target
description: 用户说的「侧边栏」可能指右侧停靠栏；排查界面问题前先确认是哪个控件
metadata:
  node_type: memory
  type: feedback
  originSessionId: 43afa54c-55a3-4b71-b95e-c3a0ba65565a
  modified: 2026-10-09T02:39:55.674Z
---

用户报告「侧边栏的添加按钮点不到」，实际指的是内容区右侧停靠栏顶部的「+」（添加窗口），不是左侧栏项目行的「+」。左右两边都有「+」，用户口中的「侧边栏」可能指任意一侧。

**Why:** 2026-10-09 先按左侧栏排查，改错位置、做了多轮无效诊断，直到用户补充「上方有最小化窗口就正常」才对上。
**How to apply:** 界面问题描述里的控件有歧义时（同名按钮出现在多处），先用一句话确认位置，或先看用户描述中的旁证（相邻元素、出现条件）再动手。调试方法见 [[ui-hit-testing-debugging]]。
