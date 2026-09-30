import { afterAll, expect, test } from 'bun:test';
import { randomUUID } from 'node:crypto';
import { existsSync, mkdirSync, readFileSync, rmSync, symlinkSync, watch, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { startDaemon, type Daemon } from '../../src/daemon.ts';
import type { Envelope } from '../../src/events.ts';
import type { Json, ModelItem } from '../../src/harness/types.ts';
import type { PluginDefinition } from '../../src/plugins.ts';
import { call, registerCheckout, startKited, type Kited } from '../harness.ts';
import { diskRecords, item, ManualModel, Seen } from '../harness-loop.ts';
import { bunPluginSource } from '../fixtures/bun-plugin-source.ts';
import { makeTemp, newRepo } from '../util.ts';

const buildRoot = makeTemp('bun-plugin-bundle-');
afterAll(() => rmSync(buildRoot, { recursive: true, force: true }));

// Bun.build 必须把 SDK 装进单文件，插件宿主只接收这个字节串，不读取或构建未知源码。
const bundle = (async () => {
  const entry = join(buildRoot, 'plugin.ts');
  symlinkSync(join(import.meta.dir, '..', '..', 'node_modules'), join(buildRoot, 'node_modules'));
  writeFileSync(entry, bunPluginSource);
  const built = await Bun.build({ entrypoints: [entry], target: 'bun', format: 'esm', minify: true });
  if (!built.success || built.outputs.length !== 1) throw new Error(`插件 fixture 打包失败：${built.logs.join('\n')}`);
  return built.outputs[0]!.text();
})();

async function workspace(k: Kited, repo: string) {
  const registered = await registerCheckout(k, repo);
  return registered.workspace.id;
}

async function install(k: Kited) {
  const pack = { id: 'custom.test', title: '测试', bundle: await bundle };
  const installed = await k.call('POST', '/plugin-definitions', pack);
  expect(installed.status).toBe(200);
  const definition = installed.body as PluginDefinition;
  expect(definition.id).toBe(pack.id);
}

async function createInstance(k: Kited, workspaceId: string) {
  const id = randomUUID();
  const created = await k.call('POST', `/workspaces/${workspaceId}/plugin-instances`, {
    id, definitionId: 'custom.test', title: '测试实例',
  });
  expect(created.status).toBe(200);
  expect(created.body).toMatchObject({ id, workspaceId, definitionId: 'custom.test', presentation: 'background' });
  return id;
}

async function tool(k: Kited, instanceId: string, name: string, operationId: string, args: Record<string, unknown>) {
  return k.call('POST', `/instances/${instanceId}/plugin/tools/${name}`, { operationId, arguments: args });
}

function output(response: { status: number; body: any }) {
  if (response.status !== 200) throw new Error(`插件调用失败：${response.status} ${JSON.stringify(response.body)}`);
  expect(response.body.isError).not.toBe(true);
  return response.body.structuredContent as Record<string, any>;
}

async function filesTarget(k: Kited, workspaceId: string) {
  const opened = await k.call('POST', `/workspaces/${workspaceId}/windows`, {
    id: randomUUID(), content: { kind: 'create', definitionId: 'kite.files' },
  });
  expect(opened.status).toBe(200);
  return opened.body.target.instanceId as string;
}

async function codingInstance(k: Kited, workspaceId: string) {
  const opened = await k.call('POST', `/workspaces/${workspaceId}/windows`, {
    id: randomUUID(), content: { kind: 'create', definitionId: 'kite.agent.coding' },
  });
  expect(opened.status).toBe(200);
  return opened.body.target.instanceId as string;
}

function modelItem(id: string, name: string, args: Json): ModelItem {
  return { ...item(id, name), call: { id, name, arguments: args } };
}

function modelResult(history: Awaited<ReturnType<ManualModel['call']>>['request']['history'], callId: string) {
  const entry = history.find((value) => value.type === 'tool_result' && value.callId === callId);
  if (entry?.type !== 'tool_result') throw new Error(`没有工具结果：${callId}`);
  return entry.result;
}

function waitFile(path: string) {
  if (existsSync(path)) return Promise.resolve();
  return new Promise<void>((resolve, reject) => {
    const watcher = watch(join(path, '..'), () => {
      if (existsSync(path)) { clearTimeout(timer); watcher.close(); resolve(); }
    });
    const timer = setTimeout(() => { watcher.close(); reject(new Error(`等待插件写入 ${path} 超时`)); }, 700);
    if (existsSync(path)) { clearTimeout(timer); watcher.close(); resolve(); }
  });
}

// 真实 Bun SDK 双向 stdio、宿主授权与 SQLite 状态收据必须一起运行才能发现交接错误。
test('Bun 插件的状态和工具收据跨进程重启保留，工作区回调随授权即时变化', async () => {
  const k = startKited();
  try {
    const repo = newRepo(k.root, 'project', { 'note.txt': '可读内容\n' });
    const workspaceId = await workspace(k, repo);
    await install(k);
    const instanceId = await createInstance(k, workspaceId);
    const listed = await k.call('GET', `/instances/${instanceId}/plugin/tools`);
    if (listed.status !== 200) throw new Error(`列插件工具失败：${listed.status} ${JSON.stringify(listed.body)}`);
    expect(listed.body.tools).toEqual(expect.arrayContaining([expect.objectContaining({ name: 'state' })]));

    const before = output(await tool(k, instanceId, 'state', 'read-before', { action: 'read' }));
    const increment = await tool(k, instanceId, 'state', 'increment-once', { action: 'increment' });
    expect(output(increment).value.count).toBe(1);
    expect(await tool(k, instanceId, 'state', 'increment-once', { action: 'increment' })).toEqual(increment);
    expect(output(await tool(k, instanceId, 'state', 'stale', {
      action: 'stale', expectedRevision: before.revision,
    })).staleRejected).toBe(true);

    const targetId = await filesTarget(k, workspaceId);
    const args = { targetId, path: 'note.txt' };
    expect(output(await tool(k, instanceId, 'read-file', 'read-denied', args)).allowed).toBe(false);
    const grants = await k.call('GET', `/instances/${instanceId}/operation-grants`);
    expect(grants.status).toBe(200);
    const granted = await k.call('PUT', `/instances/${instanceId}/operation-grants`, {
      expectedRevision: grants.body.revision,
      grants: [{ operation: 'files.read', targets: { kind: 'instances', instanceIds: [targetId] } }],
    });
    expect(granted.status).toBe(200);
    const allowed = output(await tool(k, instanceId, 'read-file', 'read-allowed', args));
    expect(allowed.allowed).toBe(true);
    expect(allowed.value.text).toContain('可读内容');
    expect(output(await tool(k, instanceId, 'read-file', 'read-forged', { ...args, forge: true })).allowed).toBe(false);
    const revoked = await k.call('PUT', `/instances/${instanceId}/operation-grants`, {
      expectedRevision: granted.body.revision, grants: [],
    });
    expect(revoked.status).toBe(200);
    expect(output(await tool(k, instanceId, 'read-file', 'read-revoked', args)).allowed).toBe(false);

    expect((await k.call('DELETE', `/instances/${instanceId}/plugin/process`)).status).toBe(200);
    const restored = output(await tool(k, instanceId, 'state', 'read-restarted', { action: 'read' }));
    expect(restored.value.count).toBe(1);
    expect(restored.pid).not.toBe(before.pid);
  } finally {
    await k.stop();
  }
}, 1000);

// Seatbelt/bubblewrap 的真实进程隔离、后代继承和进程组取消不能由启动参数或 MCP 消息验证。
test('Bun 插件及其后代被沙箱隔离，停止阻塞工具后同一 operationId 保持 unknown', async () => {
  const oldSecret = process.env.KITE_TEST_HOST_SECRET;
  process.env.KITE_TEST_HOST_SECRET = 'fixture-host-secret';
  const k = startKited();
  const listener = Bun.serve({ hostname: '127.0.0.1', port: 0, fetch: () => new Response('reachable') });
  try {
    const repo = newRepo(k.root, 'project', { 'note.txt': '工作区秘密\n' });
    const workspaceId = await workspace(k, repo);
    await install(k);
    const instanceId = await createInstance(k, workspaceId);
    const externalFile = join(k.root, 'outside-secret.txt');
    const hostFile = join(k.home, 'host-secret.txt');
    writeFileSync(externalFile, '外部秘密');
    mkdirSync(k.home, { recursive: true });
    writeFileSync(hostFile, '宿主秘密');
    const probe = output(await tool(k, instanceId, 'probe', 'probe', {
      workspaceFile: join(repo, 'note.txt'), externalFile, hostFile, port: listener.port,
    }));
    expect(probe).toMatchObject({
      workspaceRead: false, externalRead: false, hostRead: false, hostSecret: null,
      tempWrite: true, childExit: 0, childRead: 'denied',
    });
    expect(probe.tcp).not.toBe('connected');
    expect(probe.tcp).not.toBe('timeout');

    const marker = join(probe.tmpdir, 'block-' + randomUUID());
    const pending = tool(k, instanceId, 'block', 'blocked-once', { marker });
    await waitFile(marker);
    const blockedPids = JSON.parse(readFileSync(marker, 'utf8')) as { parent: number; child: number };
    expect(Number.isInteger(blockedPids.parent)).toBe(true);
    expect(Number.isInteger(blockedPids.child)).toBe(true);
    expect((await k.call('DELETE', `/instances/${instanceId}/plugin/process`)).status).toBe(200);
    expect(await pending).toMatchObject({ status: 409, body: { outcome: 'unknown' } });
    expect(existsSync(marker)).toBe(false);
    expect(await tool(k, instanceId, 'block', 'blocked-once', { marker }))
      .toMatchObject({ status: 409, body: { outcome: 'unknown' } });
    expect(existsSync(marker)).toBe(false);
    expect((await k.call('GET', `/instances/${instanceId}/plugin/process`)).body.phase).toBe('stopped');
    expect(() => process.kill(blockedPids.parent, 0)).toThrow();
    expect(() => process.kill(blockedPids.child, 0)).toThrow();
  } finally {
    await listener.stop(true);
    await k.stop();
    if (oldSecret === undefined) delete process.env.KITE_TEST_HOST_SECRET;
    else process.env.KITE_TEST_HOST_SECRET = oldSecret;
  }
}, 1000);

// Bun SDK 工具声明、实例授权、模型流与宿主持久状态跨 RPC 交接；同名工具必须落到各自实例。
test('模型按实例授权调用同名 Bun 工具，原始参数 schema 拦住错误输入且 app-only 不进入目录', async () => {
  const model = new ManualModel();
  const k = startKited(() => model);
  try {
    const repo = newRepo(k.root, 'project', { 'base.txt': '原始\n' });
    const workspaceId = await workspace(k, repo);
    await install(k);
    const firstId = await createInstance(k, workspaceId);
    const secondId = await createInstance(k, workspaceId);
    const agentId = await codingInstance(k, workspaceId);
    const listed = await k.call('GET', `/instances/${firstId}/plugin/tools`);
    expect(listed.status).toBe(200);
    const stateSchema = listed.body.tools.find((value: { name: string }) => value.name === 'state')?.inputSchema;
    expect(stateSchema).toBeDefined();
    expect(listed.body.tools).toContainEqual(expect.objectContaining({ name: 'app-only' }));
    const grants = await k.call('GET', `/instances/${agentId}/operation-grants`);
    expect(grants.status).toBe(200);
    expect((await k.call('PUT', `/instances/${agentId}/operation-grants`, {
      expectedRevision: grants.body.revision,
      grants: [{ operation: 'plugin.call', instanceId: firstId, tools: ['app-only'] }],
    })).status).not.toBe(200);
    const granted = await k.call('PUT', `/instances/${agentId}/operation-grants`, {
      expectedRevision: grants.body.revision,
      grants: [
        { operation: 'plugin.call', instanceId: firstId, tools: ['state'] },
        { operation: 'plugin.call', instanceId: secondId, tools: ['state'] },
      ],
    });
    expect(granted.status).toBe(200);
    const thread = await k.call('GET', `/threads/${agentId}`);
    expect(thread.status).toBe(200);
    const bindings = thread.body.config.pluginTools as Array<{
      instanceId: string; toolName: string; packageRevision: string; toolRevision: string;
      modelName: string; description: string; parameters: Record<string, unknown>;
    }>;
    expect(bindings).toHaveLength(2);
    expect(bindings.map((value) => value.instanceId).sort()).toEqual([firstId, secondId].sort());
    expect(bindings.map((value) => value.toolName)).toEqual(['state', 'state']);
    expect(new Set(bindings.map((value) => value.modelName)).size).toBe(2);
    for (const binding of bindings) {
      expect(binding.modelName).toMatch(/^[A-Za-z_][A-Za-z0-9_]*$/);
      expect(binding.packageRevision).toBeTruthy();
      expect(binding.toolRevision).toBeTruthy();
      expect(binding.parameters).toEqual(stateSchema);
      expect(Object.keys((binding.parameters.properties ?? {}) as object).sort()).toEqual(['action', 'expectedRevision']);
    }

    expect((await k.call('POST', `/threads/${agentId}/messages`, {
      id: randomUUID(), text: '两个计数器各加一次',
    })).status).toBe(200);
    const first = await model.call(1);
    for (const binding of bindings) {
      expect(first.request.tools.find((value) => value.name === binding.modelName)).toEqual({
        name: binding.modelName, description: binding.description, parameters: stateSchema,
      });
      expect(first.request.allowedTools).toContain(binding.modelName);
    }
    expect(first.request.tools.some((value) => value.name.includes('app-only'))).toBe(false);
    const [one, two] = bindings;
    await first.response.emit({ type: 'item', item: modelItem('first', one!.modelName, { action: 'increment' }) });
    await first.response.emit({ type: 'item', item: modelItem('second', two!.modelName, { action: 'increment' }) });
    await first.response.emit({ type: 'item', item: modelItem('invalid', one!.modelName, { action: 42 }) });
    first.response.complete();
    const second = await model.call(2);
    for (const id of ['first', 'second']) {
      const result = modelResult(second.request.history, id);
      expect(result.status).toBe('success');
      expect(JSON.parse(result.output).structuredContent.value.count).toBe(1);
    }
    expect(modelResult(second.request.history, 'invalid').status).toBe('error');
    expect(output(await tool(k, firstId, 'state', 'verify-first', { action: 'read' })).value.count).toBe(1);
    expect(output(await tool(k, secondId, 'state', 'verify-second', { action: 'read' })).value.count).toBe(1);
    second.response.complete();
    await k.waitEvent((event) => event.type === 'idle' && event.threadId === agentId);
  } finally {
    await k.stop();
  }
}, 1000);

// 模型响应与 HTTP 撤权并发，随后要经过 journal、SQLite 和 daemon 重启；旧响应不能绕过执行时授权。
test('撤权拒绝旧模型调用，固定工具目录与独立收据在恢复授权和重启后保留', async () => {
  const root = makeTemp('plugin-model-');
  const home = join(root, 'kite');
  const repo = newRepo(root, 'project', { 'base.txt': '原始\n' });
  const model = new ManualModel();
  let daemon: Daemon | undefined;
  try {
    daemon = startDaemon({ home, port: 0, model: () => model });
    const events = new Seen<Envelope>();
    daemon.kite.bus.subscribe(undefined, (event) => events.add(event));
    const apiCall = (method: string, path: string, body?: unknown) => call(daemon!.url, method, path, body);
    const registered = await apiCall('POST', '/checkouts', { path: repo });
    expect(registered.status).toBe(200);
    const workspaceId = registered.body.workspace.id as string;
    expect((await apiCall('POST', '/plugin-definitions', {
      id: 'custom.test', title: '测试', bundle: await bundle,
    })).status).toBe(200);
    const targetId = randomUUID();
    expect((await apiCall('POST', `/workspaces/${workspaceId}/plugin-instances`, {
      id: targetId, definitionId: 'custom.test', title: '目标',
    })).status).toBe(200);
    const opened = await apiCall('POST', `/workspaces/${workspaceId}/windows`, {
      id: randomUUID(), content: { kind: 'create', definitionId: 'kite.agent.coding' },
    });
    expect(opened.status).toBe(200);
    const agentId = opened.body.target.instanceId as string;
    const grants = await apiCall('GET', `/instances/${agentId}/operation-grants`);
    const granted = await apiCall('PUT', `/instances/${agentId}/operation-grants`, {
      expectedRevision: grants.body.revision,
      grants: [{ operation: 'plugin.call', instanceId: targetId, tools: ['state'] }],
    });
    expect(granted.status).toBe(200);
    const thread = await apiCall('GET', `/threads/${agentId}`);
    const pin = thread.body.config.pluginTools[0] as {
      instanceId: string; toolName: string; packageRevision: string; toolRevision: string; modelName: string;
    };
    expect(pin).toMatchObject({ instanceId: targetId, toolName: 'state' });
    const projection = {
      modelName: pin.modelName, instanceId: pin.instanceId, toolName: pin.toolName,
      packageRevision: pin.packageRevision, toolRevision: pin.toolRevision,
    };

    expect((await apiCall('POST', `/threads/${agentId}/messages`, {
      id: randomUUID(), text: '准备调用插件',
    })).status).toBe(200);
    const first = await model.call(1);
    expect(first.request.allowedTools).toContain(pin.modelName);
    const revoked = await apiCall('PUT', `/instances/${agentId}/operation-grants`, {
      expectedRevision: granted.body.revision, grants: [],
    });
    expect(revoked.status).toBe(200);
    expect(model.calls.values).toHaveLength(1);
    expect(first.signal.aborted).toBe(false);
    await first.response.emit({ type: 'item', item: modelItem('stale-call', pin.modelName, { action: 'increment' }) });
    first.response.complete();
    const second = await model.call(2);
    const denied = modelResult(second.request.history, 'stale-call');
    expect(denied.status).toBe('error');
    expect(JSON.parse(denied.output)).toMatchObject({ outcome: 'denied' });
    expect(second.request.tools.map((value) => value.name)).toEqual(first.request.tools.map((value) => value.name));
    expect(second.request.allowedTools).not.toContain(pin.modelName);
    expect(second.request.history).toContainEqual(expect.objectContaining({
      type: 'notification', notification: expect.objectContaining({ kind: 'plugin.tools.changed' }),
    }));
    expect((await apiCall('POST', `/instances/${targetId}/plugin/tools/state`, {
      operationId: 'read-after-revoke', arguments: { action: 'read' },
    })).body.structuredContent.value.count ?? 0).toBe(0);
    second.response.complete();
    await events.wait((event) => event.type === 'idle' && event.threadId === agentId);

    const unknown = await apiCall('PUT', `/instances/${agentId}/operation-grants`, {
      expectedRevision: revoked.body.revision,
      grants: [{ operation: 'plugin.call', instanceId: targetId, tools: ['read-file'] }],
    });
    expect(unknown.status).toBe(409);
    expect((await apiCall('GET', `/instances/${agentId}/operation-grants`)).body).toEqual(revoked.body);
    const restored = await apiCall('PUT', `/instances/${agentId}/operation-grants`, {
      expectedRevision: revoked.body.revision,
      grants: [{ operation: 'plugin.call', instanceId: targetId, tools: ['state'] }],
    });
    expect(restored.status).toBe(200);
    expect(model.calls.values).toHaveLength(2);
    const beforeThird = events.values.length;
    expect((await apiCall('POST', `/threads/${agentId}/messages`, {
      id: randomUUID(), text: '恢复后继续',
    })).status).toBe(200);
    const third = await model.call(3);
    expect(third.request.tools.map((value) => value.name)).toEqual(first.request.tools.map((value) => value.name));
    expect(third.request.allowedTools).toContain(pin.modelName);
    await third.response.emit({ type: 'item', item: modelItem('shared-receipt', pin.modelName, { action: 'increment' }) });
    third.response.complete();
    const fourth = await model.call(4);
    expect(modelResult(fourth.request.history, 'shared-receipt').status).toBe('success');
    expect(JSON.parse(modelResult(fourth.request.history, 'shared-receipt').output).structuredContent.value.count).toBe(1);
    const sharedOperationId = `${third.request.turnId}:shared-receipt`;
    const uiCall = {
      operationId: sharedOperationId, arguments: { action: 'increment' },
    };
    const uiResult = await apiCall('POST', `/instances/${targetId}/plugin/tools/state`, uiCall);
    expect(uiResult.status).toBe(200);
    expect(uiResult.body.structuredContent.value.count).toBe(2);
    fourth.response.complete();
    await events.wait((event) => event.type === 'idle' && event.threadId === agentId
      && events.values.indexOf(event) >= beforeThird);

    const journalPath = join(home, 'sessions', agentId, 'journal.jsonl');
    const configured = diskRecords(journalPath).filter((record) => record.type === 'request.configured');
    expect(configured[0]).toMatchObject({ snapshot: { settings: { pluginTools: [projection] } } });
    await daemon.stop();
    daemon = undefined;

    const resumedModel = new ManualModel();
    daemon = startDaemon({ home, port: 0, model: () => resumedModel });
    const persisted = await apiCall('GET', `/threads/${agentId}`);
    expect(persisted.body.config.pluginTools).toEqual(thread.body.config.pluginTools);
    const retriedModelCall = await daemon.kite.operations.invoke({
      kind: 'model', instanceId: agentId, turnId: third.request.turnId, callId: 'shared-receipt',
    }, workspaceId, 'plugin.call', {
      instanceId: targetId, tool: 'state',
      operationId: sharedOperationId, arguments: { action: 'increment' },
    });
    expect(retriedModelCall).toMatchObject({ structuredContent: { value: { count: 1 } } });
    expect(await apiCall('POST', `/instances/${targetId}/plugin/tools/state`, uiCall)).toEqual(uiResult);
    expect((await apiCall('POST', `/instances/${targetId}/plugin/tools/state`, {
      operationId: 'read-after-restart', arguments: { action: 'read' },
    })).body.structuredContent.value.count).toBe(2);
    expect((await apiCall('POST', `/threads/${agentId}/messages`, {
      id: randomUUID(), text: '重启后继续',
    })).status).toBe(200);
    const afterRestart = await resumedModel.call(1);
    expect(afterRestart.request.tools.map((value) => value.name)).toEqual(first.request.tools.map((value) => value.name));
    expect(afterRestart.request.allowedTools).toContain(pin.modelName);
    const latest = diskRecords(journalPath).filter((record) => record.type === 'request.configured').at(-1);
    expect(latest).toMatchObject({ snapshot: { settings: { pluginTools: [projection] } } });
    afterRestart.response.complete();
  } finally {
    await daemon?.stop();
    rmSync(root, { recursive: true, force: true });
  }
}, 1000);
