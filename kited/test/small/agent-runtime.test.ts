import { expect, test } from 'bun:test';
import { randomUUID } from 'node:crypto';
import type { AgentDefinition } from '../../src/agents/definition.ts';
import { startDaemon, type Daemon } from '../../src/daemon.ts';
import type { Envelope } from '../../src/events.ts';
import type { ThreadContext, WorkspaceModel } from '../../src/model.ts';
import type { DisplayEnvelope, History } from '../../src/transcript/protocol.ts';
import { api, call, registerCheckout, startKited } from '../harness.ts';
import { ManualModel, Seen } from '../harness-loop.ts';
import { newRepo } from '../util.ts';

// HTTP 配置、SQLite 两处后端、运行时缓存与显示投影跨重开交接；空会话打开过运行时也不能把首条消息交给旧后端。
test('空会话打开后端后仍可切换，重开保留身份和授权，首条消息只交给最终后端，对话后空闲仍可切换', async () => {
  const model = new ManualModel();
  const k = startKited(() => model);
  let reopened: Daemon | undefined;
  try {
    const workspace = await registerCheckout(k, newRepo(k.root, 'project', { 'base.txt': '原始\n' }));
    const workspaceId = workspace.workspace.id;
    const opened = await k.call('POST', `/workspaces/${workspaceId}/windows`, {
      id: randomUUID(), content: { kind: 'create', definitionId: 'kite.agent.coding' },
    });
    expect(opened.status).toBe(200);
    const id = opened.body.target.instanceId as string;
    const configPath = `/instances/${id}/agent-config`;
    const grantsPath = `/instances/${id}/execution-grants`;
    const initial = await k.call('GET', configPath);
    expect(initial.status).toBe(200);
    const original = structuredClone(initial.body.instance.config.agent) as AgentDefinition;
    const initialWorkspace = (await k.call('GET', `/workspaces/${workspaceId}`)).body as WorkspaceModel;
    const initialGrants = await k.call('GET', grantsPath);
    expect(initialGrants.status).toBe(200);
    const grants = await k.call('PUT', grantsPath, {
      expectedRevision: initialGrants.body.revision,
      grants: { workspace: 'read', read: [], write: [], network: [] },
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
    const claude: AgentDefinition = { ...original, runtime: 'claude', model: { model: 'sonnet', reasoning: 'high' } };
    let changedFrom = changes.values.length;
    const switched = await k.call('PUT', configPath, { expectedRevision: initial.body.revision, agent: claude });
    expect(switched.status).toBe(200);
    let stateChanged = changes.values.slice(changedFrom).filter((event) => event.type === 'thread.state').at(-1);
    expect(stateChanged?.state).toEqual((await history()).state);
    expect((await history()).state.capabilities.switchRuntime).toBe(true);
    expect((await k.call('GET', `/threads/${id}`)).body).toMatchObject({
      id, instanceId: id, definitionId: 'kite.agent.coding', runtime: 'claude', config: { agent: claude },
    });

    expect((await k.call('POST', `/threads/${id}/interrupt`, { id: 'open-claude', inputs: [] })).status).toBe(200);
    changedFrom = changes.values.length;
    const restored = await k.call('PUT', configPath, { expectedRevision: switched.body.revision, agent: original });
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
      id, instanceId: id, definitionId: 'kite.agent.coding', runtime: 'harness', config: { agent: original },
    });
    const aggregate = await call(reopened.url, 'GET', `/workspaces/${workspaceId}`);
    expect(aggregate.status).toBe(200);
    expect(aggregate.body.windows).toEqual(initialWorkspace.windows);
    expect(aggregate.body.threads).toEqual([{ instanceId: id, runtime: 'harness', nativeId: expect.any(String) }]);
    expect(aggregate.body.instances).toHaveLength(1);
    expect(aggregate.body.instances[0]).toMatchObject({
      id, workspaceId, definitionId: 'kite.agent.coding', createdAt: initial.body.instance.createdAt, config: { agent: original },
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
