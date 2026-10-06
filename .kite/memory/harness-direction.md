---
name: harness-direction
description: Claude 账号受阻后提前自研 harness，首个模型入口使用 ChatGPT 订阅
metadata:
  type: decision
---

2026-09-26 用户说明 Claude Code 账号被误封、恢复不确定，决定提前自研 harness，首个模型入口使用 ChatGPT 订阅。任务书中“第一阶段只接 Claude Code，自研与 GPT 留到第二阶段”的顺序已被覆盖。

2026-10-06 用户决定重新接入 Claude Code，见 [[claude-integration-direction]]；这不表示停止自研 harness，也不能据此推断账号已经恢复。

用户还明确需要多机使用：每台工作机单独设备登录，不默认借用日常 Codex 凭据，不跨机器同步 refresh token。

**Why:** Kite 的可用性不能依赖 Claude 账号恢复；用户选择的是订阅入口和由 Kite 管理的模型循环。
**How to apply:** 不擅自改成按量 API key，也不把调用 Codex CLI 当成自研 harness。接入操作与能力现状查 [kited 说明](../../docs/kited.md)；早期 [接入评估](../../docs/harness-接入评估.md) 是建议与历史背景，不是全部已确认规格。工作区隔离按 [[session-worktree-decision]]，不再机械解释为每个线程必须单独建工作树。
