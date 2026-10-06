import { expect, test } from 'bun:test';
import { randomUUID } from 'node:crypto';
import { rmSync } from 'node:fs';
import { join } from 'node:path';
import type { AgentDefinition } from '../../src/agents/definition.ts';
import { startDaemon, type Daemon } from '../../src/daemon.ts';
import type { Envelope } from '../../src/events.ts';
import type { ContextDefinition } from '../../src/harness/context/types.ts';
import { call, registerCheckout, startKited } from '../harness.ts';
import { ManualModel, Seen } from '../harness-loop.ts';
import { makeTemp, newRepo } from '../util.ts';

interface Template {
  definition: ContextDefinition;
  revision: string;
}

function definition(id: string, text: string): ContextDefinition {
  return {
    version: 2, id, title: '测试上下文模板', scene: 'thread.create',
    blocks: [{ type: 'paragraph', id: 'rules', title: '规则', parts: [{ type: 'text', text }] }],
  };
}

function withoutContext(agent: AgentDefinition) {
  const { context: _context, ...configuration } = agent;
  return configuration;
}

// HTTP revision 校验、SQLite 落盘、目录重开与首请求绑定共同决定重试是否覆盖已有模板。
test('模板保存处理重试与冲突，重启后首请求使用已存版本', async () => {
  const root = makeTemp('context-templates-');
  const home = join(root, 'kite');
  const model = new ManualModel();
  let daemon: Daemon | undefined;
  try {
    daemon = startDaemon({ home, port: 0, lightTasks: false, model: () => model });
    const first = definition('test.persisted', '保存前版本：先检查项目约定。');
    const created = await call(daemon.url, 'POST', '/context-templates', { definition: first });
    expect(created.status).toBe(200);
    expect(await call(daemon.url, 'POST', '/context-templates', { definition: first })).toEqual(created);

    const next = definition(first.id, '保存后版本：检查完成再报告结果。');
    expect((await call(daemon.url, 'POST', '/context-templates', { definition: next })).status).toBe(409);
    const updated = await call(daemon.url, 'PUT', `/context-templates/${first.id}`, {
      expectedRevision: created.body.revision, definition: next,
    });
    expect(updated.status).toBe(200);
    expect(updated.body.definition).toEqual(next);
    expect(updated.body.revision).not.toBe(created.body.revision);
    expect((await call(daemon.url, 'PUT', `/context-templates/${first.id}`, {
      expectedRevision: created.body.revision, definition: first,
    })).status).toBe(409);
    await daemon.stop();
    daemon = undefined;

    daemon = startDaemon({ home, port: 0, lightTasks: false, model: () => model });
    const events = new Seen<Envelope>();
    daemon.kite.bus.subscribe(undefined, (event) => events.add(event));
    const reopened = await call(daemon.url, 'GET', '/context-templates');
    expect(reopened.status).toBe(200);
    expect(reopened.body.templates.filter((template: Template) => template.definition.id === first.id)).toEqual([updated.body]);
    expect(await call(daemon.url, 'POST', '/context-templates', { definition: next })).toEqual(updated);

    const repo = newRepo(root, 'project', { 'base.txt': '原始内容\n' });
    const checkout = await call(daemon.url, 'POST', '/checkouts', { path: repo });
    expect(checkout.status).toBe(200);
    const workspace = await call(daemon.url, 'POST', '/workspaces', {
      checkout: checkout.body.checkout.id, prompt: '使用重启前的模板', runtime: 'harness',
      contextTemplate: { id: next.id, revision: updated.body.revision },
    });
    expect(workspace.status).toBe(200);
    const id = workspace.body.threads[0].instanceId as string;
    const request = await model.call(1);
    expect(request.request.instructions).toContain('保存后版本：检查完成再报告结果。');
    expect(request.request.instructions).not.toContain('保存前版本：先检查项目约定。');
    request.response.complete();
    await events.wait((event) => event.type === 'idle' && event.threadId === id);
  } finally {
    await daemon?.stop();
    rmSync(root, { recursive: true, force: true });
  }
}, 1000);

// 目录的场景边界、实例快照和创建请求跨模块交接；误选标题模板不得改变实例，合法模板保留配置与权限。
test('模板修改隔离已有实例，切换模板保留配置与权限', async () => {
  const model = new ManualModel();
  const k = startKited(() => model);
  try {
    const repo = newRepo(k.root, 'project', { 'base.txt': '原始内容\n' });
    const registered = await registerCheckout(k, repo);
    const workspaceId = registered.workspace.id;
    const opened = await k.call('POST', `/workspaces/${workspaceId}/windows`, {
      id: randomUUID(), content: { kind: 'create', definitionId: 'kite.agent.coding' },
    });
    expect(opened.status).toBe(200);
    const id = opened.body.target.instanceId as string;
    const configPath = `/instances/${id}/agent-config`;
    const templatePath = `/instances/${id}/context-template`;
    const grantsPath = `/instances/${id}/execution-grants`;
    const initial = await k.call('GET', configPath);
    expect(initial.status).toBe(200);
    const agent: AgentDefinition = {
      ...structuredClone(initial.body.instance.config.agent),
      model: { model: 'template-test-model', reasoning: 'high' }, tools: ['read'], maxRequestsPerTurn: 7,
    };
    const tuned = await k.call('PUT', configPath, { expectedRevision: initial.body.revision, agent });
    expect(tuned.status).toBe(200);
    const initialGrants = await k.call('GET', grantsPath);
    expect(initialGrants.status).toBe(200);
    const grants = await k.call('PUT', grantsPath, {
      expectedRevision: initialGrants.body.revision,
      grants: { workspace: 'read', read: [], write: [], network: [] },
    });
    expect(grants.status).toBe(200);

    const directory = await k.call('GET', '/context-templates');
    expect(directory.status).toBe(200);
    const titleTemplate = (directory.body.templates as Template[]).find((template) => template.definition.scene === 'thread.title');
    if (!titleTemplate) throw new Error('缺少标题模板');
    const beforeRejected = await k.call('GET', configPath);
    expect(beforeRejected.status).toBe(200);
    const rejected = await k.call('PUT', templatePath, {
      expectedRevision: beforeRejected.body.revision, templateId: titleTemplate.definition.id, templateRevision: titleTemplate.revision,
    });
    expect(rejected.status).toBeGreaterThanOrEqual(400);
    expect(rejected.status).toBeLessThan(500);
    expect((await k.call('GET', configPath)).body).toEqual(beforeRejected.body);
    const defaultTemplate = (directory.body.templates as Template[]).find((template) => template.definition.id === 'kite.work');
    if (!defaultTemplate) throw new Error('缺少默认工作模板');
    const first = definition(defaultTemplate.definition.id, '实例快照版本一：只检查当前问题。');
    const saved = await k.call('PUT', `/context-templates/${first.id}`, {
      expectedRevision: defaultTemplate.revision, definition: first,
    });
    expect(saved.status).toBe(200);
    const applied = await k.call('PUT', templatePath, {
      expectedRevision: tuned.body.revision, templateId: first.id, templateRevision: saved.body.revision,
    });
    expect(applied.status).toBe(200);
    expect(applied.body.instance.config.agent.context.blocks).toContainEqual(first.blocks[0]);
    expect(withoutContext(applied.body.instance.config.agent)).toEqual(withoutContext(agent));
    expect((await k.call('GET', grantsPath)).body).toEqual(grants.body);

    const next = definition(first.id, '实例快照版本二：报告问题与证据。');
    const edited = await k.call('PUT', `/context-templates/${next.id}`, {
      expectedRevision: saved.body.revision, definition: next,
    });
    expect(edited.status).toBe(200);
    expect((await k.call('GET', configPath)).body).toEqual(applied.body);
    expect(model.calls.values).toHaveLength(0);

    const latest = await k.call('POST', `/workspaces/${workspaceId}/windows`, {
      id: randomUUID(), content: { kind: 'create', definitionId: 'kite.agent.coding' },
    });
    expect(latest.status).toBe(200);
    const latestConfig = await k.call('GET', `/instances/${latest.body.target.instanceId}/agent-config`);
    expect(latestConfig.status).toBe(200);
    expect(latestConfig.body.instance.config.agent.context.blocks).toContainEqual(next.blocks[0]);

    const created = await k.call('POST', `/workspaces/${workspaceId}/threads`, {
      prompt: '用选择的模板开始', runtime: 'harness',
      contextTemplate: { id: next.id, revision: edited.body.revision },
    });
    expect(created.status).toBe(200);
    const selectedId = created.body.instanceId as string;
    const request = await model.call(1);
    expect(request.request.instructions).toContain('实例快照版本二：报告问题与证据。');
    expect(request.request.instructions).not.toContain('实例快照版本一：只检查当前问题。');
    request.response.complete();
    await k.waitEvent((event) => event.type === 'idle' && event.threadId === selectedId);

    expect((await k.call('PUT', templatePath, {
      expectedRevision: tuned.body.revision, templateId: next.id, templateRevision: edited.body.revision,
    })).status).toBe(409);
    expect((await k.call('GET', configPath)).body).toEqual(applied.body);
    const reapplied = await k.call('PUT', templatePath, {
      expectedRevision: applied.body.revision, templateId: next.id, templateRevision: edited.body.revision,
    });
    expect(reapplied.status).toBe(200);
    expect(reapplied.body.instance.config.agent.context.blocks).toContainEqual(next.blocks[0]);
    expect(withoutContext(reapplied.body.instance.config.agent)).toEqual(withoutContext(agent));
    expect((await k.call('GET', grantsPath)).body).toEqual(grants.body);
    expect(model.calls.values).toHaveLength(1);
  } finally {
    await k.stop();
  }
}, 1000);
