import { expect, test } from 'bun:test';
import { readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { AccountClient } from '../../src/account-client.ts';
import { GitHosting } from '../../src/account/git-hosting.ts';
import { createAccountService } from '../../src/account/service.ts';
import { credentialEnv } from '../../src/git-credential.ts';
import type { Checkout, Machine, Project, Workspace } from '../../src/model.ts';
import { normalizeRemote } from '../../src/remote-url.ts';
import { makeTemp } from '../util.ts';

interface Login { token: string; user: { id: string; email: string } }
interface Device {
  id: string;
  name: string;
  role: 'controller' | 'worker';
  kind: 'phone' | 'tablet' | 'computer' | 'unknown';
}
interface Enrollment { device: Device; controlURL: string; authKey: string }
interface HeadscaleUser { id: string; name: string }
interface PreAuthKey { id: string; key: string; user: string }
interface CatalogSnapshot { machine: Machine; projects: Project[]; checkouts: Checkout[]; workspaces: Workspace[] }
interface CatalogEntry { device: Device; machineId: string; updatedAt: number | null; revision: number; snapshot: CatalogSnapshot | null }
interface Publisher { deviceId: string; url: string; token: string }
interface Worker extends Publisher { machineId: string }
interface ProjectRecord { id: string; name: string; remote: string; url: string; hosted: boolean; createdAt: number }
interface GitHubFake { webURL: string; apiURL: string }
interface Node {
  id: string;
  name: string;
  user: { id: string };
  preAuthKey: { id: string };
  ipAddresses: string[];
  online: boolean;
}

const password = 'Kite-test-password-2026';
const controlURL = 'https://network.kite.test';

async function setup(options: { github?: GitHubFake } = {}) {
  const root = makeTemp('kite-account-');
  const users: HeadscaleUser[] = [];
  const keys: PreAuthKey[] = [];
  const nodes: Node[] = [];
  const deletedNodes: string[] = [];
  const expiredAuthKeys: string[] = [];
  let now = Date.now();
  let sequence = 0;
  const headscale = Bun.serve({
    hostname: '127.0.0.1', port: 0,
    async fetch(request) {
      if (request.headers.get('authorization') !== 'Bearer headscale-test-key') {
        return Response.json({ error: '缺少 Headscale 凭据' }, { status: 401 });
      }
      const url = new URL(request.url);
      if (url.pathname === '/api/v1/user' && request.method === 'GET') {
        return Response.json({ users: users.filter((user) => user.name === url.searchParams.get('name')) });
      }
      if (url.pathname === '/api/v1/user' && request.method === 'POST') {
        const body = await request.json() as { name: string };
        const user = { id: String(++sequence), name: body.name };
        users.push(user);
        return Response.json({ user });
      }
      if (url.pathname === '/api/v1/preauthkey' && request.method === 'POST') {
        const body = await request.json() as { user: string };
        const key = { id: String(++sequence), key: crypto.randomUUID(), user: String(body.user) };
        keys.push(key);
        return Response.json({ preAuthKey: key });
      }
      if (url.pathname === '/api/v1/preauthkey/expire' && request.method === 'POST') {
        const body = await request.json() as { id: string };
        const key = keys.find((key) => key.id === String(body.id));
        if (!key) return Response.json({}, { status: 404 });
        expiredAuthKeys.push(key.key);
        return Response.json({});
      }
      if (url.pathname === '/api/v1/node' && request.method === 'GET') return Response.json({ nodes });
      const match = /^\/api\/v1\/node\/([^/]+)$/.exec(url.pathname);
      if (match && request.method === 'DELETE') {
        const index = nodes.findIndex((node) => node.id === match[1]);
        if (index < 0) return Response.json({}, { status: 404 });
        deletedNodes.push(nodes.splice(index, 1)[0]!.id);
        return Response.json({});
      }
      return Response.json({ error: '未知的 Headscale 请求' }, { status: 404 });
    },
  });
  // 托管仓库要让真实 git 走 HTTP，服务挂在本机端口上，baseURL 就是这个地址。
  let service: Awaited<ReturnType<typeof createAccountService>>;
  const server = Bun.serve({ hostname: '127.0.0.1', port: 0, fetch: (request) => service.fetch(request) });
  const baseURL = server.url.origin;
  const serviceOptions = {
    databasePath: join(root, 'account.sqlite'), baseURL,
    secret: 'kite-test-secret-2026-with-enough-entropy',
    headscale: { url: headscale.url.origin, apiKey: 'headscale-test-key', controlURL },
    git: options.github ? { github: { clientId: 'kite-test-client', ...options.github } } : undefined,
    now: () => now,
  };
  try {
    service = await createAccountService(serviceOptions);
  } catch (error) {
    await server.stop(true);
    await headscale.stop(true);
    rmSync(root, { recursive: true, force: true });
    throw error;
  }
  async function call(method: string, path: string, token?: string, body?: unknown) {
    const headers: Record<string, string> = {};
    if (token) headers.authorization = `Bearer ${token}`;
    if (body !== undefined) headers['content-type'] = 'application/json';
    const response = await service.fetch(new Request(baseURL + path, {
      method, headers, body: body === undefined ? undefined : JSON.stringify(body),
    }));
    return { status: response.status, body: await response.json() as any };
  }
  async function signUp(name: string): Promise<Login> {
    const response = await call('POST', '/api/auth/sign-up/email', undefined, { email: `${name}@kite.test`, password, name });
    expect(response.status).toBe(200);
    return response.body;
  }
  async function enroll(token: string, name: string, role: Device['role'], kind?: Device['kind']): Promise<Enrollment> {
    const response = await call('POST', '/api/devices/enroll', token, { name, role, kind });
    expect(response.status).toBeGreaterThanOrEqual(200);
    expect(response.status).toBeLessThan(300);
    return response.body;
  }
  function node(enrollment: Enrollment, ip: string, overrides: Partial<Node> = {}): Node {
    const key = keys.find((key) => key.key === enrollment.authKey);
    if (!key) throw new Error('入网返回的 authKey 不属于 Headscale');
    const node: Node = {
      id: String(++sequence), name: enrollment.device.name,
      user: { id: key.user }, preAuthKey: { id: key.id }, ipAddresses: [ip], online: true,
      ...overrides,
    };
    nodes.push(node);
    return node;
  }
  async function complete(token: string, enrollment: Enrollment, node: Node) {
    return call('POST', `/api/devices/${enrollment.device.id}/complete`, token, { ip: node.ipAddresses[0], port: 5483 });
  }
  async function session(token: string): Promise<Login> {
    const invitation = await call('POST', '/api/invitations', token);
    expectSuccess(invitation);
    const accepted = await call('POST', '/api/invitations/accept', undefined, { token: invitation.body.token });
    expectSuccess(accepted);
    return accepted.body;
  }
  async function publisher(token: string, enrollment: Enrollment, machineId: string): Promise<Publisher> {
    const response = await call('POST', `/api/devices/${enrollment.device.id}/catalog-publisher`, token, { machineId });
    expectSuccess(response);
    expect(response.body.deviceId).toBe(enrollment.device.id);
    expect(response.body.url).toBe(baseURL);
    return response.body;
  }
  async function catalog(token: string): Promise<CatalogEntry[]> {
    const response = await call('GET', '/api/catalog', token);
    expect(response.status).toBe(200);
    return response.body;
  }
  let workerIP = 0;
  /** 已入网并取得目录上报（工作机）凭据的工作机；token 是登录会话，每台工作机用自己的会话。 */
  async function worker(token: string, name: string): Promise<Worker> {
    const enrollment = await enroll(token, name, 'worker');
    expectSuccess(await complete(token, enrollment, node(enrollment, `100.64.9.${++workerIP}`)));
    const machineId = crypto.randomUUID();
    return { ...await publisher(token, enrollment, machineId), machineId };
  }
  return {
    baseURL, root, call, signUp, enroll, node, complete, session, publisher, catalog, worker, deletedNodes, expiredAuthKeys,
    advance(ms: number) { now += ms; },
    async restart() {
      await service.close();
      service = await createAccountService(serviceOptions);
    },
    async stop() {
      try { await service.close(); }
      finally {
        await server.stop(true);
        await headscale.stop(true);
        rmSync(root, { recursive: true, force: true });
      }
    },
  };
}

function expectSuccess(response: { status: number }) {
  expect(response.status).toBeGreaterThanOrEqual(200);
  expect(response.status).toBeLessThan(300);
}

function expectRejected(response: { status: number }) {
  expect(response.status).toBeGreaterThanOrEqual(400);
  expect(response.status).toBeLessThan(500);
}

function expectEncrypted(root: string, values: string[]) {
  const files = readdirSync(root).filter((name) => name.startsWith('account.sqlite'));
  expect(files).toContain('account.sqlite');
  for (const file of files) {
    const bytes = readFileSync(join(root, file));
    for (const value of values) expect(bytes.includes(Buffer.from(value))).toBe(false);
  }
}

function snapshot(machineId: string, project: Project): CatalogSnapshot {
  const checkout: Checkout = {
    id: crypto.randomUUID(), machineId, projectId: project.id,
    path: `/workspace/${machineId}`, remote: project.remote, createdAt: project.createdAt,
  };
  return {
    machine: { id: machineId, name: '目录工作机', createdAt: project.createdAt }, projects: [project], checkouts: [checkout],
    workspaces: [{ id: crypto.randomUUID(), checkoutId: checkout.id, name: project.name, cwd: checkout.path,
      kind: 'root', branch: 'main', base: null, status: 'open', createdAt: project.createdAt }],
  };
}

// Better Auth 会话、工作机令牌和 SQLite 项目归属跨接口配合；同名凭据不能串账号、串项目或向账号回退。
test('账号和项目的同名密钥独立分发，管理列表只返回所选范围的元数据，缺失引用整批失败', async () => {
  const k = await setup();
  try {
    const alice = await k.signUp('secret-scope-alice');
    const bob = await k.signUp('secret-scope-bob');
    const box = await k.worker(alice.token, '密钥工作机');
    const outsider = await k.worker(bob.token, '其他账号工作机');
    const first = await k.call('POST', '/api/projects', box.token, { remote: 'https://example.test/secret/first.git' });
    const second = await k.call('POST', '/api/projects', box.token, { remote: 'https://example.test/secret/second.git' });
    const foreign = await k.call('POST', '/api/projects', outsider.token, { remote: 'https://example.test/secret/first.git' });
    expect(first.status).toBe(201);
    expect(second.status).toBe(201);
    expect(foreign.status).toBe(201);

    const accountValue = '账号共享假秘密-9a3f26';
    const projectValue = '项目文件假秘密-72c151\n第二行';
    const shared = await k.call('POST', '/api/credentials', alice.token,
      { type: 'secret', name: 'api_key', meta: { kind: 'text' }, secret: { value: accountValue } });
    const scoped = await k.call('POST', '/api/credentials', alice.token,
      { type: 'secret', name: 'api_key', projectId: first.body.id, meta: { kind: 'file' }, secret: { value: projectValue } });
    expect(shared.status).toBe(201);
    expect(scoped.status).toBe(201);
    const account = await k.call('GET', '/api/credentials', alice.token);
    const project = await k.call('GET', `/api/credentials?projectId=${first.body.id}`, alice.token);
    expect(account.status).toBe(200);
    expect(project.status).toBe(200);
    expect(account.body).toEqual([expect.objectContaining({ id: shared.body.id, type: 'secret', name: 'api_key', meta: { kind: 'text' }, projectId: null })]);
    expect(project.body).toEqual([expect.objectContaining({ id: scoped.body.id, type: 'secret', name: 'api_key', meta: { kind: 'file' }, projectId: first.body.id })]);
    expect((await k.call('GET', `/api/credentials?projectId=${second.body.id}`, alice.token)).body).toEqual([]);
    expect((await k.call('GET', '/api/credentials', bob.token)).body).toEqual([]);
    for (const response of [account, project]) {
      expect(JSON.stringify(response.body)).not.toContain(accountValue);
      expect(JSON.stringify(response.body)).not.toContain(projectValue);
    }

    const request = { projectId: first.body.id, references: ['{account.api_key}', '{project.api_key}'] };
    const resolved = await k.call('POST', '/api/credentials/resolve', box.token, request);
    expect(resolved.status).toBe(200);
    expect(resolved.body).toEqual([
      { reference: '{account.api_key}', kind: 'text', value: accountValue },
      { reference: '{project.api_key}', kind: 'file', value: projectValue },
    ]);
    const available = await new AccountClient(() => ({ url: k.baseURL, token: box.token })).listSecrets(first.body.id);
    expect(available).toEqual(expect.arrayContaining([
      expect.objectContaining({ reference: '{account.api_key}', name: 'api_key', kind: 'text', projectId: null }),
      expect.objectContaining({ reference: '{project.api_key}', name: 'api_key', kind: 'file', projectId: first.body.id }),
    ]));
    expect(available).toHaveLength(2);
    expect(JSON.stringify(available)).not.toContain(accountValue);
    expect(JSON.stringify(available)).not.toContain(projectValue);
    expect((await k.call('GET', `/api/credentials/available?projectId=${first.body.id}`, outsider.token)).status).toBe(404);
    expect((await k.call('GET', '/api/credentials/available', outsider.token)).body).toEqual([]);
    expect((await k.call('GET', '/api/credentials', box.token)).status).toBe(403);
    expect((await k.call('POST', '/api/credentials', box.token,
      { type: 'secret', name: 'by_worker', meta: { kind: 'text' }, secret: { value: '工作机不能新建' } })).status).toBe(403);
    expect((await k.call('PUT', `/api/credentials/${shared.body.id}`, box.token, { secret: { value: '工作机不能改写' } })).status).toBe(403);
    expect((await k.call('DELETE', `/api/credentials/${shared.body.id}`, box.token)).status).toBe(403);
    expectRejected(await k.call('POST', '/api/credentials/resolve', alice.token, request));
    expect((await k.call('GET', `/api/credentials?projectId=${foreign.body.id}`, alice.token)).status).toBe(404);
    expect((await k.call('POST', '/api/credentials', alice.token,
      { type: 'secret', name: 'api_key', projectId: foreign.body.id, meta: { kind: 'text' }, secret: { value: '不能写他人项目' } })).status).toBe(404);
    // 其他账号拿到凭据 ID 也不能替换或删除。
    expect((await k.call('PUT', `/api/credentials/${shared.body.id}`, bob.token, { secret: { value: '他人不能改写' } })).status).toBe(404);
    expectSuccess(await k.call('DELETE', `/api/credentials/${shared.body.id}`, bob.token));

    for (const [token, body] of [
      [outsider.token, request],
      [outsider.token, { references: ['{account.api_key}'] }],
      [box.token, { projectId: foreign.body.id, references: ['{project.api_key}'] }],
      [box.token, { projectId: second.body.id, references: ['{account.api_key}', '{project.api_key}'] }],
      [box.token, { projectId: first.body.id, references: ['{account.api_key}', '{project.missing}'] }],
    ] as const) {
      const missing = await k.call('POST', '/api/credentials/resolve', token, body);
      expect({ body, status: missing.status }).toEqual({ body, status: 404 });
      expect(JSON.stringify(missing.body)).not.toContain(accountValue);
      expect(JSON.stringify(missing.body)).not.toContain(projectValue);
    }
    expect((await k.call('POST', '/api/credentials/resolve', box.token, { references: ['{project.api_key}'] })).status).toBe(409);
    expectSuccess(await k.call('DELETE', `/api/credentials/${scoped.body.id}`, alice.token));
    expect((await k.call('GET', `/api/credentials?projectId=${first.body.id}`, alice.token)).body).toEqual([]);
    expect((await k.call('POST', '/api/credentials/resolve', box.token, request)).status).toBe(404);
    expect((await k.call('POST', '/api/credentials/resolve', box.token, { references: ['{account.api_key}'] })).body)
      .toEqual([{ reference: '{account.api_key}', kind: 'text', value: accountValue }]);
  } finally { await k.stop(); }
}, 1_000);

// 三类凭据共用一张表，类型是安全边界：API Key 只能由工作机整组领取，Git token 只能按远程地址领取，
// 两者都不能被命令里的 {account.名称} 引用出来；整组领取也不能串到其他账号。
test('同一供应商的两把 API Key 只由本账号工作机整组领取，API Key 与 Git 凭据不能按共享密钥引用领取', async () => {
  const k = await setup();
  try {
    const alice = await k.signUp('api-key-alice');
    const bob = await k.signUp('api-key-bob');
    const box = await k.worker(alice.token, 'API 工作机');
    const create = (token: string, body: unknown) => k.call('POST', '/api/credentials', token, body);
    const keys = ['sk-openai-main-假密钥-1a2b', 'sk-openai-side-假密钥-3c4d'];
    for (const [index, name] of ['openai_main', 'openai_side'].entries()) {
      expect((await create(alice.token, { type: 'api', name, meta: { provider: 'openai' }, secret: { key: keys[index] } })).status).toBe(201);
    }
    expect((await create(bob.token, { type: 'api', name: 'openai_main', meta: { provider: 'openai' }, secret: { key: 'sk-bob-假密钥-9z' } })).status).toBe(201);
    expect((await create(alice.token, { type: 'git', name: 'gitea', meta: { username: 'kite' }, secret: { token: 'git-假令牌-5e6f' } })).status).toBe(201);
    expect((await create(alice.token, { type: 'api', name: 'deepseek_admin', meta: { provider: 'deepseek' },
      secret: { key: 'sk-ds-假密钥', adminKey: 'sk-ds-admin-假密钥' } })).status).toBe(400);

    const leased = await new AccountClient(() => ({ url: k.baseURL, token: box.token })).apiKeys();
    expect(leased.map(({ name, provider, key }) => ({ name, provider, key })).sort((a, b) => a.name.localeCompare(b.name))).toEqual([
      { name: 'openai_main', provider: 'openai', key: keys[0] },
      { name: 'openai_side', provider: 'openai', key: keys[1] },
    ]);
    expect(JSON.stringify((await k.call('GET', '/api/credentials', alice.token)).body)).not.toContain('假密钥');
    for (const reference of ['{account.openai_main}', '{account.gitea}']) {
      const resolved = await k.call('POST', '/api/credentials/resolve', box.token, { references: [reference] });
      expect({ reference, status: resolved.status }).toEqual({ reference, status: 404 });
    }
  } finally { await k.stop(); }
}, 1_000);

// Bun SQLite 的落盘/重开、HTTP 客户端与工作机认证必须共同生效：轮换或撤销后不能拿缓存中的密钥。
test('密钥以密文持久化，客户端每次取最新值，工作机凭据轮换和撤销后立即拒绝读取', async () => {
  const k = await setup();
  try {
    const owner = await k.signUp('secret-rotation-owner');
    const peer = await k.session(owner.token);
    const enrollment = await k.enroll(peer.token, '可撤销的密钥工作机', 'worker');
    expectSuccess(await k.complete(peer.token, enrollment, k.node(enrollment, '100.64.8.1')));
    const machineId = crypto.randomUUID();
    const grant = await k.publisher(peer.token, enrollment, machineId);
    let link = { url: k.baseURL, token: grant.token };
    const client = new AccountClient(() => link);
    const firstValue = '持久化假秘密-88254b';
    const nextValue = '轮换后的假秘密-4cc95e';
    const references = ['{account.shared_key}'];
    const created = await k.call('POST', '/api/credentials', owner.token,
      { type: 'secret', name: 'shared_key', meta: { kind: 'text' }, secret: { value: firstValue } });
    expect(created.status).toBe(201);
    expect(await client.resolveSecrets(references)).toEqual([{ reference: references[0]!, kind: 'text', value: firstValue }]);
    expectEncrypted(k.root, [firstValue]);
    await k.restart();
    expect(await client.resolveSecrets(references)).toEqual([{ reference: references[0]!, kind: 'text', value: firstValue }]);

    k.advance(1);
    expectSuccess(await k.call('PUT', `/api/credentials/${created.body.id}`, owner.token, { secret: { value: nextValue } }));
    expect(await client.resolveSecrets(references)).toEqual([{ reference: references[0]!, kind: 'text', value: nextValue }]);
    expectEncrypted(k.root, [firstValue, nextValue]);
    const rotated = await k.publisher(peer.token, enrollment, machineId);
    expect(rotated.token).not.toBe(grant.token);
    expect((await k.call('POST', '/api/credentials/resolve', grant.token, { references })).status).toBe(401);
    await expect(client.resolveSecrets(references)).rejects.toThrow();
    link = { url: k.baseURL, token: rotated.token };
    expect(await client.resolveSecrets(references)).toEqual([{ reference: references[0]!, kind: 'text', value: nextValue }]);
    expectSuccess(await k.call('DELETE', `/api/devices/${enrollment.device.id}`, owner.token));
    expect((await k.call('POST', '/api/credentials/resolve', rotated.token, { references })).status).toBe(401);
    await expect(client.resolveSecrets(references)).rejects.toThrow();
    expectSuccess(await k.call('DELETE', `/api/credentials/${created.body.id}`, owner.token));
    expect((await k.call('GET', '/api/credentials', owner.token)).body).toEqual([]);
  } finally { await k.stop(); }
}, 1_000);

// 真实 Better Auth 密码校验与 Bun bearer 请求头、SQLite 用户记录、Headscale 节点归属必须共同生效。
test('密码登录后只能枚举本账号设备，伪造节点的用户或入网密钥都不能绑定', async () => {
  const k = await setup();
  try {
    const alice = await k.signUp('alice');
    const bob = await k.signUp('bob');
    const wrong = await k.call('POST', '/api/auth/sign-in/email', undefined, { email: alice.user.email, password: 'wrong-password' });
    expect(wrong.status).toBe(401);
    const login = await k.call('POST', '/api/auth/sign-in/email', undefined, { email: alice.user.email, password });
    expect(login.status).toBe(200);
    expect(login.body.user.id).toBe(alice.user.id);
    expect(login.body.token).not.toBe(alice.token);

    const left = await k.enroll(login.body.token, 'Alice 的 Mac', 'worker');
    const right = await k.enroll(bob.token, 'Bob 的手机', 'controller');
    expect(left.controlURL).toBe(controlURL);
    const bobNode = k.node(right, '100.64.0.2');
    const forgedUser = k.node(left, '100.64.0.3', { user: bobNode.user });
    expectRejected(await k.complete(login.body.token, left, forgedUser));
    const forgedKey = k.node(left, '100.64.0.4', { preAuthKey: bobNode.preAuthKey });
    expectRejected(await k.complete(login.body.token, left, forgedKey));

    expectSuccess(await k.complete(login.body.token, left, k.node(left, '100.64.0.1')));
    expectSuccess(await k.complete(bob.token, right, bobNode));
    const aliceDevices = await k.call('GET', '/api/devices', login.body.token);
    const bobDevices = await k.call('GET', '/api/devices', bob.token);
    expect(aliceDevices.status).toBe(200);
    expect(bobDevices.status).toBe(200);
    expect(aliceDevices.body.map((device: Device) => device.id)).toEqual([left.device.id]);
    expect(bobDevices.body.map((device: Device) => device.id)).toEqual([right.device.id]);
    expect((await k.call('GET', '/api/devices')).status).toBe(401);
  } finally { await k.stop(); }
}, 1_000);

// 邀请并发消费跨 SQLite 状态与 Better Auth 会话创建，必须只提交一次且不能复用来源会话；
// 设备类型补报须按登记会话归属授权，登记与补报的类型在账号服务重开后仍能从 SQLite 读出。
test('同一邀请并发接受只成功一次，新设备取得独立会话且只能补报自己的类型，服务重启后保留', async () => {
  const k = await setup();
  try {
    const owner = await k.signUp('owner');
    const invitation = await k.call('POST', '/api/invitations', owner.token);
    expectSuccess(invitation);
    const responses = await Promise.all(Array.from({ length: 2 }, () =>
      k.call('POST', '/api/invitations/accept', undefined, { token: invitation.body.token })));
    const accepted = responses.filter((response) => response.status >= 200 && response.status < 300);
    expect(accepted).toHaveLength(1);
    expectRejected(responses.find((response) => response !== accepted[0])!);
    const invited = accepted[0]!.body as Login;
    expect(invited.user.id).toBe(owner.user.id);
    expect(typeof invited.token).toBe('string');
    expect(invited.token).not.toBe(owner.token);

    const original = await k.enroll(owner.token, '原设备', 'controller');
    const scanned = await k.enroll(invited.token, '扫码设备', 'worker', 'phone');
    expect(original.device.id).not.toBe(scanned.device.id);
    expect(original.device.kind).toBe('unknown');
    expect(scanned.device.kind).toBe('phone');
    expectSuccess(await k.complete(owner.token, original, k.node(original, '100.64.1.1')));
    expectSuccess(await k.complete(invited.token, scanned, k.node(scanned, '100.64.1.2')));
    const reported = await k.call('PATCH', `/api/devices/${original.device.id}`, owner.token, { kind: 'computer' });
    expect(reported.status).toBe(200);
    expect(reported.body).toEqual({ ok: true });
    expect((await k.call('PATCH', `/api/devices/${original.device.id}`, invited.token, { kind: 'tablet' })).status).toBe(403);
    expect((await k.call('PATCH', `/api/devices/${scanned.device.id}`, owner.token, { kind: 'tablet' })).status).toBe(403);
    await k.restart();
    const devices = await k.call('GET', '/api/devices', invited.token);
    expect(devices.status).toBe(200);
    expect(devices.body.map((device: Device) => device.id).sort()).toEqual([original.device.id, scanned.device.id].sort());
    expect(devices.body).toEqual(expect.arrayContaining([
      expect.objectContaining({ id: original.device.id, kind: 'computer' }),
      expect.objectContaining({ id: scanned.device.id, kind: 'phone' }),
    ]));
    expect((await k.call('GET', '/api/devices', owner.token)).status).toBe(200);
  } finally { await k.stop(); }
}, 1_000);

// 邀请寿命与签发来源会话分别失效；Headscale 已入网但 App 尚未完成绑定时，撤销不能漏掉节点和密钥。
test('过期和来源已撤销的邀请不能换登录，撤销也删除尚未完成绑定的节点及其入网密钥', async () => {
  const k = await setup();
  try {
    const owner = await k.signUp('owner');
    const source = await k.enroll(owner.token, '签发设备', 'controller');
    const pending = k.node(source, '100.64.3.1');
    const expired = await k.call('POST', '/api/invitations', owner.token);
    expectSuccess(expired);
    k.advance(5 * 60 * 1_000 + 1);
    expectRejected(await k.call('POST', '/api/invitations/accept', undefined, { token: expired.body.token }));

    const revoked = await k.call('POST', '/api/invitations', owner.token);
    expectSuccess(revoked);
    expectSuccess(await k.call('DELETE', `/api/devices/${source.device.id}`, owner.token));
    expect(k.expiredAuthKeys).toEqual([source.authKey]);
    expect(k.deletedNodes).toEqual([pending.id]);
    expect((await k.call('GET', '/api/devices', owner.token)).status).toBe(401);
    expectRejected(await k.call('POST', '/api/invitations/accept', undefined, { token: revoked.body.token }));
  } finally { await k.stop(); }
}, 1_000);

// 删除本账号设备同时跨 Headscale 节点与 Better Auth 会话，不能撤销其他设备或其他账号的资源。
test('跨账号撤销无效，本账号撤销只移除目标节点和会话并保留另一设备', async () => {
  const k = await setup();
  try {
    const owner = await k.signUp('owner');
    const outsider = await k.signUp('outsider');
    const invitation = await k.call('POST', '/api/invitations', owner.token);
    expectSuccess(invitation);
    const accepted = await k.call('POST', '/api/invitations/accept', undefined, { token: invitation.body.token });
    expectSuccess(accepted);
    const other = accepted.body as Login;
    const first = await k.enroll(owner.token, '保留设备', 'controller');
    const second = await k.enroll(other.token, '撤销设备', 'worker');
    const firstNode = k.node(first, '100.64.2.1');
    const secondNode = k.node(second, '100.64.2.2');
    expectSuccess(await k.complete(owner.token, first, firstNode));
    expectSuccess(await k.complete(other.token, second, secondNode));

    expect((await k.call('DELETE', `/api/devices/${second.device.id}`, outsider.token)).status).toBe(404);
    expect(k.deletedNodes).toEqual([]);
    expect((await k.call('GET', '/api/devices', other.token)).status).toBe(200);
    expectSuccess(await k.call('DELETE', `/api/devices/${second.device.id}`, owner.token));
    expect(k.deletedNodes).toEqual([secondNode.id]);
    expect((await k.call('GET', '/api/devices', other.token)).status).toBe(401);
    const remaining = await k.call('GET', '/api/devices', owner.token);
    expect(remaining.status).toBe(200);
    expect(remaining.body.map((device: Device) => device.id)).toEqual([first.device.id]);
    expect((await k.call('GET', '/api/devices', outsider.token)).status).toBe(200);
  } finally { await k.stop(); }
}, 1_000);

// 同账号机器目录跨 SQLite 快照与 Headscale 在线状态汇总；并发发布和过时重试不能覆盖已接受的新版本。
test('两台工作机共享项目身份且离线目录保留，快照替换清除旧项并拒绝乱序或冲突发布', async () => {
  const k = await setup();
  try {
    const owner = await k.signUp('catalog-owner');
    const peer = await k.session(owner.token);
    const left = await k.enroll(owner.token, '第一台工作机', 'worker');
    const right = await k.enroll(peer.token, '第二台工作机', 'worker');
    const leftNode = k.node(left, '100.64.4.1');
    expectSuccess(await k.complete(owner.token, left, leftNode));
    expectSuccess(await k.complete(peer.token, right, k.node(right, '100.64.4.2')));
    const project = { id: crypto.randomUUID(), name: '共同项目', remote: 'example.test/owner/shared', createdAt: 1_700_000_000_000 };
    const leftSnapshot = snapshot(crypto.randomUUID(), project);
    const rightSnapshot = snapshot(crypto.randomUUID(), project);
    const leftPublisher = await k.publisher(owner.token, left, leftSnapshot.machine.id);
    const rightPublisher = await k.publisher(peer.token, right, rightSnapshot.machine.id);
    const initial = await k.catalog(owner.token);
    expect(initial).toHaveLength(2);
    expect(initial.map((entry) => [entry.revision, entry.updatedAt, entry.snapshot])).toEqual([[0, null, null], [0, null, null]]);

    const leftPath = `/api/catalog/${left.device.id}`;
    const rightPath = `/api/catalog/${right.device.id}`;
    expectSuccess(await k.call('PUT', leftPath, leftPublisher.token, { revision: 1, snapshot: leftSnapshot }));
    expectSuccess(await k.call('PUT', rightPath, rightPublisher.token, { revision: 1, snapshot: rightSnapshot }));
    leftNode.online = false;
    const offline = await k.catalog(owner.token);
    expect(offline).toHaveLength(2);
    expect(offline.find((entry) => entry.device.id === left.device.id)?.snapshot).toEqual(leftSnapshot);
    expect(offline.find((entry) => entry.device.id === right.device.id)?.snapshot).toEqual(rightSnapshot);
    expect(offline.map((entry) => entry.snapshot!.projects[0]!.id)).toEqual([project.id, project.id]);
    const devices = await k.call('GET', '/api/devices', owner.token);
    expect(offline.find((entry) => entry.device.id === left.device.id)?.device)
      .toEqual(devices.body.find((device: Device) => device.id === left.device.id));

    k.advance(100);
    const replacement = { ...leftSnapshot, workspaces: [] };
    expectSuccess(await k.call('PUT', leftPath, leftPublisher.token, { revision: 3, snapshot: replacement }));
    expect((await k.call('PUT', leftPath, leftPublisher.token, { revision: 2, snapshot: leftSnapshot })).status).toBe(409);
    expect((await k.call('PUT', leftPath, leftPublisher.token, { revision: 3, snapshot: replacement })).status).toBe(200);
    expect((await k.call('PUT', leftPath, leftPublisher.token, { revision: 3, snapshot: leftSnapshot })).status).toBe(409);
    const broken = { ...replacement, checkouts: [{ ...replacement.checkouts[0]!, projectId: crypto.randomUUID() }] };
    expect((await k.call('PUT', leftPath, leftPublisher.token, { revision: 4, snapshot: broken })).status).toBe(400);
    const duplicate = { ...replacement, projects: [project, project] };
    expect((await k.call('PUT', leftPath, leftPublisher.token, { revision: 4, snapshot: duplicate })).status).toBe(400);
    const replaced = (await k.catalog(owner.token)).find((entry) => entry.device.id === left.device.id)!;
    expect(replaced.revision).toBe(3);
    expect(replaced.snapshot).toEqual(replacement);
    expect(typeof replaced.updatedAt).toBe('number');

    const candidates = ['并发目录甲', '并发目录乙'].map((name) => ({ ...replacement, machine: { ...replacement.machine, name } }));
    const outcomes = await Promise.all(candidates.map((candidate) =>
      k.call('PUT', leftPath, leftPublisher.token, { revision: 4, snapshot: candidate })));
    expect(outcomes.map((result) => result.status).sort()).toEqual([200, 409]);
    const final = await k.catalog(peer.token);
    expect(final.find((entry) => entry.device.id === left.device.id)?.snapshot)
      .toEqual(candidates[outcomes.findIndex((result) => result.status === 200)]);
    expect(final.find((entry) => entry.device.id === right.device.id)?.snapshot).toEqual(rightSnapshot);
  } finally { await k.stop(); }
}, 1_000);

// 真实账号会话与目录发布凭据是不同权限；设备角色、会话归属、凭据轮换和撤销须共同限制目录访问。
test('目录发布只授权已绑定的本机工作机会话，专用凭据不能越权且轮换和删设备立即失效', async () => {
  const k = await setup();
  try {
    const owner = await k.signUp('publisher-owner');
    const controller = await k.session(owner.token);
    const peer = await k.session(owner.token);
    const outsider = await k.signUp('publisher-outsider');
    const worker = await k.enroll(owner.token, '发布工作机', 'worker');
    const control = await k.enroll(controller.token, '控制端', 'controller');
    const other = await k.enroll(peer.token, '另一工作机', 'worker');
    const machineId = crypto.randomUUID();
    const grantPath = `/api/devices/${worker.device.id}/catalog-publisher`;
    expectRejected(await k.call('POST', grantPath, owner.token, { machineId }));
    expectSuccess(await k.complete(owner.token, worker, k.node(worker, '100.64.5.1')));
    expectSuccess(await k.complete(controller.token, control, k.node(control, '100.64.5.2')));
    expectSuccess(await k.complete(peer.token, other, k.node(other, '100.64.5.3')));
    expectRejected(await k.call('POST', `/api/devices/${control.device.id}/catalog-publisher`, controller.token, { machineId }));
    expectRejected(await k.call('POST', grantPath, peer.token, { machineId }));
    expectRejected(await k.call('POST', grantPath, outsider.token, { machineId }));
    const grant = await k.publisher(owner.token, worker, machineId);
    const otherId = crypto.randomUUID();
    const otherGrant = await k.publisher(peer.token, other, otherId);
    expect(grant.token).not.toBe(owner.token);
    expect(grant.token).not.toBe(otherGrant.token);
    for (const path of ['/api/account', '/api/catalog', '/api/devices']) {
      expect((await k.call('GET', path, grant.token)).status).toBe(401);
    }
    expectRejected(await k.call('POST', grantPath, grant.token, { machineId }));
    const project = { id: crypto.randomUUID(), name: '私有项目', remote: 'example.test/owner/private', createdAt: 1_700_000_000_000 };
    const catalog = snapshot(machineId, project);
    const path = `/api/catalog/${worker.device.id}`;
    expectRejected(await k.call('PUT', path, owner.token, { revision: 1, snapshot: catalog }));
    expectRejected(await k.call('PUT', `/api/catalog/${other.device.id}`, grant.token, { revision: 1, snapshot: snapshot(otherId, project) }));
    expect((await k.call('PUT', path, grant.token, { revision: 1, snapshot: snapshot(otherId, project) })).status).toBe(400);
    expectSuccess(await k.call('PUT', path, grant.token, { revision: 1, snapshot: catalog }));
    expect((await k.catalog(outsider.token)).some((entry) => entry.device.id === worker.device.id)).toBe(false);

    const rotated = await k.publisher(owner.token, worker, machineId);
    expect(rotated.token).not.toBe(grant.token);
    expectRejected(await k.call('PUT', path, grant.token, { revision: 2, snapshot: catalog }));
    expectSuccess(await k.call('PUT', path, rotated.token, { revision: 2, snapshot: catalog }));
    expectSuccess(await k.call('DELETE', `/api/devices/${worker.device.id}`, controller.token));
    expectRejected(await k.call('PUT', path, rotated.token, { revision: 3, snapshot: catalog }));
    expect((await k.catalog(controller.token)).some((entry) => entry.device.id === worker.device.id)).toBe(false);
  } finally { await k.stop(); }
}, 1_000);

/**
 * 测试自己起的 git 用的环境：全局配置指向临时文件，不读系统配置（Xcode 自带的 osxkeychain 助手），不弹提示。
 * git 的网络请求要由本进程里的 Bun.serve 应答，所以只能异步起进程，不能 spawnSync 卡住事件循环。
 */
function gitEnv(home: string, global: string): Record<string, string> {
  const env: Record<string, string> = {
    PATH: process.env.PATH!, HOME: home, LANG: 'en_US.UTF-8',
    GIT_CONFIG_NOSYSTEM: '1', GIT_CONFIG_GLOBAL: global, GIT_TERMINAL_PROMPT: '0',
    GIT_AUTHOR_NAME: '测试者', GIT_AUTHOR_EMAIL: 'tester@example.com',
    GIT_COMMITTER_NAME: '测试者', GIT_COMMITTER_EMAIL: 'tester@example.com',
  };
  if (process.env.DEVELOPER_DIR) env.DEVELOPER_DIR = process.env.DEVELOPER_DIR;
  return env;
}

async function gitRun(cwd: string, env: Record<string, string>, args: string[], input?: string) {
  const child = Bun.spawn(['git', ...args], {
    cwd, env, stdin: input === undefined ? 'ignore' : new Blob([input]), stdout: 'pipe', stderr: 'pipe',
  });
  const [out, err, code] = await Promise.all([new Response(child.stdout).text(), new Response(child.stderr).text(), child.exited]);
  return { code, out: out.trim(), err };
}

async function gitDo(cwd: string, env: Record<string, string>, ...args: string[]): Promise<string> {
  const result = await gitRun(cwd, env, args);
  if (result.code !== 0) throw new Error(`git ${args.join(' ')} 失败：${result.err}`);
  return result.out;
}

function basic(username: string, password: string) {
  return `Basic ${btoa(`${username}:${password}`)}`;
}

// 依赖 git 的两条行为：收到 401 + WWW-Authenticate: Basic 才调凭据助手；GIT_CONFIG_COUNT 注入的空 credential.helper
// 清空全局配置里已有的助手列表，带地址的 credential.<url>.helper 只对该主机生效。服务端依赖 git http-backend 的 CGI 转接。
test('工作机取托管凭据后真实 git 能 clone 空托管仓库并推送再 clone，全局旧助手不抢先，无凭据或他人凭据被拒', async () => {
  const k = await setup();
  const work = makeTemp('kite-hosted-git-');
  try {
    const alice = await k.signUp('hosted-alice');
    const bob = await k.signUp('hosted-bob');
    const aliceWorker = await k.worker(alice.token, 'Alice 工作机');
    const bobWorker = await k.worker(bob.token, 'Bob 工作机');
    const created = await k.call('POST', '/api/projects', aliceWorker.token, { hosted: { name: 'notes' } });
    expect(created.status).toBe(201);
    const project = created.body as ProjectRecord;
    expect(project.hosted).toBe(true);
    expect(project.url).toBe(`${k.baseURL}/git/${project.id}.git`);

    // 全局配置里有一个对所有主机生效、给出错误口令的助手，模拟用户钥匙串里的旧凭据。
    const global = join(work, 'global.gitconfig');
    writeFileSync(global, '[credential]\n\thelper = "!f() { echo username=stale; echo password=stale; }; f"\n');
    const env = gitEnv(work, global);
    const issued = await k.call('POST', '/api/git/credential', aliceWorker.token, { url: project.url });
    expect(issued.status).toBe(200);
    expect(typeof issued.body.expiresAt).toBe('number');
    const aliceEnv = { ...env, ...credentialEnv(project.url, { username: issued.body.username, password: issued.body.password }) };

    await gitDo(work, aliceEnv, 'clone', '-q', project.url, 'first');
    const first = join(work, 'first');
    writeFileSync(join(first, 'README.md'), '托管仓库\n');
    await gitDo(first, aliceEnv, 'add', '-A');
    await gitDo(first, aliceEnv, 'commit', '-q', '-m', '第一个提交');
    const head = await gitDo(first, aliceEnv, 'rev-parse', 'HEAD');
    await gitDo(first, aliceEnv, 'push', '-q', 'origin', 'HEAD:refs/heads/main');
    await gitDo(work, aliceEnv, 'clone', '-q', project.url, 'second');
    expect(await gitDo(join(work, 'second'), aliceEnv, 'rev-parse', 'HEAD')).toBe(head);

    // 注入的助手只对托管地址生效：别的主机仍走全局助手。
    const other = await gitRun(work, aliceEnv, ['credential', 'fill'], 'protocol=https\nhost=example.com\n\n');
    expect(other.code).toBe(0);
    expect(other.out).toContain('password=stale');
    expect(other.out).not.toContain(issued.body.password);

    expect((await gitRun(work, { ...env, ...credentialEnv(project.url, null) }, ['ls-remote', project.url])).code).not.toBe(0);
    const foreign = await k.call('POST', '/api/git/credential', bobWorker.token, { url: project.url });
    expect(foreign.status).toBe(200);
    const bobEnv = { ...env, ...credentialEnv(project.url, { username: foreign.body.username, password: foreign.body.password }) };
    expect((await gitRun(work, bobEnv, ['ls-remote', project.url])).code).not.toBe(0);
    expect((await gitRun(first, bobEnv, ['push', '-q', project.url, 'HEAD:refs/heads/stolen'])).code).not.toBe(0);
  } finally {
    rmSync(work, { recursive: true, force: true });
    await k.stop();
  }
}, 1_000);

// 归一化依赖 WHATWG URL 对 scp 写法、大小写主机和结尾 .git 的解析，项目 ID 依赖登记表按（账号，归一化地址）唯一。
// 列表依赖 Bun SQLite 关联可选外观行：缺少外观的项目仍保留默认值，有外观的项目按创建顺序返回且不串账号。
test('两台工作机用 SSH 与 HTTPS 写法登记同一仓库得到同一项目，其他账号另得项目，托管地址只能找回本账号已有项目，列表按创建顺序保留默认与自选外观', async () => {
  const k = await setup();
  try {
    const alice = await k.signUp('registry-alice');
    const peer = await k.session(alice.token);
    const bob = await k.signUp('registry-bob');
    const left = await k.worker(alice.token, '左工作机');
    const right = await k.worker(peer.token, '右工作机');
    const outsider = await k.worker(bob.token, 'Bob 工作机');

    const ssh = await k.call('POST', '/api/projects', left.token, { remote: 'git@github.com:Owner/Repo.git' });
    expect(ssh.status).toBe(201);
    const https = await k.call('POST', '/api/projects', right.token, { remote: 'https://GitHub.com/owner/repo' });
    expect(https.status).toBe(200);
    expect(https.body.id).toBe(ssh.body.id);
    expect(https.body.remote).toBe(ssh.body.remote);
    const foreign = await k.call('POST', '/api/projects', outsider.token, { remote: 'https://github.com/owner/repo.git' });
    expect(foreign.status).toBe(201);
    expect(foreign.body.id).not.toBe(ssh.body.id);
    expect((await k.call('GET', `/api/projects/${ssh.body.id}`, bob.token)).status).toBe(404);

    k.advance(1);
    const own = await k.call('POST', '/api/projects', alice.token, { hosted: { name: 'mine' } });
    expect(own.status).toBe(201);
    const theirs = await k.call('POST', '/api/projects', bob.token, { hosted: { name: 'theirs' } });
    expect(theirs.status).toBe(201);
    expect((await k.call('POST', '/api/projects', left.token, { remote: theirs.body.url })).status).toBe(404);
    expect((await k.call('POST', '/api/projects', left.token, { remote: `${k.baseURL}/git/${crypto.randomUUID()}.git` })).status).toBe(404);
    const found = await k.call('POST', '/api/projects', right.token, { remote: own.body.url });
    expect(found.status).toBe(200);
    expect(found.body.id).toBe(own.body.id);
    expectSuccess(await k.call('PUT', `/api/projects/${own.body.id}/appearance`, alice.token, { icon: 'terminal', color: 'green' }));
    const listed = await k.call('GET', '/api/projects', left.token);
    expect(listed.status).toBe(200);
    expect(listed.body.map((project: ProjectRecord) => project.id).sort()).toEqual([ssh.body.id, own.body.id].sort());
    expect(listed.body).toEqual([
      expect.objectContaining({ id: ssh.body.id, icon: 'folder', color: 'primary' }),
      expect.objectContaining({ id: own.body.id, icon: 'terminal', color: 'green' }),
    ]);
  } finally { await k.stop(); }
}, 1_000);

// 迁移跨托管仓库、绑定凭据、git push 到另一台 HTTP 服务与目录快照里的检出远程：推送失败不能改项目，
// 迁移后托管仓库只读，直到所有工作机上报的检出都换成新地址才删除。
test('托管项目迁移把全部分支和标签用绑定的凭据推到新远程，失败不改项目，迁移后只读，检出都换地址后删除托管仓库', async () => {
  const k = await setup();
  const work = makeTemp('kite-migrate-');
  const target = new GitHosting(join(work, 'target'), process.env.PATH);
  await target.create('r');
  const destination = Bun.serve({
    hostname: '127.0.0.1', port: 0,
    fetch(request) {
      const match = /^\/o\/r\.git(\/.*)$/.exec(new URL(request.url).pathname);
      if (!match) return new Response('不存在', { status: 404 });
      if (request.headers.get('authorization') !== basic('migrator', 'right-token')) {
        return new Response('需要凭据', { status: 401, headers: { 'www-authenticate': 'Basic realm="target"' } });
      }
      return target.serve(request, 'r', match[1]!, 'migrator', true);
    },
  });
  try {
    const alice = await k.signUp('migrate-alice');
    const box = await k.worker(alice.token, '迁移工作机');
    const created = await k.call('POST', '/api/projects', alice.token, { hosted: { name: 'draft' } });
    expect(created.status).toBe(201);
    const hosted = created.body as ProjectRecord;
    const env = gitEnv(work, join(work, 'empty.gitconfig'));
    writeFileSync(join(work, 'empty.gitconfig'), '');
    async function hostedEnv() {
      const issued = await k.call('POST', '/api/git/credential', box.token, { url: hosted.url });
      expect(issued.status).toBe(200);
      return { ...env, ...credentialEnv(hosted.url, { username: issued.body.username, password: issued.body.password }) };
    }

    const local = join(work, 'local');
    await gitDo(work, env, 'init', '-q', '-b', 'main', local);
    writeFileSync(join(local, 'a.txt'), 'main\n');
    await gitDo(local, env, 'add', '-A');
    await gitDo(local, env, 'commit', '-q', '-m', '主线');
    await gitDo(local, env, 'tag', 'v1');
    await gitDo(local, env, 'checkout', '-q', '-b', 'feature');
    writeFileSync(join(local, 'b.txt'), 'feature\n');
    await gitDo(local, env, 'add', '-A');
    await gitDo(local, env, 'commit', '-q', '-m', '分支');
    await gitDo(local, await hostedEnv(), 'push', '-q', hosted.url, 'refs/heads/*:refs/heads/*', 'refs/tags/*:refs/tags/*');
    const refs = await gitDo(local, env, 'for-each-ref', '--format=%(refname) %(objectname)', 'refs/heads', 'refs/tags');

    const project: Project = { id: hosted.id, name: hosted.name, remote: hosted.remote, createdAt: hosted.createdAt };
    const before = snapshot(box.machineId, project);
    expectSuccess(await k.call('PUT', `/api/catalog/${box.deviceId}`, box.token, { revision: 1, snapshot: before }));

    const host = destination.url.host;
    const newURL = `${destination.url.origin}/o/r.git`;
    const bound = await k.call('POST', '/api/credentials', alice.token,
      { type: 'git', name: host, meta: { username: 'migrator' }, secret: { token: 'wrong-token' } });
    expect(bound.status).toBe(201);
    expect((await k.call('POST', `/api/projects/${hosted.id}/migrate`, alice.token, { remote: newURL })).status).toBe(409);
    const unchanged = await k.call('GET', `/api/projects/${hosted.id}`, alice.token);
    expect(unchanged.body.remote).toBe(hosted.remote);
    expect(unchanged.body.url).toBe(hosted.url);

    expectSuccess(await k.call('PUT', `/api/credentials/${bound.body.id}`, alice.token, { secret: { token: 'right-token' } }));
    expectSuccess(await k.call('POST', `/api/projects/${hosted.id}/migrate`, alice.token, { remote: newURL }));
    const moved = await k.call('GET', `/api/projects/${hosted.id}`, alice.token);
    expect(moved.body.id).toBe(hosted.id);
    expect(moved.body.remote).toBe(normalizeRemote(newURL)!);
    const migrated = await gitDo(work, env, '--git-dir', join(work, 'target', 'r.git'),
      'for-each-ref', '--format=%(refname) %(objectname)', 'refs/heads', 'refs/tags');
    expect(migrated).toBe(refs);

    // 仍有检出指向旧地址：托管仓库保留，可拉取，不可推送。
    const readEnv = await hostedEnv();
    const remoteRefs = await gitDo(local, readEnv, 'ls-remote', '--heads', '--tags', hosted.url);
    expect(remoteRefs.split('\n')).toHaveLength(3);
    writeFileSync(join(local, 'c.txt'), 'late\n');
    await gitDo(local, env, 'add', '-A');
    await gitDo(local, env, 'commit', '-q', '-m', '迁移后');
    expect((await gitRun(local, readEnv, ['push', '-q', hosted.url, 'feature'])).code).not.toBe(0);

    const after = { ...before, checkouts: before.checkouts.map((checkout) => ({ ...checkout, remote: normalizeRemote(newURL)! })) };
    expectSuccess(await k.call('PUT', `/api/catalog/${box.deviceId}`, box.token, { revision: 2, snapshot: after }));
    const issued = await k.call('POST', '/api/git/credential', box.token, { url: hosted.url });
    const gone = await fetch(`${hosted.url}/info/refs?service=git-upload-pack`, {
      headers: { authorization: basic(issued.body.username, issued.body.password) },
    });
    expect(gone.status).toBe(404);
  } finally {
    await destination.stop(true);
    rmSync(work, { recursive: true, force: true });
    await k.stop();
  }
}, 1_000);

// 服务端代跑 GitHub OAuth 设备码轮询，token 加密存入账号，再由同账号工作机按 SSH 写法的地址取用；
// Git 与通用密钥经同一账号服务重开后保留密文，管理列表不能把 Git token 暴露成 agent 可引用的密钥。
test('GitHub 授权与通用密钥重启后保留密文，同账号工作机取到 token 并能列出仓库，其他账号取不到也列不出', async () => {
  let polls = 0;
  let revoked = false;
  const github = Bun.serve({
    hostname: '127.0.0.1', port: 0,
    async fetch(request) {
      const url = new URL(request.url);
      if (url.pathname === '/login/device/code' && request.method === 'POST') {
        const form = new URLSearchParams(await request.text());
        if (form.get('client_id') !== 'kite-test-client') return Response.json({ error: 'incorrect_client_credentials' });
        return Response.json({
          device_code: 'device-code-1', user_code: 'KITE-1234', verification_uri: 'https://github.com/login/device',
          expires_in: 900, interval: 5,
        });
      }
      if (url.pathname === '/login/oauth/access_token' && request.method === 'POST') {
        const form = new URLSearchParams(await request.text());
        if (form.get('device_code') !== 'device-code-1') return Response.json({ error: 'incorrect_device_code' });
        polls += 1;
        return Response.json(polls === 1 ? { error: 'authorization_pending' } : { access_token: 'gho_device_token', token_type: 'bearer', scope: 'repo' });
      }
      if (url.pathname === '/user' && request.method === 'GET') {
        const auth = request.headers.get('authorization') ?? '';
        if (!auth.endsWith('gho_device_token')) return Response.json({ message: 'Bad credentials' }, { status: 401 });
        return Response.json({ login: 'octo-kite', id: 1 });
      }
      if (url.pathname === '/user/repos' && request.method === 'GET') {
        const auth = request.headers.get('authorization') ?? '';
        if (revoked || !auth.endsWith('gho_device_token')) return Response.json({ message: 'Bad credentials' }, { status: 401 });
        return Response.json([{ full_name: 'octo-kite/site', clone_url: 'https://github.com/octo-kite/site.git', private: true,
          pushed_at: '2026-10-01T00:00:00Z', owner: { login: 'octo-kite' } }]);
      }
      return Response.json({ message: 'Not Found' }, { status: 404 });
    },
  });
  const k = await setup({ github: { webURL: github.url.origin, apiURL: github.url.origin } });
  try {
    const alice = await k.signUp('github-alice');
    const peer = await k.session(alice.token);
    const bob = await k.signUp('github-bob');
    const box = await k.worker(peer.token, 'Alice 工作机');
    const outsider = await k.worker(bob.token, 'Bob 工作机');
    expect((await k.call('GET', '/api/git/github/repos', alice.token)).status).toBe(404);

    const started = await k.call('POST', '/api/git/github/device', alice.token);
    expectSuccess(started);
    expect(started.body.userCode).toBe('KITE-1234');
    expect(started.body.verificationURI).toBe('https://github.com/login/device');
    const poll = `/api/git/github/device/${started.body.flow}`;
    k.advance(started.body.interval * 1_000);
    const waiting = await k.call('POST', poll, alice.token);
    expectSuccess(waiting);
    expect(waiting.body.status).toBe('pending');
    k.advance(started.body.interval * 1_000);
    const done = await k.call('POST', poll, alice.token);
    expectSuccess(done);
    expect(done.body.status).toBe('authorized');

    const sharedValue = '与Git并存的假秘密-213da4';
    expect((await k.call('POST', '/api/credentials', alice.token,
      { type: 'secret', name: 'shared_key', meta: { kind: 'text' }, secret: { value: sharedValue } })).status).toBe(201);
    expectEncrypted(k.root, ['gho_device_token', sharedValue]);
    await k.restart();

    const accounts = await k.call('GET', '/api/credentials?type=git', alice.token);
    expect(accounts.status).toBe(200);
    expect(accounts.body).toEqual([expect.objectContaining({ type: 'git', name: 'github.com', meta: expect.objectContaining({ username: 'octo-kite' }) })]);
    const listed = await k.call('GET', '/api/credentials', alice.token);
    expect(listed.status).toBe(200);
    expect(JSON.stringify(listed.body)).not.toContain('gho_device_token');
    expect(JSON.stringify(listed.body)).not.toContain(sharedValue);
    const available = await k.call('GET', '/api/credentials/available', box.token);
    expect(available.body).toEqual([expect.objectContaining({ name: 'shared_key', reference: '{account.shared_key}' })]);
    expect((await k.call('POST', '/api/credentials/resolve', box.token, { references: ['{account.shared_key}'] })).body)
      .toEqual([{ reference: '{account.shared_key}', kind: 'text', value: sharedValue }]);
    const credential = await k.call('POST', '/api/git/credential', box.token, { url: 'git@github.com:o/r.git' });
    expect(credential.status).toBe(200);
    expect(credential.body).toEqual({ username: 'octo-kite', password: 'gho_device_token', expiresAt: null });
    expect((await k.call('POST', '/api/git/credential', outsider.token, { url: 'git@github.com:o/r.git' })).status).toBe(404);

    const repos = await k.call('GET', '/api/git/github/repos', peer.token);
    expect(repos.status).toBe(200);
    expect(repos.body).toEqual([{ fullName: 'octo-kite/site', url: 'https://github.com/octo-kite/site.git', private: true,
      pushedAt: '2026-10-01T00:00:00Z' }]);
    expect((await k.call('GET', '/api/git/github/repos', bob.token)).status).toBe(404);
    revoked = true;
    expect((await k.call('GET', '/api/git/github/repos', alice.token)).status).toBe(502);
  } finally {
    await k.stop();
    await github.stop(true);
  }
}, 1_000);
