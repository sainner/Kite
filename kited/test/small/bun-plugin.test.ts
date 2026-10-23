import { afterAll, expect, spyOn, test } from 'bun:test';
import { randomUUID } from 'node:crypto';
import { existsSync, mkdirSync, readFileSync, rmSync, symlinkSync, watch, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { startDaemon, type Daemon } from '../../src/daemon.ts';
import type { Envelope } from '../../src/events.ts';
import { TOOL_SEARCH } from '../../src/harness/tool-search.ts';
import type { Json, ModelItem } from '../../src/harness/types.ts';
import { call, folderWorkspace, startKited, type Kited } from '../harness.ts';
import { deferred, diskRecords, item, ManualModel, Seen } from '../harness-loop.ts';
import { editNotificationTemplate } from '../notification-templates.ts';
import { bunPluginSource } from '../fixtures/bun-plugin-source.ts';
import { makeTemp, newDir } from '../util.ts';

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

/** 按文件夹添加项目并建好工作区，返回工作区；工作区的文件在它的工作树（cwd）里，不在导入来源的文件夹里。 */
async function workspace(k: Kited, repo: string) {
  return (await folderWorkspace(k, repo)).workspace;
}

async function install(k: Kited, views?: { id: string; title: string; resourceUri: string }[], lifetime: 'window' | 'persistent' = 'persistent') {
  const pack = { id: 'custom.test', title: '测试', bundle: await bundle, views, lifetime };
  const installed = await k.call('POST', '/plugin-definitions', pack);
  expect(installed.status).toBe(200);
}

async function createInstance(k: Kited, workspaceId: string) {
  const id = randomUUID();
  const created = await k.call('POST', `/workspaces/${workspaceId}/plugin-instances`, {
    id, definitionId: 'custom.test', title: '测试实例',
  });
  expect(created.status).toBe(200);
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
    id: randomUUID(), content: { kind: 'create', definitionId: 'kite.agent' },
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

// 真实 MCP SDK 的资源内容和 _meta 经 stdio 到 HTTP；关窗与运行进程的生命周期必须在一起验证。
// 插件子进程停止与宿主拒绝重启跨进程交接：归档返回前插件进程须已退出；宿主撤下停止期间的启动阻止后，
// UI 调用、工具发现和视图读取都不能把已归档实例的进程重新拉起。随窗口实例没有独立存续，不能归档。
test('声明的 MCP App 视图读取本实例资源，拒绝不安全内容，关窗后实例继续运行；归档先停掉插件进程并收起窗口，之后的调用被拒绝且不再拉起进程，随窗口实例拒绝归档', async () => {
  const k = startKited();
  try {
    const { id: workspaceId } = await workspace(k, newDir(k.root, 'project', { 'note.txt': '原始\n' }));
    const invalid = ['non-html', 'missing', 'multiple', 'wrong-uri', 'network', 'permissions', 'oversized'];
    await install(k, ['state', ...invalid].map((id) => ({
      id, title: id, resourceUri: `ui://test/${id}.html`,
    })));
    const instanceId = await createInstance(k, workspaceId);
    const readView = (id: string) => k.call('GET', `/instances/${instanceId}/plugin/views/${id}`);
    expect(await readView('state')).toEqual({
      status: 200, body: { html: '<main>计数：0</main>', resourceUri: 'ui://test/state.html' },
    });
    output(await tool(k, instanceId, 'state', 'view-increment', { action: 'increment' }));
    expect((await readView('state')).body).toEqual({
      html: '<main>计数：1</main>', resourceUri: 'ui://test/state.html',
    });
    for (const id of ['unlisted', ...invalid]) {
      const rejected = await readView(id);
      expect(rejected.status, `${id} 不应成为可加载视图`).not.toBe(200);
    }

    const openView = () => k.call('POST', `/workspaces/${workspaceId}/windows`, {
      id: randomUUID(), content: { kind: 'open', instanceId, viewId: 'state' },
    });
    const opened = await openView();
    expect(opened.status).toBe(200);
    expect(opened.body.target.instanceId).toBe(instanceId);
    const beforeClose = output(await tool(k, instanceId, 'state', 'view-opened', { action: 'read' }));
    expect((await k.call('DELETE', `/workspaces/${workspaceId}/windows/${opened.body.id}`)).status).toBe(200);
    const running = output(await tool(k, instanceId, 'state', 'view-closed', { action: 'read' }));
    expect(running).toMatchObject({ pid: beforeClose.pid, value: { count: 1 } });

    // 再开一个窗口后归档：进程先停、窗口收起。
    expect((await openView()).status).toBe(200);
    expect((await k.call('GET', `/instances/${instanceId}/plugin/process`)).body.phase).toBe('running');
    expect((await k.call('POST', `/instances/${instanceId}/archive`)).status).toBe(200);
    expect(() => process.kill(running.pid, 0)).toThrow();
    expect(k.daemon.kite.store.instance(instanceId)?.status).toBe('archived');
    const archived = await k.call('GET', `/workspaces/${workspaceId}`);
    expect(archived.body.windows.filter((value: { target: { instanceId: string } }) =>
      value.target.instanceId === instanceId)).toEqual([]);

    expect((await tool(k, instanceId, 'state', 'archive-after', { action: 'read' })).status).not.toBe(200);
    expect((await k.call('GET', `/instances/${instanceId}/plugin/tools`)).status).not.toBe(200);
    expect((await readView('state')).status).not.toBe(200);
    const afterCalls = await k.call('GET', `/instances/${instanceId}/plugin/process`);
    expect(afterCalls.body.phase ?? 'stopped').toBe('stopped');
    expect(k.daemon.kite.store.instance(instanceId)?.status).toBe('archived');

    const filesId = await filesTarget(k, workspaceId);
    expect((await k.call('POST', `/instances/${filesId}/archive`)).status).toBe(400);
  } finally {
    await k.stop();
  }
}, 1000);

// 真实 Bun SDK、宿主授权与 SQLite 交接；工具发现等待时并发写入不能被工作区队列阻塞或被旧结果覆盖。
// Seatbelt/bubblewrap 的真实进程隔离、后代继承和进程组取消不能由启动参数或 MCP 消息验证。
test('Bun 插件及其后代被沙箱隔离，工作区回调随授权即时变化；停止阻塞工具后同一 operationId 保持 unknown，状态和工具收据跨进程重启保留', async () => {
  const oldSecret = process.env.KITE_TEST_HOST_SECRET;
  process.env.KITE_TEST_HOST_SECRET = 'fixture-host-secret';
  const k = startKited();
  const listener = Bun.serve({ hostname: '127.0.0.1', port: 0, fetch: () => new Response('reachable') });
  const discoveryStarted = deferred();
  const releaseDiscovery = deferred();
  let discovery: ReturnType<typeof spyOn> | undefined;
  let pendingGrant: ReturnType<Kited['call']> | undefined;
  try {
    const { id: workspaceId, cwd } = await workspace(k, newDir(k.root, 'project', { 'note.txt': '可读内容\n' }));
    await install(k);
    const instanceId = await createInstance(k, workspaceId);

    const before = output(await tool(k, instanceId, 'state', 'read-before', { action: 'read' }));
    const increment = await tool(k, instanceId, 'state', 'increment-once', { action: 'increment' });
    expect(output(increment).value.count).toBe(1);
    expect(await tool(k, instanceId, 'state', 'increment-once', { action: 'increment' })).toEqual(increment);
    expect(output(await tool(k, instanceId, 'state', 'stale', {
      action: 'stale', expectedRevision: before.revision,
    })).staleRejected).toBe(true);

    const externalFile = join(k.root, 'outside-secret.txt');
    const hostFile = join(k.home, 'host-secret.txt');
    writeFileSync(externalFile, '外部秘密');
    mkdirSync(k.home, { recursive: true });
    writeFileSync(hostFile, '宿主秘密');
    const probe = output(await tool(k, instanceId, 'probe', 'probe', {
      workspaceFile: join(cwd, 'note.txt'), externalFile, hostFile, port: listener.port,
    }));
    expect(probe).toMatchObject({
      workspaceRead: false, externalRead: false, hostRead: false, hostSecret: null,
      tempWrite: true, childExit: 0, childRead: 'denied',
    });
    expect(probe.tcp).not.toBe('connected');
    expect(probe.tcp).not.toBe('timeout');

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

    const callerId = await codingInstance(k, workspaceId);
    const callerGrantsPath = `/instances/${callerId}/operation-grants`;
    const callerGrants = await k.call('GET', callerGrantsPath);
    expect(callerGrants.status).toBe(200);
    const readTools = k.daemon.kite.plugins.tools.bind(k.daemon.kite.plugins);
    discovery = spyOn(k.daemon.kite.plugins, 'tools').mockImplementationOnce(async (id) => {
      const tools = await readTools(id);
      discoveryStarted.resolve();
      await releaseDiscovery.promise;
      return tools;
    });
    pendingGrant = k.call('PUT', callerGrantsPath, {
      expectedRevision: callerGrants.body.revision,
      grants: [{ operation: 'plugin.call', instanceId, tools: ['state'] }],
    });
    await discoveryStarted.promise;
    const winner = await k.call('PUT', callerGrantsPath, {
      expectedRevision: callerGrants.body.revision, grants: [{ operation: 'monitor.start' }],
    });
    expect(winner.status).toBe(200);
    expect(winner.body.revision).not.toBe(callerGrants.body.revision);
    releaseDiscovery.resolve();
    expect((await pendingGrant).status).toBe(409);
    expect((await k.call('GET', callerGrantsPath)).body).toEqual(winner.body);
    discovery.mockRestore();
    discovery = undefined;

    // 阻塞的工具挂着时停掉插件进程：这次调用和同一 operationId 的重试都是 unknown，插件进程与后代都退出。
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

    // 下一次调用重新拉起插件进程，状态还在。
    const restored = output(await tool(k, instanceId, 'state', 'read-restarted', { action: 'read' }));
    expect(restored.value.count).toBe(1);
    expect(restored.pid).not.toBe(before.pid);
  } finally {
    releaseDiscovery.resolve();
    discovery?.mockRestore();
    await pendingGrant?.catch(() => {});
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
    const { id: workspaceId } = await workspace(k, newDir(k.root, 'project', { 'base.txt': '原始\n' }));
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
      instanceId: string; toolName: string;
      modelName: string; description: string; parameters: Record<string, unknown>;
    }>;
    expect(bindings.map((value) => value.instanceId).sort()).toEqual([firstId, secondId].sort());
    expect(bindings.map((value) => value.toolName)).toEqual(['state', 'state']);
    expect(new Set(bindings.map((value) => value.modelName)).size).toBe(2);
    for (const binding of bindings) {
      expect(binding.parameters).toEqual(stateSchema);
    }

    expect((await k.call('POST', `/threads/${agentId}/messages`, {
      id: randomUUID(), text: '两个计数器各加一次',
    })).status).toBe(200);
    // 插件工具经 tool_search 按实例加载：加载结果带两个实例各自的 state 定义，下一次请求才放行它们。
    const first = await model.call(1);
    await first.response.emit({ type: 'item', item: modelItem('search', TOOL_SEARCH, { groups: [firstId, secondId] }) });
    first.response.complete();
    const second = await model.call(2);
    const loaded = modelResult(second.request.history, 'search');
    expect(loaded.status).toBe('success');
    expect(loaded.tools).toHaveLength(bindings.length);
    for (const binding of bindings) {
      expect(loaded.tools).toContainEqual({
        name: binding.modelName, description: binding.description, parameters: stateSchema,
      });
    }
    // 加载新放行的只有这两个 state，app-only 不进模型可用的工具。
    expect(second.request.allowedTools!.filter((name) => !first.request.allowedTools!.includes(name)).sort())
      .toEqual(bindings.map((value) => value.modelName).sort());
    const [one, two] = bindings;
    await second.response.emit({ type: 'item', item: modelItem('first', one!.modelName, { action: 'increment' }) });
    await second.response.emit({ type: 'item', item: modelItem('second', two!.modelName, { action: 'increment' }) });
    await second.response.emit({ type: 'item', item: modelItem('invalid', one!.modelName, { action: 42 }) });
    second.response.complete();
    const third = await model.call(3);
    for (const id of ['first', 'second']) {
      const result = modelResult(third.request.history, id);
      expect(result.status).toBe('success');
      expect(JSON.parse(result.output).structuredContent.value.count).toBe(1);
    }
    expect(modelResult(third.request.history, 'invalid').status).toBe('error');
    expect(output(await tool(k, firstId, 'state', 'verify-first', { action: 'read' })).value.count).toBe(1);
    expect(output(await tool(k, secondId, 'state', 'verify-second', { action: 'read' })).value.count).toBe(1);
    third.response.complete();
    await k.waitEvent((event) => event.type === 'idle' && event.threadId === agentId);
  } finally {
    await k.stop();
  }
}, 1000);

// 目录模板、模型响应与撤权并发，随后经 journal、SQLite 和重启；通知快照与执行时授权各自保持。
test('撤权拒绝旧模型调用，工具通知按生成时模板冻结且目录与收据跨重启保留', async () => {
  const root = makeTemp('plugin-model-');
  const home = join(root, 'kite');
  const repo = newDir(root, 'project', { 'base.txt': '原始\n' });
  const model = new ManualModel();
  let daemon: Daemon | undefined;
  try {
    daemon = startDaemon({ home, port: 0, lightTasks: false, model: () => model });
    const events = new Seen<Envelope>();
    daemon.kite.bus.subscribe(undefined, (event) => events.add(event));
    const apiCall = (method: string, path: string, body?: unknown) => call(daemon!.url, method, path, body);
    const workspaceId = (await folderWorkspace(daemon, repo)).workspace.id;
    expect((await apiCall('POST', '/plugin-definitions', {
      id: 'custom.test', title: '测试', bundle: await bundle, lifetime: 'persistent',
    })).status).toBe(200);
    const targetId = randomUUID();
    expect((await apiCall('POST', `/workspaces/${workspaceId}/plugin-instances`, {
      id: targetId, definitionId: 'custom.test', title: '目标',
    })).status).toBe(200);
    const opened = await apiCall('POST', `/workspaces/${workspaceId}/windows`, {
      id: randomUUID(), content: { kind: 'create', definitionId: 'kite.agent' },
    });
    expect(opened.status).toBe(200);
    const agentId = opened.body.target.instanceId as string;
    const oldToolsTemplate = await editNotificationTemplate(apiCall,
      'kite.plugin-tools', '插件通知旧模板', 'plugin.tools');
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
    expect(first.request.history.some((entry) => entry.type === 'notification'
      && entry.text.includes('插件通知旧模板') && entry.text.includes(pin.modelName) && entry.text.includes(targetId))).toBe(true);
    await first.response.emit({ type: 'item', item: modelItem('search', TOOL_SEARCH, { groups: [targetId] }) });
    first.response.complete();
    const second = await model.call(2);
    expect(second.request.allowedTools).toContain(pin.modelName);
    const revoked = await apiCall('PUT', `/instances/${agentId}/operation-grants`, {
      expectedRevision: granted.body.revision, grants: [],
    });
    expect(revoked.status).toBe(200);
    expect(model.calls.values).toHaveLength(2);
    expect(second.signal.aborted).toBe(false);
    const pending = structuredClone(daemon.kite.store.instanceNotifications(agentId, 0));
    expect(pending.at(-1)!.context.definition).toEqual(oldToolsTemplate.definition);
    await editNotificationTemplate(apiCall, 'kite.plugin-tools', '插件通知新模板', 'plugin.tools');
    expect(daemon.kite.store.instanceNotifications(agentId, 0)).toEqual(pending);
    expect((await apiCall('GET', `/instances/${agentId}/operation-grants`)).body).toEqual(revoked.body);
    expect(model.calls.values).toHaveLength(2);
    await second.response.emit({ type: 'item', item: modelItem('stale-call', pin.modelName, { action: 'increment' }) });
    second.response.complete();
    const third = await model.call(3);
    const denied = modelResult(third.request.history, 'stale-call');
    expect(denied.status).toBe('error');
    expect(JSON.parse(denied.output)).toMatchObject({ outcome: 'denied' });
    expect(third.request.tools.map((value) => value.name)).toEqual(first.request.tools.map((value) => value.name));
    expect(third.request.allowedTools).not.toContain(pin.modelName);
    expect(third.request.history).toContainEqual(expect.objectContaining({
      type: 'notification', notification: expect.objectContaining({ kind: 'plugin.tools.changed' }),
    }));
    const previousToolsUpdates = third.request.history.filter((entry) => entry.type === 'notification')
      .filter((entry) => entry.notification.kind === 'plugin.tools.changed');
    for (const update of previousToolsUpdates) {
      expect(update.text).toContain('插件通知旧模板');
      expect(update.text).not.toContain('插件通知新模板');
    }
    expect((await apiCall('POST', `/instances/${targetId}/plugin/tools/state`, {
      operationId: 'read-after-revoke', arguments: { action: 'read' },
    })).body.structuredContent.value.count ?? 0).toBe(0);
    third.response.complete();
    await events.wait((event) => event.type === 'idle' && event.threadId === agentId);

    const restored = await apiCall('PUT', `/instances/${agentId}/operation-grants`, {
      expectedRevision: revoked.body.revision,
      grants: [{ operation: 'plugin.call', instanceId: targetId, tools: ['state'] }],
    });
    expect(restored.status).toBe(200);
    expect(model.calls.values).toHaveLength(3);
    const beforeFourth = events.values.length;
    expect((await apiCall('POST', `/threads/${agentId}/messages`, {
      id: randomUUID(), text: '恢复后继续',
    })).status).toBe(200);
    // 重新授权后定义未变，历史里加载过的工具不用再搜就放行。
    const fourth = await model.call(4);
    expect(fourth.request.tools.map((value) => value.name)).toEqual(first.request.tools.map((value) => value.name));
    expect(fourth.request.allowedTools).toContain(pin.modelName);
    const toolsUpdates = fourth.request.history.filter((entry) => entry.type === 'notification')
      .filter((entry) => entry.notification.kind === 'plugin.tools.changed');
    expect(toolsUpdates.slice(0, previousToolsUpdates.length)).toEqual(previousToolsUpdates);
    expect(toolsUpdates.at(-1)!.text).toContain('插件通知新模板');
    expect(toolsUpdates.at(-1)!.text).toContain(pin.modelName);
    await fourth.response.emit({ type: 'item', item: modelItem('shared-receipt', pin.modelName, { action: 'increment' }) });
    fourth.response.complete();
    const fifth = await model.call(5);
    expect(modelResult(fifth.request.history, 'shared-receipt').status).toBe('success');
    expect(JSON.parse(modelResult(fifth.request.history, 'shared-receipt').output).structuredContent.value.count).toBe(1);
    const sharedOperationId = `${fourth.request.turnId}:shared-receipt`;
    const uiCall = {
      operationId: sharedOperationId, arguments: { action: 'increment' },
    };
    const uiResult = await apiCall('POST', `/instances/${targetId}/plugin/tools/state`, uiCall);
    expect(uiResult.status).toBe(200);
    expect(uiResult.body.structuredContent.value.count).toBe(2);
    fifth.response.complete();
    await events.wait((event) => event.type === 'idle' && event.threadId === agentId
      && events.values.indexOf(event) >= beforeFourth);

    const journalPath = join(home, 'sessions', agentId, 'journal.jsonl');
    const configured = diskRecords(journalPath).filter((record) => record.type === 'request.configured');
    expect(configured[0]).toMatchObject({ snapshot: { settings: { pluginTools: [projection] } } });
    await editNotificationTemplate(apiCall, 'kite.plugin-tools', '插件通知未来模板', 'plugin.tools');
    expect(model.calls.values).toHaveLength(5);
    await daemon.stop();
    daemon = undefined;

    const resumedModel = new ManualModel();
    daemon = startDaemon({ home, port: 0, lightTasks: false, model: () => resumedModel });
    const persisted = await apiCall('GET', `/threads/${agentId}`);
    expect(persisted.body.config.pluginTools).toEqual(thread.body.config.pluginTools);
    const retriedModelCall = await daemon.kite.operations.invoke({
      kind: 'model', instanceId: agentId, turnId: fourth.request.turnId, callId: 'shared-receipt',
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
    expect(afterRestart.request.history.filter((entry) => entry.type === 'notification'
      && entry.notification.kind === 'plugin.tools.changed')).toEqual(toolsUpdates);
    // 配置记录按内容去重，取重启后这次请求实际用的那份。
    const records = diskRecords(journalPath);
    const started = records.find((record) => record.type === 'request.started' && record.requestId === afterRestart.request.id);
    if (started?.type !== 'request.started') throw new Error('重启后的请求没有开始记录');
    expect(records.find((record) => record.type === 'request.configured' && record.snapshot.id === started.configurationId))
      .toMatchObject({ snapshot: { settings: { pluginTools: [projection] } } });
    afterRestart.response.complete();
  } finally {
    await daemon?.stop();
    rmSync(root, { recursive: true, force: true });
  }
}, 1000);
