import { Database } from 'bun:sqlite';
import { betterAuth, type BetterAuthOptions } from 'better-auth';
import { getMigrations } from 'better-auth/db/migration';
import { bearer } from 'better-auth/plugins';
import { createHash, randomBytes } from 'node:crypto';
import { dirname, join } from 'node:path';
import { z } from 'zod';
import { httpsRemote, normalizeRemote, remoteHost, remoteName } from '../remote-url.ts';
import type { GitCredential } from '../git-credential.ts';
import { catalogPublication, type CatalogSnapshot } from './catalog.ts';
import { CredentialCipher, GitHubDeviceFlow, gitHubRepositories, type GitHubOptions } from './credentials.ts';
import { GitHosting } from './git-hosting.ts';

interface Options {
  databasePath: string;
  baseURL: string;
  secret: string;
  headscale: { url: string; apiKey: string; controlURL: string };
  /** 托管仓库目录默认在数据库旁边的 repos/；未配置 GitHub 时不能用设备码绑定。 */
  git?: { reposPath?: string; github?: GitHubOptions };
  now?: () => number;
}
interface Device {
  id: string; userId: string; sessionId: string; name: string; role: 'controller' | 'worker';
  headscaleUser: string; keyId: string; nodeId: string | null; port: number; createdAt: number;
}
interface Node {
  id: string; user: { id: string }; preAuthKey?: { id: string };
  ipAddresses: string[]; online: boolean;
}
interface Catalog {
  deviceId: string; machineId: string; digest: string; revision: number; snapshot: string | null; updatedAt: number | null;
}
interface ProjectRow { id: string; userId: string; remote: string; name: string; hostedRepo: number; createdAt: number }
class RequestError extends Error {
  constructor(message: string, readonly status: number) { super(message); }
}
const hash = (value: string) => createHash('sha256').update(value).digest('hex');
const enrollment = z.object({ name: z.string().trim().min(1).max(80), role: z.enum(['controller', 'worker']) });
const completion = z.object({ ip: z.ipv4(), port: z.number().int().min(1).max(65535).default(5483) });
const invitation = z.object({ token: z.string().min(32).max(128) });
const projectCreation = z.union([
  z.object({ remote: z.string().min(1).max(2048) }).strict(),
  z.object({ hosted: z.object({ name: z.string().trim().min(1).max(200) }).strict() }).strict(),
]);
const gitAccount = z.object({ username: z.string().min(1).max(200).default('oauth2'), token: z.string().min(1).max(4096) }).strict();
const JSON_LIMIT = 2 * 1024 * 1024;
const HOSTED_TOKEN_MS = 60 * 60_000;

/** 密码与会话交给 Better Auth；这里只维护账号与网络设备之间的对应关系。 */
export async function createAccountService(options: Options) {
  const db = new Database(options.databasePath, { create: true });
  db.exec('PRAGMA journal_mode = WAL; PRAGMA foreign_keys = ON;');
  const now = options.now ?? Date.now;
  const authOptions = {
    database: db, baseURL: options.baseURL, secret: options.secret,
    emailAndPassword: { enabled: true, minPasswordLength: 10 },
    plugins: [bearer()],
    session: { expiresIn: 90 * 24 * 60 * 60, updateAge: 24 * 60 * 60 },
    rateLimit: { enabled: true, storage: 'database' },
    advanced: { ipAddress: { ipAddressHeaders: ['x-real-ip'] } },
    logger: { level: 'error' },
  } satisfies BetterAuthOptions;
  await (await getMigrations(authOptions)).runMigrations();
  const auth = betterAuth(authOptions);
  db.exec(`
    CREATE TABLE IF NOT EXISTS kite_device (
      id TEXT PRIMARY KEY, userId TEXT NOT NULL, sessionId TEXT NOT NULL UNIQUE,
      name TEXT NOT NULL, role TEXT NOT NULL, headscaleUser TEXT NOT NULL,
      keyId TEXT NOT NULL, nodeId TEXT UNIQUE, port INTEGER NOT NULL DEFAULT 5483, createdAt INTEGER NOT NULL
    );
    CREATE INDEX IF NOT EXISTS kite_device_user ON kite_device(userId);
    CREATE TABLE IF NOT EXISTS kite_invitation (
      digest TEXT PRIMARY KEY, userId TEXT NOT NULL, sessionId TEXT NOT NULL, expiresAt INTEGER NOT NULL
    );
    CREATE TABLE IF NOT EXISTS kite_catalog (
      deviceId TEXT PRIMARY KEY REFERENCES kite_device(id) ON DELETE CASCADE,
      machineId TEXT NOT NULL, digest TEXT NOT NULL, revision INTEGER NOT NULL DEFAULT 0,
      snapshot TEXT, updatedAt INTEGER
    );
    CREATE INDEX IF NOT EXISTS kite_catalog_digest ON kite_catalog(digest);
    CREATE TABLE IF NOT EXISTS kite_project (
      id TEXT PRIMARY KEY, userId TEXT NOT NULL, remote TEXT NOT NULL, name TEXT NOT NULL,
      hostedRepo INTEGER NOT NULL DEFAULT 0, createdAt INTEGER NOT NULL, UNIQUE(userId, remote)
    );
    CREATE TABLE IF NOT EXISTS kite_git_credential (
      userId TEXT NOT NULL, host TEXT NOT NULL, account TEXT NOT NULL, secret TEXT NOT NULL, createdAt INTEGER NOT NULL,
      PRIMARY KEY (userId, host)
    );
    CREATE TABLE IF NOT EXISTS kite_git_token (digest TEXT PRIMARY KEY, userId TEXT NOT NULL, expiresAt INTEGER NOT NULL);
  `);
  const hosting = new GitHosting(options.git?.reposPath ?? join(dirname(options.databasePath), 'repos'));
  const cipher = new CredentialCipher(options.secret);
  const github = options.git?.github && new GitHubDeviceFlow(options.git.github);
  const flows = new Map<string, { userId: string; deviceCode: string; expiresAt: number }>();
  /** 迁移中的托管仓库只读，推送到新远程期间不能再有人写入。 */
  const migrating = new Set<string>();
  const hostedURL = (id: string) => `${options.baseURL}/git/${id}.git`;
  const hostedRemote = (id: string) => normalizeRemote(hostedURL(id))!;
  const hostedHost = remoteHost(hostedRemote(crypto.randomUUID()));
  const context = await auth.$context;
  const users = new Map<string, Promise<string>>();
  async function headscale(path: string, method = 'GET', body?: unknown): Promise<any> {
    const response = await fetch(new URL(`/api/v1/${path}`, options.headscale.url), {
      method, headers: { authorization: `Bearer ${options.headscale.apiKey}`, 'content-type': 'application/json' },
      body: body === undefined ? undefined : JSON.stringify(body), signal: AbortSignal.timeout(15_000),
    });
    if (response.status === 404 && method === 'DELETE') return {};
    if (!response.ok) throw new RequestError('组网服务暂时不可用，请稍后重试', 502);
    return response.json();
  }
  function networkUser(userId: string): Promise<string> {
    let pending = users.get(userId);
    if (!pending) {
      pending = (async () => {
        const name = `kite-${hash(userId).slice(0, 40)}`;
        const found = await headscale(`user?name=${encodeURIComponent(name)}`);
        if (found.users?.[0]) return String(found.users[0].id);
        return String((await headscale('user', 'POST', { name })).user.id);
      })();
      users.set(userId, pending);
      void pending.catch(() => users.delete(userId));
    }
    return pending;
  }
  async function nodes(): Promise<Node[]> { return (await headscale('node')).nodes ?? []; }
  async function revoke(device: Device) {
    // 节点可能已入网但客户端尚未 complete。先使密钥失效，再按密钥找到所有已注册节点。
    await headscale('preauthkey/expire', 'POST', { id: device.keyId });
    const all = await nodes();
    for (const node of all) {
      if (String(node.user.id) === device.headscaleUser && (String(node.id) === device.nodeId || String(node.preAuthKey?.id) === device.keyId)) {
        await headscale(`node/${node.id}`, 'DELETE');
      }
    }
    const session = db.query<{ token: string }, [string]>('SELECT token FROM session WHERE id = ?').get(device.sessionId);
    if (session) await context.internalAdapter.deleteSession(session.token);
    db.query('DELETE FROM kite_invitation WHERE sessionId = ?').run(device.sessionId);
    db.query('DELETE FROM kite_device WHERE id = ?').run(device.id);
  }
  function view(device: Device, all: Node[]) {
    const node = all.find((n) => String(n.id) === device.nodeId && String(n.user.id) === device.headscaleUser);
    const ip = node?.ipAddresses.find((ip) => !ip.includes(':'));
    return {
      id: device.id, name: device.name, role: device.role, online: node?.online ?? false,
      joined: !!node, createdAt: device.createdAt,
      ...(ip && device.role === 'worker' ? { address: `http://${ip}:${device.port}` } : {}),
    };
  }
  const result = (body: unknown, status = 200) => Response.json(body, { status, headers: { 'cache-control': 'no-store' } });
  const bearerToken = (request: Request) => request.headers.get('authorization')?.replace(/^Bearer /, '') ?? '';

  /** 工作机凭据：目录上报时签发，绑定已入网的工作机设备，也用来登记项目和取 Git 凭据。 */
  async function worker(token: string): Promise<{ device: Device; catalog: Catalog } | null> {
    if (!token) return null;
    const catalog = db.query<Catalog, [string]>('SELECT * FROM kite_catalog WHERE digest = ?').get(hash(token));
    if (!catalog) return null;
    const device = db.query<Device, [string]>('SELECT * FROM kite_device WHERE id = ?').get(catalog.deviceId);
    const source = device && db.query<{ token: string }, [string]>('SELECT token FROM session WHERE id = ?').get(device.sessionId);
    const session = source && await context.internalAdapter.findSession(source.token);
    if (!device?.nodeId || device.role !== 'worker' || !session || session.session.expiresAt.getTime() <= now()) {
      throw new RequestError('工作机授权已失效', 401);
    }
    return { device, catalog };
  }
  /** 项目登记表允许工作机和登录的用户访问。 */
  async function owner(request: Request): Promise<{ userId: string; worker: boolean }> {
    const found = await worker(bearerToken(request));
    if (found) return { userId: found.device.userId, worker: true };
    const login = await auth.api.getSession({ headers: request.headers });
    if (!login) throw new RequestError('请登录 Kite', 401);
    return { userId: login.user.id, worker: false };
  }
  function projectView(row: ProjectRow) {
    const hosted = row.remote === hostedRemote(row.id);
    return { id: row.id, name: row.name, remote: row.remote, url: hosted ? hostedURL(row.id) : `https://${row.remote}.git`,
      hosted, createdAt: row.createdAt };
  }
  function ownedProject(id: string, userId: string): ProjectRow {
    const row = db.query<ProjectRow, [string, string]>('SELECT * FROM kite_project WHERE id = ? AND userId = ?').get(id, userId);
    if (!row) throw new RequestError('找不到项目', 404);
    return row;
  }
  function storedCredential(userId: string, host: string): GitCredential | null {
    const row = db.query<{ secret: string }, [string, string]>('SELECT secret FROM kite_git_credential WHERE userId = ? AND host = ?').get(userId, host);
    return row && JSON.parse(cipher.open(userId, host, row.secret));
  }
  function saveCredential(userId: string, host: string, account: string, credential: GitCredential) {
    db.query(`INSERT INTO kite_git_credential VALUES (?, ?, ?, ?, ?)
      ON CONFLICT(userId, host) DO UPDATE SET account=excluded.account, secret=excluded.secret, createdAt=excluded.createdAt`)
      .run(userId, host, account, cipher.seal(userId, host, JSON.stringify(credential)), now());
  }
  /** 已迁移的托管仓库，等账号下所有检出都改用新地址后删除；已移除设备的目录不再计入。 */
  function retireHostedRepos() {
    for (const row of db.query<ProjectRow, []>('SELECT * FROM kite_project WHERE hostedRepo = 1').all()) {
      if (row.remote === hostedRemote(row.id) || migrating.has(row.id)) continue;
      const snapshots = db.query<{ snapshot: string | null }, [string]>(`SELECT c.snapshot FROM kite_catalog c
        JOIN kite_device d ON d.id = c.deviceId WHERE d.userId = ?`).all(row.userId);
      const pending = snapshots.some(({ snapshot }) => snapshot && (JSON.parse(snapshot) as CatalogSnapshot).checkouts
        .some((c) => c.projectId === row.id && c.remote !== row.remote));
      if (pending) continue;
      hosting.remove(row.id);
      db.query('UPDATE kite_project SET hostedRepo = 0 WHERE id = ?').run(row.id);
    }
  }
  async function serveRepository(request: Request, id: string, rest: string): Promise<Response> {
    const basic = /^Basic (.+)$/.exec(request.headers.get('authorization') ?? '');
    const decoded = basic ? Buffer.from(basic[1]!, 'base64').toString('utf8') : '';
    const password = decoded.slice(decoded.indexOf(':') + 1);
    const token = password && db.query<{ userId: string; expiresAt: number }, [string]>('SELECT * FROM kite_git_token WHERE digest = ?').get(hash(password));
    if (!token || token.expiresAt <= now()) {
      return new Response('请提供 Kite 托管仓库凭据', { status: 401, headers: { 'www-authenticate': 'Basic realm="Kite"', 'cache-control': 'no-store' } });
    }
    const row = db.query<ProjectRow, [string, string]>('SELECT * FROM kite_project WHERE id = ? AND userId = ? AND hostedRepo = 1').get(id, token.userId);
    if (!row) return new Response('找不到托管仓库', { status: 404 });
    return hosting.serve(request, id, rest, token.userId, row.remote === hostedRemote(id) && !migrating.has(id));
  }
  async function migrate(row: ProjectRow, raw: string) {
    if (row.remote !== hostedRemote(row.id)) throw new RequestError('这个项目已经有正式远程', 409);
    const target = normalizeRemote(raw);
    if (!target) throw new RequestError('远程地址格式无法识别', 400);
    if (remoteHost(target) === hostedHost) throw new RequestError('请填写 Kite 托管以外的远程地址', 400);
    if (db.query('SELECT id FROM kite_project WHERE userId = ? AND remote = ?').get(row.userId, target)) {
      throw new RequestError('这个远程已属于另一个项目', 409);
    }
    if (migrating.has(row.id)) throw new RequestError('项目正在迁移', 409);
    migrating.add(row.id);
    try {
      try { await hosting.pushAll(row.id, httpsRemote(raw)!, storedCredential(row.userId, remoteHost(target))); }
      catch (error) { throw new RequestError(`推送到新远程失败：${(error as Error).message}`, 409); }
      try { db.query('UPDATE kite_project SET remote = ? WHERE id = ?').run(target, row.id); }
      catch { throw new RequestError('这个远程已属于另一个项目', 409); }
    } finally {
      migrating.delete(row.id);
    }
    retireHostedRepos();
    return projectView({ ...row, remote: target });
  }

  async function fetchRequest(request: Request): Promise<Response> {
    const path = new URL(request.url).pathname;
    const repository = /^\/git\/([0-9a-f-]{36})\.git(\/.*)$/.exec(path);
    if (repository) return serveRepository(request, repository[1]!, repository[2]!);
    // 推送托管仓库需要较大的请求上限；其余接口仍限制为 2 MiB。
    if (Number(request.headers.get('content-length') ?? 0) > JSON_LIMIT) throw new RequestError('请求内容过大', 413);
    if (path.startsWith('/api/auth/')) return auth.handler(request);
    if (request.method === 'GET' && path === '/health') return result({ ok: true });
    const publication = /^\/api\/catalog\/([^/]+)$/.exec(path);
    if (publication && request.method === 'PUT') {
      const token = bearerToken(request);
      const digest = hash(token);
      const found = await worker(token);
      if (!found || found.catalog.deviceId !== publication[1]) throw new RequestError('目录上报凭据已失效', 401);
      const { catalog } = found;
      const body = catalogPublication.parse(await request.json());
      if (body.snapshot.machine.id !== catalog.machineId) throw new RequestError('工作机身份不匹配', 400);
      const snapshot = JSON.stringify(body.snapshot);
      db.transaction(() => {
        const current = db.query<Catalog, [string, string]>('SELECT * FROM kite_catalog WHERE deviceId = ? AND digest = ?').get(catalog.deviceId, digest);
        if (!current) throw new RequestError('目录上报凭据已失效', 401);
        if (body.revision < current.revision || body.revision === current.revision && snapshot !== current.snapshot) {
          throw new RequestError('目录版本已过期', 409);
        }
        if (body.revision > current.revision) db.query('UPDATE kite_catalog SET revision = ?, snapshot = ?, updatedAt = ? WHERE deviceId = ?')
          .run(body.revision, snapshot, now(), catalog.deviceId);
      })();
      retireHostedRepos();
      return result({ ok: true });
    }
    if (path === '/api/git/credential' && request.method === 'POST') {
      const found = await worker(bearerToken(request));
      if (!found) throw new RequestError('请使用工作机凭据', 401);
      const userId = found.device.userId;
      const { url } = z.object({ url: z.string().min(1).max(2048) }).strict().parse(await request.json());
      const normalized = normalizeRemote(url);
      if (!normalized) throw new RequestError('远程地址格式无法识别', 400);
      const host = remoteHost(normalized);
      if (host === hostedHost) {
        const password = randomBytes(32).toString('base64url');
        const expiresAt = now() + HOSTED_TOKEN_MS;
        db.query('INSERT INTO kite_git_token VALUES (?, ?, ?)').run(hash(password), userId, expiresAt);
        return result({ username: 'kite', password, expiresAt });
      }
      const credential = storedCredential(userId, host);
      if (!credential) throw new RequestError(`尚未绑定 ${host} 的账号`, 404);
      return result({ ...credential, expiresAt: null });
    }
    if (path === '/api/projects' || path.startsWith('/api/projects/')) {
      const { userId, worker: fromWorker } = await owner(request);
      if (path === '/api/projects' && request.method === 'GET') {
        return result(db.query<ProjectRow, [string]>('SELECT * FROM kite_project WHERE userId = ? ORDER BY createdAt, rowid').all(userId).map(projectView));
      }
      if (path === '/api/projects' && request.method === 'POST') {
        const body = projectCreation.parse(await request.json());
        if ('hosted' in body) {
          const id = crypto.randomUUID();
          await hosting.create(id);
          const row: ProjectRow = { id, userId, remote: hostedRemote(id), name: body.hosted.name, hostedRepo: 1, createdAt: now() };
          db.query('INSERT INTO kite_project VALUES (?, ?, ?, ?, ?, ?)').run(row.id, row.userId, row.remote, row.name, row.hostedRepo, row.createdAt);
          return result(projectView(row), 201);
        }
        const remote = normalizeRemote(body.remote);
        if (!remote) throw new RequestError('远程地址格式无法识别', 400);
        const existing = db.query<ProjectRow, [string, string]>('SELECT * FROM kite_project WHERE userId = ? AND remote = ?').get(userId, remote);
        if (existing) return result(projectView(existing));
        // 托管仓库只能由 Kite 创建，不能凭地址登记。
        if (remoteHost(remote) === hostedHost) throw new RequestError('找不到这个托管仓库', 404);
        db.query('INSERT INTO kite_project VALUES (?, ?, ?, ?, 0, ?) ON CONFLICT(userId, remote) DO NOTHING')
          .run(crypto.randomUUID(), userId, remote, remoteName(body.remote), now());
        const row = db.query<ProjectRow, [string, string]>('SELECT * FROM kite_project WHERE userId = ? AND remote = ?').get(userId, remote)!;
        return result(projectView(row), 201);
      }
      const match = /^\/api\/projects\/([^/]+)(\/migrate)?$/.exec(path);
      if (match && !match[2] && request.method === 'GET') return result(projectView(ownedProject(match[1]!, userId)));
      if (match?.[2] && request.method === 'POST') {
        if (fromWorker) throw new RequestError('迁移远程须由用户在 App 中操作', 403);
        const { remote } = z.object({ remote: z.string().min(1).max(2048) }).strict().parse(await request.json());
        return result(await migrate(ownedProject(match[1]!, userId), remote));
      }
      throw new RequestError('找不到接口', 404);
    }
    if (request.method === 'POST' && path === '/api/invitations/accept') {
      const body = invitation.parse(await request.json());
      // DELETE RETURNING 是一次原子消费，两个扫码请求不能取得同一份授权。
      const invite = db.query<{ userId: string; sessionId: string; expiresAt: number }, [string]>(
        'DELETE FROM kite_invitation WHERE digest = ? RETURNING *',
      ).get(hash(body.token));
      if (!invite || invite.expiresAt <= now()) throw new RequestError('二维码已过期或已使用，请重新生成', 400);
      const source = db.query<{ token: string }, [string]>('SELECT token FROM session WHERE id = ?').get(invite.sessionId);
      const existing = source && await context.internalAdapter.findSession(source.token);
      if (!existing || existing.session.expiresAt.getTime() <= now()) throw new RequestError('签发二维码的设备已退出登录', 401);
      const session = await context.internalAdapter.createSession(invite.userId);
      if (!session) throw new RequestError('无法创建登录，请重试', 503);
      if (!db.query('SELECT id FROM session WHERE id = ?').get(invite.sessionId)) {
        await context.internalAdapter.deleteSession(session.token);
        throw new RequestError('签发二维码的设备已退出登录', 401);
      }
      return result({ token: session.token, user: { id: existing.user.id, email: existing.user.email, name: existing.user.name } });
    }
    const login = await auth.api.getSession({ headers: request.headers });
    if (!login) throw new RequestError('请登录 Kite', 401);
    if (path === '/api/account' && request.method === 'GET') return result({ user: login.user });
    if (path === '/api/git/accounts' && request.method === 'GET') {
      return result(db.query<{ host: string; account: string; createdAt: number }, [string]>(
        'SELECT host, account, createdAt FROM kite_git_credential WHERE userId = ? ORDER BY host').all(login.user.id));
    }
    if (path === '/api/git/accounts/github.com/repos' && request.method === 'GET') {
      const credential = storedCredential(login.user.id, 'github.com');
      if (!credential) throw new RequestError('尚未绑定 GitHub 账号', 404);
      try { return result(await gitHubRepositories(credential.password, options.git?.github?.apiURL)); }
      catch (error) { throw new RequestError((error as Error).message, 502); }
    }
    const deviceFlow = /^\/api\/git\/accounts\/github\.com\/device(?:\/([^/]+))?$/.exec(path);
    if (deviceFlow && request.method === 'POST') {
      if (!github) throw new RequestError('服务尚未配置 GitHub 授权', 503);
      if (!deviceFlow[1]) {
        const code = await github.start().catch(() => { throw new RequestError('GitHub 暂时无法访问，请稍后重试', 502); });
        const flow = randomBytes(16).toString('base64url');
        const expiresAt = now() + code.expiresIn * 1000;
        flows.set(flow, { userId: login.user.id, deviceCode: code.deviceCode, expiresAt });
        return result({ flow, userCode: code.userCode, verificationURI: code.verificationURI, expiresAt, interval: code.interval });
      }
      const pending = flows.get(deviceFlow[1]);
      if (!pending || pending.userId !== login.user.id) throw new RequestError('找不到这次授权', 404);
      if (pending.expiresAt <= now()) { flows.delete(deviceFlow[1]); return result({ status: 'expired' }); }
      const polled = await github.poll(pending.deviceCode).catch(() => { throw new RequestError('GitHub 暂时无法访问，请稍后重试', 502); });
      if (polled.status !== 'pending' && polled.status !== 'slow_down') flows.delete(deviceFlow[1]);
      if (polled.status !== 'authorized') return result({ status: polled.status });
      saveCredential(login.user.id, 'github.com', polled.login, { username: polled.login, password: polled.token });
      return result({ status: 'authorized', account: polled.login });
    }
    const account = /^\/api\/git\/accounts\/([^/]+)$/.exec(path);
    if (account) {
      const host = account[1]!.toLowerCase();
      if (!/^[a-z0-9.-]+(:\d+)?$/.test(host) || host === hostedHost) throw new RequestError('主机名无效', 400);
      if (request.method === 'PUT') {
        const body = gitAccount.parse(await request.json());
        saveCredential(login.user.id, host, body.username, { username: body.username, password: body.token });
        return result({ host, account: body.username });
      }
      if (request.method === 'DELETE') {
        db.query('DELETE FROM kite_git_credential WHERE userId = ? AND host = ?').run(login.user.id, host);
        return result({ ok: true });
      }
    }
    if (path === '/api/catalog' && request.method === 'GET') {
      const devices = db.query<Device, [string, string]>('SELECT * FROM kite_device WHERE userId = ? AND role = ? ORDER BY createdAt, rowid').all(login.user.id, 'worker');
      const all = devices.length ? await nodes() : [];
      return result(devices.map((device) => {
        const catalog = db.query<Catalog, [string]>('SELECT * FROM kite_catalog WHERE deviceId = ?').get(device.id);
        return catalog && { device: view(device, all), machineId: catalog.machineId, updatedAt: catalog.updatedAt,
          revision: catalog.revision, snapshot: catalog.snapshot ? JSON.parse(catalog.snapshot) : null };
      }).filter(Boolean));
    }
    const publisher = /^\/api\/devices\/([^/]+)\/catalog-publisher$/.exec(path);
    if (publisher && request.method === 'POST') {
      const device = db.query<Device, [string, string]>('SELECT * FROM kite_device WHERE id = ? AND userId = ?').get(publisher[1]!, login.user.id);
      if (!device) throw new RequestError('找不到设备', 404);
      if (device.sessionId !== login.session.id || device.role !== 'worker' || !device.nodeId) throw new RequestError('请在已入网的工作机上设置目录上报', 403);
      const { machineId } = z.object({ machineId: z.uuid() }).strict().parse(await request.json());
      const existing = db.query<Catalog, [string]>('SELECT * FROM kite_catalog WHERE deviceId = ?').get(device.id);
      if (existing && existing.machineId !== machineId) throw new RequestError('本设备已绑定另一台工作机，请重新加入设备', 409);
      const owner = db.query<{ deviceId: string }, [string, string]>(`SELECT c.deviceId FROM kite_catalog c JOIN kite_device d ON d.id = c.deviceId
        WHERE d.userId = ? AND c.machineId = ?`).get(login.user.id, machineId);
      if (owner && owner.deviceId !== device.id) throw new RequestError('这台工作机已由另一设备登记', 409);
      const token = randomBytes(32).toString('base64url');
      db.query(`INSERT INTO kite_catalog (deviceId, machineId, digest) VALUES (?, ?, ?)
        ON CONFLICT(deviceId) DO UPDATE SET digest=excluded.digest, revision=0`).run(device.id, machineId, hash(token));
      return result({ deviceId: device.id, url: options.baseURL, token });
    }
    if (path === '/api/invitations' && request.method === 'POST') {
      const token = randomBytes(32).toString('base64url');
      const expiresAt = now() + 5 * 60_000;
      db.query('DELETE FROM kite_invitation WHERE expiresAt <= ? OR sessionId = ?').run(now(), login.session.id);
      db.query('INSERT INTO kite_invitation VALUES (?, ?, ?, ?)').run(hash(token), login.user.id, login.session.id, expiresAt);
      return result({ token, expiresAt });
    }
    if (path === '/api/devices/enroll' && request.method === 'POST') {
      const body = enrollment.parse(await request.json());
      const old = db.query<Device, [string]>('SELECT * FROM kite_device WHERE sessionId = ?').get(login.session.id);
      if (old?.nodeId) throw new RequestError('本次登录已经加入设备，请使用已有设备', 409);
      const user = await networkUser(login.user.id);
      const key = (await headscale('preauthkey', 'POST', {
        user, reusable: false, ephemeral: false, expiration: new Date(now() + 10 * 60_000).toISOString(),
      })).preAuthKey;
      if (old) await headscale('preauthkey/expire', 'POST', { id: old.keyId });
      const id = old?.id ?? crypto.randomUUID();
      db.query(`INSERT INTO kite_device VALUES (?, ?, ?, ?, ?, ?, ?, NULL, 5483, ?)
        ON CONFLICT(sessionId) DO UPDATE SET name=excluded.name, role=excluded.role, keyId=excluded.keyId`).run(
        id, login.user.id, login.session.id, body.name, body.role, user, String(key.id), now(),
      );
      return result({ device: { id, ...body }, controlURL: options.headscale.controlURL, authKey: key.key });
    }
    if (path === '/api/devices' && request.method === 'GET') {
      const devices = db.query<Device, [string]>('SELECT * FROM kite_device WHERE userId = ? ORDER BY createdAt, rowid').all(login.user.id);
      const all = devices.length ? await nodes() : [];
      return result(devices.map((device) => view(device, all)));
    }
    const match = /^\/api\/devices\/([^/]+)(\/complete)?$/.exec(path);
    if (match) {
      const device = db.query<Device, [string, string]>('SELECT * FROM kite_device WHERE id = ? AND userId = ?').get(match[1]!, login.user.id);
      if (!device) throw new RequestError('找不到设备', 404);
      if (match[2] && request.method === 'POST') {
        if (device.sessionId !== login.session.id) throw new RequestError('请在加入的设备上完成设置', 403);
        const body = completion.parse(await request.json());
        const all = await nodes();
        const node = all.find((n) => n.ipAddresses.includes(body.ip));
        if (!node || String(node.user.id) !== device.headscaleUser || String(node.preAuthKey?.id) !== device.keyId) {
          throw new RequestError('设备尚未完成入网，请稍后重试', 409);
        }
        db.query('UPDATE kite_device SET nodeId = ?, port = ? WHERE id = ?').run(String(node.id), body.port, device.id);
        return result(view({ ...device, nodeId: String(node.id), port: body.port }, all));
      }
      if (!match[2] && request.method === 'DELETE') {
        // 上游失败时保留记录，允许重试，不把尚有网络权限的设备从列表隐藏。
        await revoke(device);
        return result({ ok: true });
      }
    }
    throw new RequestError('找不到接口', 404);
  }
  let cleanup: Promise<void> | undefined;
  const timer = setInterval(() => {
    if (cleanup) return;
    cleanup = (async () => {
      const devices = db.query<Device & { sessionToken: string | null }, []>(`SELECT d.*, s.token AS sessionToken
        FROM kite_device d LEFT JOIN session s ON s.id = d.sessionId`).all();
      for (const device of devices) {
        const session = device.sessionToken && await context.internalAdapter.findSession(device.sessionToken);
        if (!session || session.session.expiresAt.getTime() <= now()) await revoke(device);
      }
      db.query('DELETE FROM kite_invitation WHERE expiresAt <= ?').run(now());
      db.query('DELETE FROM kite_git_token WHERE expiresAt <= ?').run(now());
      for (const [flow, pending] of flows) if (pending.expiresAt <= now()) flows.delete(flow);
      retireHostedRepos();
    })().catch(() => console.error('账号设备过期清理失败，将在下一轮重试')).finally(() => { cleanup = undefined; });
  }, 60_000);
  timer.unref();
  return {
    async fetch(request: Request): Promise<Response> {
      try { return await fetchRequest(request); }
      catch (error) {
        if (error instanceof RequestError) return result({ error: error.message }, error.status);
        if (error instanceof z.ZodError || error instanceof SyntaxError) return result({ error: '输入内容不完整或格式有误' }, 400);
        console.error('账号服务请求失败', error instanceof Error ? error.message : '未知错误');
        return result({ error: '服务暂时不可用，请稍后重试' }, 500);
      }
    },
    async close(): Promise<void> { clearInterval(timer); await cleanup; db.close(); },
  };
}
