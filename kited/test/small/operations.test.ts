import { afterEach, expect, test } from 'bun:test';
import { existsSync, rmSync } from 'node:fs';
import { join } from 'node:path';
import { startDaemon, type Daemon } from '../../src/daemon.ts';
import type { Json, ModelItem } from '../../src/harness/types.ts';
import { operationContracts } from '../../src/operation-contract.ts';
import { call, registerCheckout, startKited, type Kited } from '../harness.ts';
import { diskRecords, item, ManualModel } from '../harness-loop.ts';
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

// HTTP、SQLite 收据和窗口目录跨重启交接：同一创建操作只生成一个实例和窗口，查询不能唤醒线程。
test('agent.start 跨重启重试复用实例与窗口，后台实例不建窗口且 list 只读', async () => {
  const root = makeTemp();
  const home = join(root, 'kite');
  const repo = newRepo(root, 'project', { 'base.txt': '原始\n' });
  const model = new ManualModel();
  let daemon: Daemon | undefined;
  try {
    daemon = startDaemon({ home, port: 0, model: () => model });
    const checkout = await call(daemon.url, 'POST', '/checkouts', { path: repo });
    expect(checkout.status).toBe(200);
    const workspaceId = checkout.body.workspace.id as string;
    const catalog = await call(daemon.url, 'GET', '/operations');
    expect(catalog.status).toBe(200);
    expect(catalog.body.map((entry: { name: string }) => entry.name).sort()).toEqual(Object.keys(operationContracts).sort());

    const windowRequest = { operationId: 'create-window', definitionId: 'kite.agent.coding', title: '编码线程' };
    const backgroundRequest = { operationId: 'create-background', definitionId: 'kite.agent.review', presentation: 'background' };
    const window = await call(daemon.url, 'POST', operationPath(workspaceId, 'agent.start'), windowRequest);
    const background = await call(daemon.url, 'POST', operationPath(workspaceId, 'agent.start'), backgroundRequest);
    expect(window.status).toBe(200);
    expect(background.status).toBe(200);
    const windowId = window.body.windowId as string;
    const codingId = window.body.instanceId as string;
    const reviewId = background.body.instanceId as string;
    expect(typeof windowId).toBe('string');
    expect(background.body.windowId).toBeUndefined();
    const codingExecution = await call(daemon.url, 'GET', `/instances/${codingId}/execution-grants`);
    const reviewExecution = await call(daemon.url, 'GET', `/instances/${reviewId}/execution-grants`);
    expect(codingExecution.body.grants).toEqual({ workspace: 'write', read: [], write: [], network: [] });
    expect(reviewExecution.body.grants).toEqual({ workspace: 'read', read: [], write: [], network: [] });
    const revisedExecution = await call(daemon.url, 'PUT', `/instances/${codingId}/execution-grants`, {
      expectedRevision: codingExecution.body.revision,
      grants: { workspace: 'read', read: [], write: [], network: [] },
    });
    expect(revisedExecution.status).toBe(200);
    const journalPath = join(home, 'sessions', codingId, 'journal.jsonl');
    expect(existsSync(journalPath)).toBe(false);
    const listed = await call(daemon.url, 'POST', operationPath(workspaceId, 'agent.list'), {});
    expect(listed.status).toBe(200);
    expect(listed.body.agents.map((agent: { instanceId: string }) => agent.instanceId).sort()).toEqual([codingId, reviewId].sort());
    expect(listed.body.agents.find((agent: { instanceId: string }) => agent.instanceId === reviewId).presentation).toBe('background');
    expect(model.calls.values).toHaveLength(0);
    expect(existsSync(journalPath)).toBe(false);
    await daemon.stop();
    daemon = undefined;

    daemon = startDaemon({ home, port: 0, model: () => model });
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
    operationId: 'parent-agent', definitionId: 'kite.agent.coding',
  });
  const unrelated = await kk.call('POST', operationPath(workspaceId, 'agent.start'), {
    operationId: 'unrelated-agent', definitionId: 'kite.agent.coding', presentation: 'inline',
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
    definitionId: 'kite.agent.review', presentation: 'background',
  }) });
  first.response.complete();
  const second = await model.call(2);
  const aggregate = await kk.call('GET', '/workspaces');
  const workspace = aggregate.body.find((entry: { workspace: { id: string } }) => entry.workspace.id === workspaceId);
  const child = workspace.instances.find((instance: { definitionId: string }) => instance.definitionId === 'kite.agent.review');
  if (!child) throw new Error('模型没有创建审查实例');
  expect(child.origin).toMatchObject({ instanceId: parentId, callId: 'create-review' });
  const modelCaller = { kind: 'model' as const, instanceId: parentId, turnId: first.request.turnId, callId: 'authorization' };
  await expect(kk.daemon.kite.operations.invoke(modelCaller, otherWorkspaceId, 'agent.list', {}))
    .rejects.toMatchObject({ outcome: 'denied' });
  await expect(kk.daemon.kite.operations.invoke({ kind: 'model', instanceId: child.id }, workspaceId, 'agent.list', {}))
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
  expect(denied?.type).toBe('tool_result');
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
    operationId: 'stop-test-agent', definitionId: 'kite.agent.coding',
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
