---
name: todo-decentralized-rollout
description: 去中心化改造还没做完的部分：租约续约与过期等 CloudKit 一起做、CloudKit 本身、登出重启关机预告待真机实测、kite-net 重启后丢对端（已加诊断）、Mac mini 连不上
metadata:
  node_type: memory
  type: todo
  originSessionId: ccf87b9c-2b46-46a9-b897-c6e74a46569c
  modified: 2026-10-19T07:01:08.009Z
---

来源：2026-10-15 按 [[decentralized-direction]] 实施了不依赖付费开发者账号的部分；2026-10-16 补上自动换机的环境声明（Xcode、连着的 iPhone/iPad，优先不带电池的机器）、登出/重启/关机预告、App 里的流转与强制接管入口（侧栏工作区的 ⋯ 与右键菜单，Line 在侧栏顶部标志的右键菜单）。现状以 [分布式架构](../../docs/分布式架构.md) 的状态段为准。

未解决：
- 执行权租约的续约与过期（意外失联后自动接手）：用户 2026-10-16 定为等 CloudKit 一起做。理由是现在只有「有远程且打开自动换机」的项目用得上 Git ref 续约，每次续约都要推用户的远程；Line 没有远程，要等 CloudKit 才有见证方。
- CloudKit 见证、推送与后备：等加入付费开发者账号。
- 登出、重启、关机预告用的是 loginwindow 的 notify 键（`com.apple.system.loginwindow.*`，非公开接口，取自 loginwindow 二进制里的字符串），没在真机上触发过：需要用户在打开了自动换机的项目里有工作中的工作区时登出或重启一次，看 kited 日志里的「[换机]」与目标机是否接手。收不到就要换信号来源（例如 App 里的 NSWorkspace.willPowerOffNotification）。
- kite-net 从保存的状态重启后可能停在残缺状态（2026-10-16 本机见过一次，原因未查）：16:30 kited 重启后 `/network` 一直是 Running、有节点名和 ID，却没有用户、对端 0；只让 kite-net 退出、由 kited 拉起后，用户和 5 台对端都回来了。kite-net 已加兜底，状态里没有用户时读本机登录档案，App 以执行端登录不再空等；对端列表和 `authorized` 都靠 `Self.UserID`，这种状态下其他设备连这台工作机可能被拒，兜底解决不了。再出现时先查 `StatusWithoutPeers` 的 `Self.UserID` 和网络映射的 `UserProfiles`，再动手修。2026-10-17 WorkStation 系统更新重启、登录后又像是坏了一次（不确定是同一个问题）：Tailscale 显示在线，但 Mac mini 发往它局域网端点的探测没有回应，Mac mini 的组网日志里一直是「derp-7 does not know about peer」（它的中继 derp-7 上查不到它）。WorkStation 安装新版、kite-net 重启后，几秒内就直连上了。没在 WorkStation 那边留日志。2026-10-19（WorkStation=本机，Mac mini=另一台工作机）：
  - 中继连不上的根因已修：组网库每收到网络地图就按调试能力重设「绑网卡」，把 kite-net 的「不绑」改回绑，中继、日志、引导 DNS 连接从物理网卡直出、绕开 TUN 卡在 SYN_SENT。`tailscale-pinned-unbound.patch` 钉住不绑，已上线验证。组网库日志上传已关（`TS_NO_LOGS_NO_SUPPORT`）。
  - 本机已配受管网络通道：入口在本机回环，17:56 起 `up`，18:29 起加了通道内 IPv6（入口做转换）；当时所在网络映射不随目标变化（`mapvarydest=false`），本机会换网络，这个结论只代表当时。模拟入口失效 70 秒：通道停在 handshaking、netcheck 全是 `udp=false`、上报端点里没有公网地址，没有旁路。验收用的 debug.log 已删。
  - 「对端为空」诊断：每次启动刚进 Running、网络地图未到时会打一行（自己在线 false、用户资料 []、对端 0），属正常；要查的是它持续不变的情况。本机三次重启两次卡在对端 0 是修绑网卡之前的事，修后未再见。
  - 遗留：Mac mini 收不到本机的账号数据（停在 14:05），不知道新发布、不自动更新，只走中继、不报端点。疑似 14:04 自动更新后 kite-net 用 Security 框架直读通道私钥弹窗等人允许，可能连带挡住 kited 取凭据密钥、同步写入卡住，未证实，要有人到它跟前看弹窗或 `kite net`、`kite-service restart`。之后 N0—N1 才可能打洞直连。
  - 通道内地址与对外端点已分开：`tailscale-managed-udp.patch` 让 netcheck 经通道探测 IPv6、通道模式不做宿主 ICMP、本机地址只报局域网 IPv4、可清缓存端点；kite-net 不再把 address6 报成静态端点，换网或通道重新握手时清缓存并重测（立即、3 秒、10 秒）。18:29 已上线，通道配了通道内 IPv6（ULA，入口做转换）。已验：端点只剩经通道的公网 IPv4 与局域网 IPv4；新配置下 IPv6 套接字经通道开出；当前网络无 IPv6，netcheck `v6=false`、不报 IPv6 端点；通道失效时公网端点撤回、无 ICMP、无 UDP 出网，恢复后 1 秒内端点回来。未验：入口侧确认 IPv6 探测到达后被丢弃；入口自己断开再恢复时（kite-net 不重启）的重新探测；到有 IPv6 的网络时出现 IPv6 端点、换回后撤回。
  - 已上线的防再犯：通道私钥改经 `/usr/bin/security` 存取（旧条目头一次仍要允许一次）；`security` 60 秒超时；同步取不到凭据密钥时先写其余条目、不推进进度，发布记录不被凭据卡住。

完成条件：上面各项处理掉或另立记忆后删除本条。
