---
name: feedback-docs-principles-only
description: 用户反对将界面打磨细节和试改流水存成长期文档或 memory
metadata:
  type: feedback
---

用户在 2026-10-07 要求文档只写大的设计原则；2026-10-10 又指出 memory 中的图表排列、悬停效果、试过后撤回的样式等属于无效细节流水。

**Why:** 局部 UI 每次试改都追加到长期记录，会形成与代码重复且易过时的另一套说明；转存到 memory 也没有增加后续价值。
**How to apply:** 按 [AGENTS.md 的知识分工](../../AGENTS.md#持久知识的分工与准入) 筛选，只保留有后续用途的决定理由、反馈、未决事项与资料入口；已落地的界面细节及试改过程直接清理，不从 docs 转存 memory，也不反向搬运。相关：[[feedback-docs-current-state]]。
