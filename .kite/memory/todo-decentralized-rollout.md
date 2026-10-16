---
name: todo-decentralized-rollout
description: 去中心化改造还没做完的部分：租约续约与过期等 CloudKit 一起做、CloudKit 本身、登出重启关机预告待真机实测、kite-net 重启后丢用户和对端
metadata:
  node_type: memory
  type: todo
  originSessionId: ccf87b9c-2b46-46a9-b897-c6e74a46569c
  modified: 2026-10-16T08:12:48.206Z
---

来源：2026-10-15 按 [[decentralized-direction]] 实施了不依赖付费开发者账号的部分；2026-10-16 补上自动换机的环境声明（Xcode、连着的 iPhone/iPad，优先不带电池的机器）、登出/重启/关机预告、App 里的流转与强制接管入口（侧栏工作区的 ⋯ 与右键菜单，Line 在侧栏顶部标志的右键菜单）。现状以 [分布式架构](../../docs/分布式架构.md) 的状态段为准。

未解决：
- 执行权租约的续约与过期（意外失联后自动接手）：用户 2026-10-16 定为等 CloudKit 一起做。理由是现在只有「有远程且打开自动换机」的项目用得上 Git ref 续约，每次续约都要推用户的远程；Line 没有远程，要等 CloudKit 才有见证方。
- CloudKit 见证、推送与后备：等加入付费开发者账号。
- 登出、重启、关机预告用的是 loginwindow 的 notify 键（`com.apple.system.loginwindow.*`，非公开接口，取自 loginwindow 二进制里的字符串），没在真机上触发过：需要用户在打开了自动换机的项目里有工作中的工作区时登出或重启一次，看 kited 日志里的「[换机]」与目标机是否接手。收不到就要换信号来源（例如 App 里的 NSWorkspace.willPowerOffNotification）。
- kite-net 从保存的状态重启后可能停在残缺状态（2026-10-16 本机见过一次，原因未查）：16:30 kited 重启后 `/network` 一直是 Running、有节点名和 ID，却没有用户、对端 0；只让 kite-net 退出、由 kited 拉起后，用户和 5 台对端都回来了。kite-net 已加兜底，状态里没有用户时读本机登录档案，App 以执行端登录不再空等；对端列表和 `authorized` 都靠 `Self.UserID`，这种状态下其他设备连这台工作机可能被拒，兜底解决不了。再出现时先查 `StatusWithoutPeers` 的 `Self.UserID` 和网络映射的 `UserProfiles`，再动手修。

完成条件：上面各项处理掉或另立记忆后删除本条。
