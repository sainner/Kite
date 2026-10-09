import { afterEach, expect, test } from 'bun:test';
import { existsSync, rmSync } from 'node:fs';
import { join } from 'node:path';
import { startDaemon, type Daemon } from '../../src/daemon.ts';
import { OperationError } from '../../src/errors.ts';
import type { Json, ModelItem } from '../../src/harness/types.ts';
import { OperationReceipts } from '../../src/operations/receipts.ts';
import { Store } from '../../src/store.ts';
import { call, linkNewAccount, registerCheckout, startKited, type Kited } from '../harness.ts';
import { deferred, diskRecords, item, ManualModel } from '../harness-loop.ts';
import { makeTemp, newRepo } from '../util.ts';

let kited: Kited | undefined;
afterEach(async () => { await kited?.stop(); kited = undefined; });

const operationPath = (workspaceId: string, name: string) => `/workspaces/${workspaceId}/operations/${name}`;

async function emptyWorkspace(k: Kited, name: string) {
  const repo = newRepo(k.root, name, { 'base.txt': '原始\n' });
  const registered = await registerCheckout(k, repo);
  return { workspaceId: registered.workspace.id, repo };
}

function calledItem(id: string, name: string, args: Json): ModelItem {
  return { ...item(id, name), call: { id, name, arguments: args } };
}

// Promise 并发、SQLite 重开和落盘失败后的异步清理共同决定是否重放副作用，单看任一模块不能验证。
test('并发收据共享一次执行，重开保留结果与错误，落盘失败等清理后保持 unknown', async () => {
  const root = makeTemp('operation-receipts-');
  const database = join(root, 'store.sqlite');
  let store = new Store(database);
  const value = { count: 1 };
  const completed = deferred<typeof value>();
  const started = deferred();
  const releases = [() => completed.resolve(value)];
  let executed = 0;
  const request = { actor: 'actor', id: 'shared', request: '{"count":1}' };
  const execute = () => { executed++; started.resolve(); return completed.promise; };
  const neverReplay = async (): Promise<typeof value> => { executed++; throw new Error('不应重放已登记操作'); };
  try {
    const receipts = new OperationReceipts(store);
    const first = receipts.run({ ...request, execute });
    await started.promise;
    expect(store.operationReceipt(request.actor, request.id)).toEqual({ request: request.request, result: null });
    const second = receipts.run({ ...request, execute });
    await expect(receipts.run({ ...request, request: '{"count":2}', execute: neverReplay }))
      .rejects.toMatchObject({ outcome: 'denied' });
    expect(await receipts.run({ ...request, actor: 'other-actor', execute: async () => ({ count: 2 }) }))
      .toEqual({ count: 2 });
    expect(executed).toBe(1);
    completed.resolve(value);
    expect(await Promise.all([first, second])).toEqual([value, value]);
    expect(await new OperationReceipts(store).run({ ...request, execute: neverReplay })).toEqual(value);

    const unfinished = { actor: 'actor', id: 'unfinished', request: '{}' };
    store.beginOperation(unfinished.actor, unfinished.id, unfinished.request);
    store.close();
    store = new Store(database);
    const reopened = new OperationReceipts(store);
    expect(await reopened.run({ ...request, execute: neverReplay })).toEqual(value);
    await expect(reopened.run({ ...unfinished, execute: neverReplay })).rejects.toMatchObject({ outcome: 'unknown' });
    expect(executed).toBe(1);

    const syncFailure = { actor: 'actor', id: 'sync-failure', request: '{}' };
    let syncAttempts = 0;
    await expect(reopened.run({ ...syncFailure, execute() { syncAttempts++; throw new Error('同步执行异常'); } }))
      .rejects.toMatchObject({ outcome: 'unknown' });
    await expect(reopened.run({ ...syncFailure, execute: neverReplay })).rejects.toMatchObject({ outcome: 'unknown' });
    expect(syncAttempts).toBe(1);
    const denied = { actor: 'actor', id: 'business-denied', request: '{}' };
    await expect(reopened.run({ ...denied, execute() { throw new OperationError('权限已撤回', 'denied', 403); } }))
      .rejects.toMatchObject({ outcome: 'denied', status: 403 });
    await expect(new OperationReceipts(store).run({ ...denied, execute: neverReplay }))
      .rejects.toMatchObject({ outcome: 'denied', status: 403 });

    for (const outcome of ['success', 'denied'] as const) {
      const cleanupStarted = deferred();
      const cleanupDone = deferred();
      releases.push(() => cleanupDone.resolve());
      const failedWrite = { actor: 'actor', id: `disk-full-${outcome}`, request: '{}' };
      const failing = new OperationReceipts({
        operationReceipt: (actor, id) => store.operationReceipt(actor, id),
        beginOperation: (actor, id, encoded) => store.beginOperation(actor, id, encoded),
        finishOperation() { throw new Error('模拟 SQLite 落盘失败'); },
      });
      let failureExecutions = 0;
      let settled = false;
      let retrySettled = false;
      const attempt = failing.run({
        ...failedWrite,
        execute() {
          failureExecutions++;
          if (outcome === 'denied') throw new OperationError('权限已撤回', 'denied', 403);
          return Promise.resolve(value);
        },
        async onPersistenceFailure() { cleanupStarted.resolve(); await cleanupDone.promise; },
      }).then(() => { settled = true; return undefined; }, (error: unknown) => { settled = true; return error; });
      await cleanupStarted.promise;
      const retry = failing.run({ ...failedWrite, execute: neverReplay })
        .then(() => { retrySettled = true; return undefined; }, (error: unknown) => { retrySettled = true; return error; });
      // 等一个事件循环检查点，让已排队的 Promise 都有机会完成；清理闸门仍未放行。
      await new Promise<void>((resolve) => setImmediate(resolve));
      expect(settled).toBe(false);
      expect(retrySettled).toBe(false);
      expect(store.operationReceipt(failedWrite.actor, failedWrite.id)).toEqual({ request: '{}', result: null });
      cleanupDone.resolve();
      expect(await attempt).toMatchObject({ outcome: 'unknown' });
      expect(await retry).toMatchObject({ outcome: 'unknown' });
      await expect(new OperationReceipts(store).run({ ...failedWrite, execute: neverReplay }))
        .rejects.toMatchObject({ outcome: 'unknown' });
      expect(failureExecutions).toBe(1);
    }
    expect(executed).toBe(1);
  } finally {
    for (const release of releases) release();
    store.close();
    rmSync(root, { recursive: true, force: true });
  }
}, 1000);

// HTTP、SQLite 收据和窗口目录跨重启交接：同一创建操作只生成一个实例和窗口，查询不能唤醒线程。
test('agent.start 跨重启重试复用实例与窗口，后台实例不建窗口且 list 只读', async () => {
  const root = makeTemp();
  const home = join(root, 'kite');
  const account = linkNewAccount(home);
  const repo = newRepo(root, 'project', { 'base.txt': '原始\n' });
  const model = new ManualModel();
  let daemon: Daemon | undefined;
  try {
    daemon = startDaemon({ home, port: 0, lightTasks: false, model: () => model });
    const checkout = await call(daemon.url, 'POST', '/checkouts', { path: repo });
    expect(checkout.status).toBe(200);
    const workspaceId = checkout.body.workspace.id as string;

    const windowRequest = { operationId: 'create-window', title: '编码线程' };
    const backgroundRequest = { operationId: 'create-background', role: 'kite.review', presentation: 'background' };
    const window = await call(daemon.url, 'POST', operationPath(workspaceId, 'agent.start'), windowRequest);
    const background = await call(daemon.url, 'POST', operationPath(workspaceId, 'agent.start'), backgroundRequest);
    expect(window.status).toBe(200);
    expect(background.status).toBe(200);
    const windowId = window.body.windowId as string;
    const codingId = window.body.instanceId as string;
    const reviewId = background.body.instanceId as string;
    expect(background.body.windowId).toBeUndefined();
    const codingExecution = await call(daemon.url, 'GET', `/instances/${codingId}/execution-grants`);
    const reviewExecution = await call(daemon.url, 'GET', `/instances/${reviewId}/execution-grants`);
    const revisedExecution = await call(daemon.url, 'PUT', `/instances/${codingId}/execution-grants`, {
      expectedRevision: codingExecution.body.revision,
      grants: { workspace: 'read', read: [], write: [], network: [] },
    });
    expect(revisedExecution.status).toBe(200);
    const journalPath = join(home, 'sessions', codingId, 'journal.jsonl');
    const listed = await call(daemon.url, 'POST', operationPath(workspaceId, 'agent.list'), {});
    expect(listed.status).toBe(200);
    expect(Object.fromEntries(listed.body.agents.map((agent: { instanceId: string; role: { id: string } | null }) => [agent.instanceId, agent.role?.id])))
      .toEqual({ [codingId]: 'kite.work', [reviewId]: 'kite.review' });
    expect(model.calls.values).toHaveLength(0);
    expect(existsSync(journalPath)).toBe(false);
    await daemon.stop();
    daemon = undefined;

    daemon = startDaemon({ home, port: 0, lightTasks: false, model: () => model });
    expect((await call(daemon.url, 'GET', `/instances/${codingId}/execution-grants`)).body).toEqual(revisedExecution.body);
    expect((await call(daemon.url, 'GET', `/instances/${reviewId}/execution-grants`)).body).toEqual(reviewExecution.body);
    const retriedWindow = await call(daemon.url, 'POST', operationPath(workspaceId, 'agent.start'), windowRequest);
    const retriedBackground = await call(daemon.url, 'POST', operationPath(workspaceId, 'agent.start'), backgroundRequest);
    expect(retriedWindow.status).toBe(200);
    expect(retriedBackground.status).toBe(200);
    expect(retriedWindow.body).toEqual(window.body);
    expect(retriedBackground.body).toEqual(background.body);
    expect((await call(daemon.url, 'POST', operationPath(workspaceId, 'agent.start'), {
      ...windowRequest, title: '相同收据的冲突参数',
    })).status).toBe(409);
    const aggregate = await call(daemon.url, 'GET', '/workspaces');
    const workspace = aggregate.body.find((entry: { workspace: { id: string } }) => entry.workspace.id === workspaceId);
    expect(workspace.instances.filter((instance: { id: string }) => [codingId, reviewId].includes(instance.id))).toHaveLength(2);
    expect(workspace.windows.filter((entry: { target: { instanceId: string } }) => [codingId, reviewId].includes(entry.target.instanceId)))
      .toEqual([expect.objectContaining({ id: windowId, target: { instanceId: codingId, viewId: 'conversation' } })]);
    expect(model.calls.values).toHaveLength(0);
  } finally {
    await daemon?.stop();
    account.stop();
    rmSync(root, { recursive: true, force: true });
  }
}, 1000);

// 模型工具到宿主身份、实例来源、授权快照与执行时重验跨模块交接；撤权后旧请求也不能再调用。
test('模型创建记录来源并受工作区与目标授权约束，撤权即时拒绝且下一请求移除工具', async () => {
  const model = new ManualModel();
  kited = startKited(() => model);
  const kk = kited;
  const { workspaceId } = await emptyWorkspace(kk, 'main');
  const { workspaceId: otherWorkspaceId } = await emptyWorkspace(kk, 'other');
  const parent = await kk.call('POST', operationPath(workspaceId, 'agent.start'), {
    operationId: 'parent-agent', role: 'kite.work',
  });
  const unrelated = await kk.call('POST', operationPath(workspaceId, 'agent.start'), {
    operationId: 'unrelated-agent', role: 'kite.work', presentation: 'inline',
  });
  expect(parent.status).toBe(200);
  expect(unrelated.status).toBe(200);
  const parentId = parent.body.instanceId as string;
  const unrelatedId = unrelated.body.instanceId as string;
  expect((await kk.call('POST', operationPath(workspaceId, 'agent.send'), {
    operationId: 'run-parent', instanceId: parentId, text: '创建审查线程',
  })).status).toBe(200);
  const first = await model.call(1);
  expect(first.request.allowedTools).toContain('agent_start');
  await first.response.emit({ type: 'item', item: calledItem('create-review', 'agent_start', {
    role: 'kite.review', presentation: 'background',
  }) });
  first.response.complete();
  const second = await model.call(2);
  const aggregate = await kk.call('GET', '/workspaces');
  const workspace = aggregate.body.find((entry: { workspace: { id: string } }) => entry.workspace.id === workspaceId);
  const child = workspace.instances.find((instance: { origin?: { callId: string } }) => instance.origin?.callId === 'create-review');
  if (!child) throw new Error('模型没有创建审查实例');
  // 审查角色的子实例照样带着代理的默认授权，挡住它的是角色白名单：协作工具不在它的工具里
  expect(child.config.role.id).toBe('kite.review');
  expect(child.config.agent.tools).toEqual(['read']);
  expect(child.origin).toMatchObject({ instanceId: parentId, callId: 'create-review' });
  const modelCaller = { kind: 'model' as const, instanceId: parentId, turnId: first.request.turnId, callId: 'authorization' };
  await expect(kk.daemon.kite.operations.invoke(modelCaller, otherWorkspaceId, 'agent.list', {}))
    .rejects.toMatchObject({ outcome: 'denied' });
  await expect(kk.daemon.kite.operations.invoke(modelCaller, workspaceId, 'agent.send', {
    operationId: 'send-unrelated', instanceId: unrelatedId, text: '不应发送',
  })).rejects.toMatchObject({ outcome: 'denied' });
  const grants = await kk.call('GET', `/instances/${parentId}/operation-grants`);
  expect(grants.status).toBe(200);
  expect((await kk.call('PUT', `/instances/${parentId}/operation-grants`, {
    expectedRevision: grants.body.revision, grants: [],
  })).status).toBe(200);
  expect(second.request.allowedTools).toContain('agent_list');
  await second.response.emit({ type: 'item', item: calledItem('after-revoke', 'agent_list', {}) });
  second.response.complete();
  const third = await model.call(3);
  expect(third.request.allowedTools).not.toContain('agent_list');
  const denied = third.request.history.find((entry) => entry.type === 'tool_result' && entry.callId === 'after-revoke');
  if (denied?.type !== 'tool_result') throw new Error('撤权后的调用没有结果');
  expect(denied.result.status).not.toBe('success');
  third.response.complete();
  await kk.waitEvent((event) => event.type === 'idle' && event.threadId === parentId);
}, 1000);

// 新旧 HTTP 发送和停止共用 journal 去重；继续操作的持久收据阻止完成后迟到重试再次启动模型。
test('新旧发送停止入口共用收据并退回草稿，resume 重试不会再启动请求', async () => {
  const model = new ManualModel();
  kited = startKited(() => model);
  const kk = kited;
  const { workspaceId } = await emptyWorkspace(kk, 'project');
  const created = await kk.call('POST', operationPath(workspaceId, 'agent.start'), {
    operationId: 'stop-test-agent',
  });
  expect(created.status).toBe(200);
  const instanceId = created.body.instanceId as string;
  const opening = { operationId: 'same-send', instanceId, text: '保持执行' };
  const firstSend = await kk.call('POST', operationPath(workspaceId, 'agent.send'), opening);
  expect(firstSend.status).toBe(200);
  const first = await model.call(1);
  const oldSend = await kk.call('POST', `/threads/${instanceId}/messages`, { id: opening.operationId, text: opening.text });
  expect(oldSend.status).toBe(200);
  expect(oldSend.body.id).toBe(firstSend.body.id);
  expect((await kk.call('POST', operationPath(workspaceId, 'agent.send'), {
    operationId: 'queued-send', instanceId, text: '待退回',
  })).status).toBe(200);
  const draft = { id: 'unconfirmed', text: '未确认草稿', source: 'human' as const };
  const stop = await kk.call('POST', operationPath(workspaceId, 'agent.stop'), {
    operationId: 'same-stop', instanceId, inputs: [draft],
  });
  expect(stop.status).toBe(200);
  expect(first.signal.aborted).toBe(true);
  expect(stop.body.returned).toEqual([
    { id: 'queued-send', text: '待退回', source: 'human' }, draft,
  ]);
  const oldStop = await kk.call('POST', `/threads/${instanceId}/interrupt`, { id: 'same-stop', inputs: [draft] });
  expect(oldStop.status).toBe(200);
  expect(oldStop.body.returned).toEqual(stop.body.returned);
  const journalPath = join(kk.home, 'sessions', instanceId, 'journal.jsonl');
  expect(diskRecords(journalPath).filter((record) => record.type === 'thread.stopped')).toHaveLength(1);
  expect(model.calls.values).toHaveLength(1);

  expect((await kk.call('POST', `/threads/${instanceId}/messages`, { id: 'needs-resume', text: '故意断流' })).status).toBe(200);
  const failed = await model.call(2);
  failed.response.finish();
  await kk.waitEvent((event) => event.type === 'harness' && event.threadId === instanceId && event.event.type === 'state'
    && event.event.state.waitingForResume);
  const resumed = await kk.call('POST', operationPath(workspaceId, 'agent.resume'), {
    operationId: 'same-resume', instanceId,
  });
  expect(resumed.status).toBe(200);
  const continued = await model.call(3);
  continued.response.complete();
  await kk.waitEvent((event) => event.type === 'idle' && event.threadId === instanceId);
  const retry = await kk.call('POST', operationPath(workspaceId, 'agent.resume'), {
    operationId: 'same-resume', instanceId,
  });
  expect(retry.status).toBe(200);
  expect(retry.body).toEqual(resumed.body);
  expect(model.calls.values).toHaveLength(3);
}, 1000);
