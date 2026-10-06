import { expect, test } from 'bun:test';
import { rmSync } from 'node:fs';
import { join } from 'node:path';
import { createAccountService } from '../../src/account/service.ts';
import type { Checkout, Machine, Project, Workspace } from '../../src/model.ts';
import { makeTemp } from '../util.ts';

interface Login { token: string; user: { id: string; email: string } }
interface Device { id: string; name: string; role: 'controller' | 'worker' }
interface Enrollment { device: Device; controlURL: string; authKey: string }
interface HeadscaleUser { id: string; name: string }
interface PreAuthKey { id: string; key: string; user: string }
interface CatalogSnapshot { machine: Machine; projects: Project[]; checkouts: Checkout[]; workspaces: Workspace[] }
interface CatalogEntry { device: Device; machineId: string; updatedAt: number | null; revision: number; snapshot: CatalogSnapshot | null }
interface Publisher { deviceId: string; url: string; token: string }
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

async function setup() {
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
  const baseURL = 'http://127.0.0.1:5484';
  let service: Awaited<ReturnType<typeof createAccountService>>;
  try {
    service = await createAccountService({
      databasePath: join(root, 'account.sqlite'), baseURL,
      secret: 'kite-test-secret-2026-with-enough-entropy',
      headscale: { url: headscale.url.origin, apiKey: 'headscale-test-key', controlURL },
      now: () => now,
    });
  } catch (error) {
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
  async function enroll(token: string, name: string, role: Device['role']): Promise<Enrollment> {
    const response = await call('POST', '/api/devices/enroll', token, { name, role });
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
  return {
    call, signUp, enroll, node, complete, session, publisher, catalog, deletedNodes, expiredAuthKeys,
    advance(ms: number) { now += ms; },
    async stop() {
      try { await service.close(); }
      finally {
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

function snapshot(machineId: string, project: Project): CatalogSnapshot {
  const checkout: Checkout = {
    id: crypto.randomUUID(), machineId, projectId: project.id,
    path: `/workspace/${machineId}`, commits: 'kite', createdAt: project.createdAt,
  };
  return {
    machine: { id: machineId, name: '目录工作机', createdAt: project.createdAt }, projects: [project], checkouts: [checkout],
    workspaces: [{ id: crypto.randomUUID(), checkoutId: checkout.id, name: project.name, cwd: checkout.path,
      kind: 'root', branch: 'main', base: null, status: 'open', createdAt: project.createdAt }],
  };
}

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

// 邀请并发消费跨 SQLite 状态与 Better Auth 会话创建，必须只提交一次且不能复用来源会话。
test('同一邀请并发接受只成功一次，新设备取得本账号的独立会话', async () => {
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
    const scanned = await k.enroll(invited.token, '扫码设备', 'worker');
    expect(original.device.id).not.toBe(scanned.device.id);
    expectSuccess(await k.complete(owner.token, original, k.node(original, '100.64.1.1')));
    expectSuccess(await k.complete(invited.token, scanned, k.node(scanned, '100.64.1.2')));
    const devices = await k.call('GET', '/api/devices', invited.token);
    expect(devices.status).toBe(200);
    expect(devices.body.map((device: Device) => device.id).sort()).toEqual([original.device.id, scanned.device.id].sort());
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
    const project = { id: crypto.randomUUID(), name: '共同项目', createdAt: 1_700_000_000_000 };
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
    const project = { id: crypto.randomUUID(), name: '私有项目', createdAt: 1_700_000_000_000 };
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
