---
name: feedback-same-object-states
description: 用户视为同一对象的连续阶段，应保持对象与视图身份
metadata:
  node_type: memory
  type: feedback
  originSessionId: fb452e76-f93b-4298-8a43-d5ac59ca192f
---

2026-10-09 用户在新代理草稿转为正式代理时指出：这应当是同一个组件的不同状态，而非替换两个组件。

**Why:** 分别建对象再补转场会重建滚动、动画等视图状态，破坏用户感知的连续性。
**How to apply:** 对草稿转实体等连续阶段，先明确对象身份如何贯穿全程，再实现状态变化；不要靠转场掩盖身份切换。具体交接机制由代码表达。
