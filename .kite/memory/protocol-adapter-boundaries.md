---
name: protocol-adapter-boundaries
description: 前端会话协议统一，完整 agent 与模型 API 分别适配，原生存储无需统一
metadata:
  type: project
---

2026-09-26 与用户讨论并澄清的架构方向：前端与 harness 之间的会话协议（①），和 harness 与模型服务之间的模型协议（②），职责不同，不要求一致。

**应用：**

- ①按 Kite 的会话语义定义：消息、文字增量、工具调用与结果、回合状态及控制操作。将来接回 Claude Code 时保持这套前端接口，由后端适配差异；某后端不支持的操作可通过能力声明表达，不让前端按供应商分叉。具体字段尚未定案。
- Claude Code 是完整 harness，其适配器负责 SDK 控制（发送、打断、恢复）以及实时消息、历史记录到 Kite 事件的转换。它与「给自研 harness 接另一家模型 API」是两类适配。
- 自研 harness 的模型适配器负责内部模型请求/输出与供应商 API 的转换，循环和工具执行仍由 Kite 管理。协议确实一致的供应商共用适配器、只换配置；不能仅凭“兼容 OpenAI”就假定可替换，要区分 Responses、Chat Completions 及实际支持的字段。有具体差异再补，不提前造通用框架。
- 自研 harness 无需把存储格式做成 Claude Code 的格式。双方保留满足各自恢复需求的原生记录，再产生统一的 Kite 会话事件；续接模型所需的原始/opaque 字段不能因不显示而丢弃。
- JSONL 只是一行一个 JSON 的组织方式，不等于模型网络协议。落盘记录、模型上下文、实时事件和界面显示数据相互关联但不等同；界面可以把多个记录合成一张工具卡片或一个段落。

**实现边界：** 这是后续接口设计的方向，统一前端协议和 Claude Code 适配器尚未完成；不代表用户要求现在就恢复 Claude Code 接入。当前 App 仍使用假数据，HTTP 目前按 runtime 转发 harness 原生事件或 SDK 消息。相关后端进展见 [harness 方向](harness-direction.md)。
