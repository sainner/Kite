# Claude 会话重组实验（2026-10-09）

验证在已运行的 Claude 会话末尾追加压缩分界与一份重组的历史后，CLI 恢复时发给模型的内容，以及 SDK 显示接口的读取范围。结论见 [实验记录](../../docs/research/2026-10-09-Claude会话重组.md)。

| 脚本 | 内容 | 用法 |
|---|---|---|
| `rebase.ts` | 原生跑三轮后追加分界：第一轮原样拷贝、第二轮换成摘要、第三轮原样拷贝，再恢复问第四轮 | `bun rebase.ts <输出目录>` |
| `mod.ts` | 加载 `mod-plugin/` 接管 `session.compact`：第三轮工具调用报出大用量把引擎推过自动压缩阈值，hook 保留首尾两轮原消息、中间换成 `$.model.fork` 写的摘要，再恢复问第四轮；`KITE_SPIKE_SHAPE=suffix` 时只保留第三轮、摘要放在最前 | `bun mod.ts <输出目录>` |
| `cleanup.ts` | 在 `mod.ts` 压缩过的会话上追加一次重组：拷贝当前主链、助手消息换新 `message.id`、更新 last-prompt，再恢复检查是否还有重复 | `bun cleanup.ts <mod.ts 的输出目录>` |
| `summary.ts` | 在原生会话上用 `resume` + `forkSession` + `persistSession: false` 发摘要指令，与正常续接的请求比较，检查是否写文件 | `bun summary.ts <输出目录>` |

复用 `spikes/handoff/native.ts` 的假 Anthropic 端点与隔离配置目录，跑的是 kited 当时锁定的 Claude Agent SDK 0.3.280（CLI 2.1.280），不消耗额度。环境变量 `KEEP_MESSAGE_ID=1` 时拷贝的助手条目沿用原 message.id，用来复现内容重复的现象。
