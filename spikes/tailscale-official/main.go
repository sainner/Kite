// 实验：用 tsnet 以独立节点连 Tailscale 官方协调服务，走交互式登录，记下登录耗时、用户身份、
// 官方中继列表与到各对端的路径和延迟；在组网的 80 端口回答来访者的 WhoIs，供其他设备核对「同一用户」的判定。
// 状态目录与现有 Headscale 网络的节点分开，不影响 kite-net。
package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"net/http"
	"net/netip"
	"os"
	"os/signal"
	"sort"
	"strings"
	"syscall"
	"time"

	"tailscale.com/client/local"
	"tailscale.com/ipn"
	"tailscale.com/tailcfg"
	"tailscale.com/tsnet"
	"tailscale.com/types/views"
)

func main() {
	host, _ := os.Hostname()
	dir := flag.String("dir", "", "节点状态目录（必填，与 kite-net 的目录分开）")
	hostname := flag.String("hostname", "kite-spike-"+strings.ToLower(strings.Split(host, ".")[0]), "节点名")
	// 网络侧按源端口放行 UDP 时，固定端口让 STUN 探测与点对点流量走同一个映射；0 为随机。
	port := flag.Uint("port", 41641, "WireGuard 与 STUN 共用的本机 UDP 端口")
	router := flag.String("router", "", "认证通道：路由器的 WireGuard 端点，如 192.168.31.1:51820；不填则走本机网络")
	routerKey := flag.String("router-key", "", "认证通道：路由器的 WireGuard 公钥（base64）")
	tunnel := flag.String("tunnel", "", "认证通道：分给本机的通道内 IPv4 地址")
	tunnel6 := flag.String("tunnel6", "", "认证通道：分给本机的通道内 IPv6 地址，可不填")
	channelVerbose := flag.Bool("channel-verbose", false, "打印通道的握手细节")
	showKey := flag.Bool("show-key", false, "打印本机的通道公钥（没有就生成并存进钥匙串）后退出")
	flag.Parse()
	if *showKey {
		private, created, err := channelKey(keyAccount)
		if err != nil {
			log.Fatal(err)
		}
		public, err := publicKey(private)
		if err != nil {
			log.Fatal(err)
		}
		log.Printf("通道公钥：%s（%s）", base64.StdEncoding.EncodeToString(public[:]), map[bool]string{true: "刚生成并存进钥匙串", false: "钥匙串里已有"}[created])
		return
	}
	if *dir == "" {
		log.Fatal("要用 -dir 指定节点状态目录")
	}
	started := time.Now()
	// ControlURL 留空即 Tailscale 官方协调服务。
	srv := &tsnet.Server{Dir: *dir, Hostname: *hostname, Port: uint16(*port), Logf: func(string, ...any) {}, UserLogf: func(string, ...any) {}}
	defer srv.Close()
	var ch *channel
	if *router != "" {
		ch = mustOpenChannel(*router, *routerKey, *tunnel, *tunnel6, *channelVerbose)
		srv.PacketListener = ch
		log.Printf("组网的 UDP 只经认证通道（%s，通道内地址 %s %s）", *router, *tunnel, *tunnel6)
	}
	if err := srv.Start(); err != nil {
		log.Fatalf("节点启动失败：%v", err)
	}
	lc, err := srv.LocalClient()
	if err != nil {
		log.Fatal(err)
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	waitRunning(ctx, lc, started)
	// 通道的 IPv6 是可路由的全局地址，中间没有 NAT；宿主网卡没有 IPv6 时 magicsock 不做 IPv6 的 STUN，
	// 直接把它报成静态端点。
	if ch != nil && ch.local6.IsValid() {
		if conn, ok := srv.Sys().MagicSock.GetOK(); ok {
			conn.SetStaticEndpoints(views.SliceOf([]netip.AddrPort{netip.AddrPortFrom(ch.local6, uint16(*port))}))
		}
	}

	st, err := lc.Status(ctx)
	if err != nil {
		log.Fatal(err)
	}
	user := st.User[st.Self.UserID]
	tailnet := ""
	if st.CurrentTailnet != nil {
		tailnet = st.CurrentTailnet.Name
	}
	log.Printf("本机 %s %v；用户 %s（ID %d，%s）；tailnet %s；主中继 %s", st.Self.DNSName, st.Self.TailscaleIPs,
		user.LoginName, user.ID, user.DisplayName, tailnet, st.Self.Relay)
	if dm, err := lc.CurrentDERPMap(ctx); err == nil {
		var regions []string
		for _, region := range dm.Regions {
			regions = append(regions, region.RegionCode+" "+region.RegionName)
		}
		sort.Strings(regions)
		log.Printf("官方中继 %d 个区域：%s", len(regions), strings.Join(regions, "、"))
	}

	ln, err := srv.Listen("tcp", ":80")
	if err != nil {
		log.Fatal(err)
	}
	go http.Serve(ln, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		who, err := lc.WhoIs(r.Context(), r.RemoteAddr)
		answer := map[string]any{"remote": r.RemoteAddr}
		if err != nil {
			answer["error"] = err.Error()
		} else {
			answer["node"] = who.Node.ComputedName
			answer["user"] = who.UserProfile.LoginName
			answer["userID"] = who.Node.User
			answer["tags"] = who.Node.Tags
			answer["sameUser"] = who.Node.User == st.Self.UserID && len(who.Node.Tags) == 0
		}
		log.Printf("来访 %v", answer)
		w.Header().Set("content-type", "application/json")
		json.NewEncoder(w).Encode(answer)
	}))
	log.Printf("在组网的 80 端口回答 WhoIs；每 15 秒探测一次各在线对端")

	tick := time.NewTicker(15 * time.Second)
	defer tick.Stop()
	for {
		if ch != nil {
			if at := ch.lastHandshake(); at.IsZero() {
				log.Printf("通道还没有与路由器握手成功")
			} else {
				log.Printf("通道最近握手：%v 前", time.Since(at).Round(time.Second))
			}
		}
		probe(ctx, lc)
		select {
		case <-ctx.Done():
			return
		case <-tick.C:
		}
	}
}

const keyAccount = "router-wireguard"

func mustOpenChannel(router, routerKey, tunnel, tunnel6 string, verbose bool) *channel {
	endpoint, err := netip.ParseAddrPort(router)
	if err != nil {
		log.Fatalf("路由器端点无效：%v", err)
	}
	keyBytes, err := base64.StdEncoding.DecodeString(routerKey)
	if err != nil || len(keyBytes) != 32 {
		log.Fatal("路由器公钥要是 base64 的 32 字节")
	}
	local, err := netip.ParseAddr(tunnel)
	if err != nil || !local.Is4() {
		log.Fatal("通道内地址要是 IPv4")
	}
	var local6 netip.Addr
	if tunnel6 != "" {
		if local6, err = netip.ParseAddr(tunnel6); err != nil || !local6.Is6() {
			log.Fatal("通道内 IPv6 地址无效")
		}
	}
	private, _, err := channelKey(keyAccount)
	if err != nil {
		log.Fatal(err)
	}
	var peer [32]byte
	copy(peer[:], keyBytes)
	ch, err := openChannel(endpoint, peer, private, local, local6, verbose)
	if err != nil {
		log.Fatal(err)
	}
	return ch
}

// waitRunning 打印登录地址，等节点进入 Running。
func waitRunning(ctx context.Context, lc *local.Client, started time.Time) {
	watcher, err := lc.WatchIPNBus(ctx, ipn.NotifyInitialState)
	if err != nil {
		log.Fatal(err)
	}
	defer watcher.Close()
	for {
		n, err := watcher.Next()
		if err != nil {
			log.Fatalf("等待上线失败：%v", err)
		}
		if n.BrowseToURL != nil && *n.BrowseToURL != "" {
			log.Printf("登录地址（启动后 %v）：%s", time.Since(started).Round(time.Millisecond), *n.BrowseToURL)
		}
		if n.State != nil {
			log.Printf("状态 %s（启动后 %v）", *n.State, time.Since(started).Round(time.Millisecond))
			if *n.State == ipn.Running {
				return
			}
		}
	}
}

var lastSelf string

// probe 对每个在线对端做一次 disco 探测，记下延迟和走的路径：直连地址、官方中继区域或 peer relay。
// 本机对外报告的端点（STUN 探到的公网映射与本地地址）变化时也记一笔。
func probe(ctx context.Context, lc *local.Client) {
	st, err := lc.Status(ctx)
	if err != nil {
		log.Printf("读状态失败：%v", err)
		return
	}
	if self := fmt.Sprint(st.Self.Addrs); self != lastSelf {
		lastSelf = self
		log.Printf("本机端点 %s", self)
	}
	for _, peer := range st.Peer {
		if !peer.Online || len(peer.TailscaleIPs) == 0 {
			continue
		}
		ip := peer.TailscaleIPs[0]
		for _, candidate := range peer.TailscaleIPs {
			if candidate.Is4() {
				ip = candidate
			}
		}
		// 状态里只有本机的端点；对端的端点取协调服务下发的节点信息。
		var endpoints []netip.AddrPort
		if who, err := lc.WhoIs(ctx, ip.String()); err == nil && who.Node != nil {
			endpoints = who.Node.Endpoints
		}
		current := "未定"
		switch {
		case peer.CurAddr != "":
			current = "直连 " + peer.CurAddr
		case peer.PeerRelay != "":
			current = "peer relay " + peer.PeerRelay
		case peer.Relay != "":
			current = "官方中继 " + peer.Relay
		}
		pingCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
		result, err := lc.Ping(pingCtx, netip.Addr(ip), tailcfg.PingDisco)
		cancel()
		ping := ""
		switch {
		case err != nil:
			ping = "探测超时或失败"
		case result.Err != "":
			ping = "探测失败 " + result.Err
		case result.Endpoint != "":
			ping = fmt.Sprintf("探测经直连 %s 往返 %.0f 毫秒", result.Endpoint, result.LatencySeconds*1000)
		case result.PeerRelay != "":
			ping = fmt.Sprintf("探测经 peer relay %s 往返 %.0f 毫秒", result.PeerRelay, result.LatencySeconds*1000)
		default:
			ping = fmt.Sprintf("探测经官方中继 %s 往返 %.0f 毫秒", result.DERPRegionCode, result.LatencySeconds*1000)
		}
		log.Printf("对端 %s（%s）：当前路径 %s；%s；对方端点 %v", peer.HostName, peer.OS, current, ping, endpoints)
	}
}
