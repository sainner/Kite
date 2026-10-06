/**
 * Git 凭据的加密存储与 GitHub 设备码授权。
 * 加密密钥从账号服务密钥派生，不另设密钥；密文绑定账号与主机，整行挪到别的账号或主机下无法解密。
 */
import { createCipheriv, createDecipheriv, hkdfSync, randomBytes } from 'node:crypto';

export class CredentialCipher {
  private readonly key: Buffer;

  constructor(secret: string) {
    this.key = Buffer.from(hkdfSync('sha256', secret, 'kite-account', 'git-credentials', 32));
  }

  seal(userId: string, host: string, plain: string): string {
    const iv = randomBytes(12);
    const cipher = createCipheriv('aes-256-gcm', this.key, iv);
    cipher.setAAD(Buffer.from(`${userId}\n${host}`));
    const body = Buffer.concat([cipher.update(plain, 'utf8'), cipher.final()]);
    return Buffer.concat([iv, cipher.getAuthTag(), body]).toString('base64');
  }

  open(userId: string, host: string, sealed: string): string {
    const raw = Buffer.from(sealed, 'base64');
    const decipher = createDecipheriv('aes-256-gcm', this.key, raw.subarray(0, 12));
    decipher.setAAD(Buffer.from(`${userId}\n${host}`));
    decipher.setAuthTag(raw.subarray(12, 28));
    return Buffer.concat([decipher.update(raw.subarray(28)), decipher.final()]).toString('utf8');
  }
}

export interface GitHubOptions {
  clientId: string;
  /** 测试替换用；默认 GitHub 官方地址。 */
  webURL?: string;
  apiURL?: string;
}

export interface DeviceCode {
  deviceCode: string;
  userCode: string;
  verificationURI: string;
  expiresIn: number;
  interval: number;
}

export type DevicePoll =
  | { status: 'pending' | 'slow_down' | 'expired' | 'denied' }
  | { status: 'authorized'; token: string; login: string };

async function form(url: string, body: Record<string, string>): Promise<any> {
  const response = await fetch(url, {
    method: 'POST', headers: { accept: 'application/json', 'content-type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams(body), signal: AbortSignal.timeout(15_000),
  });
  if (!response.ok) throw new Error(`GitHub 返回 ${response.status}`);
  return response.json();
}

/** OAuth App 的设备码流程。repo 权限覆盖账号下的全部仓库，代价见 docs/项目与远程仓库.md。 */
export class GitHubDeviceFlow {
  private readonly web: string;
  private readonly api: string;

  constructor(private readonly options: GitHubOptions) {
    this.web = options.webURL ?? 'https://github.com';
    this.api = options.apiURL ?? 'https://api.github.com';
  }

  async start(): Promise<DeviceCode> {
    const r = await form(`${this.web}/login/device/code`, { client_id: this.options.clientId, scope: 'repo' });
    if (!r.device_code) throw new Error('GitHub 没有返回设备码');
    return { deviceCode: r.device_code, userCode: r.user_code, verificationURI: r.verification_uri,
      expiresIn: Number(r.expires_in) || 900, interval: Number(r.interval) || 5 };
  }

  async poll(deviceCode: string): Promise<DevicePoll> {
    const r = await form(`${this.web}/login/oauth/access_token`, {
      client_id: this.options.clientId, device_code: deviceCode, grant_type: 'urn:ietf:params:oauth:grant-type:device_code',
    });
    if (r.access_token) {
      const user = await fetch(`${this.api}/user`, {
        headers: { authorization: `Bearer ${r.access_token}`, accept: 'application/vnd.github+json' }, signal: AbortSignal.timeout(15_000),
      });
      if (!user.ok) throw new Error(`读取 GitHub 账号失败：${user.status}`);
      return { status: 'authorized', token: r.access_token, login: String((await user.json() as { login: string }).login) };
    }
    if (r.error === 'authorization_pending') return { status: 'pending' };
    if (r.error === 'slow_down') return { status: 'slow_down' };
    if (r.error === 'expired_token') return { status: 'expired' };
    if (r.error === 'access_denied') return { status: 'denied' };
    throw new Error(`GitHub 授权失败：${r.error ?? '未知错误'}`);
  }
}
