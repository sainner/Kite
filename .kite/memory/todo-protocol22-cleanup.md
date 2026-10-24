---
name: todo-protocol22-cleanup
description: 协议 22 去掉了待恢复与 agent_resume，其他工作机升级前要先清旧数据，否则启动时配置读不了
metadata:
  node_type: memory
  type: todo
  originSessionId: a6b65669-3bb6-437a-bf94-442259ad86e4
  modified: 2026-10-24T10:40:02.745Z
---

协议 22 去掉了「待恢复」状态和 `agent_resume` 工具（被 kited 退出打断的回合改为自动接着做）。新版不认旧数据，读不了就报错：实例配置里留着 `agent_resume` 时报「agent 配置无效」，授权里留着 `agent.resume` 时启动就崩。

本机已于 2026-10-24 征得同意后清完（数据库备份在 `~/.kite/kite.db.before-protocol22`）。其他工作机（如 defa7f61）升级前要做同样的事，先征得用户同意：

- 停 kited，备份 `kite.db`。
- 去掉 `plugin_instances.config` 里 `agent.tools` 中的 `agent_resume`，以及 `grants` 中 `operation` 为 `agent.resume` 的项。通知正文和操作收据里出现这个名字只是历史文字，不用改。
- 用新代码读一遍所有会话：journal 里有 `recovery.confirmed` 记录，或 `claude-control.json` 里还有 `recovery` 或 `unconfirmed` 输入的，新版读不了。这类会话按删会话的做法删掉：先归档它的子代理，再删会话目录和库里的行。

**Why:** 项目不做兼容，旧数据读不了就删（见 [[feedback-stale-data]]）；10-23 清 `terminal_run` 也是这么做的（见 [[todo-preview-plugin]]）。

**How to apply:** 给某台工作机升级到协议 22 或更高之前先按上面做。所有工作机都清完后删掉这条。
