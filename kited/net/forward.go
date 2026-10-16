package main

import (
	"context"
	"fmt"
	"log"
	"net"
	"net/http"
	"net/http/httputil"
	"net/url"
	"sort"
	"strconv"
	"strings"
	"sync"

	"tailscale.com/client/local"
	"tailscale.com/tsnet"
)

// forwards 是给同账号设备开的网页预览端口：组网上的端口 N 转到本机的 localhost:N，见 docs/成果查看与位置.md「运行中的网页」。
// 哪些端口可以转由 kited 决定（本工作区仍在运行的终端实例所监听的端口），这里只照单开关，并拒绝 kited 与本节点自己的端口。
// 请求按本机访问的样子转交：Host 改成 localhost:N，不加转发头，开发服务器的主机检查、绝对路径资源和自动刷新照常工作。
type forwards struct {
	srv      *tsnet.Server
	lc       *local.Client
	active   *sync.Map
	report   *reporter
	reserved map[int]bool

	mu      sync.Mutex
	servers map[int]*http.Server
}

// set 换成给定的端口集合：不再需要的端口连同已有连接一起关掉。
func (f *forwards) set(ports []int) {
	f.mu.Lock()
	defer f.mu.Unlock()
	want := map[int]bool{}
	for _, port := range ports {
		if port > 0 && port < 65536 && !f.reserved[port] {
			want[port] = true
		}
	}
	for port, server := range f.servers {
		if !want[port] {
			server.Close()
			delete(f.servers, port)
		}
	}
	for port := range want {
		if f.servers[port] != nil {
			continue
		}
		ln, err := f.srv.Listen("tcp", fmt.Sprintf(":%d", port))
		if err != nil {
			log.Printf("转发端口 %d 失败：%v", port, err)
			continue
		}
		server := &http.Server{Handler: f.handler(port)}
		f.servers[port] = server
		go server.Serve(ln)
	}
	list := make([]int, 0, len(f.servers))
	for port := range f.servers {
		list = append(list, port)
	}
	sort.Ints(list)
	f.report.update(func(s *status) { s.Forwards = list })
}

func (f *forwards) handler(port int) http.Handler {
	target := &url.URL{Scheme: "http", Host: net.JoinHostPort("localhost", strconv.Itoa(port))}
	proxy := &httputil.ReverseProxy{
		Rewrite: func(r *httputil.ProxyRequest) {
			r.SetURL(target)
			r.Out.Host = target.Host
		},
		FlushInterval: -1,
	}
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !authorized(f.lc, r) {
			http.Error(w, "设备不属于本账号或授权已撤销", http.StatusUnauthorized)
			return
		}
		// 设备失去授权时由主循环取消，WebSocket 这类长连接随之断开。
		ctx, cancel := context.WithCancel(r.Context())
		defer cancel()
		f.active.Store(r, cancel)
		defer f.active.Delete(r)
		proxy.ServeHTTP(w, r.WithContext(ctx))
	})
}

// parsePorts 读逗号分隔的端口，读不懂的跳过。
func parsePorts(text string) []int {
	var ports []int
	for _, field := range strings.Split(text, ",") {
		if port, err := strconv.Atoi(strings.TrimSpace(field)); err == nil {
			ports = append(ports, port)
		}
	}
	return ports
}

// reservedPorts 是本节点对外的端口和 kited 的远程监听端口，永不转发。
func reservedPorts(listen string, target string) map[int]bool {
	reserved := map[int]bool{}
	for _, value := range []string{listen, target[strings.LastIndex(target, ":")+1:]} {
		if port, err := strconv.Atoi(value); err == nil {
			reserved[port] = true
		}
	}
	return reserved
}
