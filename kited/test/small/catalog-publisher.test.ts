import { expect, test } from 'bun:test';
import { mkdirSync, rmSync, statSync } from 'node:fs';
import { join } from 'node:path';
import { AccountClient } from '../../src/account-client.ts';
import { CatalogPublisher } from '../../src/catalog-publisher.ts';
import { Bus, type Envelope } from '../../src/events.ts';
import { Kite } from '../../src/kite.ts';
import type { Checkout, Machine, Project, Workspace } from '../../src/model.ts';
import { Store } from '../../src/store.ts';
import { startFakeAccount } from '../fake-account.ts';
import { aborted, deferred, ManualModel, Seen } from '../harness-loop.ts';
import { ENV, makeTemp, newRepo } from '../util.ts';

type Upload = { revision: number; snapshot: { machine: Machine; projects: Project[]; checkouts: Checkout[]; workspaces: Workspace[] } };
type Received = { number: number; method: string; path: string; authorization: string | null; body: Upload; release(): void; cancelled: Promise<void> };

// 真实 SQLite、Bun HTTP 取消、事件订阅与另一个进程读取持久配置配合：在途变更不能丢，重启不能重用已发送版本。
test('目录发布在请求期间保留后续变更且只发摘要，停止取消请求并在新进程恢复时递增版本', async () => {
  const root = makeTemp('catalog-publisher-');
  const home = join(root, 'kite');
  mkdirSync(home);
  const database = join(root, 'kite.sqlite');
  const file = join(root, 'publisher.json');
  const requests = new Seen<Received>();
  const endpoint = Bun.serve({
    hostname: '127.0.0.1', port: 0,
    async fetch(request) {
      const body = await request.json() as Upload;
      const release = deferred();
      const cancelled = aborted(request.signal);
      requests.add({ number: requests.values.length + 1, method: request.method, path: new URL(request.url).pathname,
        authorization: request.headers.get('authorization'), body, release: () => release.resolve(), cancelled });
      await Promise.race([release.promise, cancelled]);
      return Response.json({});
    },
  });
  const store = new Store(database);
  const bus = new Bus();
  const events = new Seen<Envelope>();
  const unsubscribe = bus.subscribe(undefined, (event) => events.add(event));
  const model = new ManualModel();
  // 登记检出要向账号的项目登记表要项目 ID；目录上报另发给上面的端点，便于挂起请求。
  const account = startFakeAccount(join(root, 'account'));
  const kite = new Kite(store, home, bus, { lightTasks: false, model: () => model },
    new AccountClient(() => ({ url: account.url, token: account.token })));
  let publisher: CatalogPublisher | undefined;
  let child: Bun.Subprocess<'ignore', 'ignore', 'pipe'> | undefined;
  let closed = false;
  try {
    const first = await kite.registerCheckout({ path: newRepo(root, 'first', { 'base.txt': '目录测试\n' }) });
    const privateBody = '私密会话正文不得上传到托管目录';
    const privateConfig = '私密会话配置不得上传到托管目录';
    const workspace = await kite.createWorkspace(first.checkout.id, '公开工作区', privateBody);
    const threadId = workspace.threads[0]!.instanceId;
    (await model.call(1)).response.complete();
    await events.wait((event) => event.type === 'idle' && event.threadId === threadId);
    const instance = store.instance(threadId)!;
    store.setInstanceConfig(threadId, { ...instance.config, catalogProbe: privateConfig });

    publisher = new CatalogPublisher(file, kite);
    const deviceId = crypto.randomUUID();
    const token = 'dedicated-catalog-publisher-token';
    const config = { url: endpoint.url.origin, deviceId, token };
    await publisher.configure(config);
    const initial = await requests.wait((request) => request.number === 1);
    expect([initial.method, initial.path, initial.authorization]).toEqual(['PUT', `/api/catalog/${deviceId}`, `Bearer ${token}`]);
    expect(statSync(file).mode & 0o777).toBe(0o600);

    const second = await kite.registerCheckout({ path: newRepo(root, 'second', { 'base.txt': '另一个检出\n' }) });
    await kite.archiveWorkspace(workspace.workspace.id, true);
    const expected = { machine: kite.machine(), projects: kite.projects(), checkouts: kite.checkouts(),
      workspaces: kite.workspaces().map((model) => model.workspace) };
    initial.release();
    const changed = await requests.wait((request) => request.number === 2);
    expect(changed.body.revision).toBeGreaterThan(initial.body.revision);
    expect(changed.body.snapshot).toEqual(expected);
    expect(changed.body.snapshot.checkouts.some((checkout) => checkout.id === second.checkout.id)).toBe(true);
    expect(changed.body.snapshot.workspaces.find((entry) => entry.id === workspace.workspace.id)?.status).toBe('archived');
    for (const upload of [initial.body, changed.body]) {
      expect(Object.keys(upload.snapshot).sort()).toEqual(['checkouts', 'machine', 'projects', 'workspaces']);
      expect(JSON.stringify(upload)).not.toContain(privateBody);
      expect(JSON.stringify(upload)).not.toContain(privateConfig);
    }

    // 配置响应丢失后的同内容重试只补报，不能重置已发送的版本。
    await publisher.configure(config);
    changed.release();
    const retried = await requests.wait((request) => request.number === 3);
    expect(retried.body.revision).toBeGreaterThan(changed.body.revision);
    expect(retried.body.snapshot).toEqual(expected);
    await publisher.stop();
    publisher = undefined;
    await retried.cancelled;
    unsubscribe();
    await kite.shutdown();
    store.close();
    closed = true;
    expect(requests.values).toHaveLength(3);

    // 独立进程不能继承模块内计数器；恢复中的请求继续挂起，以验证正常停止确实取消 HTTP 请求。
    const script = `
      import { CatalogPublisher } from ${JSON.stringify(join(import.meta.dir, '../../src/catalog-publisher.ts'))};
      import { Kite } from ${JSON.stringify(join(import.meta.dir, '../../src/kite.ts'))};
      import { Store } from ${JSON.stringify(join(import.meta.dir, '../../src/store.ts'))};
      import { Bus } from ${JSON.stringify(join(import.meta.dir, '../../src/events.ts'))};
      const stopping = new Promise(resolve => process.once('SIGTERM', resolve));
      const store = new Store(${JSON.stringify(database)});
      const kite = new Kite(store, ${JSON.stringify(home)}, new Bus(), { lightTasks: false });
      const publisher = new CatalogPublisher(${JSON.stringify(file)}, kite);
      await stopping;
      await publisher.stop();
      await kite.shutdown();
      store.close();
    `;
    child = Bun.spawn([process.execPath, '--eval', script], { env: ENV(), stdin: 'ignore', stdout: 'ignore', stderr: 'pipe' });
    const stderr = new Response(child.stderr).text();
    const restored = await Promise.race([
      requests.wait((request) => request.number === 4),
      child.exited.then(async (code) => { throw new Error(`发布器恢复进程提前退出 ${code}：${await stderr}`); }),
    ]);
    expect(restored.body.revision).toBeGreaterThan(retried.body.revision);
    expect(restored.body.snapshot).toEqual(expected);
    expect(restored.authorization).toBe(`Bearer ${token}`);
    child.kill('SIGTERM');
    const code = await child.exited;
    if (code !== 0) throw new Error(`发布器恢复进程失败 ${code}：${await stderr}`);
    await restored.cancelled;
    expect(requests.values).toHaveLength(4);
  } finally {
    for (const request of requests.values) request.release();
    await publisher?.stop();
    if (child?.exitCode === null) child.kill('SIGTERM');
    await child?.exited;
    unsubscribe();
    if (!closed) { await kite.shutdown(); store.close(); }
    await endpoint.stop(true);
    account.stop();
    rmSync(root, { recursive: true, force: true });
  }
}, 1_000);
