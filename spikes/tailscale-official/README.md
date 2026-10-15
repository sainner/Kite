# Tailscale 官方组网实验（2026-10-15）

验证 Kite 改用 Tailscale 官方协调服务后，Mac 端 tsnet 的交互式登录、身份与到各对端的路径。结论见 [官方组网实测](../../docs/research/2026-10-15-官方组网实测.md)。

`main.go` 起一个连官方服务的独立节点：打印登录地址与上线耗时、本机用户与 tailnet、官方中继列表；在组网的 80 端口回答来访者的 WhoIs（是否同一用户、有无标签）；每 15 秒对各在线对端做一次 disco 探测，记下直连地址或中继区域与往返延迟。状态目录与 kite-net 分开，不影响现有网络。

```sh
go build -o /tmp/ts-spike . && /tmp/ts-spike -dir <状态目录>
GOFLAGS=-mod=mod go build -o /tmp/tailscale-cli tailscale.com/cmd/tailscale && /tmp/tailscale-cli netcheck
```

依赖版本与 `kited/net` 相同（tailscale.com v1.104.0），但用的是打过补丁的副本：先运行 `./patch-tailscale.sh`，它从模块缓存复制 tailscale.com 并打上 `tailscale-packet-listener.patch`（tsnet 可注入自定义 UDP 监听，注入时关掉端口映射），放到 `build/tailscale-kite` 供 `go.mod` 的 replace 使用。

经路由器认证通道（受管网络）运行：

```sh
/tmp/ts-spike -show-key   # 生成通道私钥存进登录钥匙串，打印公钥交给网络管理员
/tmp/ts-spike -dir <状态目录> -router <路由器端点> -router-key <路由器公钥> -tunnel <通道内 IPv4> -tunnel6 <通道内 IPv6>
```

`channel.go` 在进程内用 wireguard-go 建到路由器的通道，组网 UDP 只经它出网；`netstack/` 是 wireguard-go 的用户态网络栈，复制过来只改了一处与 tailscale 锁定的 gvisor 版本不兼容的判断；`keychain_darwin.go` 管通道私钥。通道配了 IPv6 时，把通道地址报成静态端点。
