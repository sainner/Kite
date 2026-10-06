// kite-net 把 kited 接入组网：用 tsnet 以独立节点上线，不依赖系统 VPN。
// 只转发同账号设备的 HTTP 请求，来源身份由 tsnet 的 WhoIs 提供。
// 节点状态以 JSON 行写到标准输出，供 kited 显示登录网址和组网地址。
package main

import (
	"context"
	"encoding/json"
	"log"
	"net"
	"net/http"
	"net/http/httputil"
	"net/netip"
	"net/url"
	"os"
	"sync"
	"tailscale.com/client/local"
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
}

func main() {
	log.SetFlags(0)
	env := func(key string) string {
		value := os.Getenv(key)
		if value == "" && key != "KITE_NET_CONTROL_URL" {
			log.Fatalf("缺少 %s", key)
		}
		return value
	}
	target := env("KITE_NET_TARGET")
	srv := &tsnet.Server{
		Dir:        env("KITE_NET_DIR"),
		Hostname:   env("KITE_NET_HOSTNAME"),
		ControlURL: env("KITE_NET_CONTROL_URL"),
		// 只在节点需要登录时生效，已登录的节点忽略它。
		AuthKey:  os.Getenv("KITE_NET_AUTH_KEY"),
		Logf:     func(string, ...any) {},
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
	go watch(srv, socks.Addr().(*net.TCPAddr).Port, changed)
	go func() {
		for range time.Tick(time.Second) {
			changed()
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

// watch 跟随节点状态。需要登录而还没有登录网址时主动请求一次，例如运行中节点密钥过期。
func watch(srv *tsnet.Server, socksPort int, changed func()) {
	ctx := context.Background()
	lc, err := srv.LocalClient()
	if err != nil {
		log.Fatalf("读取节点状态失败：%v", err)
	}
	watcher, err := lc.WatchIPNBus(ctx, ipn.NotifyInitialState|ipn.NotifyNoPrivateKeys)
	if err != nil {
		log.Fatalf("读取节点状态失败：%v", err)
	}
	out := json.NewEncoder(os.Stdout)
	var current status
	requested := false
	for {
		n, err := watcher.Next()
		if err != nil {
			log.Fatalf("节点状态中断：%v", err)
		}
		next := current
		next.SocksPort = socksPort
		if n.State != nil {
			changed()
		}
		if n.State != nil {
			next.State = n.State.String()
		}
		if n.BrowseToURL != nil {
			next.LoginURL = *n.BrowseToURL
		}
		if next.State == ipn.NeedsLogin.String() && next.LoginURL == "" && !requested {
			requested = true
			if err := lc.StartLoginInteractive(ctx); err != nil {
				log.Printf("请求登录网址失败：%v", err)
			}
		}
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
		}
		if next.State != current.State || next.LoginURL != current.LoginURL || next.Name != current.Name || len(next.IPs) != len(current.IPs) {
			current = next
			out.Encode(current)
		}
	}
}
