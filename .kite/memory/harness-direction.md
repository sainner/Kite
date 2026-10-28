---
name: harness-direction
description: 自研 harness、工作机独立订阅授权与辅助模型的当前取舍
metadata:
  type: decision
---

自研 harness 负责模型循环，Kite 维护统一执行宿主；主要模型入口使用工作机独立授权的 ChatGPT 订阅。Claude Code 管理自己的模型循环，作为另一执行后端接入，重复能力按职责显式关闭。

每台工作机独立登录，不借用日常 Codex 凭据，不跨机器复制 refresh token。标题等辅助生成使用工作机的 ChatGPT 订阅，与主会话模型独立选型。

DeepSeek 没有订阅，2026-10-18 按用户要求以账号凭据里的 API Key 接入自研 harness，作为并列的模型厂商，不替代 ChatGPT 订阅。辅助生成的模板也可选 DeepSeek，内置默认仍是 ChatGPT，只有语音整理 2026-10-29 按用户要求默认用 DeepSeek（见 [[voice-input-direction]]）。

**Why:** 工作台的可用性不能依赖单一 agent 产品；ChatGPT 是常驻账号，辅助生成不应依赖额外启动完整 agent 或非常驻的 Claude 账号。
**How to apply:** 不把调用 Codex CLI 当作自研 harness，不擅自把订阅入口换成按量 API key（DeepSeek 是用户指定的例外）。当前接入、模型账号与后端职责由 [工作机说明](../../docs/kited.md) 维护；续期未决项见 [[todo-subscription-auth]]，DeepSeek 待实测项见 [[todo-deepseek-validation]]。
