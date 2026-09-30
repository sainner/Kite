import { afterEach, expect, test } from 'bun:test';
import { randomUUID } from 'node:crypto';
import { existsSync, rmSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import type { AgentDefinition } from '../../src/agent-definition.ts';
import { startDaemon, type Daemon } from '../../src/daemon.ts';
import type { Envelope } from '../../src/events.ts';
import { restoreContext } from '../../src/harness/context/assembler.ts';
import type { Json, ModelItem, ThreadNotification } from '../../src/harness/types.ts';
import { operationToolNames } from '../../src/operation-contract.ts';
import { pluginDefinition } from '../../src/plugins.ts';
import { call, registerCheckout, startKited, type Kited } from '../harness.ts';
import { diskRecords, item, ManualModel, Seen } from '../harness-loop.ts';
import { makeTemp, newRepo, read } from '../util.ts';

let kited: Kited | undefined;
afterEach(async () => { await kited?.stop(); kited = undefined; });

function calledItem(id: string, name: string, args: Json): ModelItem {
  return { ...item(id, name), call: { id, name, arguments: args } };
}

function notificationMetadata(notification: ThreadNotification): Omit<ThreadNotification, 'context'> {
  const { context: _context, ...metadata } = notification;
  return metadata;
}

function revisedAgent(agent: AgentDefinition, model: string, tools: AgentDefinition['tools']): AgentDefinition {
  return {
    ...structuredClone(agent),
    model: { model, reasoning: 'high' },
    tools,
    maxRequestsPerTurn: 2,
    context: {
      ...structuredClone(agent.context),
      id: `${agent.context.id}.edited`,
      blocks: [...agent.context.blocks, {
        type: 'paragraph', id: 'updated-rule', title: '更新规则',
        parts: [{ type: 'text', text: '新规则：只读取，不再修改文件。' }],
      }],
    },
  };
}

// HTTP/SQLite 配置提交、模型流、受管工具和 journal 在请求边界交接；旧请求必须执行原来允许的 patch。
test('运行中换配置不唤醒或取消请求，旧工具完成后下一请求采用新配置并追加上下文通知', async () => {
  const oldModel = new ManualModel();
  const newModel = new ManualModel();
  kited = startKited((thread) => (thread.config.agent as AgentDefinition).model.model === 'test-new-model' ? newModel : oldModel);
  const kk = kited;
  const repo = newRepo(kk.root, 'project', { 'base.txt': '原始\n' });
  const registered = await registerCheckout(kk, repo);
  const workspaceId = registered.workspace.id;
  const opened = await kk.call('POST', `/workspaces/${workspaceId}/windows`, {
    id: randomUUID(), content: { kind: 'create', definitionId: 'kite.agent.coding' },
  });
  expect(opened.status).toBe(200);
  const threadId = opened.body.target.instanceId as string;
  const initial = await kk.call('GET', `/instances/${threadId}/agent-config`);
  expect(initial.status).toBe(200);
  const original = structuredClone(initial.body.instance.config.agent) as AgentDefinition;
  const codingDefinition = pluginDefinition('kite.agent.coding').agent;
  if (!codingDefinition) throw new Error('缺少 coding agent 定义');
  expect(original.tools).toEqual(codingDefinition.tools);
  expect(original.model).toEqual(codingDefinition.model);
  for (const block of codingDefinition.context.blocks) expect(original.context.blocks).toContainEqual(block);

  const sent = await kk.call('POST', `/threads/${threadId}/messages`, { id: randomUUID(), text: '创建一个文件' });
  expect(sent.status).toBe(200);
  const first = await oldModel.call(1);
  expect(first.request.allowedTools).toEqual(['read', 'patch', 'shell', ...operationToolNames]);
  const changed = revisedAgent(original, 'test-new-model', ['read']);
  const updated = await kk.call('PUT', `/instances/${threadId}/agent-config`, {
    expectedRevision: initial.body.revision, agent: changed,
  });
  expect(updated.status).toBe(200);
  expect(updated.body.revision).not.toBe(initial.body.revision);
  expect(newModel.calls.values).toHaveLength(0);
  expect(first.signal.aborted).toBe(false);

  const patch = calledItem('old-patch', 'patch', {
    operations: [{ type: 'create_file', path: 'from-old-request.txt', diff: '+旧请求仍可写入\n+' }],
  });
  await first.response.emit({ type: 'item', item: patch });
  first.response.complete();
  const second = await newModel.call(1);
  expect(read(join(repo, 'base.txt'))).toBe('原始\n');
  const thread = await kk.call('GET', `/threads/${threadId}`);
  expect(thread.body.config.agent).toEqual(changed);
  expect(read(join(thread.body.workspace.cwd, 'from-old-request.txt'))).toBe('旧请求仍可写入\n');
  expect(second.request.instructions).toBe(first.request.instructions);
  expect(second.request.tools.map((value) => value.name)).toEqual(first.request.tools.map((value) => value.name));
  expect(second.request.allowedTools).toEqual(['read']);
  expect(second.request.history.slice(0, first.request.history.length)).toEqual(first.request.history);
  expect(second.request.history).toContainEqual(expect.objectContaining({
    type: 'tool_result', callId: 'old-patch', result: expect.objectContaining({ status: 'success' }),
  }));
  const notices = second.request.history.filter((entry) => entry.type === 'notification');
  expect(notices.some((entry) => entry.text.includes('新规则：只读取'))).toBe(true);

  const records = diskRecords(join(kk.home, 'sessions', threadId, 'journal.jsonl'));
  const configurations = records.filter((record) => record.type === 'request.configured');
  const starts = records.filter((record) => record.type === 'request.started');
  expect(configurations).toHaveLength(2);
  expect(starts).toHaveLength(2);
  const delivered = starts[1]!.notifications ?? [];
  expect(delivered).toHaveLength(notices.length);
  for (const entry of notices) {
    const source = delivered.find((notice) => notice.id === entry.notification.id);
    if (!source) throw new Error(`缺少通知快照：${entry.notification.id}`);
    expect(entry.notification).toEqual(notificationMetadata(source));
    expect(entry.text).toBe(restoreContext(source.context).instructions);
  }
  expect(starts.map((record) => record.configurationId)).toEqual(configurations.map((record) => record.snapshot.id));
  expect(configurations[0]!.snapshot.settings.allowedTools).toEqual(['read', 'patch', 'shell', ...operationToolNames]);
  expect(configurations[1]!.snapshot.settings).toMatchObject({
    model: { model: 'test-new-model', reasoning: 'high' }, maxRequestsPerTurn: 2, allowedTools: ['read'],
  });
  second.response.complete();
  await kk.waitEvent((event) => event.type === 'idle' && event.threadId === threadId);
}, 1000);

// SQLite 通知游标与 journal 原子落盘要跨重启去重；review 的工具限制还要经过真实工作树执行验证。
test('闲置时改配置跨重启只投递一次，review 输出 patch 和 shell 也不能改文件', async () => {
  const root = makeTemp();
  const home = join(root, 'kite');
  const repo = newRepo(root, 'project', { 'base.txt': '原始\n' });
  const firstModel = new ManualModel();
  let daemon: Daemon | undefined;
  try {
    daemon = startDaemon({ home, port: 0, model: () => firstModel });
    const firstEvents = new Seen<Envelope>();
    daemon.kite.bus.subscribe(undefined, (event) => firstEvents.add(event));
    const checkout = await call(daemon.url, 'POST', '/checkouts', { path: repo });
    expect(checkout.status).toBe(200);
    const workspaceId = checkout.body.workspace.id as string;
    const opened = await call(daemon.url, 'POST', `/workspaces/${workspaceId}/windows`, {
      id: randomUUID(), content: { kind: 'create', definitionId: 'kite.agent.coding' },
    });
    expect(opened.status).toBe(200);
    const codingId = opened.body.target.instanceId as string;
    expect((await call(daemon.url, 'POST', `/threads/${codingId}/messages`, { id: randomUUID(), text: '先建立历史' })).status).toBe(200);
    const first = await firstModel.call(1);
    first.response.complete();
    await firstEvents.wait((event) => event.type === 'idle' && event.threadId === codingId);
    const initial = await call(daemon.url, 'GET', `/instances/${codingId}/agent-config`);
    const changed = revisedAgent(structuredClone(initial.body.instance.config.agent) as AgentDefinition, 'after-restart', ['read']);
    const updated = await call(daemon.url, 'PUT', `/instances/${codingId}/agent-config`, {
      expectedRevision: initial.body.revision, agent: changed,
    });
    expect(updated.status).toBe(200);
    expect(firstModel.calls.values).toHaveLength(1);
    const pending = structuredClone(daemon.kite.store.instanceNotifications(codingId, 0));
    expect(pending).toHaveLength(1);
    const firstNotice = pending[0]!;
    expect(firstNotice.sequence).toBeGreaterThan(0);
    expect(restoreContext(firstNotice.context).instructions).toContain('after-restart');
    await daemon.stop();
    daemon = undefined;

    const resumedModel = new ManualModel();
    const reviewModel = new ManualModel();
    daemon = startDaemon({ home, port: 0, model: (thread) => thread.definitionId === 'kite.agent.review' ? reviewModel : resumedModel });
    expect(daemon.kite.store.instanceNotifications(codingId, 0)).toEqual(pending);
    const secondEvents = new Seen<Envelope>();
    daemon.kite.bus.subscribe(undefined, (event) => secondEvents.add(event));
    const resumed = await call(daemon.url, 'POST', `/threads/${codingId}/messages`, { id: randomUUID(), text: '重启后继续' });
    expect(resumed.status).toBe(200);
    const second = await resumedModel.call(1);
    expect(second.request.instructions).toBe(first.request.instructions);
    const updates = second.request.history.filter((entry) => entry.type === 'notification');
    const durableUpdates = updates.filter((entry) => entry.notification.sequence !== undefined);
    expect(durableUpdates).toHaveLength(1);
    expect(durableUpdates[0]!.notification).toEqual(notificationMetadata(firstNotice));
    const deliveredAfterRestart = diskRecords(join(home, 'sessions', codingId, 'journal.jsonl'))
      .filter((record) => record.type === 'request.started').at(-1)!.notifications ?? [];
    expect(deliveredAfterRestart).toHaveLength(updates.length);
    for (const update of updates) {
      const source = deliveredAfterRestart.find((notice) => notice.id === update.notification.id);
      if (!source) throw new Error(`缺少通知快照：${update.notification.id}`);
      expect(update.notification).toEqual(notificationMetadata(source));
      expect(update.text).toBe(restoreContext(source.context).instructions);
    }
    expect(updates.some((entry) => entry.text.includes('新规则：只读取'))).toBe(true);
    second.response.complete();
    await secondEvents.wait((event) => event.type === 'idle' && event.threadId === codingId);

    const threadView = await call(daemon.url, 'GET', `/threads/${codingId}`);
    const cwd = threadView.body.workspace.cwd as string;
    writeFileSync(join(cwd, 'AGENTS.md'), '后续材料：只供第三次请求读取\n');
    const later: AgentDefinition = structuredClone(changed);
    later.model.model = 'later-model';
    later.context.id += '.later';
    later.context.blocks.push({
      type: 'condition', id: 'cwd-choice', title: '工作区条件', variable: 'environment.cwd',
      cases: [{ id: 'current', title: '当前工作区', equals: cwd, blocks: [{
        type: 'paragraph', id: 'selected-rule', title: '选中规则',
        parts: [{ type: 'text', text: '条件分支：当前工作区' }],
      }] }],
      otherwise: { id: 'other', title: '其他目录', blocks: [] },
    });
    const laterUpdated = await call(daemon.url, 'PUT', `/instances/${codingId}/agent-config`, {
      expectedRevision: updated.body.revision, agent: later,
    });
    expect(laterUpdated.status).toBe(200);
    expect(daemon.kite.store.instanceNotifications(codingId, 0)[0]).toEqual(firstNotice);

    const thirdEventStart = secondEvents.values.length;
    expect((await call(daemon.url, 'POST', `/threads/${codingId}/messages`, { id: randomUUID(), text: '再继续一次' })).status).toBe(200);
    const third = await resumedModel.call(2);
    expect(third.request.history.filter((entry) => entry.type === 'notification' && entry.notification.id === firstNotice.id))
      .toEqual([durableUpdates[0]!]);
    expect(third.request.history.some((entry) => entry.type === 'notification' && entry.text.includes('后续材料：只供第三次请求读取'))).toBe(true);
    const codingRecords = diskRecords(join(home, 'sessions', codingId, 'journal.jsonl'));
    const codingStarts = codingRecords.filter((record) => record.type === 'request.started');
    expect(codingStarts.at(-2)!.notifications).toEqual(deliveredAfterRestart);
    expect(codingStarts.at(-1)!.notifications?.some((notice) => notice.id === firstNotice.id)).toBe(false);
    expect(codingStarts.at(-1)!.notifications?.some((notice) => notice.sequence! > firstNotice.sequence!)).toBe(true);
    const contextRecords = codingRecords.filter((record) => record.type === 'context.prepared');
    const latestContext = restoreContext(contextRecords.at(-1)!.snapshot);
    expect(latestContext.instructions).toContain('条件分支：当前工作区');
    expect(latestContext.blocks.some((block) => block.type === 'condition' && block.branchId === 'current')).toBe(true);
    third.response.complete();
    await secondEvents.wait((event) => event.type === 'idle' && event.threadId === codingId
      && secondEvents.values.indexOf(event) >= thirdEventStart);

    const review = await call(daemon.url, 'POST', `/workspaces/${workspaceId}/windows`, {
      id: randomUUID(), content: { kind: 'create', definitionId: 'kite.agent.review' },
    });
    expect(review.status).toBe(200);
    const reviewId = review.body.target.instanceId as string;
    const reviewConfig = await call(daemon.url, 'GET', `/instances/${reviewId}/agent-config`);
    const reviewAgent = structuredClone(reviewConfig.body.instance.config.agent) as AgentDefinition;
    const reviewDefinition = pluginDefinition('kite.agent.review').agent;
    if (!reviewDefinition) throw new Error('缺少 review agent 定义');
    expect(reviewAgent.tools).toEqual(reviewDefinition.tools);
    expect(reviewAgent.model).toEqual(reviewDefinition.model);
    for (const block of reviewDefinition.context.blocks) expect(reviewAgent.context.blocks).toContainEqual(block);
    expect((await call(daemon.url, 'PUT', `/instances/${reviewId}/agent-config`, {
      expectedRevision: reviewConfig.body.revision, agent: { ...reviewAgent, maxRequestsPerTurn: 1 },
    })).status).toBe(200);
    expect((await call(daemon.url, 'POST', `/threads/${reviewId}/messages`, { id: randomUUID(), text: '只审查' })).status).toBe(200);
    const malicious = await reviewModel.call(1);
    expect(malicious.request.allowedTools).toEqual(['read']);
    void malicious.response.emit({ type: 'item', item: calledItem('review-patch', 'patch', {
      operations: [{ type: 'create_file', path: 'forbidden-patch.txt', diff: '+不应出现\n+' }],
    }) });
    void malicious.response.emit({ type: 'item', item: calledItem('review-shell', 'shell', {
      description: '不应执行', command: "printf forbidden > forbidden-shell.txt",
    }) });
    malicious.response.complete();
    await secondEvents.wait((event) => event.type === 'idle' && event.threadId === reviewId);
    const reviewThread = await call(daemon.url, 'GET', `/threads/${reviewId}`);
    expect(existsSync(join(reviewThread.body.workspace.cwd, 'forbidden-patch.txt'))).toBe(false);
    expect(existsSync(join(reviewThread.body.workspace.cwd, 'forbidden-shell.txt'))).toBe(false);
    const reviewRecords = diskRecords(join(home, 'sessions', reviewId, 'journal.jsonl'));
    expect(reviewRecords.filter((record) => record.type === 'tool.finished').every((record) => record.result.status !== 'success')).toBe(true);
  } finally {
    await daemon?.stop();
    rmSync(root, { recursive: true, force: true });
  }
}, 1000);
