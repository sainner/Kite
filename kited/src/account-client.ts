/**
 * kited 访问账号服务的项目登记表与凭据分发，使用目录上报的工作机凭据。
 * 接口见 docs/托管账号与设备.md 的「项目与 Git 远程」。
 */
import type { ResolvedSecret, SecretMetadata } from './secrets.ts';
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

/** 账号里的一把模型 API Key；OpenAI、Anthropic 可以只有组织管理 Key。 */
export interface ApiKey {
  id: string;
  name: string;
  provider: 'openai' | 'anthropic' | 'deepseek';
  key?: string;
  adminKey?: string;
}

/** 资源库里的一项；插件包在列表里不带代码，单独读取时才有。 */
export interface LibraryItem {
  kind: 'role' | 'template' | 'emblem' | 'plugin';
  id: string;
  revision: string;
  updatedAt: number;
  body: Record<string, unknown>;
}

/** 项目约束，首期只有工具规则；没设置过时是不限制的黑名单。 */
export interface ProjectConstraints {
  tools: { mode: 'allow' | 'deny'; tools: string[] };
  revision: string;
}

export class AccountClient {
  constructor(private readonly link: () => AccountLink | undefined) {}

  get linked(): boolean { return !!this.link(); }

  /** 非 2xx 一律抛错，状态码随 KiteError 带出；401 表示工作机授权失效。 */
  private async request<T>(method: string, path: string, body?: unknown, signal?: AbortSignal): Promise<T> {
    const link = this.link();
    if (!link) throw new KiteError('这台工作机还没有加入 Kite 账号，请先在 App 中登录', 409);
    let response: Response;
    try {
      response = await fetch(new URL(path, link.url), {
        method, signal: signal ? AbortSignal.any([signal, AbortSignal.timeout(15_000)]) : AbortSignal.timeout(15_000),
        headers: { authorization: `Bearer ${link.token}`, ...(body === undefined ? {} : { 'content-type': 'application/json' }) },
        body: body === undefined ? undefined : JSON.stringify(body),
      });
    } catch (error) {
      signal?.throwIfAborted();
      throw new KiteError(`连不上 Kite 账号服务：${(error as Error).message}`, 502);
    }
    const data = await response.json().catch(() => ({})) as T & { error?: string };
    if (response.status === 401) throw new KiteError('工作机的账号授权已失效，请在 App 中重新登录', 409);
    if (!response.ok) throw new KiteError(data.error ?? `账号服务返回 ${response.status}`, response.status === 404 ? 404 : response.status >= 500 ? 502 : 409);
    return data;
  }

  resolveSecrets(references: string[], projectId?: string, signal?: AbortSignal): Promise<ResolvedSecret[]> {
    return this.request('POST', '/api/credentials/resolve', { references, projectId }, signal);
  }

  listSecrets(projectId?: string, signal?: AbortSignal): Promise<Array<SecretMetadata & { reference: string }>> {
    return this.request('GET', `/api/credentials/available${projectId ? `?projectId=${encodeURIComponent(projectId)}` : ''}`, undefined, signal);
  }

  /** 账号保存的模型 API Key，只用于查询额度。 */
  apiKeys(signal?: AbortSignal): Promise<ApiKey[]> { return this.request('GET', '/api/credentials/api', undefined, signal); }

  /** 按远程地址登记；同一远程总是得到同一个项目。 */
  register(remote: string): Promise<RegisteredProject> { return this.request('POST', '/api/projects', { remote }); }

  /** 为没有远程的文件夹新建托管项目。 */
  createHosted(name: string): Promise<RegisteredProject> { return this.request('POST', '/api/projects', { hosted: { name } }); }

  projects(): Promise<RegisteredProject[]> { return this.request('GET', '/api/projects'); }

  library(signal?: AbortSignal): Promise<LibraryItem[]> { return this.request('GET', '/api/library', undefined, signal); }

  libraryItem(kind: LibraryItem['kind'], id: string): Promise<LibraryItem> {
    return this.request('GET', `/api/library/${kind}/${encodeURIComponent(id)}`);
  }

  /** expectedRevision 为 null 表示新建，省略表示不做版本校验。 */
  putLibrary(kind: LibraryItem['kind'], id: string, body: object, expectedRevision?: string | null): Promise<LibraryItem> {
    return this.request('PUT', `/api/library/${kind}/${encodeURIComponent(id)}`, { body, ...(expectedRevision === undefined ? {} : { expectedRevision }) });
  }

  constraints(projectId: string, signal?: AbortSignal): Promise<ProjectConstraints> {
    return this.request('GET', `/api/projects/${encodeURIComponent(projectId)}/constraints`, undefined, signal);
  }

  /** 访问某个 HTTPS 远程的凭据；账号没有绑定这个平台时为 null，交给用户本机的 git 配置。 */
  async credential(url: string): Promise<GitCredential | null> {
    try {
      const { username, password } = await this.request<GitCredential>('POST', '/api/git/credential', { url });
      return { username, password };
    } catch (error) {
      if (error instanceof KiteError && error.status === 404) return null;
      throw error;
    }
  }
}
