import { afterEach, expect, test } from 'bun:test';
import { existsSync, rmSync } from 'node:fs';
import { join } from 'node:path';
import { startDaemon, type Daemon } from '../../src/daemon.ts';
import { OperationError } from '../../src/errors.ts';
import type { Envelope } from '../../src/events.ts';
import { responsesInput } from '../../src/harness/responses.ts';
import type { Json, ModelItem, ModelRequest, ToolResult } from '../../src/harness/types.ts';
import type { OperationGrant } from '../../src/operations/contract.ts';
import { OperationReceipts } from '../../src/operations/receipts.ts';
import { Store } from '../../src/store.ts';
import type { PendingInput } from '../../src/transcript/protocol.ts';
import { after, call, folderWorkspace, mark, startKited, waitIdle, type Kited } from '../harness.ts';
import { deferred, diskRecords, item, ManualModel } from '../harness-loop.ts';
import { makeTemp, newDir } from '../util.ts';

let kited: Kited | undefined;
afterEach(async () => { await kited?.stop(); kited = undefined; });

const operationPath = (workspaceId: string, name: string) => `/workspaces/${workspaceId}/operations/${name}`;

async function emptyWorkspace(k: Kited, name: string) {
  const registered = await folderWorkspace(k, newDir(k.root, name, { 'base.txt': '原始\n' }));
  return { workspaceId: registered.workspace.id };
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
  const repo = newDir(root, 'project', { 'base.txt': '原始\n' });
  const model = new ManualModel();
  let daemon: Daemon | undefined;
  try {
    daemon = startDaemon({ home, port: 0, lightTasks: false, model: () => model });
    const workspaceId = (await folderWorkspace(daemon, repo)).workspace.id;

    const windowRequest = { operationId: 'create-window', title: '编码线程', presentation: 'window' };
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
      grants: { workspace: 'read', add: { read: [], write: [], network: [], unsandboxed: [] }, remove: { read: [], write: [], network: [], unsandboxed: [] } },
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
    rmSync(root, { recursive: true, force: true });
  }
}, 1000);

// 模型工具到宿主身份、实例来源、授权快照与执行时重验跨模块交接；撤权后旧请求也不能再调用。
test('模型创建记录来源，协作操作受工作区、角色工具与协作范围约束', async () => {
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
  // 只读审查角色用不了协作工具，默认也不带协作操作的授权
  expect(child.config.role.id).toBe('kite.review');
  expect(child.origin).toMatchObject({ instanceId: parentId, callId: 'create-review' });
  const modelCaller = { kind: 'model' as const, instanceId: parentId, turnId: first.request.turnId, callId: 'authorization' };
  await expect(kk.daemon.kite.operations.invoke(modelCaller, otherWorkspaceId, 'agent.list', {}))
    .rejects.toMatchObject({ outcome: 'denied' });
  await expect(kk.daemon.kite.operations.invoke({ kind: 'model', instanceId: child.id }, workspaceId, 'agent.list', {}))
    .rejects.toMatchObject({ outcome: 'denied' });
  await expect(kk.daemon.kite.operations.invoke(modelCaller, workspaceId, 'agent.send', {
    operationId: 'send-unrelated', instanceId: unrelatedId, text: '不应发送',
  })).rejects.toMatchObject({ outcome: 'denied' });
  second.response.complete();
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

const textItem = (id: string, text: string): ModelItem => ({
  id, raw: { type: 'message', role: 'assistant', content: [{ type: 'output_text', text }] },
});
const resultOf = (request: ModelRequest, callId: string): ToolResult | undefined => {
  const found = request.history.find((entry) => entry.type === 'tool_result' && entry.callId === callId);
  return found?.type === 'tool_result' ? found.result : undefined;
};
const inputsOf = (request: ModelRequest) => request.history.flatMap((entry) => entry.type === 'input' ? [entry.input] : []);
/** 按 Responses 格式交给模型的用户侧正文，即模型实际读到的文字。 */
const userTexts = (request: ModelRequest): string[] => responsesInput(request.history).flatMap((message) =>
  message.role === 'user' ? (message.content as Array<{ type: string; text?: string }>).flatMap((part) => part.text ?? []) : []);
/** 宿主投给线程的东西：Kite 来源的输入与通知。代理自己的工具结果、调用参数里也会出现子代理的 ID，不算。 */
const hostDeliveries = (request: ModelRequest): string[] => request.history.flatMap((entry) =>
  entry.type === 'input' && entry.input.source === 'kite' ? [entry.input.text] : entry.type === 'notification' ? [entry.text] : []);

/** 每个线程一个手动模型，kited 与测试都按实例 ID 取同一个，先取的先建。 */
function threadModels() {
  const models = new Map<string, ManualModel>();
  const of = (id: string) => {
    let model = models.get(id);
    if (!model) models.set(id, model = new ManualModel());
    return model;
  };
  return { of, factory: (thread: { id: string }) => of(thread.id) };
}

async function childOf(k: Kited, workspaceId: string, callId: string): Promise<{ id: string }> {
  const aggregate = await k.call('GET', '/workspaces');
  const workspace = aggregate.body.find((entry: { workspace: { id: string } }) => entry.workspace.id === workspaceId);
  const child = workspace.instances.find((instance: { origin?: { callId: string } }) => instance.origin?.callId === callId);
  if (!child) throw new Error(`调用 ${callId} 没有建出子代理`);
  return child;
}

/*
 * 几个部分的配合：agent_start 带 prompt 时子代理以代理来信立即开工；子代理回合收尾时运行时的 idle 回调触发回报，
 * 回报经 kite.reply 读子代理的显示投影取最后的回复，作为 Kite 来源的输入投给已经空闲的交代方，让它开始新回合。
 * 交给模型（Responses 格式）时回报开头写明是 Kite 自动发的，子代理收到的 prompt 包在交代方标题的代理来信里。
 * 提问不阻塞（docs/实例操作.md「子代理回报」：卡在等用户回应不算结束）：子代理发出 question 后回合照常结束，
 * 这时还有没回应的提问，不回报、交代方留着；用户回应后结果作为来源为 kite 的输入开始新回合，这一回合完成才回报。
 * 不阻塞的提问、回应投递与回报三处配合，才知道交代方是在哪一回合收到回报的。
 */
test('子代理带 prompt 开工，提问没回应时回合结束不回报；用户回应后那一回合完成，回报投给已空闲的交代方并开始新回合，只这一次，正文含子代理实例 ID 与回应后的最后回复且标明由 Kite 发出', async () => {
  const models = threadModels();
  kited = startKited(models.factory);
  const kk = kited;
  const { workspaceId } = await emptyWorkspace(kk, 'main');
  const parent = await kk.call('POST', operationPath(workspaceId, 'agent.start'), {
    operationId: 'parent-agent', title: '统筹', prompt: '拆给子代理做',
  });
  expect(parent.status).toBe(200);
  const parentId = parent.body.instanceId as string;
  const a = models.of(parentId);
  const a1 = await a.call(1);
  await a1.response.emit({ type: 'item', item: calledItem('start-child', 'agent_start', { title: '数行数', prompt: '数一下 base.txt 有几行' }) });
  a1.response.complete();
  const a2 = await a.call(2);
  const child = await childOf(kk, workspaceId, 'start-child');
  const b = models.of(child.id);
  const b1 = await b.call(1);
  expect(inputsOf(b1.request)).toEqual([expect.objectContaining({
    text: '数一下 base.txt 有几行', source: 'agent', from: { kind: 'agent', instance: parentId, title: '统筹' },
  })]);
  expect(userTexts(b1.request)).toContainEqual(expect.stringContaining('<agent-message from="统筹">'));
  let since = mark(kk);
  await a2.response.emit({ type: 'item', item: textItem('parent-waits', '等它做完') });
  a2.response.complete();
  await waitIdle(kk, parentId, since);

  // 子代理先问用户：工具立即返回，回合接着结束，提问还挂着。这时回报的话，交代方会拿着「先问问」开始新回合。
  since = mark(kk);
  await b1.response.emit({ type: 'item', item: calledItem('child-ask', 'question', { questions: [
    { question: '空行算不算？', multiSelect: false, options: [{ label: '算', description: '按 wc -l' }, { label: '不算', description: '只数有字的行' }] },
  ] }) });
  b1.response.complete();
  const asked = await kk.waitEvent((event) => event.type === 'asks' && event.threadId === child.id && event.asks.length > 0 && after(kk, since)(event));
  const ask = (asked as Extract<Envelope, { type: 'asks' }>).asks[0]!;
  const b2 = await b.call(2);
  expect(resultOf(b2.request, 'child-ask')?.status).toBe('success');
  await b2.response.emit({ type: 'item', item: textItem('child-asks', '先问问用户空行算不算') });
  b2.response.complete();
  await waitIdle(kk, child.id, since);

  // 用户回应：回答作为 kite 来源的输入开始子代理的新回合，这一回合完成后才回报。
  expect((await kk.call('POST', `/threads/${child.id}/waiting/${ask.id}`, { answers: [{ selected: ['算'] }] })).status).toBe(200);
  const b3 = await b.call(3);
  expect(inputsOf(b3.request).at(-1)).toMatchObject({ source: 'kite' });
  const reply = '一共 1 行，写的是原始。';
  await b3.response.emit({ type: 'item', item: textItem('child-reply', reply) });
  b3.response.complete();
  const a3 = await a.call(3);
  expect(a3.request.turnId).not.toBe(a1.request.turnId);
  const reports = hostDeliveries(a3.request);
  expect(reports).toHaveLength(1);
  expect(reports[0]).toContain(child.id);
  expect(reports[0]).toContain('数行数');
  expect(reports[0]).toContain(reply);
  expect(reports[0]).not.toContain('先问问用户');
  const seen = userTexts(a3.request).filter((text) => text.includes(child.id));
  expect(seen).toHaveLength(1);
  expect(seen[0]).toMatch(/^【?这条消息由 Kite 自动发出，不是用户说的话/);
  since = mark(kk);
  a3.response.complete();
  await waitIdle(kk, parentId, since);
}, 1000);

/*
 * 几个部分的配合：停止操作要在子代理回合收尾之前登记停止者，收尾时的 idle 回调据此不回报给停下它的交代方；
 * 用户经 HTTP 发的消息与代理来信都要经 sendInput 登记，用户在交代的回合里发了消息，这一回合就归用户。
 * 两种都不回报，没有回报只能由之后一次照常的回报作界：交代方的历史从头到尾只收到这一条。
 * 真实出过的 bug：交代方对已经空闲的子代理 agent_stop（什么都没停），停止者照样记下、没有回合收尾来消掉它，
 * 落到之后再交代的那一回合上，被当成交代方自己停下的，回合完成后不回报。
 */
test('交代方自己 agent_stop 停下的回合与用户发过消息的回合都不回报；对已空闲的子代理 agent_stop 之后再交代，回合完成照常回报一次', async () => {
  const models = threadModels();
  kited = startKited(models.factory);
  const kk = kited;
  const { workspaceId } = await emptyWorkspace(kk, 'main');
  const parent = await kk.call('POST', operationPath(workspaceId, 'agent.start'), {
    operationId: 'parent-agent', title: '统筹', prompt: '开个子代理再停掉',
  });
  expect(parent.status).toBe(200);
  const parentId = parent.body.instanceId as string;
  const a = models.of(parentId);
  /** 交代方这一请求调一次工具，下一请求拿到结果后结束回合；返回那次工具结果。 */
  const delegate = async (number: number, callId: string, name: string, args: Json) => {
    const request = await a.call(number);
    await request.response.emit({ type: 'item', item: calledItem(callId, name, args) });
    request.response.complete();
    const next = await a.call(number + 1);
    const since = mark(kk);
    next.response.complete();
    await waitIdle(kk, parentId, since);
    return next.request.history.find((entry) => entry.type === 'tool_result' && entry.callId === callId);
  };

  // 交代方自己停下子代理：停下的回合不回报给它。
  const a1 = await a.call(1);
  await a1.response.emit({ type: 'item', item: calledItem('start-child', 'agent_start', { title: '慢活', prompt: '慢慢做' }) });
  a1.response.complete();
  await a.call(2);
  const child = await childOf(kk, workspaceId, 'start-child');
  const b = models.of(child.id);
  const b1 = await b.call(1);
  const stopped = await delegate(2, 'stop-child', 'agent_stop', { instanceId: child.id });
  expect(stopped).toMatchObject({ type: 'tool_result', result: { status: 'success' } });
  expect(b1.signal.aborted).toBe(true);

  // 交代之后用户也给子代理发了消息：这一回合归用户，不回报。
  expect((await kk.call('POST', `/threads/${parentId}/messages`, { text: '让它接着做' })).status).toBe(200);
  const sent = await delegate(4, 'send-child', 'agent_send', { instanceId: child.id, text: '接着做' });
  expect(sent).toMatchObject({ type: 'tool_result', result: { status: 'success' } });
  const b2 = await b.call(2);
  expect((await kk.call('POST', `/threads/${child.id}/messages`, { text: '这个我自己盯着' })).status).toBe(200);
  await b2.response.emit({ type: 'item', item: textItem('child-ack', '收到') });
  b2.response.complete();
  const b3 = await b.call(3);
  expect(inputsOf(b3.request)).toContainEqual(expect.objectContaining({ text: '这个我自己盯着', source: 'human' }));
  let since = mark(kk);
  await b3.response.emit({ type: 'item', item: textItem('child-for-user', '按你说的改好了') });
  b3.response.complete();
  await waitIdle(kk, child.id, since);

  // 子代理已经空闲时交代方停它：什么都没停，子代理不起新请求。
  expect((await kk.call('POST', `/threads/${parentId}/messages`, { text: '先停掉它' })).status).toBe(200);
  expect(await delegate(6, 'stop-idle', 'agent_stop', { instanceId: child.id })).toMatchObject({ type: 'tool_result' });

  // 作界：再交代一次，回合完成后照常回报（不被上一步当成交代方自己停下的），且交代方历史里只有这一条回报。
  expect((await kk.call('POST', `/threads/${parentId}/messages`, { text: '再交代一次' })).status).toBe(200);
  await delegate(8, 'send-again', 'agent_send', { instanceId: child.id, text: '最后再做一次' });
  const b4 = await b.call(4);
  expect(b.calls.values).toHaveLength(4);
  await b4.response.emit({ type: 'item', item: textItem('child-final', '最后一次做完了') });
  b4.response.complete();
  const a10 = await a.call(10);
  const reports = hostDeliveries(a10.request).filter((text) => text.includes(child.id));
  expect(reports).toHaveLength(1);
  expect(reports[0]).toContain('最后一次做完了');
  expect(reports[0]).not.toContain('按你说的改好了');
  since = mark(kk);
  a10.response.complete();
  await waitIdle(kk, parentId, since);
}, 1000);

/** 操作工具失败时输出 {error, outcome}，取其中的 outcome。 */
const failedOutcome = (result: ToolResult | undefined) => {
  if (result?.status !== 'error') throw new Error(`工具应失败：${JSON.stringify(result)}`);
  return (JSON.parse(result.output) as { outcome: string }).outcome;
};

/*
 * 几个部分的配合：协作范围是授权的目标，经 operation-grants 把 agent.stop 等几项的目标改成同工作区后，下一回合的 agent_stop 才能对准非后代；
 * 超出后代范围的停止在操作入口里经 Waits.approve 挂在调用方线程上，线程状态里出现这项审批，
 * 用户经 POST /threads/:id/waiting/:id 回应后工具调用才失败或继续，对方的回合随之照跑或真的被停下。
 * 停下时对方队里还有用户排着的话：agent_stop 带着停止方（by 是 A）经操作、主循环的停止收据到显示投影，
 * 退回只看停止方，留在队里的输入决定显示的能停、等继续和下一条是不是插话，要整条跑起来才知道配合得对不对。
 * 真实出过的 bug：代理用 agent_stop 停下别的线程，用户排在那个线程队里的话被退进了停止方的工具结果，待发送里没了、也不回输入框；
 * 停下后队里留着输入时停止按钮一直在、再停什么也不做；用户再发一条被标成插话（midTurn），因为队里有留下的消息。
 */
test('同工作区范围的代理停非后代的代理要逐次等用户批准：拒绝时工具失败且对方照跑，批准后对方停下；仅后代范围下直接拒绝、不问；停下时用户排在对方队里的话不退给停止方，留在队里等继续、不能再停，用户再发一条开新一轮、不算插话', async () => {
  const models = threadModels();
  kited = startKited(models.factory);
  const kk = kited;
  const { workspaceId } = await emptyWorkspace(kk, 'main');
  const start = async (operationId: string) => {
    const started = await kk.call('POST', operationPath(workspaceId, 'agent.start'), { operationId });
    expect(started.status).toBe(200);
    return started.body.instanceId as string;
  };
  const aId = await start('agent-a');
  const bId = await start('agent-b');
  const a = models.of(aId);
  expect((await kk.call('POST', `/threads/${bId}/messages`, { text: '一直跑' })).status).toBe(200);
  const running = await models.of(bId).call(1);

  const isApproval = (since: number) => (e: Envelope) => e.type === 'waiting' && e.threadId === aId && !!e.waiting && after(kk, since)(e);
  const approval = async (since: number) => {
    const waiting = (await kk.waitEvent(isApproval(since)) as Extract<Envelope, { type: 'waiting' }>).waiting!;
    if (waiting.kind !== 'approval') throw new Error(`应是审批：${JSON.stringify(waiting)}`);
    return waiting;
  };
  const waitingOf = async () => (await kk.call('GET', `/threads/${aId}/state`)).body.waiting;
  const respond = (id: string, decision: string) => kk.call('POST', `/threads/${aId}/waiting/${id}`, { decision });
  const stopB = async (request: Awaited<ReturnType<ManualModel['call']>>, callId: string) => {
    const since = mark(kk);
    await request.response.emit({ type: 'item', item: calledItem(callId, 'agent_stop', { instanceId: bId }) });
    request.response.complete();
    return since;
  };

  // 仅后代（默认）：B 不是 A 建的，直接拒绝，不挂审批。
  expect((await kk.call('POST', `/threads/${aId}/messages`, { text: '停掉 B' })).status).toBe(200);
  let since = await stopB(await a.call(1), 'stop-out-of-scope');
  const refused = await a.call(2);
  expect(failedOutcome(resultOf(refused.request, 'stop-out-of-scope'))).toBe('denied');
  expect(kk.events.filter(isApproval(since))).toEqual([]);
  expect(running.signal.aborted).toBe(false);
  since = mark(kk);
  refused.response.complete();
  await waitIdle(kk, aId, since);

  // 改成同工作区：把目标是仅后代的那几项授权的目标都改成同工作区。
  const grantsPath = `/instances/${aId}/operation-grants`;
  const grants = await kk.call('GET', grantsPath);
  const widened = (grants.body.grants as OperationGrant[]).map((grant) =>
    'targets' in grant && grant.targets.kind === 'descendants' ? { ...grant, targets: { kind: 'workspace' } } : grant);
  expect(widened).toContainEqual({ operation: 'agent.stop', targets: { kind: 'workspace' } });
  expect((await kk.call('PUT', grantsPath, { expectedRevision: grants.body.revision, grants: widened })).status).toBe(200);

  // 同工作区：每次停止都先问；拒绝时这次工具调用失败，B 照跑。
  expect((await kk.call('POST', `/threads/${aId}/messages`, { text: '还是停掉 B' })).status).toBe(200);
  const first = await approval(await stopB(await a.call(3), 'stop-denied'));
  expect(first.mustAsk).toBe(true);
  expect(await waitingOf()).toEqual(first);
  expect(running.signal.aborted).toBe(false);
  expect(await respond(first.id, 'deny')).toEqual({ status: 200, body: { ok: true } });
  const denied = await a.call(4);
  expect(failedOutcome(resultOf(denied.request, 'stop-denied'))).toBe('denied');
  expect(await waitingOf()).toBeUndefined();
  expect(running.signal.aborted).toBe(false);

  // 再调一次，批准这一次后 B 停下。停之前用户给 B 排了一条话。
  expect((await kk.call('POST', `/threads/${bId}/messages`, { id: 'user-queued', text: '用户排着的话' })).status).toBe(200);
  const second = await approval(await stopB(denied, 'stop-approved'));
  expect(second.id).not.toBe(first.id);
  expect(running.signal.aborted).toBe(false);
  const stopping = mark(kk);
  expect(await respond(second.id, 'once')).toEqual({ status: 200, body: { ok: true } });
  const approved = await a.call(5);
  expect(resultOf(approved.request, 'stop-approved')?.status).toBe('success');
  expect(running.signal.aborted).toBe(true);
  // A 停 B 只退 A 自己发去的，用户的话不进 A 的工具结果，留在 B 的待发送里；B 等继续，停止按钮没了。
  expect(JSON.parse(resultOf(approved.request, 'stop-approved')!.output)).toEqual({ returned: [] });
  await kk.waitEvent((event) => after(kk, stopping)(event) && event.type === 'harness' && event.threadId === bId
    && event.event.type === 'state' && event.event.state.waitingForResume);
  const stoppedB = (await kk.call('GET', `/threads/${bId}/history`)).body;
  expect(stoppedB.pending).toEqual([expect.objectContaining({ id: 'user-queued', text: '用户排着的话', source: 'human' })]);
  expect(stoppedB.state).toMatchObject({ busy: false, waitingForResume: true, capabilities: { interrupt: false } });
  since = mark(kk);
  approved.response.complete();
  await waitIdle(kk, aId, since);

  // 用户再发一条：留下的那条先交给模型，新的这条开新一轮，待发送和记录里都不算插话。
  const pendingSeen: PendingInput[] = [];
  const unsubscribe = kk.daemon.kite.events.subscribe((event) => 'threadId' in event && event.threadId === bId,
    (event) => { if (event.type === 'thread.pending') pendingSeen.push(...event.pending); });
  since = mark(kk);
  expect((await kk.call('POST', `/threads/${bId}/messages`, { id: 'user-again', text: '用户再发一条' })).status).toBe(200);
  const resumedB = await models.of(bId).call(2);
  unsubscribe();
  expect(inputsOf(resumedB.request).map((input) => input.id).slice(-2)).toEqual(['user-queued', 'user-again']);
  expect([...new Set(pendingSeen.filter((input) => input.id === 'user-again').map((input) => input.midTurn))]).toEqual([false]);
  resumedB.response.complete();
  await waitIdle(kk, bId, since);
  const records = (await kk.call('GET', `/threads/${bId}/history`)).body.records as Array<{ block: { type: string; id?: string; midTurn?: boolean } }>;
  expect(records.find((record) => record.block.type === 'human' && record.block.id === 'user-again')?.block.midTurn).toBe(false);
}, 1000);
