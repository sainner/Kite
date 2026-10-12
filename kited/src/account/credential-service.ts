/** 凭据管理与分发；账号和工作机的认证仍由服务入口提供。 */
import { z } from 'zod';
import type { GitCredential } from '../git-credential.ts';
import { secretName, secretReference, secretValue } from '../secrets.ts';
import type { Credential, CredentialStore, CredentialType } from './credential-store.ts';
import { bearerToken, RequestError, result } from './http.ts';

interface Options {
  hostedHost: string;
  now(): number;
  worker(token: string): Promise<{ device: { userId: string } } | null>;
  owner(request: Request): Promise<{ userId: string; worker: boolean }>;
  ownedProject(id: string, userId: string): void;
}

const credentialType = z.enum(['secret', 'git', 'api', 'speech']);
/** 各类凭据的名称、公开信息与保密内容；API 与语音识别凭据的 hint、admin 由服务端生成。 */
const credentialFields: Record<CredentialType, { name: z.ZodType<string>; meta: z.ZodType<Record<string, unknown>>; secret: z.ZodType<Record<string, string | undefined>> }> = {
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
const credentialCreation = z.object({ type: credentialType, name: z.unknown(), projectId: z.uuid().optional(),
  meta: z.unknown().optional(), secret: z.unknown() }).strict();
const credentialChange = z.object({ name: z.unknown().optional(), meta: z.unknown().optional(), secret: z.unknown().optional() }).strict()
  .refine((change) => Object.keys(change).length > 0, '没有要修改的内容');

export function createCredentialService(credentials: CredentialStore, { hostedHost, now, worker, owner, ownedProject }: Options) {
  function storedCredential(userId: string, host: string): GitCredential | null {
    const found = credentials.find(userId, 'git', null, host);
    const secret = found && credentials.open<{ token: string }>(userId, found.id);
    return found && secret ? { username: String(found.meta.username), password: secret.token } : null;
  }
  function saveCredential(userId: string, host: string, username: string, token: string) {
    const found = credentials.find(userId, 'git', null, host);
    if (found) credentials.update(userId, found.id, { name: host, meta: { username }, secret: { token } }, now());
    else credentials.create(userId, { type: 'git', projectId: null, name: host, meta: { username } }, { token }, now());
  }
  function secretList(userId: string, projectId?: string) {
    if (projectId) ownedProject(projectId, userId);
    return credentials.list(userId, projectId ?? null, 'secret')
      .map(({ name, meta, updatedAt }) => ({ name, kind: meta.kind, updatedAt, projectId: projectId ?? null }));
  }
  /** 按类型校验名称、公开信息与保密内容；不提供保密内容时只校验前两项。 */
  function credentialInput(type: CredentialType, input: { name: unknown; meta?: unknown; secret?: unknown }) {
    const fields = credentialFields[type];
    const name = fields.name.parse(input.name);
    const meta = fields.meta.parse(input.meta ?? {});
    const secret = input.secret === undefined ? undefined : fields.secret.parse(input.secret);
    if (type === 'git' && name === hostedHost) throw new RequestError('主机名无效', 400);
    if (type === 'api' && secret) {
      const { key, adminKey } = secret;
      if (meta.provider === 'deepseek' && (!key || adminKey)) throw new RequestError('DeepSeek 只需要 API Key', 400);
      if (!key && !adminKey) throw new RequestError('至少填写调用 Key 或管理 Key', 400);
      Object.assign(meta, { hint: (key ?? adminKey)!.slice(-4), admin: !!adminKey });
    }
    if (type === 'speech' && secret) Object.assign(meta, { hint: secret.key!.slice(-4) });
    return { name, meta, secret };
  }
  /** 改名或替换内容，类型与范围不变；API 与语音识别凭据不换密钥时沿用原来的 hint、admin，换供应商必须换密钥。 */
  function changeCredential(userId: string, existing: Credential, change: z.infer<typeof credentialChange>): Credential {
    const keyed = existing.type === 'api' || existing.type === 'speech';
    const meta = change.meta ?? (keyed ? { provider: existing.meta.provider } : existing.meta);
    const input = credentialInput(existing.type, { name: change.name ?? existing.name, meta, secret: change.secret });
    if (keyed && !input.secret) {
      if (input.meta.provider !== existing.meta.provider) throw new RequestError('更换供应商需要重新填写密钥', 400);
      Object.assign(input.meta, existing.type === 'api' ? { hint: existing.meta.hint, admin: existing.meta.admin } : { hint: existing.meta.hint });
    }
    return credentials.update(userId, existing.id, { name: input.name, meta: input.meta, secret: input.secret }, now());
  }

  async function fetch(request: Request, path: string): Promise<Response> {
    if (path === '/api/credentials/resolve' && request.method === 'POST') {
      const found = await worker(bearerToken(request));
      if (!found) throw new RequestError('请使用工作机凭据', 401);
      const userId = found.device.userId;
      const body = z.object({ projectId: z.uuid().optional(), references: z.array(secretReference).min(1).max(32) }).strict().parse(await request.json());
      if (body.projectId) ownedProject(body.projectId, userId);
      return result([...new Set(body.references)].map((reference) => {
        const [scope, name] = reference.slice(1, -1).split('.') as [string, string];
        if (scope === 'project' && !body.projectId) throw new RequestError('当前执行没有绑定项目', 409);
        const found = credentials.find(userId, 'secret', scope === 'project' ? body.projectId! : null, name);
        const secret = found && credentials.open<{ value: string }>(userId, found.id);
        if (!found || !secret) throw new RequestError(`找不到密钥 ${reference}`, 404);
        return { reference, kind: found.meta.kind, value: secret.value };
      }));
    }
    if (path === '/api/credentials/available' && request.method === 'GET') {
      const found = await worker(bearerToken(request));
      if (!found) throw new RequestError('请使用工作机凭据', 401);
      const userId = found.device.userId;
      const projectId = z.uuid().optional().parse(new URL(request.url).searchParams.get('projectId') ?? undefined);
      return result([...secretList(userId), ...(projectId ? secretList(userId, projectId) : [])]
        .map((entry) => ({ ...entry, reference: `{${entry.projectId ? 'project' : 'account'}.${entry.name}}` })));
    }
    if (path === '/api/credentials/api' && request.method === 'GET') {
      const found = await worker(bearerToken(request));
      if (!found) throw new RequestError('请使用工作机凭据', 401);
      const userId = found.device.userId;
      return result(credentials.list(userId, null, 'api').map((credential) => ({ id: credential.id, name: credential.name,
        provider: credential.meta.provider, ...credentials.open<{ key?: string; adminKey?: string }>(userId, credential.id) })));
    }
    if (path === '/api/credentials/speech' && request.method === 'GET') {
      const found = await worker(bearerToken(request));
      if (!found) throw new RequestError('请使用工作机凭据', 401);
      const userId = found.device.userId;
      return result(credentials.list(userId, null, 'speech').map((credential) => ({ id: credential.id, name: credential.name,
        provider: credential.meta.provider, ...credentials.open<{ key: string }>(userId, credential.id) })));
    }
    const user = await owner(request);
    if (user.worker) throw new RequestError('凭据管理需要登录 Kite 账号', 403);
    if (path === '/api/credentials' && request.method === 'GET') {
      const query = new URL(request.url).searchParams;
      const projectId = z.uuid().optional().parse(query.get('projectId') ?? undefined);
      const type = credentialType.optional().parse(query.get('type') ?? undefined);
      if (projectId) ownedProject(projectId, user.userId);
      return result(credentials.list(user.userId, projectId ?? null, type));
    }
    if (path === '/api/credentials' && request.method === 'POST') {
      const body = credentialCreation.parse(await request.json());
      if (body.projectId) {
        if (body.type !== 'secret') throw new RequestError('只有共享密钥可以设为项目专用', 400);
        ownedProject(body.projectId, user.userId);
      }
      const input = credentialInput(body.type, { ...body, secret: body.secret ?? null });
      return result(credentials.create(user.userId, { type: body.type, projectId: body.projectId ?? null, name: input.name, meta: input.meta },
        input.secret, now()), 201);
    }
    const id = z.uuid().parse(path.slice('/api/credentials/'.length));
    if (request.method === 'DELETE') {
      credentials.delete(user.userId, id);
      return result({ ok: true });
    }
    if (request.method === 'PUT') {
      const existing = credentials.get(user.userId, id);
      if (!existing) throw new RequestError('找不到凭据', 404);
      return result(changeCredential(user.userId, existing, credentialChange.parse(await request.json())));
    }
    throw new RequestError('未知的凭据接口', 404);
  }

  return { fetch, storedCredential, saveCredential };
}
