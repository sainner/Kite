// kite-net 把 kited 接入组网：用 tsnet 以独立节点上线，不依赖系统 VPN。
// 组网端口上收到的连接原样转给 kited 的远程监听，认证仍由 kited 的配对令牌负责。
// 节点状态以 JSON 行写到标准输出，供 kited 显示登录网址和组网地址。
package main

import (
	"context"
	"encoding/json"
	"io"
	"log"
	"net"
	"net/netip"
	"os"

	"tailscale.com/ipn"
	"tailscale.com/tsnet"
)

type status struct {
	State    string   `json:"state"`
	LoginURL string   `json:"loginURL,omitempty"`
	IPs      []string `json:"ips,omitempty"`
	Name     string   `json:"name,omitempty"`
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
	go watch(srv)
	ln, err := srv.Listen("tcp", ":"+env("KITE_NET_PORT"))
	if err != nil {
		log.Fatalf("组网端口监听失败：%v", err)
	}
	for {
		conn, err := ln.Accept()
		if err != nil {
			log.Fatalf("组网监听已关闭：%v", err)
		}
		go forward(conn, target)
	}
}

func forward(conn net.Conn, target string) {
	defer conn.Close()
	upstream, err := net.Dial("tcp", target)
	if err != nil {
		return
	}
	defer upstream.Close()
	done := make(chan struct{}, 2)
	go func() { io.Copy(upstream, conn); done <- struct{}{} }()
	go func() { io.Copy(conn, upstream); done <- struct{}{} }()
	<-done
}

// watch 跟随节点状态。需要登录而还没有登录网址时主动请求一次，例如运行中节点密钥过期。
func watch(srv *tsnet.Server) {
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
