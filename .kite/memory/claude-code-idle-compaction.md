---
name: claude-code-idle-compaction
description: Claude Code 的自动压缩大多是空闲约 55 分钟时预先算好；两边上下文积攒速度的实测对比，Kite 已照此加空闲压缩、待真实会话验收
metadata:
  type: context
---

2026-10-28 对比本机 Kite 项目下的 Claude Code 会话记录（`~/.claude/projects/*Kite*`）得到：

- Claude Code 的 27 次自动压缩里 25 次发生在上一次模型调用后约 54–56 分钟（赶在 1 小时缓存过期前），当时上下文 20 万到 79 万；用户都是一小时以后才回来，回来时上下文已经只剩约 5 万。只有 2 次是窗口快满（约 97 万）才压。这是 SDK 设置里的 `precomputeCompactionEnabled`（只在 `autoCompactEnabled` 打开时生效）。
- Kite 的 Claude 线程关了这两项（`kited/src/claude/options.ts`），压缩只走 Kite 自己的规则：回合结束时用量到窗口 85% 才压（`AUTO_COMPACT_RATIO`）。所以 Kite 线程跨休息一直积攒，直到 85 万当场压缩。
- 每次模型调用让上下文涨多少，Kite 约 2.5–3.4 千 token，Claude Code 约 2.0–2.6 千，差得不多：Kite 的 shell 输出平均更长，预览每个操作都回一张 1280×800 截图。这部分可能跟当时的任务有关，只看了 3 个 Kite 会话。

10-28 用户同意后，Kite 的 Claude 线程加了自己的空闲压缩（规则见 docs/harness-主循环.md「上下文压缩」，时机与门槛在 `kited/src/harness/compaction.ts`），用缩短时间的一次性脚本验证过定时、作废和重启后接着计时；还没装到工作机、没在真实会话里看过。harness 线程（ChatGPT、DeepSeek）没做，缓存时长不同，另议。

**How to apply:** 用户说 Kite 比 Claude Code 更常需要压缩，或者调整 Kite 的压缩时机时，先拿这条对照；真实会话里空闲约 55 分钟后应看到一次自动压缩。
