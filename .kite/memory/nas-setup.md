---
name: nas-setup
description: 用户的 NAS 是常开 Mac mini 上的 ORICO 外置盘，2026-10-22 已接上；实现工作区外的文件时据此安排验证
metadata:
  node_type: memory
  type: context
  originSessionId: 6540665c-1a55-4042-a4d9-97f02cd49897
  modified: 2026-10-16T06:10:41.510Z
---

用户说的 NAS 不是独立设备，是常开的 Mac mini 上的一块外置硬盘。2026-10-22 核对：Mac mini 上插着 ORICO（1TB、APFS、USB，挂在 `/Volumes/ORICO`，基本是空的），开发空间不够时也拿它放缓存，见 [[disk-space]]；用户这时直接在 Mac mini 上开发。

**Why:** 2026-10-22 用户定下 NAS 不单独做系统，就是工作机上的普通目录（见 docs/成果查看与位置.md「工作区外的文件」），这块盘就在 Mac mini 上。别的机器经组网访问 Mac mini 很慢（见 [[todo-remote-connections]]），人在 Mac mini 上用时没有这个问题。
**How to apply:** 实现工作区外的文件时先看 `/Volumes` 确认盘还接着；拔掉时正好验证许可在本机不生效与查看器的提示。
