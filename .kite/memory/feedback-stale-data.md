---
name: feedback-stale-data
description: 旧格式的本机数据（会话记录等）读不了导致故障时，删掉旧数据，不为它改代码做兼容
metadata:
  node_type: memory
  type: feedback
  originSessionId: 819fa660-bf52-436f-85dd-19ad32b52e38
  modified: 2026-10-16T15:44:34.492Z
---

本机 kited 的旧数据跟不上新格式而出错时，处理办法是删掉那份旧数据，不改读取代码去兼容它。2026-10-17 删除 zhinan-nas 时，一个线程的会话记录写于执行授权加 `unsandboxed` 之前，读回时补了默认值，请求配置摘要对不上，删除卡在停线程这一步。用户说「删掉旧数据就好了」，并允许删除。

**Why:** 项目在研、不考虑兼容（见 AGENTS.md），旧数据不重要。
**How to apply:** 先查清是哪份数据、确认没有在跑的进程，再告诉用户要删什么，经允许后删。不要顺手放宽校验或加迁移。
