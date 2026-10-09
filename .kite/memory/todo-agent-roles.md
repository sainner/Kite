---
name: todo-agent-roles
description: 代理与角色改造三期代码已完成，账号服务已上线，剩各工作机升级与真机验收
metadata:
  node_type: memory
  type: todo
  originSessionId: 7c9639e3-0374-46e3-81b4-3a82c2c97cb6
  modified: 2026-10-09T08:46:55.095Z
---

来源：2026-10-09 用户确认 [[agent-role-direction]]、[[project-constraints-direction]]、[[library-account-storage]]、[[model-vendor-backend]]，要求按三期推进。同日三期代码完成：角色与代理合一、资源库随账号保存（角色、后台模板、点阵签名、插件包）、项目约束。账号服务的资源库与项目约束接口同日部署，部署前的备份在 hk-server 的 `kite-hosted/backups/library-*`。

未解决：
- 各工作机的 kited 需升级到同一版本，旧 kited 没有 `/roles`、`/workspaces/:id/agent-options`，新 App 连上会报错。
- 用户尚未在 Release 版里预览角色页、代理配置与项目约束；iPhone 上的角色菜单与配置页也未在真机验收。
- 之后再议：新代理开场白、执行授权的项目上限。

**完成条件：** 各工作机升级后，用户预览确认界面，本条删除，开场白等未决项另立记忆。
