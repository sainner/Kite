/**
 * 回环、未指定、链路本地与本机自己的地址：kited 的本机接口只监听回环、信任回环客户端，命令在任何审批模式下都连不到，
 * 执行授权里也不能写（docs/工具审批与提问.md）。上游的解析地址检查只管主机名，IP 字面量与 localhost 这类名字原样放过，
 * 所以由这里判断；数字形式的 IPv4 先规范化，IPv4 映射的 IPv6 按 IPv4 网段判断。
 */
import { BlockList, isIP } from 'node:net';
import { networkInterfaces } from 'node:os';

const fixed = new BlockList();
for (const [network, prefix] of [['127.0.0.0', 8], ['0.0.0.0', 8], ['169.254.0.0', 16]] as const) fixed.addSubnet(network, prefix, 'ipv4');
for (const [network, prefix] of [['::1', 128], ['::', 128], ['fe80::', 10]] as const) fixed.addSubnet(network, prefix, 'ipv6');

/** 主机名或 IP 字面量，IPv6 可带方括号与接口后缀。own 为假时只判固定网段，不看本机网卡此刻的地址。 */
export function localHost(host: string, own = true): boolean {
  const name = host.toLowerCase().replace(/^\[|\]$/g, '').split('%')[0]!;
  if (name === 'localhost' || name.endsWith('.localhost')) return true;
  let address = name;
  try { address = new URL(`http://${isIP(name) === 6 ? `[${name}]` : name}`).hostname.replace(/^\[|\]$/g, ''); } catch { /* 解析不了的交给上游校验。 */ }
  const family = isIP(address);
  if (family === 0) return false;
  const type = family === 4 ? 'ipv4' : 'ipv6';
  if (fixed.check(address, type)) return true;
  if (!own) return false;
  const addresses = new BlockList();
  for (const entry of Object.values(networkInterfaces()).flat()) {
    // 个别解析不了的跳过，固定网段仍然生效。
    if (entry) try { addresses.addAddress(entry.address.split('%')[0]!, entry.family === 'IPv4' ? 'ipv4' : 'ipv6'); } catch { /* 跳过 */ }
  }
  return addresses.check(address, type);
}

/** 网络许可里的一项：域名或 IP，可带端口，带端口的 IPv6 用方括号。 */
export function localEndpoint(domain: string, own = true): boolean {
  const host = domain.startsWith('[') ? domain.slice(1, domain.indexOf(']')) : isIP(domain) === 6 ? domain : domain.split(':')[0]!;
  return localHost(host, own);
}

const privateRanges = new BlockList();
for (const [network, prefix] of [['10.0.0.0', 8], ['172.16.0.0', 12], ['192.168.0.0', 16], ['100.64.0.0', 10]] as const) privateRanges.addSubnet(network, prefix, 'ipv4');
privateRanges.addSubnet('fc00::', 7, 'ipv6');

/** 局域网、组网（100.64.0.0/10；Tailscale 的 fd7a:115c:a1e0::/48 在 fc00::/7 里）的 IP 地址，或 localHost 认的本机地址。 */
export function privateAddress(address: string): boolean {
  if (localHost(address)) return true;
  const family = isIP(address);
  return family !== 0 && privateRanges.check(address, family === 4 ? 'ipv4' : 'ipv6');
}
