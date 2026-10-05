/**
 * Store、Kite、HTTP 之间的工作区聚合和状态投影；这些状态要在异步准备过程
 * 中跨模块同步，单看任何一个模块的字段映射都无法确认。
 */
import { afterEach, expect, test } from 'bun:test';
import { randomUUID } from 'node:crypto';
import { existsSync, realpathSync, rmSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { startDaemon, type Daemon } from '../../src/daemon.ts';
import type { Envelope } from '../../src/events.ts';
import { startCli } from '../cli.ts';
import { after, call, machine, mark, registerCheckout, spawnKited, startKited, type Kited, type KitedProcess } from '../harness.ts';
import { ManualModel, Seen } from '../harness-loop.ts';
import { commitAll, git, makeTemp, newDir, newRepo } from '../util.ts';

let kited: Kited | undefined;
let otherKited: Kited | undefined;
let restarted: Daemon | undefined;
const roots: string[] = [];
afterEach(async () => {
  await restarted?.stop();
  restarted = undefined;
  await kited?.stop();
  kited = undefined;
  await otherKited?.stop();
  otherKited = undefined;
  for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true });
});

type WorkspaceWireEvent = {
  type: string;
  workspaceId?: string;
  model?: { workspace: { id: string }; instances?: unknown[]; windows?: unknown[] };
};

/** 工作区 SSE 首帧是完整聚合；调用方显式关闭流，避免测试留下打开的 HTTP 连接。 */
async function connectWorkspace(url: string, machineId: string, workspaceId: string) {
  const controller = new AbortController();
  const response = await fetch(`${url}/events?workspace=${workspaceId}`, {
    headers: { 'X-Kite-Machine': machineId }, signal: controller.signal,
  });
  expect(response.status).toBe(200);
  const events = new Seen<WorkspaceWireEvent>();
  const reading = (async () => {
    const reader = response.body!.pipeThrough(new TextDecoderStream()).getReader();
    let buffer = '';
    try {
      while (true) {
        const chunk = await reader.read();
        if (chunk.done) return;
        buffer += chunk.value;
        let end: number;
        while ((end = buffer.indexOf('\n\n')) >= 0) {
          const frame = buffer.slice(0, end);
          buffer = buffer.slice(end + 2);
          const data = frame.split('\n').find((line) => line.startsWith('data: '));
          if (data) events.add(JSON.parse(data.slice(6)) as WorkspaceWireEvent);
        }
      }
    } catch (error) {
      if (!controller.signal.aborted) throw error;
    }
  })();
  return {
    events,
    async close() { controller.abort(); await reading; },
  };
}

/*
 * 项目登记、异步工作树准备、模型启动、HTTP 聚合与 SQLite 线程关系要一起成立：
 * root 无线程，首线程在工作树 cwd 运行；首线程空闲后第二线程共享 cwd，归档首线程保留工作树。
 */
test('登记检出创建同工作区线程，暂停后 CLI resume 续接，归档首线程保留第二线程', async () => {
  const model = new ManualModel();
  kited = startKited(() => model);
  const kk = kited;
  const repo = newRepo(kk.root, 'project', { 'base.txt': '原始\n' });
  const root = await registerCheckout(kk, repo);
  const rootForAssertion = structuredClone(root);
  const localMachine = await machine(kk.url);
  expect(localMachine.id).toMatch(/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i);
  expect(rootForAssertion.project.id).toMatch(/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i);
  expect(rootForAssertion.machine).toEqual(localMachine);
  expect(rootForAssertion.checkout.machineId).toBe(localMachine.id);
  expect(rootForAssertion.workspace).toMatchObject({ kind: 'root', checkoutId: root.checkout.id, cwd: repo });
  expect(rootForAssertion.checkout.projectId).toBe(root.project.id);
  expect(rootForAssertion.instances).toEqual([]);
  expect(rootForAssertion.threads).toEqual([]);
  const created = await kk.call('POST', '/workspaces', {
    checkout: root.checkout.id, name: '首个工作区', prompt: '首线程', runtime: 'harness',
  });
  expect(created.status).toBe(200);
  const workspace = structuredClone(created.body);
  const firstThread = workspace.threads[0];
  const firstThreadId = firstThread.instanceId;
  expect(structuredClone(workspace)).toMatchObject({
    machine: localMachine,
    project: { id: root.project.id },
    checkout: { id: root.checkout.id, projectId: root.project.id },
    workspace: { kind: 'worktree', checkoutId: root.checkout.id, name: '首个工作区' },
  });
  expect(structuredClone(firstThread)).toEqual({ instanceId: firstThreadId, runtime: 'harness', nativeId: expect.any(String) });
  const firstInstance = workspace.instances.find((instance: any) => instance.id === firstThreadId);
  expect(firstInstance).toMatchObject({
    id: firstThreadId,
    workspaceId: workspace.workspace.id,
    definitionId: 'kite.agent.coding',
    title: '首线程',
    config: expect.any(Object),
    state: expect.any(Object),
    status: 'open',
    presentation: 'window',
  });
  const context = await kk.call('GET', `/threads/${firstThreadId}`);
  expect(context.status).toBe(200);
  expect(context.body).toMatchObject({
    machine: localMachine,
    id: firstThreadId,
    instanceId: firstThreadId,
    title: '首线程',
    status: 'open',
    workspaceId: workspace.workspace.id,
    project: { id: root.project.id },
    checkout: { id: root.checkout.id },
    workspace: { id: workspace.workspace.id, cwd: workspace.workspace.cwd },
  });
  const first = await model.call(1);
  expect(first.request.cwd).toBe(workspace.workspace.cwd);

  const busy = await kk.call('POST', `/workspaces/${workspace.workspace.id}/threads`, {
    prompt: '不应并行启动', runtime: 'harness',
  });
  expect(busy.status).toBe(409);

  first.response.complete();
  await kk.waitEvent((event) => event.type === 'idle' && event.threadId === firstThreadId);
  const secondCreated = await kk.call('POST', `/workspaces/${workspace.workspace.id}/threads`, {
    prompt: '第二线程', runtime: 'harness',
  });
  expect(secondCreated.status).toBe(200);
  const secondThread = structuredClone(secondCreated.body);
  const secondThreadId = secondThread.id;
  const secondInstanceId = secondThread.instanceId;
  expect(structuredClone(secondThread)).toMatchObject({
    id: secondInstanceId,
    instanceId: secondInstanceId,
    workspaceId: workspace.workspace.id,
    workspace: { id: workspace.workspace.id, cwd: workspace.workspace.cwd },
    status: 'open', runtime: 'harness',
  });
  expect(secondThreadId).not.toBe(firstThreadId);
  const second = await model.call(2);
  expect(second.request.cwd).toBe(workspace.workspace.cwd);
  second.response.complete();
  await kk.waitEvent((event) => event.type === 'idle' && event.threadId === secondThreadId);

  const beforePause = mark(kk);
  expect((await kk.call('POST', `/threads/${secondThreadId}/messages`, { text: '准备暂停' })).status).toBe(200);
  const interrupted = await model.call(3);
  expect((await kk.call('POST', `/threads/${secondThreadId}/messages`, { text: '恢复后继续' })).status).toBe(200);
  interrupted.response.finish();
  await kk.waitEvent((event) => event.type === 'harness' && event.threadId === secondThreadId
    && event.event.type === 'state' && event.event.state.phase === 'idle' && !event.event.state.busy
    && event.event.state.waitingForResume && event.event.state.lastOutcome?.kind === 'failed'
    && after(kk, beforePause)(event));
  expect((await kk.call('GET', `/threads/${secondThreadId}/history`)).body.state).toMatchObject({
    phase: 'idle', busy: false, waitingForResume: true, lastOutcome: { kind: 'failed' },
  });
  const resuming = startCli(kk.url, 'resume', secondThreadId);
  try {
    const next = await Promise.race([
      model.call(4).then((value) => ({ kind: 'request' as const, value })),
      resuming.finished().then((value) => ({ kind: 'exit' as const, value })),
    ]);
    if (next.kind === 'exit') throw new Error(`CLI 在模型请求前退出：${JSON.stringify(next.value)}`);
    const resumed = next.value;
    await resumed.response.emit({ type: 'item', item: {
      id: 'cli-resume-result', raw: { type: 'message', content: [{ type: 'output_text', text: 'CLI 恢复结果' }] },
    } });
    await resuming.waitText('CLI 恢复结果');
    resumed.response.complete();
    expect(await resuming.finished()).toMatchObject({ code: 0, stderr: '' });
  } finally {
    await resuming.stop();
  }

  const listed = await kk.call('GET', '/workspaces');
  const aggregate = listed.body.find((view: any) => view.workspace.id === workspace.workspace.id);
  expect(aggregate.threads).toEqual(expect.arrayContaining([
    { instanceId: firstThreadId, runtime: 'harness', nativeId: expect.any(String) },
    { instanceId: secondInstanceId, runtime: 'harness', nativeId: expect.any(String) },
  ]));
  expect(aggregate.instances.map((instance: any) => instance.id).sort()).toEqual(
    aggregate.threads.map((thread: any) => thread.instanceId).sort(),
  );
  writeFileSync(join(workspace.workspace.cwd, 'shared.txt'), '两个线程的工作区\n');
  const beforeAdopt = mark(kk);
  const adopted = await kk.call('POST', `/workspaces/${workspace.workspace.id}/adopt`);
  expect(adopted.status).toBe(200);
  expect(adopted.body.status).toBe('adopted');
  expect(kk.events.slice(beforeAdopt).filter((event) => event.type === 'workspace.adopt'
    && event.workspaceId === workspace.workspace.id)).toHaveLength(1);
  const archived = await kk.call('POST', `/threads/${firstThreadId}/archive`);
  expect(archived.status).toBe(200);
  await kk.waitEvent((event) => event.type === 'thread.changed' && event.threadId === firstThreadId && event.status === 'archived');
  expect(existsSync(workspace.workspace.cwd)).toBe(true);
  const firstView = await kk.call('GET', `/threads/${firstThreadId}`);
  const secondView = await kk.call('GET', `/threads/${secondThreadId}`);
  expect(firstView.body.status).toBe('archived');
  expect(secondView.body).toMatchObject({ id: secondThreadId, workspace: { id: workspace.workspace.id }, status: 'open' });
  const firstHistory = await kk.call('GET', `/threads/${firstThreadId}/history`);
  const secondHistory = await kk.call('GET', `/threads/${secondThreadId}/history`);
  expect(firstHistory.body.state.status).toBe('archived');
  expect(secondHistory.body.state.status).toBe('open');
  const archivedAggregate = (await kk.call('GET', '/workspaces')).body
    .find((view: any) => view.workspace.id === workspace.workspace.id);
  expect(archivedAggregate.instances.find((instance: any) => instance.id === firstThreadId)).toMatchObject({ status: 'archived' });
  expect(archivedAggregate.instances.map((instance: any) => instance.id).sort()).toEqual(
    archivedAggregate.threads.map((thread: any) => thread.instanceId).sort(),
  );
});

/*
 * 依赖 SQLite 外键重建和 git worktree 清理的配合：重启后仍须按 project→checkout→workspace→thread
 * 找到同一聚合；归档工作区才是删除其工作树的操作。
 */
test('重启后保留项目到线程的 SQLite 关系，归档工作区删除工作树', async () => {
  const root = makeTemp('model-');
  roots.push(root);
  const home = join(root, 'kite');
  const repo = newRepo(root, 'project', { 'base.txt': '原始\n' });
  const secondRepo = newRepo(root, 'second-project-dir', { 'base.txt': '第二检出\n' });
  const model = new ManualModel();
  restarted = startDaemon({ home, port: 0, lightTasks: false, model: () => model });

  const project = await call(restarted.url, 'POST', '/checkouts', { path: repo });
  expect(project.status).toBe(200);
  const secondCheckout = await call(restarted.url, 'POST', '/checkouts', {
    path: secondRepo, project: project.body.project,
  });
  expect(secondCheckout.status).toBe(200);
  expect(secondCheckout.body.checkout.id).not.toBe(project.body.checkout.id);
  expect(secondCheckout.body.workspace.id).not.toBe(project.body.workspace.id);
  const firstMachine = await machine(restarted.url);
  const created = await call(restarted.url, 'POST', '/workspaces', {
    checkout: project.body.checkout.id, prompt: '可恢复线程', runtime: 'harness',
  });
  expect(created.status).toBe(200);
  const workspace = created.body;
  const thread = workspace.threads[0];
  const first = await model.call(1);
  first.response.complete();
  await restarted.stop();
  restarted = undefined;

  restarted = startDaemon({ home, port: 0, lightTasks: false, model: () => new ManualModel() });
  expect(await machine(restarted.url)).toEqual(firstMachine);
  const listed = await call(restarted.url, 'GET', '/workspaces');
  expect(listed.status).toBe(200);
  const restored = listed.body.find((view: any) => view.workspace.id === workspace.workspace.id);
  expect(restored).toMatchObject({
    machine: firstMachine,
    project: { id: project.body.project.id },
    checkout: { id: project.body.checkout.id, projectId: project.body.project.id, machineId: firstMachine.id },
    workspace: { id: workspace.workspace.id, checkoutId: project.body.checkout.id, cwd: workspace.workspace.cwd },
    threads: [{ instanceId: thread.instanceId, runtime: 'harness', nativeId: expect.any(String) }],
    instances: [expect.objectContaining({
      id: thread.instanceId,
      workspaceId: workspace.workspace.id,
      definitionId: 'kite.agent.coding',
      status: 'open',
      presentation: 'window',
    })],
  });
  const secondRoot = listed.body.find((view: any) => view.workspace.id === secondCheckout.body.workspace.id);
  expect(secondRoot).toMatchObject({
    project: { id: project.body.project.id },
    checkout: { id: secondCheckout.body.checkout.id },
    workspace: { kind: 'root', cwd: secondRepo },
  });
  const checkouts = await call(restarted.url, 'GET', `/checkouts?project=${project.body.project.id}`);
  expect(checkouts.status).toBe(200);
  expect(checkouts.body.map((checkout: any) => checkout.id).sort()).toEqual([
    project.body.checkout.id, secondCheckout.body.checkout.id,
  ].sort());
  const projects = await call(restarted.url, 'GET', '/projects');
  expect(projects.body).toEqual([project.body.project]);
  expect(existsSync(workspace.workspace.cwd)).toBe(true);

  const archived = await call(restarted.url, 'POST', `/workspaces/${workspace.workspace.id}/archive`, { force: true });
  expect(archived.status).toBe(200);
  expect(existsSync(workspace.workspace.cwd)).toBe(false);
  const archivedModel = (await call(restarted.url, 'GET', '/workspaces')).body
    .find((view: any) => view.workspace.id === workspace.workspace.id);
  expect(archivedModel.instances.map((instance: any) => instance.id).sort()).toEqual(
    archivedModel.threads.map((entry: any) => entry.instanceId).sort(),
  );
  expect(archivedModel.instances).toEqual([expect.objectContaining({ id: thread.instanceId, status: 'archived' })]);
});

/*
 * 两份 SQLite 数据库和 HTTP 目标校验共同决定身份：同名目录不能把两台机器的项目合并，
 * 错误目标的写请求必须在登记前拒绝。并发请求还要经过同一登记队列和 SQLite/Git 操作，
 * 其中一次失败不能影响排在后面的重复登记。
 */
test('不同 home 可沿用同一项目身份，并发登记遇到失败后仍幂等且不能重绑检出', async () => {
  kited = startKited();
  otherKited = startKited();
  const left = kited;
  const right = otherKited;
  const leftRepo = newRepo(left.root, 'project', { 'base.txt': '左\n' });
  const rightRepo = newRepo(right.root, 'project', { 'base.txt': '右\n' });
  const rightSecond = newRepo(right.root, 'second', { 'base.txt': '右二\n' });
  const leftMachine = await machine(left.url);
  const rightMachine = await machine(right.url);
  expect(leftMachine.id).not.toBe(rightMachine.id);

  const badRequest = (headers: Record<string, string>) => fetch(`${right.url}/checkouts`, {
    method: 'POST', headers: { 'content-type': 'application/json', ...headers },
    body: JSON.stringify({ path: rightRepo }),
  });
  expect((await badRequest({})).status).toBe(400);
  expect((await badRequest({ 'X-Kite-Machine': leftMachine.id })).status).toBe(409);
  expect((await right.call('GET', '/projects')).body).toEqual([]);

  const leftProject = await registerCheckout(left, leftRepo);
  const rightProject = await registerCheckout(right, rightRepo);
  expect(leftProject.project.name).toBe(rightProject.project.name);
  expect(leftProject.project.id).not.toBe(rightProject.project.id);
  expect(leftProject.checkout.machineId).toBe(leftMachine.id);
  expect(rightProject.checkout.machineId).toBe(rightMachine.id);

  const [firstRegistration, failedRegistration, repeatedRegistration] = await Promise.all([
    right.call('POST', '/checkouts', { path: rightSecond, project: leftProject.project }),
    right.call('POST', '/checkouts', { path: join(right.root, 'missing-checkout'), project: leftProject.project }),
    right.call('POST', '/checkouts', { path: rightSecond, project: leftProject.project }),
  ]);
  expect(firstRegistration.status).toBe(200);
  expect(failedRegistration.status).toBeGreaterThanOrEqual(400);
  expect(failedRegistration.status).toBeLessThan(500);
  expect(repeatedRegistration.status).toBe(200);
  const imported = firstRegistration.body;
  expect(imported.project).toEqual(leftProject.project);
  expect(imported.checkout.machineId).toBe(rightMachine.id);
  expect(imported.checkout.id).not.toBe(leftProject.checkout.id);
  expect(repeatedRegistration.body.checkout.id).toBe(imported.checkout.id);
  expect(repeatedRegistration.body.workspace.id).toBe(imported.workspace.id);

  const again = await registerCheckout(right, rightSecond, leftProject.project);
  expect(again.checkout.id).toBe(imported.checkout.id);
  expect(again.workspace.id).toBe(imported.workspace.id);
  const rebound = await right.call('POST', '/checkouts', { path: rightSecond, project: rightProject.project });
  expect(rebound.status).toBe(409);
  const filtered = await right.call('GET', `/checkouts?project=${leftProject.project.id}`);
  expect(filtered.body.map((checkout: any) => checkout.id)).toEqual([imported.checkout.id]);
  expect((await right.call('GET', '/checkouts')).body).toHaveLength(2);
});

/*
 * 两个同步目录都是普通文件夹时，Kite 的 git init 与 SQLite 一对多登记必须配合：
 * 各自的 gitdir 和 HEAD 保持独立；项目身份冲突要在碰新目录之前拒绝。
 */
test('同一项目的两个同步目录各有独立 Git 历史，身份冲突不初始化第三个目录', async () => {
  // Bun 在启动时缓存 homedir()；子进程必须从启动起就继承 setup.ts 的隔离 HOME。
  const root = makeTemp('dropbox-checkouts-');
  const home = join(root, 'kite');
  let dropbox: string | undefined;
  let child: KitedProcess | undefined;
  try {
    dropbox = newDir(process.env.HOME!, `Dropbox/kite-model-${randomUUID()}`);
    const first = newDir(dropbox, 'project-a', { 'base.txt': 'A\n' });
    const second = newDir(dropbox, 'project-b', { 'base.txt': 'B\n' });
    const rejected = newDir(dropbox, 'project-c', { 'base.txt': 'C\n' });
    child = await spawnKited(home);
    const url = child.url;

    const firstRegistration = await call(url, 'POST', '/checkouts', { path: first });
    if (firstRegistration.status !== 200) throw new Error(`登记同步目录失败：${firstRegistration.status} ${JSON.stringify(firstRegistration.body)}`);
    const firstRoot = firstRegistration.body;
    const secondRegistration = await call(url, 'POST', '/checkouts', { path: second, project: firstRoot.project });
    expect(secondRegistration.status).toBe(200);
    const secondRoot = secondRegistration.body;
    expect(firstRoot.project.id).toBe(secondRoot.project.id);
    const firstGitDir = git(first, 'rev-parse', '--absolute-git-dir');
    const secondGitDir = git(second, 'rev-parse', '--absolute-git-dir');
    expect(firstGitDir).toBe(realpathSync(join(home, 'repos', `${firstRoot.checkout.id}.git`)));
    expect(secondGitDir).toBe(realpathSync(join(home, 'repos', `${secondRoot.checkout.id}.git`)));
    expect(firstGitDir).not.toBe(secondGitDir);
    writeFileSync(join(first, 'local.txt'), '只在 A\n');
    const firstHead = commitAll(first, 'A 的提交');
    writeFileSync(join(second, 'local.txt'), '只在 B\n');
    const secondHead = commitAll(second, 'B 的提交');
    expect(firstHead).not.toBe(secondHead);
    expect(git(first, 'show', 'HEAD:local.txt')).toBe('只在 A');
    expect(git(second, 'show', 'HEAD:local.txt')).toBe('只在 B');

    const conflictingProject = { ...firstRoot.project, name: `${firstRoot.project.name}-冲突` };
    const conflict = await call(url, 'POST', '/checkouts', { path: rejected, project: conflictingProject });
    expect(conflict.status).toBe(409);
    const changedTime = await call(url, 'POST', '/checkouts', {
      path: rejected, project: { ...firstRoot.project, createdAt: firstRoot.project.createdAt + 1 },
    });
    expect(changedTime.status).toBe(409);
    expect(existsSync(join(rejected, '.git'))).toBe(false);
    expect(git(first, 'rev-parse', 'HEAD')).toBe(firstHead);
    expect(git(second, 'rev-parse', 'HEAD')).toBe(secondHead);
    expect((await call(url, 'GET', '/projects')).body).toEqual([firstRoot.project]);
    expect((await call(url, 'GET', '/checkouts')).body).toHaveLength(2);
  } finally {
    try { await child?.kill('SIGTERM'); }
    finally {
      if (dropbox) rmSync(dropbox, { recursive: true, force: true });
      rmSync(root, { recursive: true, force: true });
    }
  }
});

/*
 * 依赖 HTTP 命令收据、SQLite 事务、工作区 SSE 首帧和服务重启的配合：同一命令重试
 * 不能重复建实例或窗口；随窗口实例回收后，关闭记录和请求收据在重启后仍不能复活旧目标。
 */
test('插件窗口命令去重，重连保留打开目标且回收后的关窗收据跨重启不复活实例', async () => {
  const root = makeTemp('window-model-');
  roots.push(root);
  const home = join(root, 'kite');
  const repo = newRepo(root, 'project', { 'base.txt': '原始\n' });
  restarted = startDaemon({ home, port: 0, lightTasks: false });
  const daemon = restarted;
  const internal = new Seen<Envelope>();
  const unsubscribe = daemon.kite.bus.subscribe(undefined, (event) => internal.add(event));
  let firstClient: Awaited<ReturnType<typeof connectWorkspace>> | undefined;
  let reconnected: Awaited<ReturnType<typeof connectWorkspace>> | undefined;
  try {
    const machineId = (await machine(daemon.url)).id;
    const rootModel = await call(daemon.url, 'POST', '/checkouts', { path: repo }, machineId);
    expect(rootModel.status).toBe(200);
    const created = await call(daemon.url, 'POST', '/workspaces', { checkout: rootModel.body.checkout.id }, machineId);
    expect(created.status).toBe(200);
    const workspace = created.body;
    await internal.wait((event) => event.type === 'workspace.changed'
      && event.workspaceId === workspace.workspace.id && event.status === 'open');

    firstClient = await connectWorkspace(daemon.url, machineId, workspace.workspace.id);
    await firstClient.events.wait((event) => event.type === 'workspace.model' && event.workspaceId === workspace.workspace.id);
    const requestId = randomUUID();
    const main = await call(daemon.url, 'POST', `/workspaces/${workspace.workspace.id}/windows`, {
      id: requestId, content: { kind: 'create', definitionId: 'kite.files' },
    }, machineId);
    expect(main.status).toBe(200);
    // Bun 的 objectContaining 可能会改写嵌套对象；先复制原始 HTTP JSON，再用于后续重试和目标断言。
    const mainWindow = structuredClone(main.body);
    const target = mainWindow.target as { instanceId?: string; viewId?: string } | undefined;
    if (typeof target?.instanceId !== 'string' || typeof target.viewId !== 'string') {
      throw new Error(`新插件窗口没有返回完整目标：${JSON.stringify(mainWindow)}`);
    }
    expect(structuredClone(mainWindow)).toMatchObject({
      workspaceId: workspace.workspace.id,
      target: { instanceId: target.instanceId, viewId: 'files' },
      state: 'open',
    });
    await firstClient.events.wait((event) => event.type === 'workspace.changed' && event.workspaceId === workspace.workspace.id);
    const mainModel = await call(daemon.url, 'GET', '/workspaces', undefined, machineId);
    const mainAggregate = mainModel.body.find((entry: any) => entry.workspace.id === workspace.workspace.id);
    expect(mainAggregate.instances).toEqual([expect.objectContaining({
      id: target.instanceId,
      workspaceId: workspace.workspace.id,
      definitionId: 'kite.files',
      config: expect.any(Object),
      state: expect.any(Object),
      status: 'open',
      presentation: 'window',
    })]);
    expect(mainAggregate.threads).toEqual([]);

    const retried = await call(daemon.url, 'POST', `/workspaces/${workspace.workspace.id}/windows`, {
      id: requestId, content: { kind: 'create', definitionId: 'kite.files' },
    }, machineId);
    expect(retried.status).toBe(200);
    expect(retried.body).toEqual(mainWindow);
    const changedContent = await call(daemon.url, 'POST', `/workspaces/${workspace.workspace.id}/windows`, {
      id: requestId, content: { kind: 'create', definitionId: 'kite.terminal' },
    }, machineId);
    expect(changedContent.status).toBe(409);

    const existingRequestId = randomUUID();
    const existing = await call(daemon.url, 'POST', `/workspaces/${workspace.workspace.id}/windows`, {
      id: existingRequestId, content: { kind: 'open', instanceId: target.instanceId, viewId: target.viewId },
    }, machineId);
    if (existing.status !== 200) throw new Error(`重新打开插件目标失败：${existing.status} ${JSON.stringify({ target, response: existing.body })}`);
    expect(existing.status).toBe(200);
    expect(existing.body.id).toBe(mainWindow.id);
    const undeclaredView = await call(daemon.url, 'POST', `/workspaces/${workspace.workspace.id}/windows`, {
      id: randomUUID(), content: { kind: 'open', instanceId: target.instanceId, viewId: 'secondary' },
    }, machineId);
    expect(undeclaredView.status).toBe(400);
    const otherWorkspace = await call(daemon.url, 'POST', '/workspaces', {
      checkout: rootModel.body.checkout.id,
    }, machineId);
    expect(otherWorkspace.status).toBe(200);
    await internal.wait((event) => event.type === 'workspace.changed'
      && event.workspaceId === otherWorkspace.body.workspace.id && event.status === 'open');
    expect((await call(daemon.url, 'POST', `/workspaces/${otherWorkspace.body.workspace.id}/windows`, {
      id: randomUUID(), content: { kind: 'open', instanceId: target.instanceId, viewId: target.viewId },
    }, machineId)).status).toBe(404);
    expect((await call(daemon.url, 'DELETE', `/workspaces/${otherWorkspace.body.workspace.id}/windows/${mainWindow.id}`, undefined, machineId)).status).toBe(404);

    await firstClient.close();
    firstClient = undefined;
    reconnected = await connectWorkspace(daemon.url, machineId, workspace.workspace.id);
    const snapshot = await reconnected.events.wait((event) => event.type === 'workspace.model'
      && event.workspaceId === workspace.workspace.id);
    const model = snapshot.model! as any;
    expect(model.instances).toEqual([
      expect.objectContaining({ id: target.instanceId, workspaceId: workspace.workspace.id, definitionId: 'kite.files' }),
    ]);
    expect(model.windows.map((window: any) => window.id)).toEqual([mainWindow.id]);

    await reconnected.close();
    reconnected = undefined;
    await daemon.stop();
    restarted = undefined;

    restarted = startDaemon({ home, port: 0, lightTasks: false });
    const restored = await call(restarted.url, 'GET', '/workspaces', undefined, machineId);
    expect(restored.status).toBe(200);
    const persisted = restored.body.find((entry: any) => entry.workspace.id === workspace.workspace.id);
    expect(persisted.instances).toEqual([
      expect.objectContaining({ id: target.instanceId, workspaceId: workspace.workspace.id, definitionId: 'kite.files' }),
    ]);
    expect(persisted.windows.map((window: any) => window.id)).toEqual([mainWindow.id]);

    expect((await call(restarted.url, 'DELETE', `/workspaces/${workspace.workspace.id}/windows/${mainWindow.id}`, undefined, machineId)).status).toBe(200);
    expect((await call(restarted.url, 'DELETE', `/workspaces/${workspace.workspace.id}/windows/${mainWindow.id}`, undefined, machineId)).status).toBe(200);
    expect((await call(restarted.url, 'POST', `/workspaces/${workspace.workspace.id}/windows`, {
      id: existingRequestId, content: { kind: 'open', instanceId: target.instanceId, viewId: target.viewId },
    }, machineId)).status).toBe(409);
    const closedId = await call(restarted.url, 'POST', `/workspaces/${workspace.workspace.id}/windows`, {
      id: requestId, content: { kind: 'create', definitionId: 'kite.files' },
    }, machineId);
    expect(closedId.status).toBe(409);
    const reopened = await call(restarted.url, 'POST', `/workspaces/${workspace.workspace.id}/windows`, {
      id: randomUUID(), content: { kind: 'open', instanceId: target.instanceId, viewId: target.viewId },
    }, machineId);
    expect(reopened.status).toBe(404);
    const openOnly = await call(restarted.url, 'GET', '/workspaces', undefined, machineId);
    const afterClose = openOnly.body.find((entry: any) => entry.workspace.id === workspace.workspace.id);
    expect(afterClose.instances).toEqual([]);
    expect(afterClose.windows).toEqual([]);
    await restarted.stop();
    restarted = startDaemon({ home, port: 0, lightTasks: false });
    expect((await call(restarted.url, 'DELETE', `/workspaces/${workspace.workspace.id}/windows/${mainWindow.id}`, undefined, machineId)).status).toBe(200);
    expect((await call(restarted.url, 'POST', `/workspaces/${workspace.workspace.id}/windows`, {
      id: requestId, content: { kind: 'create', definitionId: 'kite.files' },
    }, machineId)).status).toBe(409);
    const afterRestart = await call(restarted.url, 'GET', '/workspaces', undefined, machineId);
    expect(afterRestart.body.find((entry: any) => entry.workspace.id === workspace.workspace.id))
      .toMatchObject({ instances: [], windows: [] });
    expect((await call(restarted.url, 'POST', `/workspaces/${workspace.workspace.id}/archive`, { force: true }, machineId)).status).toBe(200);
    expect((await call(restarted.url, 'POST', `/workspaces/${workspace.workspace.id}/windows`, {
      id: randomUUID(), content: { kind: 'create', definitionId: 'kite.files' },
    }, machineId)).status).toBe(409);
  } finally {
    await firstClient?.close();
    await reconnected?.close();
    unsubscribe();
  }
}, 1000);

/*
 * 依赖窗口关闭、运行中 harness、agent 实例投影和工作区聚合筛选的配合：创建 agent
 * 窗口本身不能启动模型；关闭它也不能打断已经开始的回合，归档实例会收起关联窗口。
 */
test('运行中的线程关闭窗口后继续执行，重新打开目标且归档线程会收起窗口', async () => {
  const model = new ManualModel();
  kited = startKited(() => model);
  const kk = kited;
  const repo = newRepo(kk.root, 'project', { 'base.txt': '原始\n' });
  const root = await registerCheckout(kk, repo);
  const created = await kk.call('POST', '/workspaces', { checkout: root.checkout.id });
  expect(created.status).toBe(200);
  const workspace = created.body;
  await kk.waitEvent((event) => event.type === 'workspace.changed'
    && event.workspaceId === workspace.workspace.id && event.status === 'open');

  const opened = await kk.call('POST', `/workspaces/${workspace.workspace.id}/windows`, {
    id: randomUUID(), content: { kind: 'create', definitionId: 'kite.agent.coding' },
  });
  expect(opened.status).toBe(200);
  const openedWindow = structuredClone(opened.body);
  const threadId = openedWindow.target.instanceId as string;
  if (typeof threadId !== 'string') throw new Error(`新 agent 窗口没有返回实例 ID：${JSON.stringify(openedWindow)}`);
  expect(structuredClone(openedWindow)).toMatchObject({
    workspaceId: workspace.workspace.id,
    target: { instanceId: expect.any(String), viewId: 'conversation' },
    state: 'open',
  });
  expect(model.calls.values).toHaveLength(0);
  const createdAggregate = (await kk.call('GET', '/workspaces')).body
    .find((entry: any) => entry.workspace.id === workspace.workspace.id);
  expect(createdAggregate.threads).toEqual([{ instanceId: threadId, runtime: 'harness', nativeId: expect.any(String) }]);
  expect(createdAggregate.instances).toEqual([expect.objectContaining({
    id: threadId,
    workspaceId: workspace.workspace.id,
    definitionId: 'kite.agent.coding',
    status: 'open',
    presentation: 'window',
  })]);
  expect((await kk.call('POST', `/threads/${threadId}/messages`, { text: '保持执行' })).status).toBe(200);
  const running = await model.call(1);

  expect((await kk.call('DELETE', `/workspaces/${workspace.workspace.id}/windows/${openedWindow.id}`)).status).toBe(200);
  expect((await kk.call('DELETE', `/workspaces/${workspace.workspace.id}/windows/${openedWindow.id}`)).status).toBe(200);
  expect(running.signal.aborted).toBe(false);
  const activeThread = await kk.call('GET', `/threads/${threadId}`);
  expect(activeThread.body).toMatchObject({ id: threadId, workspace: { id: workspace.workspace.id }, status: 'open', busy: true });

  const reopened = await kk.call('POST', `/workspaces/${workspace.workspace.id}/windows`, {
    id: randomUUID(), content: { kind: 'open', instanceId: threadId, viewId: 'conversation' },
  });
  expect(reopened.status).toBe(200);
  const aggregation = await kk.call('GET', '/workspaces');
  const visible = aggregation.body.find((entry: any) => entry.workspace.id === workspace.workspace.id);
  expect(visible.windows).toEqual([expect.objectContaining({
    id: reopened.body.id,
    target: { instanceId: threadId, viewId: 'conversation' },
  })]);
  expect(running.signal.aborted).toBe(false);

  running.response.complete();
  await kk.waitEvent((event) => event.type === 'idle' && event.threadId === threadId);
  expect((await kk.call('POST', `/threads/${threadId}/archive`)).status).toBe(200);
  await kk.waitEvent((event) => event.type === 'thread.changed' && event.threadId === threadId && event.status === 'archived');
  const archived = await kk.call('GET', '/workspaces');
  const afterArchive = archived.body.find((entry: any) => entry.workspace.id === workspace.workspace.id);
  expect(afterArchive.windows).toEqual([]);
  expect(afterArchive.threads).toEqual([{ instanceId: threadId, runtime: 'harness', nativeId: expect.any(String) }]);
  expect(afterArchive.instances).toEqual([expect.objectContaining({ id: threadId, status: 'archived' })]);
  expect((await kk.call('POST', `/workspaces/${workspace.workspace.id}/windows`, {
    id: randomUUID(), content: { kind: 'open', instanceId: threadId, viewId: 'conversation' },
  })).status).toBe(409);
}, 1000);
