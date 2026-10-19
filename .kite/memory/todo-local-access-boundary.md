---
name: todo-local-access-boundary
description: kited 本机接口与 kite-net 本机代理对本机进程不设认证、/network 暴露端点与账号标识，待决定怎么收紧；排查装的系统版 Tailscale 用完要退
metadata:
  node_type: memory
  type: todo
  originSessionId: 972d4fea-e1c5-4037-9100-085aeb0d27d6
  modified: 2026-10-19T07:32:35.245Z
---

来源：2026-10-19 本机网络管理方要求单独检查「应用向本机进程提供网络端点信息的访问边界」。

已实测：
- kited 本机监听只查 Host 是回环名（防 DNS 重绑定）和 `X-Kite-Machine`，后者可从不设认证的 `/machine` 读到；`curl` 不带任何凭据就读到了 `/network`（组网地址、节点名、登录账号标识、本机代理端口、对外端点含公网地址）和 `/machines`。回环 TCP 不分系统用户。
- kite-net 在回环上开的 SOCKS5 与 HTTP 代理都不设认证（SOCKS5 握手接受「无认证」），端口号就在 `/network` 里。HTTP 代理只转发到组网地址段。
- 同账号的任何组网节点都能调另一台工作机 kited 的一般接口：经系统版 Tailscale 节点读到了另一台工作机的 `/machines`、`/update`。

按代码推断、未实测：本机任何进程经 kite-net 的本机代理连到别的工作机时，来源是本机这台工作机的组网地址，能过 `peerOnly` 的工作机核验，读到账号级数据同步（代码注释说带凭据明文）。

未决：本机接口与代理要不要加凭据（例如只有用户可读的令牌文件、Unix 套接字、SOCKS5 用户名密码），`/network` 是否只给已认证的 App 返回端点与账号标识。另：tsnet 默认把后台日志上传到 Tailscale 的日志服务（`TS_NO_LOGS_NO_SUPPORT` 可关，关了本地缓冲也随之清掉，要本地日志用节点目录的 debug.log），2026-10-19 因绑网卡没传出去，修好绑网卡后会传，要不要关待定。排查时用 brew 装了系统版 Tailscale（cask `tailscale-app`），它是同账号的另一个节点，排查结束后要退出登录或卸载。

完成条件：上述收紧方案定下并实现，系统版 Tailscale 已处理，删除本条。相关：[[todo-decentralized-rollout]]
