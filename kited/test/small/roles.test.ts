import { expect, test } from 'bun:test';
import { Database } from 'bun:sqlite';
import { createHash } from 'node:crypto';
import { rmSync } from 'node:fs';
import { join } from 'node:path';
import type { AgentDefinition } from '../../src/agents/definition.ts';
import { defaultAgentModel } from '../../src/agents/models.ts';
import { startDaemon, type Daemon } from '../../src/daemon.ts';
import type { Envelope } from '../../src/events.ts';
import { contextDefinitionSchema } from '../../src/harness/context/assembler.ts';
import type { ContextDefinition } from '../../src/harness/context/types.ts';
import type { Role } from '../../src/roles.ts';
import type { EmblemDesign, EmblemStatus } from '../../src/template-emblems.ts';
import { call, claudeModel, linkNewAccount, openAgent, registerCheckout, startKited } from '../harness.ts';
import { ManualModel, Seen } from '../harness-loop.ts';
import { makeTemp, newRepo } from '../util.ts';

interface Entry extends EmblemStatus { role: Role; revision: string }

function role(id: string, text: string, overrides: Partial<Role> = {}): Role {
  return {
    version: 1, id, title: '测试角色',
    context: {
      version: 2, id, title: '测试角色', scene: 'thread.create',
      blocks: [{ type: 'paragraph', id: 'rules', title: '规则', parts: [{ type: 'text', text }] }],
    },
    tools: { mode: 'deny', tools: [], required: [] },
    model: { model: defaultAgentModel, reasoning: 'medium' }, maxRequestsPerTurn: 50,
    ...overrides,
  };
}

const entries = (body: { roles: Entry[] }) => body.roles;
const findRole = (body: { roles: Entry[] }, id: string) => {
  const found = entries(body).find((entry) => entry.role.id === id);
  if (!found) throw new Error(`角色目录里没有 ${id}`);
  return found;
};

// HTTP revision 校验、SQLite 落盘、重开后的角色目录与首请求绑定共同决定重试是否覆盖已有角色。
test('角色保存处理重试与冲突，重启后按所选版本创建的首请求使用已存提示词', async () => {
  const root = makeTemp('roles-');
  const home = join(root, 'kite');
  const account = linkNewAccount(home);
  const model = new ManualModel();
  let daemon: Daemon | undefined;
  try {
    daemon = startDaemon({ home, port: 0, lightTasks: false, model: () => model });
    const first = role('test.persisted', '保存前版本：先检查项目约定。');
    const created = await call(daemon.url, 'POST', '/roles', { role: first });
    expect(created.status).toBe(200);
    expect(created.body.role).toEqual(first);
    expect(await call(daemon.url, 'POST', '/roles', { role: first })).toEqual(created);

    const next = role(first.id, '保存后版本：检查完成再报告结果。');
    expect((await call(daemon.url, 'POST', '/roles', { role: next })).status).toBe(409);
    const updated = await call(daemon.url, 'PUT', `/roles/${first.id}`, {
      expectedRevision: created.body.revision, role: next,
    });
    expect(updated.status).toBe(200);
    expect(updated.body.role).toEqual(next);
    expect(updated.body.revision).not.toBe(created.body.revision);
    expect((await call(daemon.url, 'PUT', `/roles/${first.id}`, {
      expectedRevision: created.body.revision, role: first,
    })).status).toBe(409);
    await daemon.stop();
    daemon = undefined;

    daemon = startDaemon({ home, port: 0, lightTasks: false, model: () => model });
    const events = new Seen<Envelope>();
    daemon.kite.bus.subscribe(undefined, (event) => events.add(event));
    const reopened = await call(daemon.url, 'GET', '/roles');
    expect(reopened.status).toBe(200);
    expect(entries(reopened.body).filter((entry) => entry.role.id === first.id)).toEqual([updated.body]);
    expect(await call(daemon.url, 'POST', '/roles', { role: next })).toEqual(updated);

    const repo = newRepo(root, 'project', { 'base.txt': '原始内容\n' });
    const checkout = await call(daemon.url, 'POST', '/checkouts', { path: repo });
    expect(checkout.status).toBe(200);
    const workspace = await call(daemon.url, 'POST', '/workspaces', {
      checkout: checkout.body.checkout.id, prompt: '使用重启前的角色',
      role: { id: next.id, revision: updated.body.revision },
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
    account.stop();
    rmSync(root, { recursive: true, force: true });
  }
}, 1000);

// 角色目录、实例快照、改选角色与创建请求跨模块交接：改角色只影响之后创建的代理；改选角色把提示词、工具、
// 默认模型与预算一起换成角色的并记下新的角色约束，执行授权与操作授权不动；版本过期的请求不改变实例。
test('改角色不影响已有代理，改选角色换上角色的配置并保留授权，过期的角色版本或配置版本都不改变实例', async () => {
  const model = new ManualModel();
  const k = startKited(() => model);
  try {
    const repo = newRepo(k.root, 'project', { 'base.txt': '原始内容\n' });
    const registered = await registerCheckout(k, repo);
    const workspaceId = registered.workspace.id;
    const universe = (await k.call('GET', '/roles')).body.tools as string[];
    const id = await openAgent(k.call, workspaceId);
    const configPath = `/instances/${id}/agent-config`;
    const rolePath = `/instances/${id}/role`;
    const grantsPath = `/instances/${id}/execution-grants`;
    const operationsPath = `/instances/${id}/operation-grants`;
    const initial = await k.call('GET', configPath);
    expect(initial.status).toBe(200);
    const agent: AgentDefinition = {
      ...structuredClone(initial.body.instance.config.agent),
      model: { model: 'role-test-model', reasoning: 'high' }, tools: ['read'], maxRequestsPerTurn: 7,
    };
    const tuned = await k.call('PUT', configPath, { expectedRevision: initial.body.revision, agent });
    expect(tuned.status).toBe(200);
    const initialGrants = await k.call('GET', grantsPath);
    const grants = await k.call('PUT', grantsPath, {
      expectedRevision: initialGrants.body.revision,
      grants: { workspace: 'read', read: [], write: [], network: [] },
    });
    expect(grants.status).toBe(200);
    const initialOperations = await k.call('GET', operationsPath);
    const operations = await k.call('PUT', operationsPath, {
      expectedRevision: initialOperations.body.revision, grants: [{ operation: 'agent.list' }],
    });
    expect(operations.status).toBe(200);
    const granted = await k.call('GET', configPath);
    expect(granted.body.revision).toBe(tuned.body.revision);

    const limited: Partial<Role> = {
      tools: { mode: 'deny', tools: ['shell'], required: [] }, model: { model: defaultAgentModel, reasoning: 'high' }, maxRequestsPerTurn: 3,
    };
    const first = role('test.switch', '角色版本一：只检查当前问题。', limited);
    const saved = await k.call('POST', '/roles', { role: first });
    expect(saved.status).toBe(200);
    const next = role(first.id, '角色版本二：报告问题与证据。', limited);
    const edited = await k.call('PUT', `/roles/${first.id}`, { expectedRevision: saved.body.revision, role: next });
    expect(edited.status).toBe(200);

    expect((await k.call('PUT', rolePath, {
      expectedRevision: tuned.body.revision, roleId: first.id, roleRevision: saved.body.revision,
    })).status).toBe(409);
    expect((await k.call('GET', configPath)).body).toEqual(granted.body);
    const applied = await k.call('PUT', rolePath, {
      expectedRevision: tuned.body.revision, roleId: first.id, roleRevision: edited.body.revision,
    });
    expect(applied.status).toBe(200);
    expect(applied.body.instance.config.agent).toMatchObject({
      model: limited.model, maxRequestsPerTurn: 3, tools: universe.filter((name) => name !== 'shell'),
    });
    expect(applied.body.instance.config.agent.context.blocks).toContainEqual(next.context.blocks[0]);
    expect(applied.body.instance.config.role).toEqual({ id: first.id, revision: edited.body.revision, tools: limited.tools });
    expect((await k.call('GET', grantsPath)).body).toEqual(grants.body);
    expect((await k.call('GET', operationsPath)).body).toEqual(operations.body);

    const third = role(first.id, '角色版本三：先复现再修改。', limited);
    const latest = await k.call('PUT', `/roles/${first.id}`, { expectedRevision: edited.body.revision, role: third });
    expect(latest.status).toBe(200);
    expect((await k.call('GET', configPath)).body).toEqual(applied.body);
    expect(model.calls.values).toHaveLength(0);

    const created = await k.call('POST', `/workspaces/${workspaceId}/threads`, {
      prompt: '用最新的角色开始', role: { id: first.id, revision: latest.body.revision },
    });
    expect(created.status).toBe(200);
    const selectedId = created.body.instanceId as string;
    const request = await model.call(1);
    expect(request.request.instructions).toContain('角色版本三：先复现再修改。');
    expect(request.request.instructions).not.toContain('角色版本二：报告问题与证据。');
    request.response.complete();
    await k.waitEvent((event) => event.type === 'idle' && event.threadId === selectedId);

    expect((await k.call('PUT', rolePath, {
      expectedRevision: tuned.body.revision, roleId: first.id, roleRevision: latest.body.revision,
    })).status).toBe(409);
    expect((await k.call('GET', configPath)).body).toEqual(applied.body);
    const reapplied = await k.call('PUT', rolePath, {
      expectedRevision: applied.body.revision, roleId: first.id, roleRevision: latest.body.revision,
    });
    expect(reapplied.status).toBe(200);
    expect(reapplied.body.instance.config.agent.context.blocks).toContainEqual(third.context.blocks[0]);
    expect((await k.call('GET', grantsPath)).body).toEqual(grants.body);
    expect((await k.call('GET', operationsPath)).body).toEqual(operations.body);
    expect(model.calls.values).toHaveLength(1);
  } finally {
    await k.stop();
  }
}, 1000);

// 新需求：只读审查不再由定义的执行权限保证，只靠角色的工具白名单。规则要在草稿选项（agent-options）、创建代理
// （角色给初始工具）和改配置（实例上记下的角色规则）三处都接上，漏了任何一处，审查代理就能开出写工具。
test('只读审查角色建的代理只有 read，改配置加 shell 或关掉必需的 read 都被拒，黑名单角色建代理时不能带被禁的工具', async () => {
  const model = new ManualModel();
  const k = startKited(() => model);
  try {
    const registered = await registerCheckout(k, newRepo(k.root, 'project', { 'base.txt': '原始内容\n' }));
    const workspaceId = registered.workspace.id;
    const catalog = await k.call('GET', '/roles');
    expect(catalog.status).toBe(200);
    const universe = catalog.body.tools as string[];
    const work = findRole(catalog.body, 'kite.work');
    const review = findRole(catalog.body, 'kite.review');
    const options = await k.call('GET', `/workspaces/${workspaceId}/agent-options`);
    expect(options.status).toBe(200);
    expect(options.body.roles).toEqual(expect.arrayContaining([
      { id: 'kite.work', revision: work.revision, tools: universe, required: [], blocked: [] },
      { id: 'kite.review', revision: review.revision, tools: ['read'], required: ['read'], blocked: [] },
    ]));

    const created = await k.call('POST', `/workspaces/${workspaceId}/threads`, {
      prompt: '审查改动', role: { id: 'kite.review', revision: review.revision },
    });
    expect(created.status).toBe(200);
    const id = created.body.instanceId as string;
    const first = await model.call(1);
    expect(first.request.allowedTools).toEqual(['read']);
    first.response.complete();
    await k.waitEvent((event) => event.type === 'idle' && event.threadId === id);
    const configPath = `/instances/${id}/agent-config`;
    const config = await k.call('GET', configPath);
    expect(config.body.instance.config.agent.tools).toEqual(['read']);
    expect((await k.call('GET', `/instances/${id}/agent-capabilities`)).body).toMatchObject({ tools: ['read'], required: ['read'], blocked: [] });
    for (const tools of [['read', 'shell'], []]) {
      const rejected = await k.call('PUT', configPath, {
        expectedRevision: config.body.revision, agent: { ...config.body.instance.config.agent, tools },
      });
      expect(rejected.status).toBe(400);
    }
    expect((await k.call('GET', configPath)).body).toEqual(config.body);

    const noShell = await k.call('POST', '/roles', {
      role: { ...work.role, id: 'test.no-shell', title: '不开 shell', tools: { mode: 'deny', tools: ['shell'], required: [] } },
    });
    expect(noShell.status).toBe(200);
    expect((await k.call('GET', `/workspaces/${workspaceId}/agent-options`)).body.roles).toContainEqual({
      id: 'test.no-shell', revision: noShell.body.revision, tools: universe.filter((name) => name !== 'shell'), required: [], blocked: [],
    });
    const before = (await k.call('GET', `/workspaces/${workspaceId}`)).body.instances;
    const rejected = await k.call('POST', `/workspaces/${workspaceId}/threads`, {
      prompt: '黑名单角色却要开 shell', role: { id: 'test.no-shell', revision: noShell.body.revision }, tools: ['read', 'shell'],
    });
    expect(rejected.status).toBe(400);
    expect((await k.call('GET', `/workspaces/${workspaceId}`)).body.instances).toEqual(before);
    expect(model.calls.values).toHaveLength(1);
  } finally {
    await k.stop();
  }
}, 1000);

// 新需求：三个旧定义合并为 kite.agent，创建会话模板改由角色承载。迁移分两处：Store 构造改实例与授权，
// Roles 构造把模板转成角色；签名是否过期改按角色提示词算，旧库里存的是旧模板修订，两边算法对不上，
// 迁移后所有签名都会变成过期。只有拿旧数据重开才看得出这几处合起来对不对。
test('旧库重开后旧定义的实例指向代理并补上角色，按定义的授权改成按角色，创建会话模板变成同 ID 的角色且签名仍是最新', async () => {
  const root = makeTemp('roles-legacy-');
  const home = join(root, 'kite');
  const accounts = [linkNewAccount(home)];
  let daemon: Daemon | undefined;
  try {
    daemon = startDaemon({ home, port: 0, lightTasks: false });
    const request = (method: string, path: string, body?: unknown) => call(daemon!.url, method, path, body);
    const checkout = await request('POST', '/checkouts', { path: newRepo(root, 'project', { 'base.txt': '原始\n' }) });
    expect(checkout.status).toBe(200);
    const reviewId = await openAgent(request, checkout.body.workspace.id);
    const claudeId = await openAgent(request, checkout.body.workspace.id, claudeModel);
    await daemon.stop();
    daemon = undefined;

    // 改写成接口改造前的数据：旧定义 ID、没有 config.role、按定义授权；角色表还空着，创建会话模板存在模板表里。
    const legacyTemplate = contextDefinitionSchema.parse({
      version: 2, id: 'test.legacy', title: '旧模板', scene: 'thread.create',
      blocks: [{ type: 'paragraph', id: 'rules', title: '规则', parts: [{ type: 'text', text: '旧模板正文：先读需求。' }] }],
    });
    const oldReview: ContextDefinition = contextDefinitionSchema.parse({
      version: 2, id: 'kite.review', title: '只读审查', scene: 'thread.create',
      blocks: [{ type: 'paragraph', id: 'identity', title: '审查职责', parts: [{ type: 'text', text: '用户改过的审查模板。' }] }],
    });
    const oldWork: ContextDefinition = contextDefinitionSchema.parse({
      version: 2, id: 'kite.work', title: '工作会话', scene: 'thread.create',
      blocks: [{ type: 'paragraph', id: 'identity', title: '基础行为', parts: [{ type: 'text', text: '旧的工作模板。' }] }],
    });
    // 旧模板修订就是模板定义的哈希，签名里记的是它。
    const oldRevision = createHash('sha256').update(JSON.stringify(legacyTemplate)).digest('hex');
    const design: EmblemDesign = { expression: 'sin(x*0.4+t)*cos(y*0.4-t*0.7)', positive: 'M', negative: 'Y', form: 'circle' };
    const db = new Database(join(home, 'kite.db'));
    try {
      const config = (id: string) => JSON.parse((db.query('select config from plugin_instances where id = ?').get(id) as { config: string }).config);
      const legacy = (id: string, definitionId: string, change: (config: any) => void) => {
        const { role: _role, ...rest } = config(id);
        change(rest);
        db.query('update plugin_instances set definition_id = ?, config = ? where id = ?').run(definitionId, JSON.stringify(rest), id);
      };
      legacy(reviewId, 'kite.agent.review', (value) => {
        value.agent.tools = ['read'];
        value.agent.context = { ...value.agent.context, id: 'kite.review', title: '只读审查' };
        value.grants = [{ operation: 'agent.list' },
          { operation: 'agent.start', definitionIds: ['kite.agent.coding', 'kite.agent.review', 'kite.agent.claude'] }];
      });
      legacy(claudeId, 'kite.agent.claude', (value) => {
        value.grants = [{ operation: 'agent.start', definitionIds: ['kite.agent.claude'] }];
      });
      db.query('delete from roles').run();
      for (const definition of [legacyTemplate, oldReview, oldWork]) {
        db.query('insert into context_templates values (?, ?)').run(definition.id, JSON.stringify(definition));
      }
      db.query('insert into template_emblems values (?, ?)').run(legacyTemplate.id,
        JSON.stringify({ ...design, source: 'generated', templateRevision: oldRevision }));
    } finally {
      db.close();
    }
    // 旧库的年代账号里还没有资源库；换一个空账号，免得第一次启动时同步上去的内置角色在拉取时盖掉迁移结果。
    accounts.push(linkNewAccount(home));

    daemon = startDaemon({ home, port: 0, lightTasks: false });
    const review = (await request('GET', `/threads/${reviewId}`)).body;
    expect(review.definitionId).toBe('kite.agent');
    expect(review.config.role).toMatchObject({ id: 'kite.review', tools: { mode: 'allow', tools: ['read'], required: ['read'] } });
    expect((await request('GET', `/instances/${reviewId}/agent-capabilities`)).body.tools).toEqual(['read']);
    expect((await request('GET', `/instances/${reviewId}/operation-grants`)).body.grants).toEqual([
      { operation: 'agent.list' }, { operation: 'agent.start', roleIds: ['kite.work', 'kite.review'] },
    ]);
    const claude = (await request('GET', `/threads/${claudeId}`)).body;
    expect(claude).toMatchObject({ definitionId: 'kite.agent', runtime: 'claude', config: { agent: { model: claudeModel } } });
    expect(claude.config.role).toMatchObject({ id: 'kite.work', tools: { mode: 'deny', tools: [], required: [] } });
    expect((await request('GET', `/instances/${claudeId}/operation-grants`)).body.grants).toEqual([
      { operation: 'agent.start', roleIds: ['kite.work'] },
    ]);

    const roles = (await request('GET', '/roles')).body;
    expect(findRole(roles, legacyTemplate.id)).toMatchObject({
      role: { id: legacyTemplate.id, title: legacyTemplate.title, context: legacyTemplate, tools: { mode: 'deny', tools: [], required: [] } },
      emblemState: 'ready', emblem: { ...design, source: 'generated' },
    });
    expect(findRole(roles, 'kite.review').role).toMatchObject({
      context: { blocks: oldReview.blocks }, tools: { mode: 'allow', tools: ['read'], required: ['read'] },
    });
    expect(findRole(roles, 'kite.work').role).toMatchObject({ title: '工作', context: { title: '工作', blocks: oldWork.blocks } });
    const templates = (await request('GET', '/context-templates')).body.templates as Array<{ definition: ContextDefinition }>;
    expect(templates.filter((template) => template.definition.scene === 'thread.create')).toEqual([]);
  } finally {
    await daemon?.stop();
    for (const account of accounts) account.stop();
    rmSync(root, { recursive: true, force: true });
  }
}, 1000);
