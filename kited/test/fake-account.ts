/**
 * 账号服务的替身：只有 kited 用到的项目登记、凭据分发、目录上报和托管远程，行为对照 src/account/service.ts。
 * 托管仓库直接用 GitHosting，地址是本机 http，归一化后带端口，和正式的托管地址一样能按地址找回项目。
 * 测试和本地演示脚本共用；linkAccount 把 kited 的数据目录接到这里，相当于 App 下发了目录上报配置。
 */
import { mkdirSync, rmSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { GitHosting } from '../src/account/git-hosting.ts';
import type { CatalogSnapshot } from '../src/account/catalog.ts';
import type { RegisteredProject } from '../src/account-client.ts';
import type { GitCredential } from '../src/git-credential.ts';
import { normalizeRemote, remoteHost, remoteName } from '../src/remote-url.ts';

export interface FakeAccount {
  url: string;
  token: string;
  deviceId: string;
  /** 已登记的项目，按 ID。 */
  projects: Map<string, RegisteredProject>;
  /** 各平台绑定的凭据，按主机（归一化形式，如 github.com）。 */
  credentials: Map<string, GitCredential>;
  /** 收到的最新目录快照。 */
  snapshot?: CatalogSnapshot;
  /** 托管仓库所在目录，裸仓库为 `<项目ID>.git`。 */
  repos: string;
  /**
   * 推送开始前（客户端取 receive-pack 引用广告时）调用，测试可以趁这时让远程多出提交，
   * 使这次推送在客户端被判为非快进而被拒。
   */
  beforePush?: (projectId: string) => void | Promise<void>;
  /** 把项目的远程改为 url，模拟迁移完成；不推送内容。 */
  migrate(id: string, url: string): RegisteredProject;
  stop(): void;
}

export function startFakeAccount(root: string): FakeAccount {
  const repos = join(root, 'repos');
  mkdirSync(repos, { recursive: true });
  const hosting = new GitHosting(repos, process.env.PATH);
  const token = crypto.randomUUID() + crypto.randomUUID();
  const projects = new Map<string, RegisteredProject>();
  const credentials = new Map<string, GitCredential>();
  let baseURL = '';
  const hostedURL = (id: string) => `${baseURL}/git/${id}.git`;
  const json = (body: unknown, status = 200) => Response.json(body, { status });

  const server = Bun.serve({
    hostname: '127.0.0.1', port: 0,
    async fetch(request) {
      const path = new URL(request.url).pathname;
      const repository = /^\/git\/([0-9a-f-]{36})\.git(\/.*)$/.exec(path);
      if (repository) {
        const project = projects.get(repository[1]!);
        if (!project?.hosted) return json({ error: '找不到托管仓库' }, 404);
        if (repository[2] === '/info/refs' && new URL(request.url).searchParams.get('service') === 'git-receive-pack') {
          await account.beforePush?.(project.id);
        }
        return hosting.serve(request, project.id, repository[2]!, 'kite', true);
      }
      if (request.headers.get('authorization') !== `Bearer ${token}`) return json({ error: '工作机授权已失效' }, 401);
      if (request.method === 'PUT' && path === `/api/catalog/${account.deviceId}`) {
        account.snapshot = ((await request.json()) as { snapshot: CatalogSnapshot }).snapshot;
        return json({ ok: true });
      }
      if (request.method === 'GET' && path === '/api/projects') return json([...projects.values()]);
      if (request.method === 'POST' && path === '/api/projects') {
        const body = await request.json() as { remote: string } | { hosted: { name: string } };
        if ('hosted' in body) {
          const id = crypto.randomUUID();
          await hosting.create(id);
          const project: RegisteredProject = { id, name: body.hosted.name, remote: normalizeRemote(hostedURL(id))!,
            url: hostedURL(id), hosted: true, createdAt: Date.now() };
          projects.set(id, project);
          return json(project, 201);
        }
        const remote = normalizeRemote(body.remote);
        if (!remote) return json({ error: '远程地址格式无法识别' }, 400);
        const existing = [...projects.values()].find((p) => p.remote === remote);
        if (existing) return json(existing);
        if (remoteHost(remote) === new URL(baseURL).host) return json({ error: '找不到这个托管仓库' }, 404);
        const project: RegisteredProject = { id: crypto.randomUUID(), name: remoteName(body.remote), remote,
          url: `https://${remote}.git`, hosted: false, createdAt: Date.now() };
        projects.set(project.id, project);
        return json(project, 201);
      }
      if (request.method === 'POST' && path === '/api/git/credential') {
        const remote = normalizeRemote(((await request.json()) as { url: string }).url);
        if (!remote) return json({ error: '远程地址格式无法识别' }, 400);
        const host = remoteHost(remote);
        if (host === new URL(baseURL).host) return json({ username: 'kite', password: crypto.randomUUID(), expiresAt: Date.now() + 3_600_000 });
        const credential = credentials.get(host);
        return credential ? json({ ...credential, expiresAt: null }) : json({ error: `尚未绑定 ${host} 的账号` }, 404);
      }
      return json({ error: '找不到接口' }, 404);
    },
  });
  baseURL = `http://127.0.0.1:${server.port}`;

  const account: FakeAccount = {
    url: baseURL, token, deviceId: crypto.randomUUID(), projects, credentials, repos,
    migrate(id, url) {
      const project = projects.get(id);
      if (!project) throw new Error(`没有项目 ${id}`);
      const migrated = { ...project, remote: normalizeRemote(url)!, url, hosted: false };
      projects.set(id, migrated);
      return migrated;
    },
    stop() {
      void server.stop(true);
      rmSync(repos, { recursive: true, force: true });
    },
  };
  return account;
}

/** 让 KITE_HOME 为 home 的 kited 加入这个账号。须在 kited 启动前写入。 */
export function linkAccount(home: string, account: FakeAccount): void {
  mkdirSync(home, { recursive: true });
  writeFileSync(join(home, 'catalog-publisher.json'),
    JSON.stringify({ url: account.url, deviceId: account.deviceId, token: account.token, revision: 0 }), { mode: 0o600 });
}
