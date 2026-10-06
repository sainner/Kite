/**
 * 组网：kited 用 kite-net（tsnet）以独立节点加入组网，不依赖系统 VPN。
 * kite-net 把组网端口上的连接转给远程监听；是否开启记在数据目录，登录状态由 tsnet 保存在同一目录。
 * 控制服务器是 headscale 且配置了管理密钥时，节点登录和新设备入网都用 kited 当场签发的一次性入网密钥，不经浏览器。
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
  /** 已配置 headscale 管理密钥，可自动签发入网密钥。 */
  admin: boolean;
  error?: string;
}

/** headscale 管理凭据，只存在组网目录，不开放给插件或模型工具。 */
interface HeadscaleAdmin { apiKey: string; user: string; userId: string }

export interface NetworkOptions {
  /** 节点状态目录，内含登录凭据。 */
  dir: string;
  binary: string;
  hostname: string;
  /** 组网上对外的端口。 */
  port: number;
  /** kite-net 转发到的远程监听端口。 */
  target: number;
  controlURL?: string;
}

const RESTART_DELAY = 5_000;

export class Network {
  private child?: Subprocess<'ignore', 'pipe', 'pipe'>;
  private node: Omit<NetworkStatus, 'enabled' | 'address' | 'admin'> = { state: 'Stopped' };
  private restart?: Timer;
  private readonly marker: string;
  private readonly adminFile: string;
  /** 每次进程只自动签发一次登录密钥，失败后退回浏览器登录，避免反复申请。 */
  private keyed = false;

  constructor(private opts: NetworkOptions) {
    this.marker = join(opts.dir, 'enabled');
    this.adminFile = join(opts.dir, 'headscale.json');
    if (this.enabled) this.spawn();
  }

  get controlURL(): string | undefined { return this.opts.controlURL; }

  private get admin(): HeadscaleAdmin | undefined {
    if (!this.opts.controlURL || !existsSync(this.adminFile)) return undefined;
    return JSON.parse(readFileSync(this.adminFile, 'utf8')) as HeadscaleAdmin;
  }

  private async headscale(admin: Pick<HeadscaleAdmin, 'apiKey'>, path: string, init: RequestInit = {}): Promise<any> {
    const response = await fetch(new URL(path, this.opts.controlURL), {
      ...init, headers: { Authorization: `Bearer ${admin.apiKey}`, 'Content-Type': 'application/json' },
      signal: AbortSignal.timeout(15_000),
    }).catch((e: Error) => { throw new KiteError(`连不上 headscale：${e.message}`, 502); });
    if (!response.ok) throw new KiteError(`headscale 拒绝请求（${response.status}）：${(await response.text()).slice(0, 200)}`, 502);
    return response.json();
  }

  /** 校验管理密钥并记下用户，之后签发的入网密钥都归这个用户。 */
  async configureAdmin(apiKey: string, user: string): Promise<NetworkStatus> {
    if (!this.opts.controlURL) throw new KiteError('使用 Tailscale 官方服务时不支持管理密钥，请先设置 KITE_CONTROL_URL 指向 headscale');
    const found = (await this.headscale({ apiKey }, `/api/v1/user?name=${encodeURIComponent(user)}`)).users?.[0];
    if (!found) throw new KiteError(`headscale 中没有用户 ${user}`, 404);
    mkdirSync(this.opts.dir, { recursive: true, mode: 0o700 });
    writeFileSync(this.adminFile, JSON.stringify({ apiKey, user, userId: String(found.id) }), { mode: 0o600 });
    return this.status();
  }

  /** 一次性、限时的入网密钥；没有管理密钥时返回 undefined，由对方走浏览器登录。 */
  async authKey(minutes = 10): Promise<string | undefined> {
    const admin = this.admin;
    if (!admin) return undefined;
    const created = await this.headscale(admin, '/api/v1/preauthkey', {
      method: 'POST',
      body: JSON.stringify({ user: admin.userId, reusable: false, ephemeral: false, expiration: new Date(Date.now() + minutes * 60_000).toISOString() }),
    });
    return created.preAuthKey.key as string;
  }

  /** 节点需要登录时，用自己签发的密钥重启 kite-net。 */
  private async login(child: Subprocess): Promise<void> {
    this.keyed = true;
    try {
      const key = await this.authKey();
      if (!key || this.child !== child) return;
      await this.stop(true);
      this.spawn(key);
    } catch (e) { this.node = { ...this.node, error: (e as Error).message }; }
  }

  get enabled(): boolean { return existsSync(this.marker); }

  status(): NetworkStatus {
    const ipv4 = this.node.ips?.find((ip) => !ip.includes(':'));
    return {
      ...this.node, enabled: this.enabled, admin: !!this.admin,
      ...(this.node.state === 'Running' && ipv4 ? { address: `http://${ipv4}:${this.opts.port}` } : {}),
    };
  }

  enable(): NetworkStatus {
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

  async stop(keepKeyed = false): Promise<void> {
    clearTimeout(this.restart);
    this.restart = undefined;
    const child = this.child;
    this.child = undefined;
    this.node = { state: 'Stopped' };
    if (!keepKeyed) this.keyed = false;
    if (child) { child.kill(); await child.exited; }
  }

  private spawn(authKey?: string): void {
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
        KITE_NET_DIR: this.opts.dir, KITE_NET_HOSTNAME: this.opts.hostname,
        KITE_NET_PORT: String(this.opts.port), KITE_NET_TARGET: `127.0.0.1:${this.opts.target}`,
        ...(this.opts.controlURL ? { KITE_NET_CONTROL_URL: this.opts.controlURL } : {}),
        ...(authKey ? { KITE_NET_AUTH_KEY: authKey } : {}),
      },
      stdin: 'ignore', stdout: 'pipe', stderr: 'pipe',
    });
    this.child = child;
    this.node = { state: 'Starting' };
    void this.read(child.stdout, (line) => {
      if (this.child !== child) return;
      try { this.node = JSON.parse(line); } catch { return; /* 只接受状态行。 */ }
      if (this.node.state === 'NeedsLogin' && !this.keyed && this.admin) void this.login(child);
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
