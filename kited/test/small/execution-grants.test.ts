import { afterEach, expect, test } from 'bun:test';
import { randomUUID } from 'node:crypto';
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import type { ExecutionGrants } from '../../src/execution/grants.ts';
import type { Json, ModelItem } from '../../src/harness/types.ts';
import { after, mark, registerCheckout, startKited, type Kited } from '../harness.ts';
import { diskRecords, item, ManualModel } from '../harness-loop.ts';
import { editNotificationTemplate } from '../notification-templates.ts';
import { newRepo } from '../util.ts';

let kited: Kited | undefined;
afterEach(async () => { await kited?.stop(); kited = undefined; });

const grantsPath = (id: string) => `/instances/${id}/execution-grants`;

async function codingInstance(k: Kited) {
  const repo = newRepo(k.root, 'project', { 'base.txt': '原始内容\n' });
  const registered = await registerCheckout(k, repo);
  const opened = await k.call('POST', `/workspaces/${registered.workspace.id}/windows`, {
    id: randomUUID(), content: { kind: 'create', definitionId: 'kite.agent' },
  });
  expect(opened.status).toBe(200);
  return { id: opened.body.target.instanceId as string, cwd: registered.workspace.cwd };
}

function calledItem(id: string, name: string, args: Json): ModelItem {
  return { ...item(id, name), call: { id, name, arguments: args } };
}

function result(history: Awaited<ReturnType<ManualModel['call']>>['request']['history'], callId: string) {
  const entry = history.find((item) => item.type === 'tool_result' && item.callId === callId);
  if (entry?.type !== 'tool_result') throw new Error(`缺少工具结果：${callId}`);
  return entry.result;
}

// HTTP 授权提交与 SQLite 通知快照交接；排队后编辑目录不得重渲染旧通知或改变执行权限。
test('空闲时授权保留通知快照，重试不重复投递或改动历史', async () => {
  const model = new ManualModel();
  kited = startKited(() => model);
  const k = kited;
  const { id } = await codingInstance(k);
  const initial = await k.call('GET', grantsPath(id));
  expect(initial.status).toBe(200);
  const readOnly: ExecutionGrants = { workspace: 'read', read: [], write: [], network: [] };
  const oldTemplate = await editNotificationTemplate(k.call,
    'kite.execution-permissions', '权限通知旧模板', 'execution.grants');

  expect((await k.call('POST', `/threads/${id}/messages`, { id: randomUUID(), text: '先执行' })).status).toBe(200);
  const first = await model.call(1);
  expect((await k.call('PUT', grantsPath(id), {
    expectedRevision: initial.body.revision, grants: readOnly,
  })).status).toBe(409);
  first.response.complete();
  await k.waitEvent((event) => event.type === 'idle' && event.threadId === id);

  for (const endpoint of ['localhost:8080', '127.0.0.1:8080', '[::1]:8080', '[::ffff:127.0.0.1]:8080', '2130706433:8080']) {
    const localhost: ExecutionGrants = { ...readOnly, network: [endpoint] };
    expect((await k.call('PUT', grantsPath(id), {
      expectedRevision: initial.body.revision, grants: localhost,
    })).status).not.toBe(200);
    expect((await k.call('GET', grantsPath(id))).body).toEqual(initial.body);
  }
  const updated = await k.call('PUT', grantsPath(id), { expectedRevision: initial.body.revision, grants: readOnly });
  expect(updated.status).toBe(200);
  expect(updated.body.grants).toEqual(readOnly);
  expect(updated.body.revision).not.toBe(initial.body.revision);
  expect((await k.call('PUT', grantsPath(id), {
    expectedRevision: initial.body.revision, grants: initial.body.grants,
  })).status).toBe(409);
  const repeated = await k.call('PUT', grantsPath(id), { expectedRevision: updated.body.revision, grants: readOnly });
  expect(repeated.status).toBe(200);
  expect(repeated.body).toEqual(updated.body);
  expect((await k.call('GET', grantsPath(id))).body).toEqual(updated.body);
  expect(model.calls.values).toHaveLength(1);
  const pending = structuredClone(k.daemon.kite.store.instanceNotifications(id, 0));
  const permissionsNotice = pending.find((notice) => notice.context.definition.scene === 'thread.execution_permissions_changed');
  if (!permissionsNotice) throw new Error('缺少排队中的执行授权通知');
  expect(permissionsNotice.context.definition).toEqual(oldTemplate.definition);
  expect(JSON.parse(permissionsNotice.context.bindings['execution.grants']!.text)).toEqual(readOnly);
  await editNotificationTemplate(k.call, 'kite.execution-permissions', '权限通知新模板', 'execution.grants');
  expect(k.daemon.kite.store.instanceNotifications(id, 0)).toEqual(pending);
  expect((await k.call('GET', grantsPath(id))).body).toEqual(updated.body);
  expect(model.calls.values).toHaveLength(1);

  const since = mark(k);
  expect((await k.call('POST', `/threads/${id}/messages`, { id: randomUUID(), text: '继续执行' })).status).toBe(200);
  const second = await model.call(2);
  expect(second.request.instructions).toBe(first.request.instructions);
  expect(second.request.history.slice(0, first.request.history.length)).toEqual(first.request.history);
  const permissionUpdates = second.request.history.filter((entry) => entry.type === 'notification')
    .filter((entry) => entry.notification.kind === 'execution.permissions.changed');
  expect(permissionUpdates).toHaveLength(1);
  expect(permissionUpdates[0]!.text).toContain('权限通知旧模板');
  expect(permissionUpdates[0]!.text).toContain(permissionsNotice.context.bindings['execution.grants']!.text);
  expect(permissionUpdates[0]!.text).not.toContain('权限通知新模板');
  const configured = diskRecords(join(k.home, 'sessions', id, 'journal.jsonl'))
    .filter((record) => record.type === 'request.configured');
  expect(configured.at(-1)!.snapshot.settings.execution).toEqual({ revision: updated.body.revision, grants: readOnly });
  second.response.complete();
  await k.waitEvent((event) => event.type === 'idle' && event.threadId === id && after(k, since)(event));
}, 1000);

// 缓存 Runner、OS 沙箱与模型创建子实例跨请求交接；额外目录许可不能提升受管工具或子实例权限。
test('缓存实例采用新授权，额外目录不提升受管工具和子实例权限', async () => {
  const model = new ManualModel();
  kited = startKited(() => model);
  const k = kited;
  const { id, cwd } = await codingInstance(k);
  const outside = join(k.root, 'allowed-outside');
  const hostAuth = join(k.home, 'auth');
  mkdirSync(outside);
  mkdirSync(hostAuth, { recursive: true });
  writeFileSync(join(outside, 'outside.txt'), '工作区外内容\n');
  const initial = await k.call('GET', grantsPath(id));
  expect(initial.status).toBe(200);

  expect((await k.call('POST', `/threads/${id}/messages`, { id: randomUUID(), text: '建立运行时' })).status).toBe(200);
  const first = await model.call(1);
  first.response.complete();
  await k.waitEvent((event) => event.type === 'idle' && event.threadId === id);

  for (const protectedGrant of [
    { workspace: 'read', read: [k.root], write: [], network: [] },
    { workspace: 'read', read: [k.home], write: [], network: [] },
    { workspace: 'read', read: [], write: [hostAuth], network: [] },
  ] satisfies ExecutionGrants[]) {
    expect((await k.call('PUT', grantsPath(id), {
      expectedRevision: initial.body.revision, grants: protectedGrant,
    })).status).not.toBe(200);
    expect((await k.call('GET', grantsPath(id))).body).toEqual(initial.body);
  }
  const narrowed: ExecutionGrants = { workspace: 'read', read: [], write: [outside], network: [] };
  expect((await k.call('PUT', grantsPath(id), { expectedRevision: initial.body.revision, grants: narrowed })).status).toBe(200);

  const since = mark(k);
  expect((await k.call('POST', `/threads/${id}/messages`, { id: randomUUID(), text: '检查新授权' })).status).toBe(200);
  const second = await model.call(2);
  await second.response.emit({ type: 'item', item: calledItem('read-workspace', 'read', { path: 'base.txt' }) });
  await second.response.emit({ type: 'item', item: calledItem('read-outside', 'read', { path: join(outside, 'outside.txt') }) });
  await second.response.emit({ type: 'item', item: calledItem('patch-workspace', 'patch', {
    operations: [{ type: 'create_file', path: 'blocked-patch.txt', diff: '+不应写入\n+' }],
  }) });
  await second.response.emit({ type: 'item', item: calledItem('shell-paths', 'shell', {
    description: '验证撤权和额外目录',
    command: `printf denied > '${join(cwd, 'blocked-shell.txt')}' 2>/dev/null; printf allowed > '${join(outside, 'allowed.txt')}'`,
  }) });
  await second.response.emit({ type: 'item', item: calledItem('create-child', 'agent_start', {
    role: 'kite.work', presentation: 'background',
  }) });
  second.response.complete();

  const third = await model.call(3);
  expect(result(third.request.history, 'read-workspace')).toMatchObject({ status: 'success', output: expect.stringContaining('原始内容') });
  expect(result(third.request.history, 'read-outside').status).not.toBe('success');
  expect(result(third.request.history, 'patch-workspace').status).not.toBe('success');
  expect(result(third.request.history, 'shell-paths').status).toBe('success');
  expect(result(third.request.history, 'create-child').status).toBe('success');
  expect(existsSync(join(cwd, 'blocked-patch.txt'))).toBe(false);
  expect(existsSync(join(cwd, 'blocked-shell.txt'))).toBe(false);
  expect(readFileSync(join(outside, 'allowed.txt'), 'utf8')).toBe('allowed');
  const aggregate = await k.call('GET', '/workspaces');
  const child = aggregate.body.flatMap((workspace: { instances: Array<{ id: string; origin?: { callId: string } }> }) => workspace.instances)
    .find((instance: { origin?: { callId: string } }) => instance.origin?.callId === 'create-child');
  if (!child) throw new Error('模型没有创建工作角色的子实例');
  expect((await k.call('GET', grantsPath(child.id))).body.grants).toEqual({ workspace: 'read', read: [], write: [], network: [] });
  third.response.complete();
  await k.waitEvent((event) => event.type === 'idle' && event.threadId === id && after(k, since)(event));
}, 1000);
