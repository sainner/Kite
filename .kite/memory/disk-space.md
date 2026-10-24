---
name: disk-space
description: 这台开发 Mac 的内置盘空间紧，大件下载、编译缓存放不下时可以用外置硬盘 ORICO
metadata:
  node_type: memory
  type: context
  originSessionId: 1fd0107c-f8bf-4003-bdfa-77630176dfbc
  modified: 2026-10-24T10:48:25.476Z
---

开发用的这台 Mac 内置盘只有 228GB，常年余量不多。2026-10-22 下载 Playwright 浏览器、开测试模拟器时一度占满（只剩几百 MB），用户腾出空间后说：中途空间不够时可以用 ORICO 外置硬盘（挂在 `/Volumes/ORICO`）。

2026-10-24 又只剩 3.5GB。最先看这几处：被管理项目的工作区副本 `~/.kite/worktrees/`（crevo 的灵感数据 13GB 落在这里，不在 `~/Projects` 里）、Xcode 的 `iOS DeviceSupport`（每台真机加系统版本一份，约 6–7GB）、模拟器设备与运行时、DerivedData，还有正在准备的系统更新撑大的 Preboot 卷。

**Why:** 盘满时命令连输出文件都建不了，构建、模拟器、浏览器下载都会失败。
**How to apply:** 要下载几百 MB 以上的东西、开新模拟器或编译前先看 `df -h /System/Volumes/Data`；不够时把缓存或产物放到 `/Volumes/ORICO`，不要自己删用户的文件，删这次会话产生的东西也先问。
