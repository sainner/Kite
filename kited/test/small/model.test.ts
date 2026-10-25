/**
 * Store、Kite、HTTP 之间的工作区聚合和状态投影；这些状态要在异步准备过程
 * 中跨模块同步，单看任何一个模块的字段映射都无法确认。
 */
import { afterEach, expect, test } from 'bun:test';
import { randomUUID } from 'node:crypto';
import { existsSync, rmSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { startDaemon, type Daemon } from '../../src/daemon.ts';
import { type FakeGit, startFakeGit } from '../fake-git.ts';
import {
  addProject, after, call, chatgptLogin, connect, createWorkspace, folderWorkspace, machine, mark, startKited, synced, type Kited,
} from '../harness.ts';
import { ManualModel } from '../harness-loop.ts';
import { connectSse } from '../sse.ts';
import { makeTemp, newDir } from '../util.ts';

let kited: Kited | undefined;
let otherKited: Kited | undefined;
let restarted: Daemon | undefined;
let remotes: FakeGit | undefined;
const roots: string[] = [];
afterEach(async () => {
  await restarted?.stop();
  restarted = undefined;
  await kited?.stop();
  kited = undefined;
  await otherKited?.stop();
  otherKited = undefined;
  remotes?.stop();
  remotes = undefined;
  for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true });
});

type WorkspaceWireEvent = {
  type: string;
  workspaceId?: string;
  model?: { workspace: { id: string }; instances?: unknown[] };
};

/** 工作区 SSE 首帧是完整聚合；调用方显式关闭流，避免测试留下打开的 HTTP 连接。 */
function connectWorkspace(url: string, machineId: string, workspaceId: string) {
  return connectSse<WorkspaceWireEvent>(`${url}/events?workspace=${workspaceId}`, machineId);
}

/*
 * 项目登记、异步工作树准备、模型启动、HTTP 聚合与 SQLite 线程关系要一起成立：
 * 首线程在工作树 cwd 运行；首线程还在工作时第二线程就能启动并共享 cwd，归档首线程保留工作树。
 */
test('添加项目后首线程工作时即可并行创建同工作区线程，暂停后 resume 续接，归档首线程保留第二线程', async () => {
  const model = new ManualModel();
  kited = startKited(() => model);
  const kk = kited;
  // 没有远程的项目：合回只到本机主线。
  const project = await addProject(kk, { path: newDir(kk.root, 'project', { 'base.txt': '原始\n' }) });
  const localMachine = await machine(kk.url);
  chatgptLogin(kk.home);
  const created = await kk.call('POST', '/workspaces', { project: project.id, prompt: '首线程' });
  expect(created.status).toBe(200);
  const workspace = structuredClone(created.body);
  const firstThread = workspace.threads[0];
  const firstThreadId = firstThread.instanceId;
  expect(structuredClone(workspace)).toMatchObject({
    machine: localMachine,
    project: { id: project.id },
    checkout: { projectId: project.id, machineId: localMachine.id },
    workspace: { checkoutId: workspace.checkout.id },
  });
  const firstInstance = workspace.instances.find((instance: any) => instance.id === firstThreadId);
  expect(firstInstance).toMatchObject({
    id: firstThreadId,
    workspaceId: workspace.workspace.id,
    definitionId: 'kite.agent',
    title: '首线程',
    status: 'open',
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
    project: { id: project.id },
    checkout: { id: workspace.checkout.id },
    workspace: { id: workspace.workspace.id, cwd: workspace.workspace.cwd },
  });
  const first = await model.call(1);
  expect(first.request.cwd).toBe(workspace.workspace.cwd);

  // 首线程的请求还挂着，同一工作区就能起第二线程，两个线程共享工作树 cwd 并行执行。
  const secondCreated = await kk.call('POST', `/workspaces/${workspace.workspace.id}/threads`, {
    prompt: '第二线程',
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
  expect(first.signal.aborted).toBe(false);
  second.response.complete();
  await kk.waitEvent((event) => event.type === 'idle' && event.threadId === secondThreadId);
  first.response.complete();
  await kk.waitEvent((event) => event.type === 'idle' && event.threadId === firstThreadId);

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
  // CLI 的 resume 只是调这个入口再跟到回合结束，跟随的那一段在 daemon.test.ts 的 CLI send 里。
  const beforeResume = mark(kk);
  expect((await kk.call('POST', `/threads/${secondThreadId}/resume`, {})).status).toBe(200);
  const resumed = await model.call(4);
  expect(resumed.request.history).toContainEqual(expect.objectContaining({ type: 'input', input: expect.objectContaining({ text: '恢复后继续' }) }));
  resumed.response.complete();
  await kk.waitEvent((event) => event.type === 'idle' && event.threadId === secondThreadId && after(kk, beforeResume)(event));

  const listed = await kk.call('GET', '/workspaces');
  const aggregate = listed.body.find((view: any) => view.workspace.id === workspace.workspace.id);
  // 跑过回合的线程另带活动摘要 activity，这里只核对线程身份
  expect(aggregate.threads).toEqual(expect.arrayContaining([
    expect.objectContaining({ instanceId: firstThreadId, runtime: 'harness', nativeId: expect.any(String) }),
    expect.objectContaining({ instanceId: secondInstanceId, runtime: 'harness', nativeId: expect.any(String) }),
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
  const archived = await kk.call('POST', `/instances/${firstThreadId}/archive`);
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
  const repo = newDir(root, 'project', { 'base.txt': '原始\n' });
  const model = new ManualModel();
  restarted = startDaemon({ home, port: 0, lightTasks: false, model: () => model });

  const firstMachine = await machine(restarted.url);
  const context = await createWorkspace(restarted, (await addProject(restarted, { path: repo })).id, '可恢复线程', 'harness');
  const workspace = { workspace: context.workspace };
  const thread = { instanceId: context.id };
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
    project: { id: context.project.id },
    checkout: { id: context.checkout.id, projectId: context.project.id, machineId: firstMachine.id },
    workspace: { id: workspace.workspace.id, checkoutId: context.checkout.id, cwd: workspace.workspace.cwd },
    threads: [{ instanceId: thread.instanceId, runtime: 'harness', nativeId: expect.any(String) }],
    instances: [expect.objectContaining({
      id: thread.instanceId,
      workspaceId: workspace.workspace.id,
      definitionId: 'kite.agent',
      status: 'open',
    })],
  });
  const checkouts = await call(restarted.url, 'GET', `/checkouts?project=${context.project.id}`);
  expect(checkouts.status).toBe(200);
  expect(checkouts.body.map((checkout: any) => checkout.id)).toEqual([context.checkout.id]);
  const projects = await call(restarted.url, 'GET', '/projects');
  expect(projects.body).toEqual([context.project]);
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
 * 两份 SQLite 数据库经同步的项目登记表决定身份：一台登记过的远程，另一台同步到之后再登记，得到同一项目而不另建；
 * 错误目标的写请求必须在登记前拒绝。并发请求还要经过同一登记队列与本机登记表，其中一次失败不能影响排在后面的重复登记，
 * 同一远程只登记一次。登记远程要先确认访问得到，远程用 Git 平台替身。
 */
test('两台工作机登记同一远程得到同一项目 ID，并发登记遇到失败后仍幂等', async () => {
  kited = startKited();
  otherKited = startKited();
  const left = kited;
  const right = otherKited;
  await connect(left, right);
  remotes = startFakeGit();
  const shared = remotes.create('project').url;
  const other = remotes.create('second').url;
  const leftMachine = await machine(left.url);
  const rightMachine = await machine(right.url);
  expect(leftMachine.id).not.toBe(rightMachine.id);

  const badRequest = (headers: Record<string, string>) => fetch(`${right.url}/project-registry`, {
    method: 'POST', headers: { 'content-type': 'application/json', ...headers },
    body: JSON.stringify({ remote: shared }),
  });
  expect((await badRequest({})).status).toBe(400);
  expect((await badRequest({ 'X-Kite-Machine': leftMachine.id })).status).toBe(409);
  expect(right.daemon.kite.registry.list()).toEqual([]);

  const leftProject = await addProject(left, { remote: shared });
  expect(leftProject.remote).toBe(`${new URL(shared).host}/project`);
  await synced(right, () => right.daemon.kite.registry.get(leftProject.id), '右边同步到左边登记的项目');
  expect(await addProject(right, { remote: shared })).toEqual(leftProject);

  const [firstRegistration, failedRegistration, repeatedRegistration] = await Promise.all([
    right.call('POST', '/project-registry', { remote: other }),
    right.call('POST', '/project-registry', { path: join(right.root, 'missing-checkout') }),
    right.call('POST', '/project-registry', { remote: other }),
  ]);
  expect(firstRegistration.status).toBe(200);
  expect(failedRegistration.status).toBeGreaterThanOrEqual(400);
  expect(failedRegistration.status).toBeLessThan(500);
  expect(repeatedRegistration.status).toBe(200);
  expect(firstRegistration.body.id).not.toBe(leftProject.id);
  expect(repeatedRegistration.body.id).toBe(firstRegistration.body.id);
  expect(right.daemon.kite.registry.list().map((project) => project.id).sort()).toEqual([leftProject.id, firstRegistration.body.id].sort());
});

/*
 * 依赖 HTTP 命令收据、SQLite 事务、工作区 SSE 首帧和服务重启的配合：同一命令重试
 * 不能重复建实例；关闭即回收的实例回收后，请求收据在重启后仍不能复活旧实例。
 */
test('新建实例命令去重，重连保留实例且回收后的收据跨重启不复活实例', async () => {
  const root = makeTemp('instance-model-');
  roots.push(root);
  const home = join(root, 'kite');
  const repo = newDir(root, 'project', { 'base.txt': '原始\n' });
  restarted = startDaemon({ home, port: 0, lightTasks: false });
  const daemon = restarted;
  let firstClient: Awaited<ReturnType<typeof connectWorkspace>> | undefined;
  let reconnected: Awaited<ReturnType<typeof connectWorkspace>> | undefined;
  try {
    const machineId = (await machine(daemon.url)).id;
    const workspace = await folderWorkspace(daemon, repo);

    firstClient = await connectWorkspace(daemon.url, machineId, workspace.workspace.id);
    await firstClient.events.wait((event) => event.type === 'workspace.model' && event.workspaceId === workspace.workspace.id);
    const requestId = randomUUID();
    const main = await call(daemon.url, 'POST', `/workspaces/${workspace.workspace.id}/instances`, {
      id: requestId, definitionId: 'kite.files',
    }, machineId);
    expect(main.status).toBe(200);
    // Bun 的 objectContaining 可能会改写嵌套对象；先复制原始 HTTP JSON，再用于后续重试断言。
    const mainInstance = structuredClone(main.body);
    expect(mainInstance.id).toBe(requestId);
    await firstClient.events.wait((event) => event.type === 'workspace.changed' && event.workspaceId === workspace.workspace.id);
    const mainModel = await call(daemon.url, 'GET', '/workspaces', undefined, machineId);
    const mainAggregate = mainModel.body.find((entry: any) => entry.workspace.id === workspace.workspace.id);
    expect(mainAggregate.instances).toEqual([expect.objectContaining({
      id: requestId,
      workspaceId: workspace.workspace.id,
      definitionId: 'kite.files',
      status: 'open',
    })]);
    expect(mainAggregate.threads).toEqual([]);

    const retried = await call(daemon.url, 'POST', `/workspaces/${workspace.workspace.id}/instances`, {
      id: requestId, definitionId: 'kite.files',
    }, machineId);
    expect(retried.status).toBe(200);
    expect(retried.body).toEqual(mainInstance);
    const changedContent = await call(daemon.url, 'POST', `/workspaces/${workspace.workspace.id}/instances`, {
      id: requestId, definitionId: 'kite.terminal',
    }, machineId);
    expect(changedContent.status).toBe(409);

    await firstClient.close();
    firstClient = undefined;
    reconnected = await connectWorkspace(daemon.url, machineId, workspace.workspace.id);
    const snapshot = await reconnected.events.wait((event) => event.type === 'workspace.model'
      && event.workspaceId === workspace.workspace.id);
    const model = snapshot.model! as any;
    expect(model.instances).toEqual([
      expect.objectContaining({ id: requestId, workspaceId: workspace.workspace.id, definitionId: 'kite.files' }),
    ]);

    await reconnected.close();
    reconnected = undefined;
    await daemon.stop();
    restarted = undefined;

    restarted = startDaemon({ home, port: 0, lightTasks: false });
    const restored = await call(restarted.url, 'GET', '/workspaces', undefined, machineId);
    expect(restored.status).toBe(200);
    const persisted = restored.body.find((entry: any) => entry.workspace.id === workspace.workspace.id);
    expect(persisted.instances).toEqual([
      expect.objectContaining({ id: requestId, workspaceId: workspace.workspace.id, definitionId: 'kite.files' }),
    ]);

    expect((await call(restarted.url, 'DELETE', `/instances/${requestId}`, undefined, machineId)).status).toBe(200);
    const closedId = await call(restarted.url, 'POST', `/workspaces/${workspace.workspace.id}/instances`, {
      id: requestId, definitionId: 'kite.files',
    }, machineId);
    expect(closedId.status).toBe(409);
    const openOnly = await call(restarted.url, 'GET', '/workspaces', undefined, machineId);
    const afterClose = openOnly.body.find((entry: any) => entry.workspace.id === workspace.workspace.id);
    expect(afterClose.instances).toEqual([]);
    await restarted.stop();
    restarted = startDaemon({ home, port: 0, lightTasks: false });
    expect((await call(restarted.url, 'POST', `/workspaces/${workspace.workspace.id}/instances`, {
      id: requestId, definitionId: 'kite.files',
    }, machineId)).status).toBe(409);
    const afterRestart = await call(restarted.url, 'GET', '/workspaces', undefined, machineId);
    expect(afterRestart.body.find((entry: any) => entry.workspace.id === workspace.workspace.id)).toMatchObject({ instances: [] });
    expect((await call(restarted.url, 'POST', `/workspaces/${workspace.workspace.id}/archive`, { force: true }, machineId)).status).toBe(200);
    expect((await call(restarted.url, 'POST', `/workspaces/${workspace.workspace.id}/instances`, {
      id: randomUUID(), definitionId: 'kite.files',
    }, machineId)).status).toBe(409);
  } finally {
    const closed = await Promise.allSettled([firstClient?.close(), reconnected?.close()]);
    for (const result of closed) if (result.status === 'rejected') throw result.reason;
  }
}, 1000);

/*
 * 依赖运行中 harness、agent 实例投影和工作区聚合筛选的配合：新建空 agent 实例本身不能启动模型；归档停下执行、实例记为 archived。
 */
test('新建空代理不启动模型，归档后实例记为 archived', async () => {
  const model = new ManualModel();
  kited = startKited(() => model);
  const kk = kited;
  const workspace = await folderWorkspace(kk, newDir(kk.root, 'project', { 'base.txt': '原始\n' }));

  const threadId = randomUUID();
  const opened = await kk.call('POST', `/workspaces/${workspace.workspace.id}/instances`, { id: threadId, definitionId: 'kite.agent' });
  expect(opened.status).toBe(200);
  expect(model.calls.values).toHaveLength(0);
  const createdAggregate = (await kk.call('GET', '/workspaces')).body
    .find((entry: any) => entry.workspace.id === workspace.workspace.id);
  expect(createdAggregate.threads).toEqual([{ instanceId: threadId, runtime: 'harness', nativeId: expect.any(String) }]);
  expect(createdAggregate.instances).toEqual([expect.objectContaining({
    id: threadId,
    workspaceId: workspace.workspace.id,
    definitionId: 'kite.agent',
    status: 'open',
  })]);
  expect((await kk.call('POST', `/threads/${threadId}/messages`, { text: '保持执行' })).status).toBe(200);
  const running = await model.call(1);
  const activeThread = await kk.call('GET', `/threads/${threadId}`);
  expect(activeThread.body).toMatchObject({ id: threadId, workspace: { id: workspace.workspace.id }, status: 'open', busy: true });

  running.response.complete();
  await kk.waitEvent((event) => event.type === 'idle' && event.threadId === threadId);
  expect((await kk.call('POST', `/instances/${threadId}/archive`)).status).toBe(200);
  await kk.waitEvent((event) => event.type === 'thread.changed' && event.threadId === threadId && event.status === 'archived');
  const archived = await kk.call('GET', '/workspaces');
  const afterArchive = archived.body.find((entry: any) => entry.workspace.id === workspace.workspace.id);
  expect(afterArchive.threads).toEqual([expect.objectContaining({ instanceId: threadId, runtime: 'harness', nativeId: expect.any(String) })]);
  expect(afterArchive.instances).toEqual([expect.objectContaining({ id: threadId, status: 'archived' })]);
}, 1000);
