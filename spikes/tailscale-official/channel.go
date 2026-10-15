package main

import (
	"context"
	"encoding/hex"
	"fmt"
	"net"
	"net/netip"
	"strconv"
	"strings"
	"time"

	"github.com/tailscale/wireguard-go/conn"
	"github.com/tailscale/wireguard-go/device"
	"gvisor.dev/gvisor/pkg/tcpip/adapters/gonet"
	"kite/spike/tailscale-official/netstack"
)

// channel 是到路由器的认证通道：进程内的用户态 WireGuard，经局域网连路由器，由路由器验证身份后给原生出站。
// 系统里不出现网卡，只有本进程交给它的 UDP（tailscale 的 STUN、探测与 WireGuard）经它出网；
// 通道没握手成功时这些包发不出去，不会退回本机网络直接发。
type channel struct {
	dev *device.Device
	net *netstack.Net
	// 通道内地址：IPv4 必有，IPv6 可选。
	local4, local6 netip.Addr
}

func openChannel(router netip.AddrPort, routerKey, private [32]byte, local4, local6 netip.Addr, verbose bool) (*channel, error) {
	locals := []netip.Addr{local4}
	allowed := "allowed_ip=0.0.0.0/0\n"
	if local6.IsValid() {
		locals = append(locals, local6)
		allowed += "allowed_ip=::/0\n"
	}
	tunDev, tnet, err := netstack.CreateNetTUN(locals, nil, 1420)
	if err != nil {
		return nil, fmt.Errorf("建通道网络栈失败：%w", err)
	}
	level := device.LogLevelError
	if verbose {
		level = device.LogLevelVerbose
	}
	dev := device.NewDevice(tunDev, conn.NewDefaultBind(), device.NewLogger(level, "通道："))
	config := fmt.Sprintf("private_key=%s\npublic_key=%s\nendpoint=%s\n%spersistent_keepalive_interval=25\n",
		hex.EncodeToString(private[:]), hex.EncodeToString(routerKey[:]), router, allowed)
	if err := dev.IpcSet(config); err != nil {
		dev.Close()
		return nil, fmt.Errorf("配置通道失败：%w", err)
	}
	if err := dev.Up(); err != nil {
		dev.Close()
		return nil, fmt.Errorf("启动通道失败：%w", err)
	}
	return &channel{dev: dev, net: tnet, local4: local4, local6: local6}, nil
}

// lastHandshake 是与路由器最近一次握手的时刻；从没握手成功为零值。
func (c *channel) lastHandshake() time.Time {
	state, err := c.dev.IpcGet()
	if err != nil {
		return time.Time{}
	}
	for _, line := range strings.Split(state, "\n") {
		if value, ok := strings.CutPrefix(line, "last_handshake_time_sec="); ok {
			if seconds, _ := strconv.ParseInt(value, 10, 64); seconds > 0 {
				return time.Unix(seconds, 0)
			}
		}
	}
	return time.Time{}
}

// ListenPacket 供 tsnet 创建 UDP：地址固定为通道内地址，端口照 tsnet 给的；没配 IPv6 时不给 IPv6。
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
	udp, err := c.net.ListenUDPAddrPort(netip.AddrPortFrom(local, uint16(port)))
	if err != nil {
		return nil, err
	}
	return packetConn{udp}, nil
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
