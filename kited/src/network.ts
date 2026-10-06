/**
 * 组网：kited 用 kite-net（tsnet）以独立节点加入组网，不依赖系统 VPN。
 * kite-net 把组网端口上的连接转给远程监听；是否开启记在数据目录，登录状态由 tsnet 保存在同一目录。
 * 托管账号服务签发一次性密钥；工作机不持有 Headscale 管理密钥。
 */
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { KiteError } from './errors.ts';
import { join } from 'node:path';
import type { Subprocess } from 'bun';

export interface NetworkStatus {
  enabled: boolean;
  /** tsnet 的后端状态，如 NeedsLogin、Starting、Running；未运行时为 Stopped。 */
  state: string;
  loginURL?: string;
  ips?: string[];
  name?: string;
  /** 远程设备连接时填写的地址，上线后才有。 */
  address?: string;
  /** App 复用 kited 的节点访问其他工作机，避免同一台 Mac 登记两次。 */
  socksPort?: number;
  error?: string;
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
}

const RESTART_DELAY = 5_000;

export class Network {
  private child?: Subprocess<'ignore', 'pipe', 'pipe'>;
  private node: Omit<NetworkStatus, 'enabled' | 'address'> = { state: 'Stopped' };
  private restart?: Timer;
  private readonly marker: string;
  private hosted?: { deviceId: string; controlURL: string; authKey: string };

  constructor(private opts: NetworkOptions) {
    this.marker = join(opts.dir, 'enabled');
    const hostedFile = join(opts.dir, 'account.json');
    if (existsSync(hostedFile)) this.hosted = JSON.parse(readFileSync(hostedFile, 'utf8'));
    if (this.enabled) this.spawn();
  }

  async joinAccount(config: { deviceId: string; controlURL: string; authKey: string }): Promise<NetworkStatus> {
    await this.stop();
    mkdirSync(this.opts.dir, { recursive: true, mode: 0o700 });
    writeFileSync(join(this.opts.dir, 'account.json'), JSON.stringify(config), { mode: 0o600 });
    this.hosted = config;
    return this.enable();
  }

  get enabled(): boolean { return existsSync(this.marker); }

  status(): NetworkStatus {
    const ipv4 = this.node.ips?.find((ip) => !ip.includes(':'));
    return {
      ...this.node, enabled: this.enabled,
      ...(this.node.state === 'Running' && ipv4 ? { address: `http://${ipv4}:${this.opts.port}` } : {}),
    };
  }

  enable(): NetworkStatus {
    if (!this.hosted) throw new KiteError('请先在 Kite App 中登录并加入设备');
    mkdirSync(this.opts.dir, { recursive: true, mode: 0o700 });
    writeFileSync(this.marker, '');
    if (!this.child && !this.restart) this.spawn();
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
    if (!this.hosted) { this.node = { state: 'Stopped', error: '请在 Kite App 中登录并加入设备' }; return; }
    this.restart = undefined;
    if (!existsSync(this.opts.binary)) {
      this.node = { state: 'Stopped', error: `缺少组网程序 ${this.opts.binary}，请在 kited/net 中构建` };
      return;
    }
    const proxy = Object.fromEntries(['HTTPS_PROXY', 'HTTP_PROXY', 'ALL_PROXY', 'NO_PROXY', 'https_proxy', 'http_proxy', 'all_proxy', 'no_proxy']
      .flatMap((key) => process.env[key] ? [[key, process.env[key]!]] : []));
    const child = Bun.spawn([this.opts.binary], {
      env: {
        HOME: process.env.HOME ?? '', ...proxy,
        KITE_NET_DIR: join(this.opts.dir, 'accounts', this.hosted.deviceId), KITE_NET_HOSTNAME: this.opts.hostname,
        KITE_NET_PORT: String(this.opts.port), KITE_NET_TARGET: `127.0.0.1:${this.opts.target}`,
        KITE_NET_CONTROL_URL: this.hosted.controlURL,
        KITE_NET_AUTH_KEY: this.hosted.authKey,
        ...(this.opts.proxyToken ? { KITE_NET_PROXY_TOKEN: this.opts.proxyToken } : {}),
      },
      stdin: 'ignore', stdout: 'pipe', stderr: 'pipe',
    });
    this.child = child;
    this.node = { state: 'Starting' };
    void this.read(child.stdout, (line) => {
      if (this.child !== child) return;
      try { this.node = JSON.parse(line); } catch { return; /* 只接受状态行。 */ }
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
