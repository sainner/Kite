---
name: todo-fast-mode
description: ChatGPT 快速模式已提交（210d291），真实请求能成功但提速没确认，界面没验收；Codex 用量没按快速模式折算
metadata:
  node_type: memory
  type: todo
  originSessionId: 8d72c3f0-e4cb-4f95-a2dd-efaccf4ffa5e
  modified: 2026-10-26T08:57:34.317Z
---

来源：2026-10-26 接入 ChatGPT 快速模式（实例级开关，输入区思考强度左边的闪电；请求带 `service_tier: "priority"`，取值照本机 Codex 的模型目录与配置）。

未解决：
- 界面没验收：本机 kited 已带快速模式；10-26 用户嫌闪电离思考强度太远，已挪近（f89330d），还没认可，iPhone 上没看。
- 真实请求已成功：10-26 21:40 起同一会话 19 次带 `service_tier` 的请求都正常完成。提速没确认：按请求开始到收完的整体速度，与同会话上下文 6 万以上的标准请求比约快 15%（25.7 对 22.8 tok/s），样本少、时段不同；响应里服务端实际给的档位没存，看不出 priority 是否生效。
- Kite 扫 Codex 会话记录折算用量时没读快速模式（Codex 记在 `thread_settings_applied` 的 `service_tier`，不在 `turn_context`），用户的 Codex 常开快速模式，金额只算了一半；已向用户提出，未决定做不做。

完成条件：用户在 build 里点过闪电认可；确认快速模式确实提速（或确认没有，再决定去留）；Codex 折算定了做或不做。
