---
name: light-task-direction
description: 标题等辅助生成统一使用常驻 ChatGPT 订阅直调，业务材料与校验各自负责
metadata:
  type: decision
---

2026-10-02 用户认可为标题等辅助功能提供共用的轻任务入口，后续还会增加同类功能；辅助模型与主会话独立选型。

2026-10-06 用户明确 GPT 将作为常驻账户，Claude 不是；标题等一次性辅助生成统一使用工作机的 ChatGPT 订阅直调，不跟随主会话选择 Claude。自动标题触发与更新条件的主来源见 [轻任务与会话标题](../../docs/kited.md#轻任务与会话标题)。

**Why:** 这类任务对模型能力要求较低，不需要每次启动完整 agent，也不应依赖非常驻的 Claude 账户。
**How to apply:** 摘要、标签等功能优先复用一次性模型调用，业务各自负责材料、校验与保存；有实际重复需求再提取共性。提示词仍须遵守 [[prompt-composition-direction]] 的可编辑要求，不能因为是轻任务就硬编码。
