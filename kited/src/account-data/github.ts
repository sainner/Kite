/** GitHub 设备码授权与仓库列表。 */
import { KiteError } from '../errors.ts';

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

/**
 * Kite 的 OAuth App（github.com/sainner 名下）的客户端 ID。客户端 ID 不是秘密，设备码授权也不用 client secret。
 * 这个 App 开着 Device Flow、关着令牌过期：令牌直接当 Git 口令用，这里不做续期。
 */
const KITE_CLIENT_ID = 'Ov23lioUCZM8nemspYZI';

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
      const user = await api(r.access_token, `${this.api}/user`);
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

async function api(token: string, url: string, init: RequestInit = {}): Promise<Response> {
  return fetch(url, { ...init, headers: { authorization: `Bearer ${token}`, accept: 'application/vnd.github+json',
    ...(init.body ? { 'content-type': 'application/json' } : {}) }, signal: AbortSignal.timeout(15_000) });
}

/** 已绑定 GitHub 账号能访问的仓库，按最近更新排序，只取第一页，供添加项目时挑选。 */
export async function gitHubRepositories(token: string, apiURL = 'https://api.github.com'): Promise<GitHubRepository[]> {
  const response = await api(token, `${apiURL}/user/repos?per_page=100&sort=pushed`);
  if (response.status === 401) throw new Error('GitHub 授权已失效，请重新绑定');
  if (!response.ok) throw new Error(`GitHub 返回 ${response.status}`);
  return (await response.json() as Array<{ full_name: string; clone_url: string; private: boolean; pushed_at: string | null }>)
    .map((r) => ({ fullName: r.full_name, url: r.clone_url, private: r.private, pushedAt: r.pushed_at }));
}

/** 归一化远程里的 owner 与仓库名；不是 github.com 上的仓库时为 undefined。 */
export function gitHubRepo(remote: string): { owner: string; repo: string } | undefined {
  const [host, owner, repo, ...rest] = remote.split('/');
  return host === 'github.com' && owner && repo && !rest.length ? { owner, repo } : undefined;
}

export interface OpenedPullRequest { number: number; url: string }
export type PullRequestState = 'open' | 'merged' | 'closed';

/**
 * 在工作机上绑定 GitHub：设备码授权只要客户端 ID，不要 client secret；token 存成 github.com 的 Git 凭据，随账号级数据同步。
 * 客户端 ID 默认用 Kite 的 OAuth App，KITE_GITHUB_CLIENT_ID 可以换成别的（例如测试用的 App）。
 */
export class GitHubBinding {
  private flows = new Map<string, { deviceCode: string; expiresAt: number }>();
  private readonly flow: GitHubDeviceFlow;
  private readonly apiURL?: string;
  private get apiBase() { return this.apiURL ?? 'https://api.github.com'; }

  constructor(private save: (login: string, token: string) => Promise<void>, private token: () => Promise<string | undefined>,
    options: GitHubOptions = { clientId: process.env.KITE_GITHUB_CLIENT_ID || KITE_CLIENT_ID }) {
    this.flow = new GitHubDeviceFlow(options);
    this.apiURL = options.apiURL;
  }

  async start(): Promise<{ flow: string; userCode: string; verificationURI: string; expiresAt: number; interval: number }> {
    const code = await this.flow.start().catch(() => { throw new KiteError('GitHub 暂时无法访问，请稍后重试', 502); });
    const id = crypto.randomUUID();
    const expiresAt = Date.now() + code.expiresIn * 1000;
    for (const [key, pending] of this.flows) if (pending.expiresAt <= Date.now()) this.flows.delete(key);
    this.flows.set(id, { deviceCode: code.deviceCode, expiresAt });
    return { flow: id, userCode: code.userCode, verificationURI: code.verificationURI, expiresAt, interval: code.interval };
  }

  /** 返回 pending、slow_down、expired、denied 或 authorized（带账号名）。 */
  async poll(id: string): Promise<{ status: string; account?: string }> {
    const pending = this.flows.get(id);
    if (!pending) throw new KiteError('找不到这次授权', 404);
    if (pending.expiresAt <= Date.now()) { this.flows.delete(id); return { status: 'expired' }; }
    const polled = await this.flow.poll(pending.deviceCode).catch(() => { throw new KiteError('GitHub 暂时无法访问，请稍后重试', 502); });
    if (polled.status !== 'pending' && polled.status !== 'slow_down') this.flows.delete(id);
    if (polled.status !== 'authorized') return { status: polled.status };
    await this.save(polled.login, polled.token);
    return { status: 'authorized', account: polled.login };
  }

  /**
   * GitHub 仓库的集成方式默认值：主线有保护规则或仓库有其他协作者时提交 PR，否则直接合入。没绑定或查不到时直接合入并说明。
   */
  async integration(owner: string, repo: string, branch: string | null): Promise<{ integration: 'merge' | 'pullRequest'; integrationReason: string }> {
    const token = await this.token();
    if (!token) return { integration: 'merge', integrationReason: '没有绑定 GitHub，查不到协作者与保护规则，按只有自己用的仓库处理' };
    const base = `${this.apiBase}/repos/${owner}/${repo}`;
    try {
      const [protection, collaborators] = await Promise.all([branch ? api(token, `${base}/branches/${encodeURIComponent(branch)}`) : undefined,
        api(token, `${base}/collaborators?per_page=2&affiliation=all`)]);
      if (protection?.ok && (await protection.json() as { protected?: boolean }).protected) {
        return { integration: 'pullRequest', integrationReason: `主线 ${branch} 设了保护规则` };
      }
      if (collaborators.ok && (await collaborators.json() as unknown[]).length > 1) return { integration: 'pullRequest', integrationReason: '仓库有其他协作者' };
      if (collaborators.ok) return { integration: 'merge', integrationReason: '仓库只有你一个协作者，主线没有保护规则' };
    } catch { /* 网络问题按查不到处理 */ }
    return { integration: 'merge', integrationReason: '查不到仓库的协作者与保护规则，按只有自己用的仓库处理' };
  }

  /**
   * 开 PR，标题与说明由 draft 起草（只在真要开时调用）；这个分支已有开着的 PR 时 GitHub 回 422，改为返回那一个。
   * 没绑定 GitHub 时为 undefined。
   */
  async openPullRequest(owner: string, repo: string, request: { head: string; base: string },
    draft: () => Promise<{ title: string; body: string }>): Promise<OpenedPullRequest | undefined> {
    const token = await this.token();
    if (!token) return undefined;
    const base = `${this.apiBase}/repos/${owner}/${repo}`;
    const created = await api(token, `${base}/pulls`, { method: 'POST', body: JSON.stringify({ ...request, ...await draft() }) });
    if (created.ok) {
      const pull = await created.json() as { number: number; html_url: string };
      return { number: pull.number, url: pull.html_url };
    }
    if (created.status === 422) {
      const existing = await api(token, `${base}/pulls?state=open&head=${encodeURIComponent(`${owner}:${request.head}`)}`);
      const [found] = existing.ok ? await existing.json() as Array<{ number: number; html_url: string }> : [];
      if (found) return { number: found.number, url: found.html_url };
    }
    const message = ((await created.json().catch(() => ({}))) as { message?: string }).message;
    throw new KiteError(`GitHub 没有开出 PR：${message ?? created.status}`, 502);
  }

  /** PR 现在的状态；没绑定或查不到时为 undefined。 */
  async pullRequestState(owner: string, repo: string, number: number): Promise<PullRequestState | undefined> {
    const token = await this.token();
    if (!token) return undefined;
    try {
      const response = await api(token, `${this.apiBase}/repos/${owner}/${repo}/pulls/${number}`);
      if (!response.ok) return undefined;
      const pull = await response.json() as { state: string; merged?: boolean; merged_at?: string | null };
      return pull.merged || pull.merged_at ? 'merged' : pull.state === 'closed' ? 'closed' : 'open';
    } catch { return undefined; }
  }

  /** 已绑定的 GitHub 账号能访问的仓库；没绑定时为空。 */
  async repositories(): Promise<GitHubRepository[]> {
    const token = await this.token();
    if (!token) return [];
    try { return await gitHubRepositories(token, this.apiURL); }
    catch (error) { throw new KiteError((error as Error).message, 502); }
  }
}
