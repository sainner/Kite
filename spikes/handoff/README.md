# 跨后端上下文翻译实验（2026-10-08）

验证同一会话在 Claude 与自研 harness 之间切换时，上下文能否无损交接。结论与适用范围见 [实验记录](../../docs/research/2026-10-08-跨后端上下文翻译.md)。

脚本直接引用 `kited/` 的 Claude 配置、SDK 与 ChatGPT 适配器，跑的是当时锁定的 Claude Agent SDK 0.3.280（CLI 2.1.280）。除 `gpt-probe.ts` 外都用本机假 Anthropic 端点，不消耗额度；Claude 配置目录与 HOME 指向输出目录，不读本机设置。

| 脚本 | 内容 | 用法 |
|---|---|---|
| `native.ts` | 原生会话：thinking、并行 `mcp__kite__read`、两种 hook 注入，记下原生 jsonl 和主循环请求 | `bun native.ts <输出目录>` |
| `synth.ts` | 只用中立内容合成会话文件再 resume，与 `native.ts` 第 3 次请求比对 | `bun synth.ts <同一目录> full\|minimal\|nothinking` |
| `midturn.ts` | 工具执行中插话、带图片的工具结果 | `bun midturn.ts <输出目录>` |
| `synth-midturn.ts` | 合成插话与图片，与 `midturn.ts` 比对历史前缀 | `bun synth-midturn.ts <同一目录>` |
| `structured.ts` | 带 `structuredContent` / `isError` 的 MCP 结果在请求与记录中的形状 | `bun structured.ts <输出目录>` |
| `append.ts` | 在已运行过、含 `last-prompt` 的会话末尾追加合成条目后 resume | `bun append.ts <native.ts 的目录>` |
| `gpt-probe.ts` | 把 Claude 历史翻成 Responses 条目，经 ChatGPT 订阅真实发出 | `bun gpt-probe.ts gpt-6.1-sol plain\|reasoning\|visible` |
| `real.ts` | 真实 Anthropic API：先跑一轮取得 thinking，再用生产翻译代码追加 harness 回合（`call_` ID、加密 reasoning）后 resume | `bun real.ts <工作目录> [模型]` |

`gpt-probe.ts` 会用 `~/.kite` 的订阅凭据发出一次真实请求；`real.ts` 使用本机默认 Claude 配置目录与登录，会话文件写在 `~/.claude/projects` 下。
