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
- 本 Mac 经组网到 Mac mini（kite-braddemac-mini，报 direct，两端都走公网）吞吐很低且波动大：2026-10-21 同一个 2MB 文件 8–175KB/s，最慢一次 261 秒；经 kited 的 SOCKS 直连与经 PortRelay 同时下载时速度相当，瓶颈不在转发。后果：终端网页视图预览 Mac mini 上的 Next webpack 开发服务器（单个分块 gzip 后约 2MB，一页好几个）时，分块超过 webpack 的 120 秒就报 `ChunkLoadError`，浏览器经同一条链路不报只是当时快。同日查过不是中继：数据全在 kite-net 的 UDP 上、DERP 连接只有几十 KB，UDP 经本机 root 的 kite-channel（Router 项目装的 ProxyHardening，127.0.0.1:51828）从物理网卡出网，不进 Clash；组网 TCP 握手 40–1054ms、中位 125ms。本端出口 117.186.48.10，Mac mini 218.82.8.91 不回 ping。是 Mac mini 上行、跨运营商 UDP 限速还是丢包，待网管两头实测。
- 托管仓库容量、备份，以及多远程/分叉的项目归属尚待决定；现行项目身份和集成契约见 [项目与远程仓库](../../docs/项目与远程仓库.md)。
- 平台撤权或 Git token 过期后的发现与重新绑定流程需评估。
- 文件跨机同步是候选能力，Git 经共享远程同步，两者分别确认需求。

**完成条件：** 重连问题以真实设备与网络测量定位并验证；其余逐项决定是否实施，采纳后形成对应契约。完整线上与真机验收见 [[todo-device-validation]]。
