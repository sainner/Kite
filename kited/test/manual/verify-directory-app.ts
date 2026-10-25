/**
 * 手动验收真实 DEBUG AppModel 与两个真实 kited；需要已经编译的 macOS App，不调用 xcodebuild。
 * 运行：bun kited/test/manual/verify-directory-app.ts --app /path/Kite.app
 */
import { existsSync, mkdtempSync, rmSync, statSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import type { Candidate } from '../../src/account-data/directory.ts';
import { startDaemon, type Daemon } from '../../src/daemon.ts';
import type { RegisteredProject } from '../../src/account-data/registry.ts';
import type { Machine, WorkspaceModel } from '../../src/model.ts';
import { newRepo, writeFiles } from '../util.ts';

async function call(url: string, method: string, path: string, body?: unknown, machineId?: string) {
  const headers: Record<string, string> = {};
  if (path !== '/machine') {
    if (!machineId) throw new Error(`请求 ${path} 缺少工作机 ID`);
    headers['X-Kite-Machine'] = machineId;
  }
  if (body !== undefined) headers['content-type'] = 'application/json';
  const response = await fetch(url + path, {
    method, headers, body: body === undefined ? undefined : JSON.stringify(body),
  });
  return { status: response.status, body: await response.json() as unknown };
}

async function machine(url: string): Promise<Machine> {
  const response = await call(url, 'GET', '/machine');
  if (response.status !== 200) throw new Error('读取工作机身份失败');
  return response.body as Machine;
}

/** 建工作区前 kited 按默认角色的模型检查厂商已登录：写一份一小时后过期的 ChatGPT 订阅登录（同 test/harness.ts 的 chatgptLogin）。 */
function chatgptLogin(home: string): void {
  const encoded = (value: unknown) => Buffer.from(JSON.stringify(value)).toString('base64url');
  const accessToken = `${encoded({ alg: 'RS256', typ: 'JWT' })}.${encoded({ exp: Math.floor(Date.now() / 1000) + 3600 })}.${encoded('仅验收')}`;
  writeFiles(home, { 'auth/chatgpt/auth.json': JSON.stringify({ auth_mode: 'chatgpt', tokens: { access_token: accessToken, account_id: 'verification-account' } }) });
}

/** 为项目建工作区（本机没有检出时 kited 先 clone），等它准备完（open），返回打开后的完整聚合。 */
async function openWorkspace(daemon: Daemon, machineId: string, projectId: string): Promise<WorkspaceModel> {
  const created = await call(daemon.url, 'POST', '/workspaces', { project: projectId }, machineId);
  if (created.status !== 200) throw new Error(`建工作区失败：${created.status} ${JSON.stringify(created.body)}`);
  const id = (created.body as WorkspaceModel).workspace.id;
  await new Promise<void>((resolve, reject) => {
    const settle = (status: string | undefined) => {
      if (status === 'open') { done(); resolve(); }
      else if (status === 'failed') { done(); reject(new Error(`工作区 ${id} 准备失败`)); }
    };
    const timer = setTimeout(() => { done(); reject(new Error(`等工作区 ${id} 准备完超时`)); }, 10_000);
    const unsubscribe = daemon.kite.bus.subscribe(undefined, (event) => {
      if (event.type === 'workspace.changed' && event.workspaceId === id) settle(event.status);
    });
    const done = () => { clearTimeout(timer); unsubscribe(); };
    settle(daemon.kite.store.workspace(id)?.status);
  });
  const opened = await call(daemon.url, 'GET', `/workspaces/${id}`, undefined, machineId);
  if (opened.status !== 200) throw new Error(`读取工作区 ${id} 失败：${opened.status}`);
  return opened.body as WorkspaceModel;
}

function latch() {
  let resolve!: () => void;
  const promise = new Promise<void>((done) => { resolve = done; });
  return { promise, resolve };
}

async function main() {
  if (process.platform !== 'darwin') throw new Error('真实 App 验收需要 macOS');
  const argument = process.argv.indexOf('--app');
  const supplied = argument >= 0 ? process.argv[argument + 1] : undefined;
  if (!supplied) throw new Error('需要 --app <已编译的 DEBUG Kite.app 或可执行文件>');
  const input = resolve(supplied);
  const binary = existsSync(input) && statSync(input).isDirectory() ? join(input, 'Contents/MacOS/Kite') : input;
  if (!existsSync(binary)) throw new Error('找不到指定的 App 可执行文件');
  const root = mkdtempSync(join(tmpdir(), 'kite-directory-app-'));
  const daemons: Daemon[] = [];
  const proxies: Bun.Server<undefined>[] = [];
  const operations: Array<{ machine: 'a' | 'b'; method: string; path: string }> = [];
  const held = latch();
  const release = latch();
  let holdB = false;
  let completed = false;
  let control: Bun.Server<undefined> | undefined;
  // 两台工作机互为组网对端：项目登记与目录摘要随账号级数据同步，B 为没有远程的项目建工作区时从 A 的检出 clone，得到同一项目。
  try {
    const peers: Candidate[][] = [[], []];
    for (const [index, name] of ['a', 'b'].entries()) {
      const home = join(root, `kite-${name}`);
      chatgptLogin(home);
      // catalogDelayMs: 0 让检出变化立即写进目录摘要，B 不必等 1 秒的合批才知道从哪台 clone。
      daemons.push(startDaemon({ home, port: 0, lightTasks: false, catalogDelayMs: 0,
        model: () => ({ async *stream() { yield { type: 'completed', responseId: 'directory-verification' }; } }),
        directory: { candidates: () => peers[index]! } }));
    }
    const [a, b] = daemons as [Daemon, Daemon];
    peers[0]!.push({ address: b.url, online: true });
    peers[1]!.push({ address: a.url, online: true });
    await Promise.all([a.kite.directory.refresh(), b.kite.directory.refresh()]);
    const [machineA, machineB] = await Promise.all([machine(a.url), machine(b.url)]);
    const added = await call(a.url, 'POST', '/project-registry', { path: newRepo(root, 'repo-a', { 'base.txt': 'A\n' }, null) }, machineA.id);
    if (added.status !== 200) throw new Error(`在 A 添加项目失败：${added.status} ${JSON.stringify(added.body)}`);
    const projectId = (added.body as RegisteredProject).id;
    const shared = await openWorkspace(a, machineA.id, projectId);
    // B 要同步到项目登记，并从 A 的目录摘要里看到这份检出，才知道从哪台 clone。
    const ready = () => !!b.kite.registry.get(projectId) && b.kite.directory.entries()
      .some((entry) => entry.id === machineA.id && entry.snapshot?.checkouts.some((checkout) => checkout.projectId === projectId));
    await new Promise<void>((resolve, reject) => {
      if (ready()) return resolve();
      const timer = setTimeout(() => { unsubscribe(); reject(new Error('B 没有同步到项目登记和 A 的检出')); }, 10_000);
      const unsubscribe = b.kite.accountData.subscribe(() => {
        if (!ready()) return;
        clearTimeout(timer);
        unsubscribe();
        resolve();
      });
    });
    const other = await openWorkspace(b, machineB.id, projectId);
    const opened = await call(a.url, 'POST', `/workspaces/${shared.workspace.id}/instances`, {
      id: crypto.randomUUID(), definitionId: 'kite.files',
    }, machineA.id);
    if (opened.status !== 200) throw new Error('创建真实浏览实例失败');
    const fullA = await call(a.url, 'GET', '/workspaces', undefined, machineA.id);
    const liveWorkspaceA = (fullA.body as WorkspaceModel[]).find((entry) => entry.workspace.id === shared.workspace.id);
    if (!liveWorkspaceA) throw new Error('缺少 A 的真实工作区快照');

    function proxy(name: 'a' | 'b', daemon: Daemon) {
      const server = Bun.serve({ hostname: '127.0.0.1', port: 0, idleTimeout: 0,
        async fetch(request) {
          const url = new URL(request.url);
          operations.push({ machine: name, method: request.method, path: url.pathname });
          const headers = new Headers(request.headers);
          headers.delete('host');
          headers.delete('connection');
          try {
            const response = await fetch(daemon.url + url.pathname + url.search, {
              method: request.method, headers, signal: request.signal,
              body: request.method === 'GET' || request.method === 'HEAD' ? undefined : await request.arrayBuffer(),
            });
            if (name === 'b' && holdB && request.method === 'GET' && url.pathname === '/workspaces') {
              const body = await response.arrayBuffer();
              held.resolve();
              await release.promise;
              return new Response(body, { status: response.status, headers: response.headers });
            }
            return new Response(response.body, { status: response.status, headers: response.headers });
          } catch { return Response.json({ error: '验证连接已中止' }, { status: 503 }); }
        },
      });
      proxies.push(server);
      return server;
    }
    const proxyA = proxy('a', a);
    const proxyB = proxy('b', b);
    control = Bun.serve({ hostname: '127.0.0.1', port: 0, idleTimeout: 0,
      async fetch(request) {
        const path = new URL(request.url).pathname;
        if (path === '/assert-operation-a' && request.method === 'POST') {
          const writes = operations.filter((entry) => entry.method === 'POST' && /\/instances$/.test(entry.path));
          if (!writes.some((entry) => entry.machine === 'a' && entry.path === `/workspaces/${shared.workspace.id}/instances`)
            || writes.some((entry) => entry.machine === 'b')) {
            return Response.json({ error: '选中 B 后，A 的真实实例操作未仅发往 A' }, { status: 409 });
          }
        } else if (path === '/disconnect-a' && request.method === 'POST') {
          await proxyA.stop(true);
        } else if (path === '/hold-b' && request.method === 'POST') {
          holdB = true;
        } else if (path === '/held-b' && request.method === 'GET') {
          await held.promise;
        } else if (path === '/release-b' && request.method === 'POST') {
          release.resolve();
        } else if (path === '/finished' && request.method === 'POST') {
          completed = true;
        } else {
          return Response.json({ error: '未知验证控制请求' }, { status: 404 });
        }
        return Response.json({ ok: true });
      },
    });
    const deviceA = { id: crypto.randomUUID(), name: '验证工作机 A', role: 'worker', online: true, address: proxyA.url.origin };
    const deviceB = { id: crypto.randomUUID(), name: '验证工作机 B', role: 'worker', online: true, address: proxyB.url.origin };
    function catalog(device: typeof deviceA, machine: Machine, model: WorkspaceModel) {
      return { device, machineId: machine.id, updatedAt: Date.now(), snapshot: {
        machine, projects: [model.project], checkouts: [model.checkout], workspaces: [model.workspace],
      } };
    }
    const userID = crypto.randomUUID();
    const login = { user: { id: userID, email: 'directory-verification@example.com', name: '目录验收' } };
    // 小型夹具直接交给子进程，避免签名 App 沙箱与宿主临时目录的文件权限交接。
    const fixture = JSON.stringify({ login: Buffer.from(JSON.stringify(login)).toString('base64'), userID,
      directory: { devices: [deviceA, deviceB], catalogs: [catalog(deviceA, machineA, shared), catalog(deviceB, machineB, other)] },
      controlURL: control.url.origin, projectID: shared.project.id, workspaceA: shared.workspace.id, workspaceB: other.workspace.id,
      liveWorkspaceA,
    });
    // 显式复制进程环境；只给该子进程传入口变量，避免影响其他手动验证。
    const proc = Bun.spawn([binary], { cwd: root, env: { ...(process.env as Record<string, string>), KITE_VERIFY_DIRECTORY: fixture },
      stdin: 'ignore', stdout: 'pipe', stderr: 'pipe' });
    const deadline = setTimeout(() => { if (proc.exitCode === null) proc.kill('SIGKILL'); }, 35_000);
    try {
      const [code, stdout, stderr] = await Promise.all([proc.exited, new Response(proc.stdout).text(), new Response(proc.stderr).text()]);
      if (code !== 0 || !completed) throw new Error(`目录 App 验收未完成（退出码 ${code}）：\n${stdout}\n${stderr}`);
      console.log(stdout.trim());
    } finally {
      clearTimeout(deadline);
      if (proc.exitCode === null) proc.kill('SIGKILL');
      await proc.exited;
    }
  } finally {
    release.resolve();
    held.resolve();
    await Promise.all(proxies.map((server) => server.stop(true)));
    await control?.stop(true);
    await Promise.all(daemons.map((daemon) => daemon.stop()));
    rmSync(root, { recursive: true, force: true });
  }
}

await main();
