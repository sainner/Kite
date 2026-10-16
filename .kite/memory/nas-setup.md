---
name: nas-setup
description: 用户的 NAS 是常开 Mac mini 上的外置硬盘，目前没插上；做命名位置时据此安排验证
metadata:
  node_type: memory
  type: context
  originSessionId: 6540665c-1a55-4042-a4d9-97f02cd49897
  modified: 2026-10-16T06:10:41.510Z
---

用户说的 NAS 不是独立设备，是常开的 Mac mini 上的一块外置硬盘，2026-10-16 时暂时没插上。

**Why:** 设计里 NAS 是由某台工作机提供的命名位置（见 docs/成果查看与位置.md），这块盘的提供方就是 Mac mini。
**How to apply:** 实现命名位置时，先确认盘是否已接回 Mac mini；没接时用 Mac mini 上的普通目录代替验证，离线情形正好用来验证「命名位置离线」的处理。
