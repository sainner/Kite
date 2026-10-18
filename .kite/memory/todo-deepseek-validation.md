---
name: todo-deepseek-validation
description: DeepSeek 接入 harness 后还没用真 Key 验证的几处：工具回合的推理交回、跨厂商推理占位、图片
metadata:
  type: todo
---

2026-10-18 按 DeepSeek 文档接入（Responses 兼容接口 `https://api.deepseek.com/responses`）。同日用真 Key 跑通了 `deepseek-flash` 的纯文字回复：流式事件和条目 ID 与 OpenAI 一致，适配器不用改。

待实测：
- 带工具调用的回合：推理条目交回、多轮工具调用不 400。
- 思考模式带工具时，历史里别家（GPT、Claude）的助手段没有推理，上游要不要求交回；现在给这些段补了一个空格推理占位（`kited/src/harness/deepseek.ts` 的 `withReasoning`），不需要就删。
- `deepseek-v4-pro` 收到图片是不是真的 400（现在换成说明文字）；`deepseek-flash` 的工具结果图片能不能看。

**完成条件：** 用真 Key 在 App 里跑一个带工具的 DeepSeek 会话，中途 GPT↔DeepSeek 各换一次都能继续；按结果删改占位与上面的说明。
