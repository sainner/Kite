# 工作机之间的传输速度

2026-10-22 起做的测速实验，用来判断远程看大文件慢在哪一层。条件、结果与结论见 [实验记录](../../docs/research/2026-10-22-组网传输速度.md)。

`measure.ts` 在发起方这台工作机上跑，只读本机 kited 的 `/machine`、`/network`，再按目标走不同的路径取同一批文件，每次结果追加一行到 `<输出目录>/results.jsonl`，`summary` 汇成表。不重启 kited 或 kite-net，不在对端建任何东西。

```sh
bun measure.ts env                                   # 本机组网状态、对端列表
bun measure.ts down local 1m 4m 30m 100m --runs 3    # 同设备：直连本机 kited
bun measure.ts down kite-workstation 1m 4m --runs 3  # 跨机：经本机 kite-net 的 HTTP 代理
bun measure.ts down socks:kite-workstation 1m        # 同上，改走 SOCKS5
bun measure.ts file self <工作区 ID> <路径> 1m 30m all   # 文件插件的取字节接口；self 经本机 kite-net 回到自己
bun measure.ts up kite-workstation 1m 10m            # 本机往对端发
bun measure.ts latency kite-workstation --n 20       # 小请求的首字节时间
bun measure.ts timeline kite-workstation 2m          # 逐块到达时刻，看停顿
bun measure.ts watch kite-workstation --every 90 --for 1800   # 每 90 秒一轮：闲置后取 2m、紧接着再取 2m、发 1m
bun measure.ts probe kite-workstation --n 10         # 连取 2m，同时记连接方式、端点与网关丢包
bun measure.ts overlap kite-workstation --n 30       # 一条连接 5 秒没取完就另开一条同时取，看慢的是路径还是连接
bun measure.ts strategies kite-workstation --size 4m --n 45 --every 60   # 三种取法轮流比：一条到底、分段依次、分段 4 路
bun measure.ts public                                # 本机公网出口基线
bun measure.ts summary                               # 汇总成表
bun measure.ts export > transfers.csv                # 跨机传输按北京时间列成表（起止、方向、速度、停顿区间），给网络管理员对照抓包
```

通用参数：`--out <目录>`（默认系统临时目录下的 `kite-network-throughput`）、`--runs`、`--max-time <秒>`（单次上限，到时记下已传的部分）、`--label`（写进每行，汇总时分组）、`--kited <端口>`。

## 各项测的是哪一层

| 项目 | 路径 | 说明 |
|---|---|---|
| `down local` | curl → 本机 kited | kited 取文件接口本身：`POST /update/<build>/runtime/files` 把运行目录里的文件打成 tar 流。只读、只给工作机，两台跑同一版时内容相同 |
| `down <对端>` | curl → 本机 kite-net 代理 → tsnet → 组网（直连或中继）→ 对端 kite-net → 对端 kited | 加上组网与两端之间的公网。连接类型与对端端点按每次开始时 `/network` 报的记下 |
| `file <目标>` | 同上；`self` 是经本机 kite-net 回到自己的组网地址 | `GET /workspaces/:id/files/content`，App 看文件用的接口，按 Range 取前若干字节。tsnet 连自己的组网地址在网络栈里回环，不经 WireGuard、magicsock 与受管通道 |
| `up <对端>` | 同上，方向反过来 | 向同一接口发非 JSON 的请求体，对端读完才以 400 拒绝，耗时就是上传时间；对端不留任何东西 |
| `latency` | 同上 | `GET /machine`，看往返与组网建连 |
| `timeline` | Bun fetch 经 HTTP 代理 | 逐块到达时刻、每秒收到的字节、300 ms 以上的停顿 |
| `watch` | 同 `timeline` | cold 是闲置后的第一个请求（对端机器 ID 事先取好、不发别的请求），warm 紧随其后 |
| `probe` | 同 `timeline` | 期间每 0.5 秒读 `/network` 里对端的连接方式与端点，每 0.2 秒 ping 默认网关 |
| `overlap` | 同 `timeline` | 隧道里所有 TCP 连接共用同一对 WireGuard 端点，网络分不出它们；同一时刻一条慢一条快，说明差别在两端的 TCP 状态 |
| `strategies` | 同 `timeline` | 用一组组文件当段（对端没有工作区可按 Range 续取），段约 1 MB；分段的两种取法一段 `--stall` 毫秒没有新数据就换个请求重取这段 |
| `public` | 本机出口 → Cloudflare 测速点、苹果的 networkQuality | 基线。`networkQuality -f h2` 走 TCP，`-f h3` 走 QUIC（UDP）；要先看 `egress` 一行，TCP 与 UDP 的出口可能不是同一条 |

取文件的几档：`1m`、`2m`、`4m`、`30m`、`100m`，对应运行目录里的具体文件，见脚本里的 `PAYLOADS`；上传按字节数生成。

## 限制

- 经组网访问本机自己的组网地址会被 `/update` 的工作机核验拒绝（403），「同设备经组网」这一层改用 `file` 测；`summary` 里 `self` 的 `down`、`up` 两行就是这些 403，不是传输结果。
- 跨机的反方向（对端主动从本机拉）要在对端跑同一个脚本；`up` 只是本机发起的上传，经过的路径相同、方向相同，但发起方不同。
- `udpDrops` 是本机 UDP 因接收缓冲满丢的包数，全机共用的计数，传输期间别的程序也会算进去。
