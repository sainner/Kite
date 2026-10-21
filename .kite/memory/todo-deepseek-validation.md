---
name: todo-deepseek-validation
description: DeepSeek 接入 harness 后还没用真 Key 验证的几处：工具回合的推理交回、跨厂商推理占位、图片
metadata:
  node_type: memory
  type: todo
  originSessionId: 33298c79-ec77-4ec2-ac12-9f5eaf642b69
  modified: 2026-10-18T08:43:49.356Z
---

2026-10-18 按 DeepSeek 文档接入（Responses 兼容接口 `https://api.deepseek.com/responses`）。同日用真 Key 跑通了 `deepseek-flash` 的纯文字回复：流式事件和条目 ID 与 OpenAI 一致，适配器不用改。

同日 tool search 实验（`spikes/tool-search/`，不经 Kite 适配器、原样交回 flash 的推理条目）里，flash 带推理的多轮工具调用与客户端搜索都没有 400。

待实测：
- 经 Kite 适配器的带工具回合：推理条目交回、多轮工具调用不 400。
- 思考模式带工具时，历史里别家（GPT、Claude）的助手段没有推理，上游要不要求交回；现在给这些段补了一个空格推理占位（`kited/src/harness/deepseek.ts` 的 `withReasoning`），不需要就删。
- `deepseek-flash` 的工具结果图片、用户消息附件里的图片（user 消息里的 input_image）能不能看。

**完成条件：** 用真 Key 在 App 里跑一个带工具的 DeepSeek 会话，中途 GPT↔DeepSeek 各换一次都能继续；按结果删改占位与上面的说明。
