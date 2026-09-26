---
name: harness-direction
description: Claude Code 后端不可用，自研 harness 提前开发，首个模型入口用 ChatGPT 订阅
metadata:
  type: project
---

2026-09-26 用户说明 Claude Code 账号被误封，可能无法解封，要求尽快开发自研 harness 并接入 Kite。随后明确：首个模型入口准备使用 ChatGPT 订阅。

**原因：** Kite 的可用性不能继续以 Claude Code 账号恢复为前提。原任务书中「第一阶段只接 Claude Code，自研 harness 和 GPT 留到第二阶段」的顺序已被这次决定覆盖。

**应用：** 按自研 harness 加 ChatGPT 订阅推进；保留「上游优先、只做薄层」以及每会话独立工作树、git 快照、项目知识放在项目里的原则。复用现有 kited 的项目和工作树流程，模型循环、工具执行、上下文和会话记录由新 harness 补齐。不要把订阅接入擅自改成按量 API key，也不要把调用 Codex CLI 当作已经完成自研 harness。

现有实现边界与建议顺序见 [harness 接入评估](../../docs/harness-接入评估.md)。其中的实现方案仍是建议，不是用户已经确认的全部规格。

主循环方案见 [harness 主循环设计](../../docs/harness-主循环.md)。用户在了解 Claude Code 与 Codex 的循环后，要求修改设计并实现：分开控制入口、回合循环和流式工具调度；完整调用保存后即可执行，显式声明并发的工具可以重叠执行，排他工具形成屏障；结果和快照收齐后再请求模型。独立内核位于 `kited/src/harness/`。

独立终端入口 `cd kited && bun run harness --cwd <目录>` 已接通真实 ChatGPT 订阅、文件/命令工具及会话恢复。模型循环与工具由 Kite 执行。用户明确未来要多机，并要求设备登录：通过官方登录工具为每台工作机单独授权，凭据默认放 `$KITE_HOME/auth/chatgpt/auth.json`（KITE_HOME 默认 `~/.kite`），不再默认读取日常 Codex 的凭据，也不跨机器同步 refresh token。harness 每次请求只读加载；自动刷新与系统钥匙串支持仍待完成，过期后在同一认证目录重新登录。终端直接修改指定目录；kited 新会话默认 harness，在独立工作树执行并接通快照、采纳和归档，旧会话按原 runtime 续接。App 与统一显示协议的支持范围以 [会话显示协议](../../docs/会话显示协议.md) 为准；后端可用不等于所有产品操作都已迁移。
