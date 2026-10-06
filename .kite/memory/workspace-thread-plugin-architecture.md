---
name: workspace-thread-plugin-architecture
description: 工作区承载同级实例，agent 统一为插件，自定义插件需要界面、逻辑与工作区能力
metadata:
  type: decision
---

用户希望一个工作区容纳多个同级工作窗口，让探索、审查与测试等线程并行。2026-09-28 决定 agent 也是插件，在实例层统一；子 agent 只是创建来源，不另建一套产品对象或侧栏层级。

用户取消“待命”生命周期：任务结束释放执行资源，默认保留会话，后续可追加任务。自定义插件首批需要能编写界面和逻辑，并调用工作区能力；先用内置插件验证公共契约。

**Why:** agent 与其他插件都有状态、视图和操作；同一会话本就能在执行进程退出后继续，没有必要再设待命产品状态。
**How to apply:** 对象关系与接口以 [产品架构](../../docs/产品架构.md) 和 [Agent 与插件契约](../../docs/Agent与插件契约.md) 为准，不在记忆中维护类型、字段和进度。工作区独立于单个线程，见 [[session-worktree-decision]]；非 agent 实例的保留按 [[plugin-instance-lifetime]]，执行边界按 [[sandbox-execution-direction]]。
