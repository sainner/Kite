//go:build ios

// Kite 构建 TailscaleKit 时放进 libtailscale 的源文件，见 build-tailscalekit.sh。
package main

import "github.com/tailscale/wireguard-go/device"

// wireguard-go 在 iOS 上把缓冲池限在 1024 个，是给网络扩展的内存上限准备的，取不到缓冲时收发都等着。
// 发往离线对端的包占着缓冲等握手，局域网里的 iPhone 实测每两分多钟整个节点收不到包一分多钟，
// 直到那一轮握手放弃、丢掉排队的包才恢复（2026-10-18）。Kite 是普通 App，没有那个内存上限，和 macOS 一样不设池上限。
func init() {
	device.PreallocatedBuffersPerPool = 0
}
