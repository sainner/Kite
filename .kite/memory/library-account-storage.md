---
name: library-account-storage
description: 资源库随账号保存的动机，以及不保存未修改内置项的原因
metadata:
  node_type: memory
  type: decision
  originSessionId: 7c9639e3-0374-46e3-81b4-3a82c2c97cb6
---

2026-10-09 用户确定资源库内容随 Kite 账号保存和分发；需要分机保存的内容归到具体工作机。插件包也纳入账号资源库。

**Why:** 同一项目换到另一台工作机时，角色、模板与项目约束应保持一致。曾把未改过的旧默认当成用户修改上传，盖住了新版默认，因此内置角色与模板只保存用户改过的部分。
**How to apply:** 新增资源时先确认账号与工作机归属，见 [[sidebar-navigation]]。存储接口以 [资源库](../../docs/托管账号与设备.md#资源库) 为准，写入、缓存、同步和离线规则以 [工作机资源库](../../docs/kited.md#资源库与项目约束) 为准；不同资源的同步策略不能相互套用。
