---
name: library-account-storage
description: 资源库里的内容随 Kite 账号保存与分发，需要按工作机保存的东西放到设备下各工作机的页面
metadata:
  node_type: memory
  type: decision
  originSessionId: 7c9639e3-0374-46e3-81b4-3a82c2c97cb6
  modified: 2026-10-09T06:04:35.192Z
---

2026-10-09 用户确定：上下文模板（及由它演变的角色）和凭据一样由账号保存；推而广之，资源库中的内容都随账号保存、分发到各工作机，需要分机保存的放在设备栏下对应工作机的页面里。

**Why:** 角色、模板与项目约束要在各工作机上一致；按机器保存时，同一项目换台机器能选的角色就不同。
**How to apply:** 新增或调整资源库内容时默认放账号服务，由 kited 缓存使用；会话正文等仍留在工作机，这会改变 [托管账号与设备](../../docs/托管账号与设备.md) 中托管侧保存范围的说明。同日用户确认插件包也存到账号，各工作机按需安装。导航分层见 [[sidebar-navigation]]，凭据先例见 [[credential-service-direction]]。
