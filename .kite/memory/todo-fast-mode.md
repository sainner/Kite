---
name: todo-fast-mode
description: ChatGPT 快速模式已提交（210d291），界面与真实请求都没验过；Codex 用量没按快速模式折算
metadata:
  node_type: memory
  type: todo
  originSessionId: 8d72c3f0-e4cb-4f95-a2dd-efaccf4ffa5e
  modified: 2026-10-26T08:57:34.317Z
---

来源：2026-10-26 接入 ChatGPT 快速模式（实例级开关，输入区思考强度左边的闪电；请求带 `service_tier: "priority"`，取值照本机 Codex 的模型目录与配置）。

未解决：
- 界面没验收：Debug 预览要连带这次改动的 kited 才看得到闪电，重装服务会重启 kited，用户还没定。
- 没用真实订阅发过带 `service_tier` 的请求，ChatGPT 订阅端点是否接受、是否真的提速没核实。
- Kite 扫 Codex 会话记录折算用量时没读快速模式（Codex 记在 `thread_settings_applied` 的 `service_tier`，不在 `turn_context`），用户的 Codex 常开快速模式，金额只算了一半；已向用户提出，未决定做不做。

完成条件：用户在 build 里点过闪电认可；一次真实快速模式请求成功；Codex 折算定了做或不做。
