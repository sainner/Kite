/** GitHub 设备码授权与仓库列表。 */
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

export interface GitHubRepository {
  fullName: string;
  url: string;
  private: boolean;
  pushedAt: string | null;
}

/** 已绑定 GitHub 账号能访问的仓库，按最近更新排序，只取第一页，供添加项目时挑选。 */
export async function gitHubRepositories(token: string, apiURL = 'https://api.github.com'): Promise<GitHubRepository[]> {
  const response = await fetch(`${apiURL}/user/repos?per_page=100&sort=pushed`, {
    headers: { authorization: `Bearer ${token}`, accept: 'application/vnd.github+json' }, signal: AbortSignal.timeout(15_000),
  });
  if (response.status === 401) throw new Error('GitHub 授权已失效，请重新绑定');
  if (!response.ok) throw new Error(`GitHub 返回 ${response.status}`);
  return (await response.json() as Array<{ full_name: string; clone_url: string; private: boolean; pushed_at: string | null }>)
    .map((r) => ({ fullName: r.full_name, url: r.clone_url, private: r.private, pushedAt: r.pushed_at }));
}
