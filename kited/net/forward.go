package main

import (
	"fmt"
	"log"
	"net"
	"net/http"
	"net/http/httputil"
	"net/url"
	"strconv"
	"strings"
	"sync"

	"tailscale.com/client/local"
	"tailscale.com/tsnet"
)

// forwards 是给同账号设备开的网页预览端口：组网上的端口 N 转到本机的 localhost:N，见 docs/成果查看与位置.md「运行中的网页」。
// 哪些端口可以转由 kited 决定（本工作区仍在运行的终端实例所监听的端口），这里只照单开关，并拒绝 kited 与本节点自己的端口。
// 请求按本机访问的样子转交：Host 保留页面所用的本机地址（127.0.0.1、[::1] 或 localhost），端口换成 N，不加转发头，
// 开发服务器的主机检查、按 Host 核对来源、绝对路径资源和自动刷新照常工作。统一改成 localhost 时，开在 127.0.0.1 上的页面
// 来源与 Host 对不上，只认 [::1] 的服务直接拒绝。
type forwards struct {
	srv      *tsnet.Server
	lc       *local.Client
	active   *sync.Map
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
}

func (f *forwards) handler(port int) http.Handler {
	target := &url.URL{Scheme: "http", Host: net.JoinHostPort("localhost", strconv.Itoa(port))}
	proxy := &httputil.ReverseProxy{
		Rewrite: func(r *httputil.ProxyRequest) {
			r.SetURL(target)
			r.Out.Host = net.JoinHostPort(loopbackName(r.In.Host), strconv.Itoa(port))
		},
		FlushInterval: -1,
	}
	return guard(f.lc, f.active, proxy)
}

// loopbackName 是请求 Host 里的本机地址；直接用组网地址访问等其他写法按 localhost 算。
func loopbackName(host string) string {
	name, _, err := net.SplitHostPort(host)
	if err != nil {
		name = strings.Trim(host, "[]")
	}
	if ip := net.ParseIP(name); name == "localhost" || ip != nil && ip.IsLoopback() {
		return name
	}
	return "localhost"
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
