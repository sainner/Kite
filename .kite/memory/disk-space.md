---
name: disk-space
description: 这台开发 Mac 的内置盘空间紧，大件下载、编译缓存放不下时可以用外置硬盘 ORICO；Kite 数据目录搬过去后旧工作区的 Git 指针要改真实路径；launchd 下的 kited 读 ORICO 要系统授权
metadata:
  node_type: memory
  type: context
  originSessionId: 1fd0107c-f8bf-4003-bdfa-77630176dfbc
  modified: 2026-10-24T16:14:16.148Z
---

开发用的这台 Mac 内置盘只有 228GB，常年余量不多。2026-10-22 下载 Playwright 浏览器、开测试模拟器时一度占满（只剩几百 MB），用户腾出空间后说：中途空间不够时可以用 ORICO 外置硬盘（挂在 `/Volumes/ORICO`）。

2026-10-24 又只剩 3.5GB。最先看这几处：被管理项目的工作区副本 `~/.kite/worktrees/`（crevo 的灵感数据 13GB 落在这里，不在 `~/Projects` 里）、Xcode 的 `iOS DeviceSupport`（每台真机加系统版本一份，约 6–7GB）、模拟器设备与运行时、DerivedData，还有正在准备的系统更新撑大的 Preboot 卷。

同日 `~/.kite/repos` 与 `~/.kite/worktrees` 搬到 ORICO（`/Volumes/ORICO/MacData/Developer/Kite/Repositories`、`/Volumes/ORICO/MacData/Worktrees/Kite`），原处换成符号链接。搬家前建的工作区，`.git` 指针还走 `~/.kite/repos`，沙箱只放行检出的真实路径，git 报 `not a git repository: (null)`，代理误以为「Git 元数据在沙箱外」而反复申请出沙箱。`git worktree repair` 不改这种指针（旧路径在沙箱外仍走得通），10-25 手动把两头（工作区的 `.git`、检出里 `worktrees/<id>/gitdir`）都改成真实路径后恢复；搬家后新建的工作区，git 自己写真实路径，没有这个问题。

2026-10-29 装新版 kited 时发现：launchd 拉起的进程读 ORICO 要系统授权（可移除宗卷），系统自带的命令直接 Operation not permitted，kited 的 Bun 则停下等授权、一直不动。症状是服务装完 `/machine` 能答，碰到项目的请求没回音，主线程卡在 `openat`，`git symbolic-ref` 子进程挂着；临时 launchd 任务读 ORICO 上的文件就能复现。之前几天正常，换装运行文件后才卡，授权怎么跟着 Bun 走没查清。Bun 的编译缓存原先也跟着 `~/.bun/install/bun` 链到 ORICO，已改到安装目录（见 `kited/scripts/install-macos.ts`）；`repos`、`worktrees` 仍在 ORICO，要靠授权。

**Why:** 盘满时命令连输出文件都建不了，构建、模拟器、浏览器下载都会失败。
**How to apply:** 要下载几百 MB 以上的东西、开新模拟器或编译前先看 `df -h /System/Volumes/Data`；不够时把缓存或产物放到 `/Volumes/ORICO`，不要自己删用户的文件，删这次会话产生的东西也先问。装完 kited 请求卡住时先按上面的症状查外置盘授权，授权由用户在系统设置里给。
