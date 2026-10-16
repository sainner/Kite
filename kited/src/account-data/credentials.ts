/**
 * 凭据：Git 平台授权、共享密钥、模型 API Key 与语音识别 Key，随账号级数据在工作机之间同步，保密内容落地加密。
 * 列表与管理接口只给公开信息；明文只在本机执行时取用（密钥替换、Git 访问、额度查询、语音识别）。
 * 共享密钥按账号或项目区分作用域，代理只传引用，见 docs/工具审批与提问.md。
 */
import { z } from 'zod';
import { KiteError } from '../errors.ts';
import type { GitCredential } from '../git-credential.ts';
import { secretName, secretReference, secretValue, type ResolvedSecret, type SecretMetadata } from '../secrets.ts';
import type { SpeechProvider } from '../voice/models.ts';
import type { AccountData } from './store.ts';

export interface Credential {
  id: string;
  type: CredentialType;
  /** 空表示账号共享。 */
  projectId: string | null;
  name: string;
  meta: Record<string, unknown>;
  createdAt: number;
  updatedAt: number;
}
/** 模型 API Key，只用于查询额度；OpenAI、Anthropic 可以只有组织管理 Key。 */
export interface ApiKey { id: string; name: string; provider: 'openai' | 'anthropic' | 'deepseek'; key?: string; adminKey?: string }
export interface SpeechKey { id: string; name: string; provider: SpeechProvider; key: string }

export const credentialType = z.enum(['secret', 'git', 'api', 'speech']);
export type CredentialType = z.infer<typeof credentialType>;
/** 各类凭据的名称、公开信息与保密内容；API 与语音识别凭据的 hint、admin 由这里生成。 */
const fields: Record<CredentialType, { name: z.ZodType<string>; meta: z.ZodType<Record<string, unknown>>; secret: z.ZodType<Record<string, string | undefined>> }> = {
  secret: {
    name: secretName,
    meta: z.object({ kind: secretValue.shape.kind }).strict(),
    secret: z.object({ value: secretValue.shape.value }).strict(),
  },
  git: {
    name: z.string().regex(/^[a-z0-9.-]+(:\d+)?$/, '主机名无效'),
    meta: z.object({ username: z.string().trim().min(1).max(200).default('oauth2') }).strict(),
    secret: z.object({ token: z.string().min(1).max(4096) }).strict(),
  },
  api: {
    name: z.string().trim().min(1).max(64),
    meta: z.object({ provider: z.enum(['openai', 'anthropic', 'deepseek']) }).strict(),
    secret: z.object({ key: z.string().trim().min(1).max(4096).optional(), adminKey: z.string().trim().min(1).max(4096).optional() }).strict(),
  },
  speech: {
    name: z.string().trim().min(1).max(64),
    meta: z.object({ provider: z.enum(['dashscope']) }).strict(),
    secret: z.object({ key: z.string().trim().min(1).max(4096) }).strict(),
  },
};
export const credentialCreation = z.object({ type: credentialType, name: z.unknown(), projectId: z.uuid().optional(),
  meta: z.unknown().optional(), secret: z.unknown() }).strict();
export const credentialChange = z.object({ name: z.unknown().optional(), meta: z.unknown().optional(), secret: z.unknown().optional() }).strict()
  .refine((change) => Object.keys(change).length > 0, '没有要修改的内容');

/** 校验失败按请求错误报，不暴露校验库的原文。 */
function valid<T>(schema: z.ZodType<T>, value: unknown): T {
  const parsed = schema.safeParse(value);
  if (!parsed.success) throw new KiteError('输入内容不完整或格式有误', 400);
  return parsed.data;
}

interface Stored extends Omit<Credential, 'id'> { secret?: Record<string, string | undefined>; sealed?: string }

export class Credentials {
  constructor(private data: AccountData, private options: {
    /** 项目专用的密钥要求项目在登记表里。 */
    projectExists(id: string): boolean;
    /** 项目并入了别的项目时给出保留的那个：并入项目的凭据按保留的项目列出和取用，改动时写回新的项目。 */
    canonicalProject(id: string): string | undefined;
  }) {}

  /** projectId 为 null 时只列账号共享的。 */
  list(type?: CredentialType, projectId: string | null = null): Credential[] {
    return this.entries().filter((entry) => (type === undefined || entry.type === type) && entry.projectId === projectId)
      .sort((a, b) => a.type.localeCompare(b.type) || a.name.localeCompare(b.name) || a.createdAt - b.createdAt);
  }

  async create(raw: unknown): Promise<Credential> {
    const body = valid(credentialCreation, raw);
    if (body.projectId) {
      if (body.type !== 'secret') throw new KiteError('只有共享密钥可以设为项目专用', 400);
      this.assertProject(body.projectId);
    }
    const input = this.input(body.type, { ...body, secret: body.secret ?? null });
    if (this.find(body.type, body.projectId ?? null, input.name)) throw new KiteError('同名凭据已存在', 409);
    const now = Date.now();
    return this.save(crypto.randomUUID(), { type: body.type, projectId: body.projectId ?? null, name: input.name, meta: input.meta,
      createdAt: now, updatedAt: now, secret: input.secret });
  }

  /** 改名或替换内容，类型与范围不变；API 与语音识别凭据不换密钥时沿用原来的 hint、admin，换供应商必须换密钥。 */
  async update(id: string, raw: unknown): Promise<Credential> {
    const existing = this.entries().find((entry) => entry.id === id);
    if (!existing) throw new KiteError('找不到凭据', 404);
    const change = valid(credentialChange, raw);
    const keyed = existing.type === 'api' || existing.type === 'speech';
    const meta = change.meta ?? (keyed ? { provider: existing.meta.provider } : existing.meta);
    const input = this.input(existing.type, { name: change.name ?? existing.name, meta, secret: change.secret });
    if (keyed && !input.secret) {
      if (input.meta.provider !== existing.meta.provider) throw new KiteError('更换供应商需要重新填写密钥', 400);
      const { provider: _, ...generated } = existing.meta;
      Object.assign(input.meta, generated);
    }
    const other = this.find(existing.type, existing.projectId, input.name);
    if (other && other.id !== id) throw new KiteError('同名凭据已存在', 409);
    const secret = input.secret ?? await this.secret(id);
    return this.save(id, { ...existing, name: input.name, meta: input.meta, updatedAt: Date.now(), secret });
  }

  delete(id: string): void { this.data.remove('credential', id); }

  /** 项目删除后它专用的密钥没人能取用，一起删掉。 */
  deleteProject(projectId: string): void {
    for (const entry of this.entries()) if (entry.projectId === projectId) this.delete(entry.id);
  }

  /** 执行能用的共享密钥：账号共享的，加上当前项目专用的。 */
  available(projectId?: string): Array<SecretMetadata & { reference: string }> {
    const scoped = (scope: string | null) => this.list('secret', scope)
      .map(({ name, meta, updatedAt }) => ({ name, kind: meta.kind as SecretMetadata['kind'], updatedAt, projectId: scope,
        reference: `{${scope ? 'project' : 'account'}.${name}}` }));
    return [...scoped(null), ...(projectId ? scoped(projectId) : [])];
  }

  async resolve(references: string[], projectId?: string): Promise<ResolvedSecret[]> {
    valid(z.array(secretReference).min(1).max(32), references);
    return Promise.all([...new Set(references)].map(async (reference) => {
      const [scope, name] = reference.slice(1, -1).split('.') as [string, string];
      if (scope === 'project' && !projectId) throw new KiteError('当前执行没有绑定项目', 409);
      const found = this.find('secret', scope === 'project' ? projectId! : null, name);
      const secret = found && await this.secret(found.id);
      if (!found || !secret?.value) throw new KiteError(`找不到密钥 ${reference}`, 404);
      return { reference, kind: found.meta.kind as ResolvedSecret['kind'], value: secret.value };
    }));
  }

  /** 访问某个 Git 平台的凭据；没有绑定时为 null，交给用户本机的 git 配置。 */
  async git(host: string): Promise<GitCredential | null> {
    const found = this.find('git', null, host);
    const secret = found && await this.secret(found.id);
    return found && secret?.token ? { username: String(found.meta.username), password: secret.token } : null;
  }

  async saveGit(host: string, username: string, token: string): Promise<void> {
    const found = this.find('git', null, host);
    if (found) await this.update(found.id, { meta: { username }, secret: { token } });
    else await this.create({ type: 'git', name: host, meta: { username }, secret: { token } });
  }

  async apiKeys(): Promise<ApiKey[]> {
    return Promise.all(this.list('api').map(async ({ id, name, meta }) => ({ id, name, provider: meta.provider as ApiKey['provider'],
      ...(await this.secret(id)) })));
  }

  async speechKeys(): Promise<SpeechKey[]> {
    return Promise.all(this.list('speech').map(async ({ id, name, meta }) => ({ id, name, provider: meta.provider as SpeechProvider,
      key: (await this.secret(id))!.key! })));
  }

  private async save(id: string, stored: Stored): Promise<Credential> {
    const { secret: _, sealed: __, ...view } = stored;
    this.data.put('credential', id, await this.data.seal('credential', stored as unknown as Record<string, unknown>));
    return { id, ...view };
  }

  private entries(): Credential[] {
    return this.data.list('credential').map(({ id, body }) => {
      const { secret: _, sealed: __, ...view } = body as unknown as Stored;
      return { id, ...view, projectId: view.projectId && (this.options.canonicalProject(view.projectId) ?? view.projectId) };
    });
  }

  /** 两台工作机同时建了同名的，用最近改过的那条。 */
  private find(type: CredentialType, projectId: string | null, name: string): Credential | undefined {
    return this.entries().filter((entry) => entry.type === type && entry.projectId === projectId && entry.name === name)
      .sort((a, b) => b.updatedAt - a.updatedAt)[0];
  }

  private async secret(id: string): Promise<Record<string, string | undefined> | undefined> {
    const found = this.data.get('credential', id);
    return found && (await this.data.unseal('credential', found.body)).secret as Record<string, string | undefined> | undefined;
  }

  private assertProject(id: string): void {
    if (!this.options.projectExists(id)) throw new KiteError('找不到项目', 404);
  }

  /** 按类型校验名称、公开信息与保密内容；不提供保密内容时只校验前两项。 */
  private input(type: CredentialType, input: { name: unknown; meta?: unknown; secret?: unknown }) {
    const field = fields[type];
    const name = valid(field.name, input.name);
    const meta = valid(field.meta, input.meta ?? {});
    const secret = input.secret === undefined ? undefined : valid(field.secret, input.secret);
    if (type === 'api' && secret) {
      const { key, adminKey } = secret;
      if (meta.provider === 'deepseek' && (!key || adminKey)) throw new KiteError('DeepSeek 只需要 API Key', 400);
      if (!key && !adminKey) throw new KiteError('至少填写调用 Key 或管理 Key', 400);
      Object.assign(meta, { hint: (key ?? adminKey)!.slice(-4), admin: !!adminKey });
    }
    if (type === 'speech' && secret) Object.assign(meta, { hint: secret.key!.slice(-4) });
    return { name, meta, secret };
  }
}
