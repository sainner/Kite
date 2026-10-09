---
name: todo-agent-roles
description: 代理与角色改造的三期待办：角色与代理合一、资源库迁到账号、项目约束
metadata:
  node_type: memory
  type: todo
  originSessionId: 7c9639e3-0374-46e3-81b4-3a82c2c97cb6
  modified: 2026-10-09T06:13:15.640Z
---

来源：2026-10-09 用户确认 [[agent-role-direction]]、[[project-constraints-direction]]、[[library-account-storage]]、[[model-vendor-backend]]，并要求按三期推进。

1. 角色与代理合一（角色暂存工作机）：三个 agent 定义合一；角色含工具黑白名单与必需标记、默认模型、预算；`agent.start` 改按角色；界面隐藏后端，模型菜单按厂商分；资源库角色页、草稿、代理配置；文案改名。
2. 资源库迁到账号：角色、上下文模板、插件包由账号服务保存与分发，kited 缓存使用。
3. 项目约束：账号服务按项目保存，kited 在创建和每次调用工具时检查并即时生效，App 项目设置可编辑。

之后再议：新会话开场白、执行授权的项目上限。

**完成条件：** 三期都实现、`.kite/check` 通过，相关 docs 已改为现状，本条删除，未决项转入对应记忆。
