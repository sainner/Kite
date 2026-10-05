---
name: workspace-thread-plugin-architecture
description: agent 统一为插件实例，Thread 保留会话专有数据；系统和自定义插件共用公开契约
metadata:
  type: project
---

侧边栏条目代表工作区，而不是单个会话。工作区对应一个 cwd、工作树和分支，下面可以有多个同级插件实例及其视图；agent 实例拥有工作线程。实例与工作区解耦，删除实例不自动删除工作区。多个线程可以共享 cwd，也可以使用隔离工作树。

工作区允许多个线程同时运行。只读工具和可以安全合并的 `patch` 可以并行；补丁匹配失败时交回线程重新读取和生成，删除按调用时路径执行，无法由 patch 语义约束的 shell、Git 和工作区操作另行排队或使用隔离工作树。`AgentDefinition` 作为 agent 插件的专有配置，包含上下文编排、工具、模型和回合结束约定；触发器单独声明事件与动作。subagent 是一种创建来源，不建立另一套产品对象。

Agent 的 `presentation` 为 `window`、`inline` 或 `background`。用户明确取消待命生命周期：任务结束后释放执行资源，默认保留实例和会话，后续可追加任务继续，归档和删除另行管理。`agent.list` 查询已有实例及会话状态；恢复时检查服务端能力，避免同一会话重复启动。隐藏 agent 仍保留 Thread、journal 和状态，需要用户输入时回到父线程或提升为窗口。

工作区状态以只读、可快照的公共上下文变量提供给上下文契约和触发器，例如 `workspace.cwd`、`workspace.diff.*`、`workspace.check.status`。上下文组装器只展开契约，宿主负责收集状态，触发器负责按结构化条件排队线程。

内置 agent、终端和文件系统与自定义插件共用定义、实例、操作、视图及权限契约；原生 UI、核心服务适配器和自定义执行入口可以不同。系统身份由宿主登记，自定义插件通过授权后的能力接口接入，不能靠 manifest 自称系统插件获得任意路径、shell、环境变量或认证信息。

2026-09-28 用户提出 agent 本身也是 plugin，并要求开始修改设计文档。后续按实例层统一：PluginDefinition 创建 PluginInstance；每个 agent 实例拥有一个 Thread。共有身份、工作区、标题、配置与持久生命周期由实例单独负责，Thread 保留专有数据，Runner 保留现有执行与恢复语义，不另建 Agent 持久表。窗口统一引用 instanceId + viewId；agent 默认提供一个 conversation 视图，其他插件按声明提供零到多个视图。agent.stop 等是实例操作，UI 与模型可共用经授权的业务入口。

用户明确自定义插件首批需要能编写界面和逻辑，并调用工作区能力。界面承载与工作机执行各自选型；用户于 2026-09-30 决定插件和 harness 共用操作系统沙箱，继续使用 Bun，具体动机见 [[sandbox-execution-direction]]。完整设计见 `docs/Agent与插件契约.md`；已确认的跨端窗口同步边界见 [[workspace-window-sync]]。

2026-09-28 用户明确窗口收纳方式：Mac 在右侧设类似程序坞的停靠栏，放最小化或拖动中的窗口，形状及无窗口实例的排列见 [[instance-management-entrypoints]]。右栏与左栏一样没有独立背景色。iPhone 的现有底部页签栏是折叠窗口栏的前身，始终只有一个窗口展开，其余窗口放在底部。对话控制区不再提供线程菜单和新对话入口。2026-10-01 确定的添加与实例管理入口见 [[instance-management-entrypoints]]，新窗口放置偏好见 [[new-window-placement]]。Mac 标题栏悬停时在右侧显示缩小、展开、关闭；用户明确“展开”是当前窗口独占工作区、其余窗口收进停靠栏，已独占时隐藏展开按钮。先做好这套窗口呈现，再接 agent 能力。

**Why:** 用户希望一个工作区承载多个同级工作窗口，让探索、审查和测试等线程并行运行，并让 patch 自然暴露冲突；agent 本身也有状态、视图和工具操作，可以与插件统一。会话在执行进程退出后本来就能继续，单独设置待命生命周期没有额外价值。终端和文件系统仍需要由核心服务处理工作树、Git 和进程语义。

**How to apply:** 使用 `Project → Checkout → Workspace → PluginInstance`，窗口绑定实例与视图，Thread 是 agent 专有数据。统一操作入口时核对当前会话状态重构结果，不重写停止收据或恢复状态机。`AgentDefinition` 复用 `ContextDefinition`、`ContextBinding` 和场景契约；先由内置插件验证公共契约，再接自定义界面和逻辑。
