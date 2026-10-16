/**
 * 组网：kited 用 kite-net（tsnet）以独立节点加入用户的 tailnet，不依赖系统 VPN。连 Tailscale 官方协调服务，
 * 第一次开启时状态里给出登录地址，用户在浏览器里登录（docs/分布式架构.md「身份与设备」）。
 * kite-net 把组网端口上的连接转给远程监听；是否开启记在数据目录，登录状态由 tsnet 保存在同一目录。
 * 受管网络通道是给特殊网络用的可选项，默认不配：配了以后组网的 UDP 只经到路由器的认证 WireGuard 通道出网，
 * 私钥由 kite-net 存在钥匙串里，见 docs/kited.md「受管网络通道」。
 */
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { isIPv4, isIPv6 } from 'node:net';
import { z } from 'zod';
import { KiteError } from './errors.ts';
import { join } from 'node:path';
import type { Subprocess } from 'bun';

export interface NetworkStatus {
  enabled: boolean;
  /** tsnet 的后端状态，如 NeedsLogin、Starting、Running；未运行时为 Stopped。 */
  state: string;
  /** 需要登录时，用户要在浏览器里打开的地址。 */
  loginURL?: string;
  ips?: string[];
  name?: string;
  /** 本节点的稳定 ID，重新登录前不变。 */
  id?: string;
  /** 登录的 Tailscale 用户；上线后才有。 */
  user?: { id: string; loginName: string; displayName?: string };
  /** 远程设备连接时填写的地址，上线后才有。 */
  address?: string;
  /** App 复用 kited 的节点访问其他工作机，避免同一台 Mac 登记两次。 */
  socksPort?: number;
  /** kited 自己调用其他工作机用的本机 HTTP 代理端口，只转发到组网地址。 */
  httpProxyPort?: number;
  /** 对端设备及当前连接方式，上线后由 kite-net 每秒采样。 */
  peers?: NetworkPeer[];
  /** 本机对外报告的端点：STUN 探到的公网映射、通道地址或本地地址。 */
  endpoints?: string[];
  /** 受管网络通道的状态，配了通道才有。 */
  channel?: NetworkChannelStatus;
  /** 最近一次系统电源事件（只有 macOS 有），序号递增：shutdown 是将要登出、重启或关机，stay 是登出被取消。 */
  power?: { event: 'sleep' | 'wake' | 'shutdown' | 'stay'; id: number };
  /** 正在转发给同账号设备的网页预览端口，见 forward。 */
  forwards?: number[];
  error?: string;
}

export interface NetworkChannelStatus {
  /** waitingKey 正在从钥匙串取私钥（可能在等用户允许），handshaking 还没与路由器握手成功，up 三分钟内握过手，error 出错。 */
  state: 'waitingKey' | 'handshaking' | 'up' | 'error';
  /** 最近一次与路由器握手的时刻（毫秒）。 */
  handshakeAt?: number;
  error?: string;
}

const ipPort = (value: string) => {
  const match = /^(?:\[([^\]]+)\]|([^:]+)):(\d{1,5})$/.exec(value);
  const port = Number(match?.[3]);
  return !!match && (match[1] ? isIPv6(match[1]) : isIPv4(match[2]!)) && port > 0 && port < 65536;
};
const withoutPrefix = (bits: number) => (value: string) => value.replace(new RegExp(`/${bits}$`), '');

/** 受管网络通道的配置：网络管理员给出的路由器端点、路由器公钥与分给本机的通道内地址。 */
export const networkChannelSchema = z.object({
  endpoint: z.string().trim().refine(ipPort, '路由器端点要写成 IP:端口，如 192.168.31.1:51830'),
  routerKey: z.string().trim().refine((value) => /^[A-Za-z0-9+/]{43}=$/.test(value), '路由器公钥要是 base64 的 32 字节'),
  address4: z.string().trim().transform(withoutPrefix(32)).refine(isIPv4, '通道内 IPv4 地址无效'),
  address6: z.string().trim().transform(withoutPrefix(128)).refine((value) => value === '' || isIPv6(value), '通道内 IPv6 地址无效')
    .optional().transform((value) => value || undefined),
}).strict();
export type NetworkChannel = z.infer<typeof networkChannelSchema>;

/** 组网里同一用户的一台对端设备。 */
export interface NetworkPeer {
  /** 节点的稳定 ID。 */
  id?: string;
  name: string;
  ip?: string;
  /** 对端的系统，如 macOS、iOS、linux。 */
  os?: string;
  /** 协调服务看到它在线。 */
  online?: boolean;
  /** direct 点对点直连，relay 经中继，idle 近两分钟无流量、尚未确定路径。 */
  connection: 'direct' | 'relay' | 'idle';
  /** 直连时为对端实际地址，中继时为 DERP 区域或对端中继地址。 */
  endpoint?: string;
}

export interface NetworkOptions {
  /** 节点状态目录，内含登录凭据。 */
  dir: string;
  binary: string;
  hostname: string;
  /** 组网上对外的端口。 */
  port: number;
  /** kite-net 转发到的远程监听端口。 */
  target: number;
  proxyToken?: string;
  /**
   * 系统将要睡眠、登出、重启或关机时调用 leaving；睡眠要等它返回才放行（kite-net 最多等 25 秒），其余的系统不等。
   * 醒来或登出被取消时调用 returned。
   */
  power?: { leaving(): Promise<void>; returned(): void };
}

const RESTART_DELAY = 5_000;

export class Network {
  private child?: Subprocess<'pipe', 'pipe', 'pipe'>;
  /** 处理过的最近一次电源事件。 */
  private powerEvent = 0;
  private node: Omit<NetworkStatus, 'enabled' | 'address'> = { state: 'Stopped' };
  private restart?: Timer;
  private readonly marker: string;
  private readonly channelFile: string;
  /** 节点状态（含登录凭据）所在的目录；退出登录时整个删掉。 */
  private readonly nodeDir: string;
  private forwarded: number[] = [];

  constructor(private opts: NetworkOptions) {
    this.marker = join(opts.dir, 'enabled');
    this.channelFile = join(opts.dir, 'channel.json');
    this.nodeDir = join(opts.dir, 'node');
    if (this.enabled) this.spawn();
  }

  get enabled(): boolean { return existsSync(this.marker); }

  /** 组网上对外的端口；各工作机用同一个。 */
  get port(): number { return this.opts.port; }

  /** 受管网络通道的配置，按这台机器保存，与账号无关；没配为 undefined。 */
  channel(): NetworkChannel | undefined {
    return existsSync(this.channelFile) ? networkChannelSchema.parse(JSON.parse(readFileSync(this.channelFile, 'utf8'))) : undefined;
  }

  /** 设置或清除受管网络通道；组网开着时重启 kite-net 生效。 */
  async setChannel(channel: NetworkChannel | null): Promise<NetworkStatus> {
    mkdirSync(this.opts.dir, { recursive: true, mode: 0o700 });
    if (channel) writeFileSync(this.channelFile, JSON.stringify(channel), { mode: 0o600 });
    else rmSync(this.channelFile, { force: true });
    if (this.enabled) {
      await this.stop();
      this.spawn();
    }
    return this.status();
  }

  /**
   * 通道公钥，交给网络管理员登记；kite-net 第一次取时生成私钥存进钥匙串。重新编译过的 kite-net 读钥匙串要用户在弹窗里允许，
   * 所以等得比较久。
   */
  async channelKey(): Promise<string> {
    if (!existsSync(this.opts.binary)) throw new KiteError(`缺少组网程序 ${this.opts.binary}，请在 kited/net 中运行 build.sh`, 409);
    const child = Bun.spawn([this.opts.binary, 'key'], { env: { HOME: process.env.HOME ?? '' }, stdin: 'ignore', stdout: 'pipe', stderr: 'pipe' });
    const timer = setTimeout(() => child.kill(), 120_000);
    try {
      const [out, err, code] = await Promise.all([new Response(child.stdout).text(), new Response(child.stderr).text(), child.exited]);
      if (code !== 0) throw new KiteError(`取通道公钥失败：${err.trim() || `组网程序退出（${code}）`}`, 409);
      return z.object({ publicKey: z.string() }).parse(JSON.parse(out)).publicKey;
    } finally { clearTimeout(timer); }
  }

  /**
   * 换掉转发给同账号设备的网页预览端口：组网上的端口 N 转到本机 localhost:N（docs/成果查看与位置.md「运行中的网页」）。
   * 调用方只能给本工作机上仍在运行的终端实例所监听的端口；kited 与组网自己的端口在这里和 kite-net 里都会被去掉。
   * kite-net 重启后照最近一次的集合重新开。
   */
  forward(ports: number[]): void {
    const next = [...new Set(ports)].filter((port) => Number.isInteger(port) && port > 0 && port < 65536
      && port !== this.opts.port && port !== this.opts.target).sort((a, b) => a - b);
    if (next.join() === this.forwarded.join()) return;
    this.forwarded = next;
    this.sendForwards();
  }

  private sendForwards(): void {
    try { void this.child?.stdin.write(`forward ${this.forwarded.join(',')}\n`); void this.child?.stdin.flush(); } catch { /* 节点已退出，重启时再发。 */ }
  }

  status(): NetworkStatus {
    const ipv4 = this.node.ips?.find((ip) => !ip.includes(':'));
    return {
      ...this.node, enabled: this.enabled,
      ...(this.node.state === 'Running' && ipv4 ? { address: `http://${ipv4}:${this.opts.port}` } : {}),
    };
  }

  enable(): NetworkStatus {
    mkdirSync(this.opts.dir, { recursive: true, mode: 0o700 });
    writeFileSync(this.marker, '');
    if (!this.child && !this.restart) this.spawn();
    return this.status();
  }

  /**
   * 退出 Tailscale 登录：节点在线时先让它在 Tailscale 上注销自己，管理页里不留下这台设备；再删掉节点状态，
   * 组网开着时重新起节点，等待新的登录。节点不在线时注销不了，只删本机状态，设备要到 Tailscale 管理页删。
   */
  async logout(): Promise<NetworkStatus> {
    const child = this.child;
    if (child && this.node.state === 'Running') {
      try {
        void child.stdin.write('logout\n');
        void child.stdin.flush();
        await Promise.race([child.exited, Bun.sleep(20_000)]);
      } catch { /* 节点已退出。 */ }
    }
    await this.stop();
    rmSync(this.nodeDir, { recursive: true, force: true });
    if (this.enabled) this.spawn();
    return this.status();
  }

  /** 关闭只停止节点，保留登录状态，再次开启无需重新登录。 */
  async disable(): Promise<NetworkStatus> {
    rmSync(this.marker, { force: true });
    await this.stop();
    return this.status();
  }

  async stop(): Promise<void> {
    clearTimeout(this.restart);
    this.restart = undefined;
    const child = this.child;
    this.child = undefined;
    this.node = { state: 'Stopped' };
    if (child) { child.kill(); await child.exited; }
  }

  private spawn(): void {
    this.restart = undefined;
    if (!existsSync(this.opts.binary)) {
      this.node = { state: 'Stopped', error: `缺少组网程序 ${this.opts.binary}，请在 kited/net 中运行 build.sh` };
      return;
    }
    let channel: NetworkChannel | undefined;
    try { channel = this.channel(); }
    catch (error) { this.node = { state: 'Stopped', error: `受管网络通道配置无效：${(error as Error).message}` }; return; }
    const proxy = Object.fromEntries(['HTTPS_PROXY', 'HTTP_PROXY', 'ALL_PROXY', 'NO_PROXY', 'https_proxy', 'http_proxy', 'all_proxy', 'no_proxy']
      .flatMap((key) => process.env[key] ? [[key, process.env[key]!]] : []));
    const child = Bun.spawn([this.opts.binary], {
      env: {
        HOME: process.env.HOME ?? '', ...proxy,
        KITE_NET_DIR: this.nodeDir, KITE_NET_HOSTNAME: this.opts.hostname,
        KITE_NET_PORT: String(this.opts.port), KITE_NET_TARGET: `127.0.0.1:${this.opts.target}`,
        ...(this.opts.proxyToken ? { KITE_NET_PROXY_TOKEN: this.opts.proxyToken } : {}),
        ...(channel ? { KITE_NET_CHANNEL: JSON.stringify(channel) } : {}),
      },
      stdin: 'pipe', stdout: 'pipe', stderr: 'pipe',
    });
    this.child = child;
    this.node = { state: 'Starting' };
    this.powerEvent = 0;
    if (this.forwarded.length) this.sendForwards();
    void this.read(child.stdout, (line) => {
      if (this.child !== child) return;
      try { this.node = JSON.parse(line); } catch { return; /* 只接受状态行。 */ }
      const power = this.node.power;
      if (!power || power.id <= this.powerEvent) return;
      this.powerEvent = power.id;
      if (power.event === 'wake' || power.event === 'stay') { this.opts.power?.returned(); return; }
      const ready = () => {
        try { void child.stdin.write(`power-ready ${power.id}\n`); void child.stdin.flush(); } catch { /* 节点已退出。 */ }
      };
      void (this.opts.power?.leaving() ?? Promise.resolve()).catch((error: unknown) => console.error(`[换机] ${(error as Error).message}`)).finally(ready);
    });
    let lastError = '';
    void this.read(child.stderr, (line) => { lastError = line; console.error(`kite-net：${line}`); });
    void child.exited.then((code) => {
      if (this.child !== child) return;
      this.child = undefined;
      this.node = { state: 'Stopped', error: lastError || `组网程序退出（${code}）` };
      if (this.enabled) this.restart = setTimeout(() => this.spawn(), RESTART_DELAY);
    });
  }

  private async read(stream: ReadableStream<Uint8Array>, line: (text: string) => void): Promise<void> {
    const decoder = new TextDecoder();
    let buffer = '';
    for await (const chunk of stream) {
      buffer += decoder.decode(chunk, { stream: true });
      let index: number;
      while ((index = buffer.indexOf('\n')) >= 0) {
        const text = buffer.slice(0, index).trim();
        buffer = buffer.slice(index + 1);
        if (text) line(text);
      }
    }
  }
}
