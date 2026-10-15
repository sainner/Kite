---
name: todo-decentralized-rollout
description: 去中心化改造落地后还没做的部分：执行权租约续约与过期、CloudKit、自动换机的环境声明、关机预告、App 里的流转入口
metadata:
  node_type: memory
  type: todo
  originSessionId: 464317e8-02e9-4e1b-b76d-815e9115f417
  modified: 2026-10-15T12:42:45.207Z
---

来源：2026-10-15 按 [[decentralized-direction]] 实施了第 1 至第 4 步里不依赖付费开发者账号的部分（账号级数据同步、没有远程的项目互为远程、Tailscale 官方登录、工作区副本与只递执行权的交接、强制接管、睡眠前自动换机），账号服务、Headscale 与托管仓库的代码和部署配置已从仓库删除。用户说过当时完全没在用，数据都不重要，所以没有做迁移。

未解决：
- 没做：执行权租约的续约与过期（意外失联后自动接手；Git ref 见证方续约要往用户远程频繁推送，频率与代价待用户定）；CloudKit 见证、推送与后备（等加入付费开发者账号）；自动换机的环境声明（Xcode、连着的设备）与优先不带电池的机器；关机、重启、注销的预告（现在只接了睡眠）；App 里工作区流转与强制接管的入口（现在只能经 Line 的 line_workspace）。

完成条件：上面各项处理掉或另立记忆后删除本条。
