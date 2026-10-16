package main

import (
	"errors"
	"log"
	"net"
	"net/netip"
	"sync"
	"sync/atomic"
	"time"
)

// localLinks 记着本机直连的局域网网段，每几秒按网卡重读一次，换了 Wi-Fi 也跟得上。
type localLinks struct {
	prefixes atomic.Pointer[[]netip.Prefix]
}

func watchLocalLinks() *localLinks {
	l := &localLinks{}
	l.refresh()
	go func() {
		for range time.Tick(5 * time.Second) {
			l.refresh()
		}
	}()
	return l
}

func (l *localLinks) refresh() {
	var prefixes []netip.Prefix
	ifaces, _ := net.Interfaces()
	for _, iface := range ifaces {
		// 回环和点对点的网卡（VPN 之类的 utun）不算局域网。
		if iface.Flags&net.FlagUp == 0 || iface.Flags&(net.FlagLoopback|net.FlagPointToPoint) != 0 {
			continue
		}
		addrs, err := iface.Addrs()
		if err != nil {
			continue
		}
		for _, addr := range addrs {
			ipnet, ok := addr.(*net.IPNet)
			if !ok {
				continue
			}
			ip, ok := netip.AddrFromSlice(ipnet.IP)
			ip = ip.Unmap()
			if !ok || !ip.Is4() || !(ip.IsPrivate() || ip.IsLinkLocalUnicast()) {
				continue
			}
			ones, bits := ipnet.Mask.Size()
			if bits == 128 {
				ones -= 96
			}
			prefixes = append(prefixes, netip.PrefixFrom(ip, ones).Masked())
		}
	}
	l.prefixes.Store(&prefixes)
}

func (l *localLinks) contains(addr netip.Addr) bool {
	addr = addr.Unmap()
	for _, prefix := range *l.prefixes.Load() {
		if prefix.Contains(addr) {
			return true
		}
	}
	return false
}

// splitConn 是配了通道时交给 magicsock 的 IPv4 UDP：发往本机直连网段的走网卡上的普通 socket，
// 同一局域网里的设备因此能直连；其余（STUN、公网上的对端）仍只经通道出网。两路收到的包合并成一路。
type splitConn struct {
	tunnel   packetConn
	lan      *net.UDPConn
	links    *localLinks
	arrivals chan arrival
	done     chan struct{}
	closing  sync.Once
}

// arrival 是某一路收到的包；data 借用那一路的缓冲，读的一方复制完发 taken，那一路才接着收。
type arrival struct {
	data  []byte
	from  netip.AddrPort
	err   error
	taken chan struct{}
}

func newSplitConn(tunnel packetConn, lan *net.UDPConn, links *localLinks) *splitConn {
	s := &splitConn{tunnel: tunnel, lan: lan, links: links, arrivals: make(chan arrival), done: make(chan struct{})}
	go s.pump(tunnel.ReadFromUDPAddrPort, false)
	go s.pump(lan.ReadFromUDPAddrPort, true)
	return s
}

func (s *splitConn) pump(read func([]byte) (int, netip.AddrPort, error), lan bool) {
	buf := make([]byte, 64<<10)
	taken := make(chan struct{}, 1)
	failing := false
	for {
		n, from, err := read(buf)
		select {
		case <-s.done:
			return
		default:
		}
		// 局域网这一路出错不交给 magicsock：它会当成整个 socket 坏了而停止收包，连带通道也收不到。
		if err != nil && lan {
			if !failing {
				log.Printf("受管网络通道：局域网直连收包出错，稍后重试：%v", err)
			}
			failing = true
			time.Sleep(time.Second)
			continue
		}
		failing = false
		select {
		case s.arrivals <- arrival{data: buf[:n], from: from, err: err, taken: taken}:
		case <-s.done:
			return
		}
		select {
		case <-taken:
		case <-s.done:
			return
		}
	}
}

func (s *splitConn) ReadFromUDPAddrPort(b []byte) (int, netip.AddrPort, error) {
	select {
	case a := <-s.arrivals:
		n := copy(b, a.data)
		a.taken <- struct{}{}
		return n, a.from, a.err
	case <-s.done:
		return 0, netip.AddrPort{}, net.ErrClosed
	}
}

func (s *splitConn) ReadFrom(b []byte) (int, net.Addr, error) {
	n, from, err := s.ReadFromUDPAddrPort(b)
	if !from.IsValid() {
		return n, nil, err
	}
	return n, net.UDPAddrFromAddrPort(from), err
}

func (s *splitConn) WriteToUDPAddrPort(b []byte, to netip.AddrPort) (int, error) {
	if s.links.contains(to.Addr()) {
		return s.lan.WriteToUDPAddrPort(b, netip.AddrPortFrom(to.Addr().Unmap(), to.Port()))
	}
	return s.tunnel.WriteToUDPAddrPort(b, to)
}

func (s *splitConn) WriteTo(b []byte, to net.Addr) (int, error) {
	udp, ok := to.(*net.UDPAddr)
	if !ok {
		return 0, errors.New("只能发往 UDP 地址")
	}
	return s.WriteToUDPAddrPort(b, udp.AddrPort())
}

// LocalAddr 报不指定地址加局域网 socket 的端口，magicsock 据此把本机各网卡的地址都报成本地端点。
func (s *splitConn) LocalAddr() net.Addr {
	return &net.UDPAddr{IP: net.IPv4zero, Port: s.lan.LocalAddr().(*net.UDPAddr).Port}
}

func (s *splitConn) Close() error {
	var err error
	s.closing.Do(func() {
		close(s.done)
		err = errors.Join(s.tunnel.Close(), s.lan.Close())
	})
	return err
}

// 两路合并后读超时没法落到单个 socket 上；magicsock 在 macOS 上不设读超时。
func (s *splitConn) SetDeadline(t time.Time) error {
	return errors.New("合并的 UDP 不支持读超时")
}

func (s *splitConn) SetReadDeadline(t time.Time) error {
	return errors.New("合并的 UDP 不支持读超时")
}

func (s *splitConn) SetWriteDeadline(t time.Time) error {
	return errors.Join(s.tunnel.SetWriteDeadline(t), s.lan.SetWriteDeadline(t))
}

// listenLAN 在网卡上开局域网直连用的 UDP，端口优先用 magicsock 要的，被占了就随便给一个。
func listenLAN(port uint16) (*net.UDPConn, error) {
	conn, err := net.ListenUDP("udp4", &net.UDPAddr{Port: int(port)})
	if err != nil && port != 0 {
		conn, err = net.ListenUDP("udp4", &net.UDPAddr{})
	}
	return conn, err
}
