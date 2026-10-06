---
name: workspace-window-sync
description: 同一工作区共享窗口集合，各设备独立布局与焦点
metadata:
  type: decision
---

2026-09-28 用户确认“同一组窗口，分别排布”：添加与关闭跨端同步，分栏、尺寸、停靠、展开与焦点由各设备分别管理。

**Why:** Mac 可同时展开多个窗口，iPhone 一次只展开一个；手机切换不应让 Mac 的其他窗口一起缩小。
**How to apply:** 设备重连以服务端窗口集合为准，本地布局不能复活已关闭窗口。关闭后的实例回收见 [[plugin-instance-lifetime]]，具体窗口契约查 [Agent 与插件契约](../../docs/Agent与插件契约.md)。
