---
name: todo-development-workflow
description: 开发工作流待补齐项，供后续会话复核与继续处理
metadata:
  type: todo
---

**状态：** 待评估，保留原清单而非排期承诺。

**来源：** 原 docs/Agent与插件契约.md 的开发工作流清单及 docs/kited.md 的未完成项；2026-10-06 从文档迁入，原清单的建议顺序不视为排期或新执行授权。

**待处理：** 复核结构化 check 结果如何进入会话与检查排队、沙箱内 agent 所需的宿主 Git 暂存提交入口、会话回退与分叉。文件快照回退不等于会话历史回退。另有候选改进：采纳提交说明由 agent 生成、二进制冲突由用户二选一，以及旧 Claude 历史元数据、插话附件和子 agent 展示适配；不能把旧清单解释为现在立即恢复全部 Claude 原生能力。

**完成条件：** 逐项核对当前实现和用户需求，拆出已确认工作；形成操作与失败契约后验证，已完成或不再需要的项移除。Claude 范围遵守 [[claude-integration-direction]]。
