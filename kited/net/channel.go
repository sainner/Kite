package main

import (
	"context"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"log"
	"net"
	"net/netip"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/tailscale/wireguard-go/conn"
	"github.com/tailscale/wireguard-go/device"
	"github.com/tailscale/wireguard-go/tun"
	"gvisor.dev/gvisor/pkg/tcpip/adapters/gonet"
	"kite/net/netstack"
)

// channelConfig 是受管网络通道的配置，由 kited 经 KITE_NET_CHANNEL 以 JSON 传入。
type channelConfig struct {
	// 路由器的 WireGuard 端点，如 192.168.31.1:51830。
	Endpoint string `json:"endpoint"`
	// 路由器的 WireGuard 公钥（base64）。
	RouterKey string `json:"routerKey"`
	// 分给本机的通道内地址；IPv6 可以没有。
	Address4 string `json:"address4"`
	Address6 string `json:"address6,omitempty"`
}

// channelPort 是通道里组网 UDP 用的端口，与网络侧约定一致。
const channelPort = 41641

// channelStatus 随节点状态上报：waitingKey 正在从钥匙串取私钥（可能在等用户允许），
// handshaking 还没与路由器握手成功，up 最近三分钟内握手过，error 配置或私钥出错。
type channelStatus struct {
	State       string `json:"state"`
	HandshakeAt int64  `json:"handshakeAt,omitempty"`
	Error       string `json:"error,omitempty"`
}

// channel 是到路由器的认证通道：进程内的用户态 WireGuard，经局域网连路由器，由路由器验证身份后给原生出站。
// 系统里不出现网卡，组网的 UDP（STUN、探测与点对点 WireGuard）出网只经它。私钥取到、通道建好之前，
// 交给它的包一律发不出去，也不会退回本机网络直接发。发往本机直连网段的不出网，直接走网卡，见 splitConn。
type channel struct {
	config         channelConfig
	tun            tun.Device
	net            *netstack.Net
	local4, local6 netip.Addr
	links          *localLinks

	mu    sync.Mutex
	dev   *device.Device
	state channelStatus
}

func parseChannel(text string) (*channel, error) {
	var config channelConfig
	if err := json.Unmarshal([]byte(text), &config); err != nil {
		return nil, fmt.Errorf("受管网络通道配置无效：%w", err)
	}
	local4, err := netip.ParseAddr(config.Address4)
	if err != nil || !local4.Is4() {
		return nil, fmt.Errorf("通道内 IPv4 地址无效：%q", config.Address4)
	}
	locals := []netip.Addr{local4}
	var local6 netip.Addr
	if config.Address6 != "" {
		if local6, err = netip.ParseAddr(config.Address6); err != nil || !local6.Is6() {
			return nil, fmt.Errorf("通道内 IPv6 地址无效：%q", config.Address6)
		}
		locals = append(locals, local6)
	}
	tunDev, tnet, err := netstack.CreateNetTUN(locals, nil, 1420)
	if err != nil {
		return nil, fmt.Errorf("建通道网络栈失败：%w", err)
	}
	return &channel{config: config, tun: tunDev, net: tnet, local4: local4, local6: local6, links: watchLocalLinks(),
		state: channelStatus{State: "waitingKey"}}, nil
}

// start 在后台取私钥、建好到路由器的 WireGuard。取私钥可能要等用户在钥匙串弹窗里允许。
func (c *channel) start() {
	go func() {
		if err := c.connect(); err != nil {
			log.Printf("受管网络通道：%v", err)
			c.mu.Lock()
			c.state = channelStatus{State: "error", Error: err.Error()}
			c.mu.Unlock()
		}
	}()
}

func (c *channel) connect() error {
	endpoint, err := netip.ParseAddrPort(c.config.Endpoint)
	if err != nil {
		return fmt.Errorf("路由器端点无效：%q", c.config.Endpoint)
	}
	routerKey, err := base64.StdEncoding.DecodeString(c.config.RouterKey)
	if err != nil || len(routerKey) != 32 {
		return fmt.Errorf("路由器公钥要是 base64 的 32 字节")
	}
	private, err := channelKey()
	if err != nil {
		return err
	}
	allowed := "allowed_ip=0.0.0.0/0\n"
	if c.local6.IsValid() {
		allowed += "allowed_ip=::/0\n"
	}
	dev := device.NewDevice(c.tun, conn.NewDefaultBind(), device.NewLogger(device.LogLevelError, "受管网络通道："))
	config := fmt.Sprintf("private_key=%s\npublic_key=%s\nendpoint=%s\n%spersistent_keepalive_interval=25\n",
		hex.EncodeToString(private[:]), hex.EncodeToString(routerKey), endpoint, allowed)
	if err := dev.IpcSet(config); err != nil {
		dev.Close()
		return fmt.Errorf("配置通道失败：%w", err)
	}
	if err := dev.Up(); err != nil {
		dev.Close()
		return fmt.Errorf("启动通道失败：%w", err)
	}
	c.mu.Lock()
	c.dev = dev
	c.state = channelStatus{State: "handshaking"}
	c.mu.Unlock()
	return nil
}

// status 读一次通道状态；与路由器的握手每两分钟左右重做一次，三分钟内握过手算通。
func (c *channel) status() channelStatus {
	c.mu.Lock()
	dev, state := c.dev, c.state
	c.mu.Unlock()
	if dev == nil {
		return state
	}
	ipc, err := dev.IpcGet()
	if err != nil {
		return channelStatus{State: "error", Error: err.Error()}
	}
	for _, line := range strings.Split(ipc, "\n") {
		if value, ok := strings.CutPrefix(line, "last_handshake_time_sec="); ok {
			if seconds, _ := strconv.ParseInt(value, 10, 64); seconds > 0 {
				at := time.Unix(seconds, 0)
				state.HandshakeAt = at.UnixMilli()
				if time.Since(at) < 3*time.Minute {
					state.State = "up"
				} else {
					state.State = "handshaking"
				}
			}
		}
	}
	return state
}

// lanEndpoint 判断本机网卡上的地址能不能报成对外端点：只报本机直连局域网的 IPv4，同一局域网的设备经它直连；
// 其余（TUN、点对点网卡、宿主自己的 IPv6）对端发来的包到不了通道，报出去只会让对端白试。
func (c *channel) lanEndpoint(ip netip.Addr) bool {
	return ip.Is4() && c.links.contains(ip)
}

// ListenPacket 供 tsnet 创建 UDP：通道这一路固定用通道内地址和约定的端口；IPv4 另开一路局域网直连，
// 端口照 tsnet 给的。没配 IPv6 时不给 IPv6。
func (c *channel) ListenPacket(ctx context.Context, network, address string) (net.PacketConn, error) {
	local := c.local4
	switch {
	case network == "udp6" && c.local6.IsValid():
		local = c.local6
	case network != "udp4":
		return nil, fmt.Errorf("通道不承载 %s", network)
	}
	_, portText, err := net.SplitHostPort(address)
	if err != nil {
		return nil, err
	}
	port, err := strconv.ParseUint(portText, 10, 16)
	if err != nil {
		return nil, err
	}
	udp, err := c.net.ListenUDPAddrPort(netip.AddrPortFrom(local, channelPort))
	if err != nil {
		return nil, err
	}
	tunnel := packetConn{udp}
	if network != "udp4" {
		return tunnel, nil
	}
	lan, err := listenLAN(uint16(port))
	if err != nil {
		log.Printf("受管网络通道：开不了局域网直连的 UDP，只走通道：%v", err)
		return tunnel, nil
	}
	return newSplitConn(tunnel, lan, c.links), nil
}

// packetConn 补上 magicsock 要的 netip 收发接口。
type packetConn struct{ *gonet.UDPConn }

func (p packetConn) WriteToUDPAddrPort(b []byte, to netip.AddrPort) (int, error) {
	return p.WriteTo(b, net.UDPAddrFromAddrPort(to))
}

func (p packetConn) ReadFromUDPAddrPort(b []byte) (int, netip.AddrPort, error) {
	n, from, err := p.ReadFrom(b)
	udp, ok := from.(*net.UDPAddr)
	if !ok {
		return n, netip.AddrPort{}, err
	}
	return n, udp.AddrPort(), err
}
