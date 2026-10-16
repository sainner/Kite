// kite-net 把 kited 接入组网：用 tsnet 以独立节点上线，不依赖系统 VPN。默认连 Tailscale 官方协调服务，用户在浏览器里登录。
// 只转发同账号设备的 HTTP 请求，来源身份由 tsnet 的 WhoIs 提供，来源的组网 IP 放在 X-Kite-Peer 里交给 kited。
// 节点状态以 JSON 行写到标准输出，供 kited 显示登录网址、组网地址和对端连接方式。
// 系统将要睡眠时状态里带一个睡眠事件，kited 交出要换机的工作区后在标准输入回「power-ready <序号>」，最多等 25 秒再放行睡眠；
// 将要登出、重启、关机时带一个 shutdown 事件，系统不等这里，kited 收到 SIGTERM 后自己等交接收尾。
// 退出登录时 kited 在标准输入写「logout」，节点在 Tailscale 上注销自己后退出，管理页里不留下这台设备。
// 配了受管网络通道（KITE_NET_CHANNEL）时，组网的 UDP 只经到路由器的认证通道出网，见 channel.go；
// `kite-net key` 打印通道公钥供网络管理员登记。
package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net"
	"net/http"
	"net/http/httputil"
	"net/netip"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"sync"
	"tailscale.com/client/local"
	"tailscale.com/net/netns"
	"tailscale.com/net/socks5"
	"time"

	"tailscale.com/ipn"
	"tailscale.com/tsnet"
	"tailscale.com/types/views"
)

type status struct {
	State    string   `json:"state"`
	LoginURL string   `json:"loginURL,omitempty"`
	IPs      []string `json:"ips,omitempty"`
	Name     string   `json:"name,omitempty"`
	// 本节点的稳定 ID，重新登录前不变。
	ID string `json:"id,omitempty"`
	// 登录的 Tailscale 用户；上线后才有。
	User      *user `json:"user,omitempty"`
	SocksPort int   `json:"socksPort,omitempty"`
	// kited 调用同账号的其他工作机时用的本机 HTTP 代理；Bun 的 fetch 不支持 SOCKS。
	HTTPProxyPort int    `json:"httpProxyPort,omitempty"`
	Peers         []peer `json:"peers,omitempty"`
	// 本机对外报告的端点：STUN 探到的公网映射、通道地址或本地地址。
	Endpoints []string `json:"endpoints,omitempty"`
	// 受管网络通道的状态；没配通道时没有。
	Channel *channelStatus `json:"channel,omitempty"`
	// 最近一次系统电源事件：sleep 将要睡眠，wake 醒来，shutdown 将要登出、重启或关机，stay 登出被取消；序号递增，kited 按序号认新事件。
	Power *power `json:"power,omitempty"`
}

type power struct {
	Event string `json:"event"`
	ID    int64  `json:"id"`
}

type user struct {
	ID          string `json:"id"`
	LoginName   string `json:"loginName"`
	DisplayName string `json:"displayName,omitempty"`
}

// peer 是同一用户的一台对端设备与当前的连接方式：direct 为点对点直连，relay 经中继，idle 表示近两分钟没有流量、尚未确定路径。
type peer struct {
	// 节点的稳定 ID，重新登录前不变。
	ID         string `json:"id"`
	Name       string `json:"name"`
	IP         string `json:"ip,omitempty"`
	OS         string `json:"os,omitempty"`
	Online     bool   `json:"online"`
	Connection string `json:"connection"`
	// 直连时是对端的实际地址，中继时是 DERP 区域或对端中继地址。
	Endpoint string `json:"endpoint,omitempty"`
}

// reporter 合并节点状态与对端采样，内容变化时才输出一行。
type reporter struct {
	mu      sync.Mutex
	current status
	last    []byte
	out     *json.Encoder
}

func (r *reporter) update(change func(*status)) {
	r.mu.Lock()
	defer r.mu.Unlock()
	change(&r.current)
	line, _ := json.Marshal(r.current)
	if !bytes.Equal(line, r.last) {
		r.last = line
		r.out.Encode(r.current)
	}
}

func main() {
	log.SetFlags(0)
	if len(os.Args) > 1 && os.Args[1] == "key" {
		public, err := channelPublicKey()
		if err != nil {
			log.Fatal(err)
		}
		json.NewEncoder(os.Stdout).Encode(map[string]string{"publicKey": public})
		return
	}
	// tsnet 不创建系统隧道，无需绑物理网卡来防止路由回环；交给系统路由才能使用代理的虚拟地址。
	netns.SetDisableBindConnToInterface(log.Printf, true)
	env := func(key string) string {
		value := os.Getenv(key)
		if value == "" {
			log.Fatalf("缺少 %s", key)
		}
		return value
	}
	target := env("KITE_NET_TARGET")
	dir := env("KITE_NET_DIR")
	// 节点目录下存在 debug.log 时，把组网库日志带时间追加写入，排查连接问题用；删除文件并重启组网即关闭。
	logf := func(string, ...any) {}
	if f, err := os.OpenFile(filepath.Join(dir, "debug.log"), os.O_WRONLY|os.O_APPEND, 0); err == nil {
		logf = log.New(f, "", log.LstdFlags|log.Lmicroseconds).Printf
	}
	srv := &tsnet.Server{
		Dir:      dir,
		Hostname: env("KITE_NET_HOSTNAME"),
		// 留空即 Tailscale 官方协调服务；组网层保持可替换，测试或自建时可以另指。
		ControlURL: os.Getenv("KITE_NET_CONTROL_URL"),
		Logf:       logf,
		UserLogf:   log.Printf,
	}
	defer srv.Close()
	var ch *channel
	if text := os.Getenv("KITE_NET_CHANNEL"); text != "" {
		var err error
		if ch, err = parseChannel(text); err != nil {
			log.Fatal(err)
		}
		srv.Port = channelPort
		srv.PacketListener = ch
		ch.start()
	}
	if err := srv.Start(); err != nil {
		log.Fatalf("组网节点启动失败：%v", err)
	}
	if ch != nil {
		if endpoint, ok := ch.staticEndpoint(); ok {
			if conn, ok := srv.Sys().MagicSock.GetOK(); ok {
				conn.SetStaticEndpoints(views.SliceOf([]netip.AddrPort{endpoint}))
			}
		}
	}
	lc, err := srv.LocalClient()
	if err != nil {
		log.Fatal(err)
	}
	socks, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		log.Fatal(err)
	}
	defer socks.Close()
	go (&socks5.Server{Dialer: srv.Dial}).Serve(socks)
	forward, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		log.Fatal(err)
	}
	defer forward.Close()
	go http.Serve(forward, peerProxy(srv))
	var active sync.Map
	changed := func() {
		active.Range(func(key, value any) bool {
			request := key.(*http.Request)
			if !authorized(lc, request) {
				if _, present := active.LoadAndDelete(key); present {
					value.(context.CancelFunc)()
					log.Print("远程设备已失去网络授权，关闭连接")
				}
			}
			return true
		})
	}
	report := &reporter{out: json.NewEncoder(os.Stdout), current: status{SocksPort: socks.Addr().(*net.TCPAddr).Port,
		HTTPProxyPort: forward.Addr().(*net.TCPAddr).Port}}
	ready := make(chan int64, 8)
	go readCommands(lc, ready)
	watchPower(report, ready)
	go watch(srv, report, changed)
	go func() {
		for range time.Tick(time.Second) {
			changed()
			endpoints := selfEndpoints(lc)
			report.update(func(s *status) {
				s.Peers = peers(lc, s.State)
				s.Endpoints = endpoints
				if ch != nil {
					state := ch.status()
					s.Channel = &state
				}
			})
		}
	}()
	ln, err := srv.Listen("tcp", ":"+env("KITE_NET_PORT"))
	if err != nil {
		log.Fatalf("组网端口监听失败：%v", err)
	}
	targetURL, err := url.Parse("http://" + target)
	if err != nil {
		log.Fatal(err)
	}
	proxy := httputil.NewSingleHostReverseProxy(targetURL)
	proxy.FlushInterval = -1
	token := env("KITE_NET_PROXY_TOKEN")
	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !authorized(lc, r) {
			http.Error(w, "设备不属于本账号或授权已撤销", http.StatusUnauthorized)
			return
		}
		ctx, cancel := context.WithCancel(r.Context())
		defer cancel()
		active.Store(r, cancel)
		defer active.Delete(r)
		// 外部传入的身份字段一律覆盖，内部端口也不能独立信任这些字段。
		r.Header.Set("X-Kite-Network", token)
		if source, err := netip.ParseAddrPort(r.RemoteAddr); err == nil {
			r.Header.Set("X-Kite-Peer", source.Addr().Unmap().String())
		} else {
			r.Header.Del("X-Kite-Peer")
		}
		proxy.ServeHTTP(w, r.WithContext(ctx))
	})
	log.Fatal(http.Serve(ln, handler))
}

// tailnet 地址段：IPv4 的 CGNAT 段与 Tailscale 的 IPv6 段。代理只转发到这里，不是通往外网的出口。
var tailnetRanges = []netip.Prefix{netip.MustParsePrefix("100.64.0.0/10"), netip.MustParsePrefix("fd7a:115c:a1e0::/48")}

// peerProxy 是本机的 HTTP 正向代理：请求行带完整地址，经 tsnet 拨到对端的组网端口。对端的 kite-net 自己核验来源身份。
func peerProxy(srv *tsnet.Server) http.Handler {
	proxy := &httputil.ReverseProxy{
		Director:      func(*http.Request) {},
		Transport:     &http.Transport{DialContext: srv.Dial},
		FlushInterval: -1,
	}
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		host, _, err := net.SplitHostPort(r.URL.Host)
		addr, parseErr := netip.ParseAddr(host)
		if r.URL.Scheme != "http" || err != nil || parseErr != nil || !inTailnet(addr) {
			http.Error(w, "只转发到组网内的工作机", http.StatusForbidden)
			return
		}
		proxy.ServeHTTP(w, r)
	})
}

func inTailnet(addr netip.Addr) bool {
	for _, prefix := range tailnetRanges {
		if prefix.Contains(addr.Unmap()) {
			return true
		}
	}
	return false
}

func authorized(lc *local.Client, r *http.Request) bool {
	peer, err := lc.WhoIs(r.Context(), r.RemoteAddr)
	if err != nil || peer.Node == nil || len(peer.Node.Tags) != 0 || peer.Node.Expired ||
		(!peer.Node.KeyExpiry.IsZero() && !peer.Node.KeyExpiry.After(time.Now())) {
		return false
	}
	self, err := lc.StatusWithoutPeers(r.Context())
	return err == nil && self.BackendState == ipn.Running.String() && self.Self != nil && !self.Self.Expired &&
		self.Self.UserID != 0 && peer.Node.User == self.Self.UserID
}

// selfEndpoints 是本机对外报告的端点，顺序照组网库给的。
func selfEndpoints(lc *local.Client) []string {
	st, err := lc.StatusWithoutPeers(context.Background())
	if err != nil || st.Self == nil {
		return nil
	}
	return st.Self.Addrs
}

// peers 采样同一用户、不带标签的对端设备及连接方式，判断方式与上游 tailscale status 一致；共享进来的、别的用户的设备不列。
func peers(lc *local.Client, state string) []peer {
	if state != ipn.Running.String() {
		return nil
	}
	st, err := lc.Status(context.Background())
	if err != nil || st.Self == nil || st.Self.UserID == 0 {
		return nil
	}
	var list []peer
	for _, ps := range st.Peer {
		if ps.UserID != st.Self.UserID || (ps.Tags != nil && ps.Tags.Len() > 0) || ps.ShareeNode {
			continue
		}
		p := peer{ID: string(ps.ID), Name: ps.HostName, OS: ps.OS, Online: ps.Online, Connection: "idle"}
		if len(ps.TailscaleIPs) > 0 {
			p.IP = ps.TailscaleIPs[0].String()
		}
		if ps.Active {
			switch {
			case ps.CurAddr != "":
				p.Connection, p.Endpoint = "direct", ps.CurAddr
			case ps.PeerRelay != "":
				p.Connection, p.Endpoint = "relay", ps.PeerRelay
			case ps.Relay != "":
				p.Connection, p.Endpoint = "relay", ps.Relay
			}
		}
		list = append(list, p)
	}
	sort.Slice(list, func(i, j int) bool {
		return list[i].Name < list[j].Name || list[i].Name == list[j].Name && list[i].IP < list[j].IP
	})
	return list
}

// watch 跟随节点状态。需要登录而还没有登录网址时主动请求一次，例如运行中节点密钥过期。
func watch(srv *tsnet.Server, report *reporter, changed func()) {
	ctx := context.Background()
	lc, err := srv.LocalClient()
	if err != nil {
		log.Fatalf("读取节点状态失败：%v", err)
	}
	watcher, err := lc.WatchIPNBus(ctx, ipn.NotifyInitialState|ipn.NotifyNoPrivateKeys)
	if err != nil {
		log.Fatalf("读取节点状态失败：%v", err)
	}
	requested := false
	for {
		n, err := watcher.Next()
		if err != nil {
			log.Fatalf("节点状态中断：%v", err)
		}
		if n.State != nil {
			changed()
		}
		var needsLogin bool
		report.update(func(next *status) {
			if n.State != nil {
				next.State = n.State.String()
			}
			if n.BrowseToURL != nil {
				next.LoginURL = *n.BrowseToURL
			}
			needsLogin = next.State == ipn.NeedsLogin.String() && next.LoginURL == ""
			if next.State == ipn.Running.String() {
				requested = false
				next.LoginURL = ""
				next.IPs = nil
				ip4, ip6 := srv.TailscaleIPs()
				for _, ip := range []netip.Addr{ip4, ip6} {
					if ip.IsValid() {
						next.IPs = append(next.IPs, ip.String())
					}
				}
				if st, err := lc.StatusWithoutPeers(ctx); err == nil && st.Self != nil {
					next.Name = st.Self.DNSName
					next.ID = string(st.Self.ID)
					if profile, ok := st.User[st.Self.UserID]; ok {
						next.User = &user{ID: fmt.Sprint(int64(st.Self.UserID)), LoginName: profile.LoginName, DisplayName: profile.DisplayName}
					}
				}
			} else {
				next.Peers = nil
				next.User = nil
			}
		})
		if needsLogin && !requested {
			requested = true
			if err := lc.StartLoginInteractive(ctx); err != nil {
				log.Printf("请求登录网址失败：%v", err)
			}
		}
	}
}

// readCommands 读 kited 写在标准输入的命令：power-ready <序号> 放行睡眠，logout 注销本节点后退出。
func readCommands(lc *local.Client, ready chan<- int64) {
	scanner := bufio.NewScanner(os.Stdin)
	for scanner.Scan() {
		line := scanner.Text()
		var id int64
		if _, err := fmt.Sscanf(line, "power-ready %d", &id); err == nil {
			// 没有在等的睡眠时不积压，免得挡住后面的命令；睡眠只认不小于自己序号的回复。
			select {
			case ready <- id:
			default:
			}
		} else if line == "logout" {
			ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
			err := lc.Logout(ctx)
			cancel()
			if err != nil {
				log.Fatalf("在 Tailscale 上注销节点失败：%v", err)
			}
			os.Exit(0)
		}
	}
}

// watchPower 把系统电源事件写进状态；睡眠要等 kited 回 power-ready 或 25 秒后放行。
func watchPower(report *reporter, ready <-chan int64) {
	var next int64
	last := ""
	watchSystemPower(func(event string, allow func()) {
		// 登出、重启、关机的预告可能接连来几条，到取消或醒来之前只报第一条。
		if event == "shutdown" && last == "shutdown" {
			return
		}
		last = event
		next++
		id := next
		report.update(func(s *status) { s.Power = &power{Event: event, ID: id} })
		if event != "sleep" {
			return
		}
		timeout := time.After(25 * time.Second)
	wait:
		for {
			select {
			case got := <-ready:
				if got >= id {
					break wait
				}
			case <-timeout:
				break wait
			}
		}
		allow()
	})
}
