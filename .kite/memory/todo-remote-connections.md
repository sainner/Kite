---
name: todo-remote-connections
description: iPhone 重连排查与托管远程的运维和多机待决事项
metadata:
  node_type: memory
  type: todo
  originSessionId: 3bbba462-9ad2-41bc-9e07-d09b9246eca4
  modified: 2026-10-21T08:47:09.707Z
---

**状态：** 待排查与决策，未确认实施顺序。
**来源：** iPhone 重连诊断、托管远程的待定清单与多机同步讨论。

- iPhone 节点重建后的首次握手与返回前台重连仍需测量。排查入口包括 hk-server 的公网 STUN UDP 3478、节点网络探测和 [TimingTrace](../../app/README.md#预览和验证)；当前连通性与原因需要重新核验，不预设云侧规则是根因。
- 局域网下 iPhone 每 2 分 20 秒断一分多钟（2026-10-18 查明并修好）：iPhone 节点对离线对端反复握手期间整个接收卡住（`udp=false`，DERP 也收不到），到那一轮 `Handshake did not complete after 20 attempts, giving up` 的同一毫秒恢复。修法两处，原因在代码注释里：App 不连组网报告离线的工作机（`AppModel.follow`）；iOS 的组网库不设 wireguard-go 缓冲池上限（`app/scripts/libtailscale-ios-buffers.go`）。同日真机复测，前台约 12 分钟：事件流始终是同一条连接，收包间隔不超过 16 秒，网络探测全是 `udp=true`。验证范围：缓冲池耗尽是按代码推断的，没直接量过；复测时 iPhone 不再碰离线对端，第二处修法单独是否有效没验证，组网报在线、实际不通的工作机仍会走到它。Mac 上 kited 照旧连离线工作机，macOS 没有池上限，暂不处理。取证做法：iPhone 系统日志用 `sudo log collect --device-udid`，要用户在自己的终端跑（`!` 输不了密码）；Release 版组网库日志在标准错误，用 `devicectl device process launch --console --terminate-existing -e '{"TS_DEBUG_DISCO":"true"}'` 收，时间以 Mac 侧打的时间戳为准（这台 iPhone 时钟比控制面慢约 1 小时，库自己的时间戳对不上）；Mac 侧在节点目录建 `debug.log` 再重启 kite-net，用完删掉再重启。
- kite-workstation 与 Mac mini 之间经组网传输时快时慢（报 direct，两端都走公网，电信对移动）。2026-10-22 从 Mac mini 发起实测：快时 1–3 MB/s，约四分之一的取、四成的发掉进 13–250 KB/s 的慢状态；kited 与 kite-net 本身能跑几百 MB/s，不是瓶颈。慢由路径上的阵发问题触发、被单条隧道 TCP 的状态拖长（同时新开的连接常常很快；推测在 tsnet 的 gVisor 网络栈，未验证）。10-21 终端网页视图预览 Mac mini 上 Next 开发服务器报 `ChunkLoadError` 就是这个：单个分块约 2MB，超过 webpack 的 120 秒。10-21 在 workstation 侧查过不是中继：数据全在 kite-net 的 UDP 上，经 Router 项目装的 ProxyHardening（127.0.0.1:51828）从物理网卡出网，不进 Clash。详情、方法与未测项见 [组网传输速度实测](../../docs/research/2026-10-22-组网传输速度.md)。待做：强制中继、同局域网、在 workstation 侧反向测并 ping 网关、系统 TCP 对照；同日对比实验：约 1 MB 一段、4 路同时取、某段 2 秒无数据就换连接重取，45 轮里最慢 8.4 秒，一条连接取到底有 5 次 180 秒没取完；用一组组文件模拟，真按 Range 续取没直接测。App 看远程文件已按此改（`KitedClient.download`，每次下载用自己的会话：段请求在共用会话里排队等连接的时间也算进 2 秒超时，实测确认），待用 iPhone、iPad 或另一台 Mac 打开 Mac mini 上几十 MB 的文件手测；附件上传与工作机之间的传输（含自动更新取新版，`kited/src/update/updates.ts` 一批一条连接取到底）未改；10-23 Mac mini 取 43 MB 新版，前几分钟约 10 KB/s，之后几分钟内取完。
- 托管仓库容量、备份，以及多远程/分叉的项目归属尚待决定；现行项目身份和集成契约见 [项目与远程仓库](../../docs/项目与远程仓库.md)。
- 平台撤权或 Git token 过期后的发现与重新绑定流程需评估。
- 文件跨机同步是候选能力，Git 经共享远程同步，两者分别确认需求。

**完成条件：** 重连问题以真实设备与网络测量定位并验证；其余逐项决定是否实施，采纳后形成对应契约。完整线上与真机验收见 [[todo-device-validation]]。
