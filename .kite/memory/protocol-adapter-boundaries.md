---
name: protocol-adapter-boundaries
description: 统一前端会话语义，区分完整 agent 与模型 API 适配，保留原生恢复记录
metadata:
  type: decision
---

用户于 2026-09-26 确认：Kite 的前端会话协议与自研 harness 的模型协议职责不同，不要求一致。Claude Code 是完整 agent 后端，接回它与给自研 harness 增加模型 API 是两类适配。

**Why:** 前端要保持统一会话体验，各后端仍需保留自己的执行与恢复能力。
**How to apply:** 前端差异以能力声明表达，不按供应商分叉；完整 agent 适配控制、历史与事件，模型适配器只转换请求和输出。原生记录不为显示统一而改写，恢复所需的 opaque 字段不得丢弃。不能仅凭“兼容 OpenAI”就认定模型接口可互换。字段以 [会话显示协议](../../docs/会话显示协议.md) 为准，Claude 接入范围遵循 [[claude-integration-direction]]。
