/**
 * kited 访问账号服务的项目登记表与凭据分发，使用目录上报的工作机凭据。
 * 接口见 docs/托管账号与设备.md 的「项目与 Git 远程」。
 */
import { KiteError } from './errors.ts';
import type { GitCredential } from './git-credential.ts';

export interface AccountLink {
  url: string;
  token: string;
}

/** 登记表里的项目。url 是访问地址：托管项目指向托管服务，其余为 HTTPS 写法。 */
export interface RegisteredProject {
  id: string;
  name: string;
  remote: string;
  url: string;
  hosted: boolean;
  createdAt: number;
}

export class AccountClient {
  constructor(private readonly link: () => AccountLink | undefined) {}

  get linked(): boolean { return !!this.link(); }

  private async request<T>(method: string, path: string, body?: unknown): Promise<{ status: number; body: T }> {
    const link = this.link();
    if (!link) throw new KiteError('这台工作机还没有加入 Kite 账号，请先在 App 中登录', 409);
    let response: Response;
    try {
      response = await fetch(new URL(path, link.url), {
        method, signal: AbortSignal.timeout(15_000),
        headers: { authorization: `Bearer ${link.token}`, ...(body === undefined ? {} : { 'content-type': 'application/json' }) },
        body: body === undefined ? undefined : JSON.stringify(body),
      });
    } catch (error) {
      throw new KiteError(`连不上 Kite 账号服务：${(error as Error).message}`, 502);
    }
    const data = await response.json().catch(() => ({})) as T & { error?: string };
    if (response.status === 401) throw new KiteError('工作机的账号授权已失效，请在 App 中重新登录', 409);
    if (!response.ok && response.status !== 404) throw new KiteError(data.error ?? `账号服务返回 ${response.status}`, response.status >= 500 ? 502 : 409);
    return { status: response.status, body: data };
  }

  /** 按远程地址登记；同一远程总是得到同一个项目。 */
  async register(remote: string): Promise<RegisteredProject> {
    const r = await this.request<RegisteredProject & { error?: string }>('POST', '/api/projects', { remote });
    if (r.status === 404) throw new KiteError(r.body.error ?? '找不到这个项目', 404);
    return r.body;
  }

  /** 为没有远程的文件夹新建托管项目。 */
  async createHosted(name: string): Promise<RegisteredProject> {
    return (await this.request<RegisteredProject>('POST', '/api/projects', { hosted: { name } })).body;
  }

  async projects(): Promise<RegisteredProject[]> {
    return (await this.request<RegisteredProject[]>('GET', '/api/projects')).body;
  }

  /** 访问某个 HTTPS 远程的凭据；账号没有绑定这个平台时为 null，交给用户本机的 git 配置。 */
  async credential(url: string): Promise<GitCredential | null> {
    const r = await this.request<GitCredential>('POST', '/api/git/credential', { url });
    return r.status === 404 ? null : { username: r.body.username, password: r.body.password };
  }
}
