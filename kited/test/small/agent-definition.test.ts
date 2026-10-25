import { afterEach, expect, test } from 'bun:test';
import { randomUUID } from 'node:crypto';
import { rmSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import type { AgentDefinition } from '../../src/agents/definition.ts';
import { startDaemon, type Daemon } from '../../src/daemon.ts';
import type { Envelope } from '../../src/events.ts';
import { restoreContext } from '../../src/harness/context/assembler.ts';
import { TOOL_SEARCH } from '../../src/harness/tool-search.ts';
import type { Json, ModelItem, ThreadNotification } from '../../src/harness/types.ts';
import type { ThreadContext } from '../../src/model.ts';
import type { DisplayEnvelope, History } from '../../src/transcript/protocol.ts';
import { api, call, folderWorkspace, openAgent, startKited, type Kited } from '../harness.ts';
import { diskRecords, item, ManualModel, Seen } from '../harness-loop.ts';
import { editNotificationTemplate } from '../notification-templates.ts';
import { makeTemp, newDir, read } from '../util.ts';

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
test('运行中换配置不打断旧工具，下一请求再采用新配置', async () => {
  const oldModel = new ManualModel();
  const newModel = new ManualModel();
  kited = startKited((thread) => (thread.config.agent as AgentDefinition).model.model === 'test-new-model' ? newModel : oldModel);
  const kk = kited;
  const registered = await folderWorkspace(kk, newDir(kk.root, 'project', { 'base.txt': '原始\n' }));
  const workspaceId = registered.workspace.id;
  const threadId = await openAgent(kk.call, workspaceId);
  const initial = await kk.call('GET', `/instances/${threadId}/agent-config`);
  expect(initial.status).toBe(200);
  const original = structuredClone(initial.body.instance.config.agent) as AgentDefinition;

  const sent = await kk.call('POST', `/threads/${threadId}/messages`, { id: randomUUID(), text: '创建一个文件' });
  expect(sent.status).toBe(200);
  const first = await oldModel.call(1);
  expect(first.request.allowedTools).toContain('patch');
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
  const thread = await kk.call('GET', `/threads/${threadId}`);
  expect(thread.body.config.agent).toEqual(changed);
  expect(read(join(thread.body.workspace.cwd, 'from-old-request.txt'))).toBe('旧请求仍可写入\n');
  expect(second.request.instructions).toBe(first.request.instructions);
  expect(second.request.tools.map((value) => value.name)).toEqual(first.request.tools.map((value) => value.name));
  expect(second.request.allowedTools).toEqual(['read', TOOL_SEARCH]);
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
  expect(configurations[0]!.snapshot.settings.allowedTools).toEqual(first.request.allowedTools);
  expect(configurations[1]!.snapshot.settings).toMatchObject({
    model: { model: 'test-new-model', reasoning: 'high' }, allowedTools: ['read', TOOL_SEARCH],
  });
  second.response.complete();
  await kk.waitEvent((event) => event.type === 'idle' && event.threadId === threadId);
}, 1000);

// HTTP 参数、实例创建时的角色绑定（含 KITE_MODEL 覆盖）、窗口建立与运行时取模型要一起成立：草稿显式选的模型
// 必须压过角色默认值和环境变量，并且就是运行时实际拿到的模型；参数不成立的请求（关掉角色的必需工具）要在建实例前拒绝，不留实例或窗口。
test('按草稿选择创建代理时显式模型压过角色默认值和 KITE_MODEL 并同时建窗口，工具缺了角色的必需工具时拒绝且不留实例', async () => {
  const previous = process.env.KITE_MODEL;
  process.env.KITE_MODEL = 'env-override-model';
  try {
    const model = new ManualModel();
    const runtimeModels: AgentDefinition['model'][] = [];
    kited = startKited((thread) => {
      runtimeModels.push(structuredClone((thread.config.agent as AgentDefinition).model));
      return model;
    });
    const kk = kited;
    const registered = await folderWorkspace(kk, newDir(kk.root, 'project', { 'base.txt': '原始\n' }));
    const workspaceId = registered.workspace.id;
    const aggregate = async () => {
      const response = await kk.call('GET', `/workspaces/${workspaceId}`);
      expect(response.status).toBe(200);
      return response.body as { instances: { id: string }[] };
    };
    const roles = await kk.call('GET', '/roles');
    const review = (roles.body.roles as Array<{ role: { id: string }; revision: string }>).find((entry) => entry.role.id === 'kite.review')!;
    const role = { id: review.role.id, revision: review.revision };

    const chosen = { model: 'draft-chosen-model', reasoning: 'low' };
    const created = await kk.call('POST', `/workspaces/${workspaceId}/threads`, { prompt: '审查一下', role, model: chosen });
    expect(created.status).toBe(200);
    const id = created.body.instanceId as string;
    const first = await model.call(1);
    expect(runtimeModels).toEqual([chosen]);
    const thread = await kk.call('GET', `/threads/${id}`);
    expect(thread.body).toMatchObject({ definitionId: 'kite.agent', runtime: 'harness' });
    expect(thread.body.config.agent.model).toEqual(chosen);
    const withThread = await aggregate();
    expect(withThread.instances.map((value) => value.id)).toEqual([id]);
    first.response.complete();
    await kk.waitEvent((event) => event.type === 'idle' && event.threadId === id);

    const rejected = await kk.call('POST', `/workspaces/${workspaceId}/threads`, {
      prompt: '只读审查却不要 read', role, tools: ['shell'],
    });
    expect(rejected.status).toBe(400);
    expect(await aggregate()).toMatchObject({ instances: withThread.instances });
    expect(model.calls.values).toHaveLength(1);
  } finally {
    if (previous === undefined) delete process.env.KITE_MODEL;
    else process.env.KITE_MODEL = previous;
  }
}, 1000);

// 模板目录、SQLite 排队快照与 journal 跨重启交接；缓存 Runner 仅在正文变化时读取新基础通知模板。
// 真实回归：原样 PUT 曾漏掉 configurationBoundary，导致 App 无法解码成功保存的配置快照。
test('原样保存保留配置快照，通知跨重启保留且按请求边界采用新模板', async () => {
  const root = makeTemp();
  const home = join(root, 'kite');
  const repo = newDir(root, 'project', { 'base.txt': '原始\n' });
  const firstModel = new ManualModel();
  let daemon: Daemon | undefined;
  try {
    daemon = startDaemon({ home, port: 0, lightTasks: false, model: () => firstModel });
    const apiCall = (method: string, path: string, body?: unknown) => call(daemon!.url, method, path, body);
    const firstEvents = new Seen<Envelope>();
    daemon.kite.bus.subscribe(undefined, (event) => firstEvents.add(event));
    const workspaceId = (await folderWorkspace(daemon, repo)).workspace.id;
    const codingId = await openAgent(apiCall, workspaceId);
    expect((await call(daemon.url, 'POST', `/threads/${codingId}/messages`, { id: randomUUID(), text: '先建立历史' })).status).toBe(200);
    const first = await firstModel.call(1);
    first.response.complete();
    await firstEvents.wait((event) => event.type === 'idle' && event.threadId === codingId);
    const oldConfigurationTemplate = await editNotificationTemplate(apiCall,
      'kite.agent-configuration', '配置通知旧模板', 'agent.model');
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
    expect(firstNotice.context.definition).toEqual(oldConfigurationTemplate.definition);
    expect(restoreContext(firstNotice.context).instructions).toContain('配置通知旧模板\nafter-restart');
    const newConfigurationTemplate = await editNotificationTemplate(apiCall,
      'kite.agent-configuration', '配置通知新模板', 'agent.model');
    expect(daemon.kite.store.instanceNotifications(codingId, 0)).toEqual(pending);
    const current = await apiCall('GET', `/instances/${codingId}/agent-config`);
    expect(current.status).toBe(200);
    expect(current.body).toEqual(updated.body);
    const saved = await apiCall('PUT', `/instances/${codingId}/agent-config`, {
      expectedRevision: current.body.revision, agent: current.body.instance.config.agent,
    });
    expect(saved.status).toBe(200);
    expect(saved.body).toEqual(current.body);
    expect(daemon.kite.store.instanceNotifications(codingId, 0)).toEqual(pending);
    expect(firstModel.calls.values).toHaveLength(1);
    await daemon.stop();
    daemon = undefined;

    const resumedModel = new ManualModel();
    daemon = startDaemon({ home, port: 0, lightTasks: false, model: () => resumedModel });
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
    expect(durableUpdates[0]!.text).toContain('配置通知旧模板\nafter-restart');
    expect(durableUpdates[0]!.text).not.toContain('配置通知新模板');
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

    const journalPath = join(home, 'sessions', codingId, 'journal.jsonl');
    const beforeTemplateEdit = diskRecords(journalPath);
    const beforeTemplateEditNotifications = structuredClone(daemon.kite.store.instanceNotifications(codingId, 0));
    const newContextTemplate = await editNotificationTemplate(apiCall,
      'kite.context-update', '基础通知新模板', 'context.instructions');
    expect(diskRecords(journalPath)).toEqual(beforeTemplateEdit);
    expect(daemon.kite.store.instanceNotifications(codingId, 0)).toEqual(beforeTemplateEditNotifications);
    expect(resumedModel.calls.values).toHaveLength(1);
    const unchangedEventStart = secondEvents.values.length;
    expect((await apiCall('POST', `/threads/${codingId}/messages`, {
      id: randomUUID(), text: '正文未变，模板更新也不生成通知',
    })).status).toBe(200);
    const unchanged = await resumedModel.call(2);
    expect(unchanged.request.instructions).toBe(first.request.instructions);
    expect(unchanged.request.history.filter((entry) => entry.type === 'notification')).toEqual(updates);
    expect(diskRecords(journalPath).filter((record) => record.type === 'request.started').at(-1)!.notifications ?? []).toEqual([]);
    unchanged.response.complete();
    await secondEvents.wait((event) => event.type === 'idle' && event.threadId === codingId
      && secondEvents.values.indexOf(event) >= unchangedEventStart);

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
    const latestConfigurationNotice = daemon.kite.store.instanceNotifications(codingId, firstNotice.sequence!).at(-1)!;
    expect(latestConfigurationNotice.context.definition).toEqual(newConfigurationTemplate.definition);

    const thirdEventStart = secondEvents.values.length;
    expect((await call(daemon.url, 'POST', `/threads/${codingId}/messages`, { id: randomUUID(), text: '再继续一次' })).status).toBe(200);
    const third = await resumedModel.call(3);
    expect(third.request.instructions).toBe(first.request.instructions);
    expect(third.request.history.filter((entry) => entry.type === 'notification' && entry.notification.id === firstNotice.id))
      .toEqual([durableUpdates[0]!]);
    expect(third.request.history.some((entry) => entry.type === 'notification' && entry.text.includes('后续材料：只供第三次请求读取'))).toBe(true);
    expect(third.request.history.some((entry) => entry.type === 'notification'
      && entry.text.includes('配置通知新模板\nlater-model'))).toBe(true);
    const contextUpdate = third.request.history.find((entry) => entry.type === 'notification'
      && entry.text.includes('基础通知新模板'));
    if (contextUpdate?.type !== 'notification') throw new Error('缓存 Runner 未使用更新后的基础通知模板');
    expect(contextUpdate.text).toContain('后续材料：只供第三次请求读取');
    const codingRecords = diskRecords(join(home, 'sessions', codingId, 'journal.jsonl'));
    const codingStarts = codingRecords.filter((record) => record.type === 'request.started');
    expect(codingStarts.at(-3)!.notifications).toEqual(deliveredAfterRestart);
    expect(codingStarts.at(-2)!.notifications ?? []).toEqual([]);
    expect(codingStarts.at(-1)!.notifications?.some((notice) => notice.id === firstNotice.id)).toBe(false);
    expect(codingStarts.at(-1)!.notifications?.some((notice) => notice.sequence! > firstNotice.sequence!)).toBe(true);
    expect(codingStarts.at(-1)!.notifications?.find((notice) => notice.id === contextUpdate.notification.id)?.context.definition)
      .toEqual(newContextTemplate.definition);
    const contextRecords = codingRecords.filter((record) => record.type === 'context.prepared');
    const latestContext = restoreContext(contextRecords.at(-1)!.snapshot);
    expect(latestContext.instructions).toContain('条件分支：当前工作区');
    expect(latestContext.blocks.some((block) => block.type === 'condition' && block.branchId === 'current')).toBe(true);
    third.response.complete();
    await secondEvents.wait((event) => event.type === 'idle' && event.threadId === codingId
      && secondEvents.values.indexOf(event) >= thirdEventStart);
  } finally {
    await daemon?.stop();
    rmSync(root, { recursive: true, force: true });
  }
}, 1000);

// HTTP 配置、SQLite 两处后端、运行时缓存与显示投影跨重开交接；空会话打开过运行时也不能把首条消息交给旧后端。
// 后端由模型推出：配置里带的 runtime 字段不算数，换了厂商的模型才换后端，只改思考强度时后端不动。
test('空会话打开后端后按模型换后端，只改思考强度不换后端，重开保留身份和授权，首条消息只交给最终后端，对话后空闲仍可切换', async () => {
  const model = new ManualModel();
  const k = startKited(() => model);
  let reopened: Daemon | undefined;
  try {
    const workspace = await folderWorkspace(k, newDir(k.root, 'project', { 'base.txt': '原始\n' }));
    const workspaceId = workspace.workspace.id;
    const id = await openAgent(k.call, workspaceId);
    const configPath = `/instances/${id}/agent-config`;
    const grantsPath = `/instances/${id}/execution-grants`;
    const initial = await k.call('GET', configPath);
    expect(initial.status).toBe(200);
    const original = structuredClone(initial.body.instance.config.agent) as AgentDefinition;
    const initialGrants = await k.call('GET', grantsPath);
    expect(initialGrants.status).toBe(200);
    const grants = await k.call('PUT', grantsPath, {
      expectedRevision: initialGrants.body.revision,
      grants: { workspace: 'read', add: { read: [], write: [], network: [], unsandboxed: [] }, remove: { read: [], write: [], network: [], unsandboxed: [] } },
    });
    expect(grants.status).toBe(200);
    const operationGrants = await k.call('GET', `/instances/${id}/operation-grants`);
    expect(operationGrants.status).toBe(200);
    const history = async () => {
      const result = await k.call('GET', `/threads/${id}/history`);
      expect(result.status).toBe(200);
      return result.body as History;
    };
    expect((await history()).state.capabilities.switchRuntime).toBe(true);
    const changes = new Seen<DisplayEnvelope>();
    k.daemon.kite.events.subscribe((event) => 'threadId' in event && event.threadId === id,
      (event) => changes.add(event));
    const requestCount = api.log.length;

    expect((await k.call('POST', `/threads/${id}/interrupt`, { id: 'open-harness', inputs: [] })).status).toBe(200);
    expect(original.runtime).toBe('harness');
    const claude: AgentDefinition = { ...original, runtime: 'claude', model: { model: 'sonnet', reasoning: 'high' } };
    let changedFrom = changes.values.length;
    // 只换模型、runtime 字段仍写 harness：后端随 Claude 模型换过去
    const switched = await k.call('PUT', configPath, { expectedRevision: initial.body.revision, agent: { ...claude, runtime: 'harness' } });
    expect(switched.status).toBe(200);
    let stateChanged = changes.values.slice(changedFrom).filter((event) => event.type === 'thread.state').at(-1);
    expect(stateChanged?.state).toEqual((await history()).state);
    expect((await history()).state.capabilities.switchRuntime).toBe(true);
    expect((await k.call('GET', `/threads/${id}`)).body).toMatchObject({
      id, instanceId: id, definitionId: 'kite.agent', runtime: 'claude', config: { agent: claude },
    });
    expect(k.daemon.kite.store.thread(id)?.runtime).toBe('claude');

    expect((await k.call('POST', `/threads/${id}/interrupt`, { id: 'open-claude', inputs: [] })).status).toBe(200);
    // 模型不变只改思考强度：即使 runtime 字段写 harness，后端也留在 Claude
    const reasoned = await k.call('PUT', configPath, {
      expectedRevision: switched.body.revision, agent: { ...claude, runtime: 'harness', model: { model: 'sonnet', reasoning: 'medium' } },
    });
    expect(reasoned.status).toBe(200);
    expect(reasoned.body.instance.config.agent).toMatchObject({ runtime: 'claude', model: { model: 'sonnet', reasoning: 'medium' } });
    expect((await k.call('GET', `/threads/${id}`)).body.runtime).toBe('claude');
    expect(k.daemon.kite.store.thread(id)?.runtime).toBe('claude');
    changedFrom = changes.values.length;
    // 换回 OpenAI 的模型、runtime 字段仍写 claude：后端随模型回到自研
    const restored = await k.call('PUT', configPath, { expectedRevision: reasoned.body.revision, agent: { ...original, runtime: 'claude' } });
    expect(restored.status).toBe(200);
    stateChanged = changes.values.slice(changedFrom).filter((event) => event.type === 'thread.state').at(-1);
    const empty = await history();
    expect(stateChanged?.state).toEqual(empty.state);
    expect(empty.state.capabilities.switchRuntime).toBe(true);
    expect(empty.records).toEqual([]);
    expect(empty.pending).toEqual([]);
    expect(model.calls.values).toHaveLength(0);
    expect(api.log).toHaveLength(requestCount);
    await k.daemon.stop();

    reopened = startDaemon({ home: k.home, port: 0, model: () => model, lightTasks: false });
    const events = new Seen<Envelope>();
    reopened.kite.bus.subscribe(undefined, (event) => events.add(event));
    const current = await call(reopened.url, 'GET', `/threads/${id}`);
    expect(current.status).toBe(200);
    expect(current.body as ThreadContext).toMatchObject({
      id, instanceId: id, definitionId: 'kite.agent', runtime: 'harness', config: { agent: original },
    });
    const aggregate = await call(reopened.url, 'GET', `/workspaces/${workspaceId}`);
    expect(aggregate.status).toBe(200);
    expect(aggregate.body.threads).toEqual([{ instanceId: id, runtime: 'harness', nativeId: expect.any(String) }]);
    expect(aggregate.body.instances).toHaveLength(1);
    expect(aggregate.body.instances[0]).toMatchObject({
      id, workspaceId, definitionId: 'kite.agent', createdAt: initial.body.instance.createdAt, config: { agent: original },
    });
    expect((await call(reopened.url, 'GET', grantsPath)).body).toEqual(grants.body);
    expect((await call(reopened.url, 'GET', `/instances/${id}/operation-grants`)).body).toEqual(operationGrants.body);
    expect((await call(reopened.url, 'GET', `/threads/${id}/history`)).body.state.capabilities.switchRuntime).toBe(true);

    const sent = await call(reopened.url, 'POST', `/threads/${id}/messages`, { id: 'final-runtime-input', text: '只在最终后端执行一次' });
    expect(sent.status).toBe(200);
    const first = await model.call(1);
    expect(first.request.history.flatMap((entry) => entry.type === 'input' ? [entry.input] : []))
      .toEqual([{ id: 'final-runtime-input', text: '只在最终后端执行一次', source: 'human' }]);
    expect((await call(reopened.url, 'GET', `/threads/${id}/history`)).body.state.capabilities.switchRuntime).toBe(false);
    first.response.complete();
    await events.wait((event) => event.type === 'idle' && event.threadId === id);
    expect(model.calls.values).toHaveLength(1);
    expect(api.log).toHaveLength(requestCount);
    // 已有对话的会话空闲后仍可切换；切换本身只翻译上下文，不请求任何一方的模型。
    expect((await call(reopened.url, 'GET', `/threads/${id}/history`)).body.state.capabilities.switchRuntime).toBe(true);
    const latest = await call(reopened.url, 'GET', configPath);
    const switchedAfterTalk = await call(reopened.url, 'PUT', configPath, { expectedRevision: latest.body.revision, agent: claude });
    expect(switchedAfterTalk.status).toBe(200);
    expect((await call(reopened.url, 'GET', `/threads/${id}`)).body).toMatchObject({ runtime: 'claude', config: { agent: claude } });
    expect(model.calls.values).toHaveLength(1);
    expect(api.log).toHaveLength(requestCount);
  } finally {
    await reopened?.stop();
    await k.stop();
  }
}, 1000);
