// kite-net 把 kited 接入组网：用 tsnet 以独立节点上线，不依赖系统 VPN。
// 只转发同账号设备的 HTTP 请求，来源身份由 tsnet 的 WhoIs 提供。
// 节点状态以 JSON 行写到标准输出，供 kited 显示登录网址、组网地址和对端连接方式。
package main

import (
	"bytes"
	"context"
	"encoding/json"
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
)

type status struct {
	State     string   `json:"state"`
	LoginURL  string   `json:"loginURL,omitempty"`
	IPs       []string `json:"ips,omitempty"`
	Name      string   `json:"name,omitempty"`
	SocksPort int      `json:"socksPort,omitempty"`
	Peers     []peer   `json:"peers,omitempty"`
}

// peer 是对端设备当前的连接方式：direct 为点对点直连，relay 经中继，idle 表示近两分钟没有流量、尚未确定路径。
type peer struct {
	Name       string `json:"name"`
	IP         string `json:"ip,omitempty"`
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
	// tsnet 不创建系统隧道，无需绑物理网卡来防止路由回环；交给系统路由才能使用代理的虚拟地址。
	netns.SetDisableBindConnToInterface(log.Printf, true)
	env := func(key string) string {
		value := os.Getenv(key)
		if value == "" && key != "KITE_NET_CONTROL_URL" {
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
		Dir:        dir,
		Hostname:   env("KITE_NET_HOSTNAME"),
		ControlURL: env("KITE_NET_CONTROL_URL"),
		// 只在节点需要登录时生效，已登录的节点忽略它。
		AuthKey:  os.Getenv("KITE_NET_AUTH_KEY"),
		Logf:     logf,
		UserLogf: log.Printf,
	}
	defer srv.Close()
	if err := srv.Start(); err != nil {
		log.Fatalf("组网节点启动失败：%v", err)
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
	report := &reporter{out: json.NewEncoder(os.Stdout), current: status{SocksPort: socks.Addr().(*net.TCPAddr).Port}}
	go watch(srv, report, changed)
	go func() {
		for range time.Tick(time.Second) {
			changed()
			report.update(func(s *status) { s.Peers = peers(lc, s.State) })
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
		proxy.ServeHTTP(w, r.WithContext(ctx))
	})
	log.Fatal(http.Serve(ln, handler))
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

// peers 采样对端连接方式，判断方式与上游 tailscale status 一致。
func peers(lc *local.Client, state string) []peer {
	if state != ipn.Running.String() {
		return nil
	}
	st, err := lc.Status(context.Background())
	if err != nil {
		return nil
	}
	var list []peer
	for _, ps := range st.Peer {
		p := peer{Name: ps.HostName, Connection: "idle"}
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
				}
			} else {
				next.Peers = nil
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
