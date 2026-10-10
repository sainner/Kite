---
name: template-emblem-direction
description: 角色点阵签名的创作动机与可编辑要求；契约见 docs
metadata:
  node_type: memory
  type: decision
  originSessionId: 6f8f1e31-d75b-4eed-a575-7e4a2357be0d
---

2026-10-09 用户提出用 AI 生成的点阵签名表达角色，让新代理的空白页更生动；选择数学表达式作为可预览、手改、重新生成的材料，参考 tixy.land。

**Why:** 用户希望每个角色有自己的视觉表达，并延续 [[prompt-composition-direction]] 的可编辑要求；生成结果应当是用户可以继续修改的素材。
**How to apply:** 调整签名能力时保留用户编辑权，生成契约由 [角色点阵签名](../../docs/kited.md#角色点阵签名) 维护。布局、求值算法和性能数据不在记忆中另存一份。
