import { expect, test } from 'bun:test';
import { Database } from 'bun:sqlite';
import { rmSync } from 'node:fs';
import { join } from 'node:path';
import type { AgentDefinition } from '../../src/agents/definition.ts';
import { defaultAgentModel } from '../../src/agents/models.ts';
import { startDaemon, type Daemon } from '../../src/daemon.ts';
import type { Envelope } from '../../src/events.ts';
import type { OperationGrant } from '../../src/operations/contract.ts';
import type { Role } from '../../src/roles.ts';
import type { EmblemStatus } from '../../src/template-emblems.ts';
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

/** 代理的默认协作授权，对应模型工具 agent_*。 */
const collaboration: OperationGrant[] = [
  { operation: 'agent.list' }, { operation: 'agent.start', roleIds: ['kite.work', 'kite.review'] },
  { operation: 'agent.send', targets: { kind: 'created' } },
  { operation: 'agent.resume', targets: { kind: 'created' } },
  { operation: 'agent.stop', targets: { kind: 'created' } },
];
/** 授权按操作名排序后比较；顺序不是约定。 */
const byOperation = (grants: OperationGrant[]) => [...grants].sort((a, b) => a.operation.localeCompare(b.operation));

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
// 默认模型与预算一起换成角色的并记下新的角色约束，执行授权不动；新旧角色都允许协作工具，操作授权（含用户收窄过的）
// 也保持原样；版本过期的请求不改变实例。
test('改角色不影响已有代理，改选到同样允许协作工具的角色换上角色的配置并保留执行与操作授权，过期的角色版本或配置版本都不改变实例', async () => {
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

// 真实出过的 bug：协作授权只在创建时按角色过滤，改选角色不调整，只读审查建的空代理改选成工作后 agent_* 工具配上了
// 却没有授权，用不了。要 HTTP 路由、角色快照、实例配置与授权读取几处接上才对：改选时去掉新角色用不了的、补上旧角色
// 用不了而新角色能用的；两个角色都能用的保持原样，用户撤回或收窄的不被补回；文件授权不经模型工具，不受影响。
test('只读审查的空代理改选为工作后拿到协作授权，再改选同样能协作的角色不补回用户撤回的，改回只读审查只去掉协作授权', async () => {
  const k = startKited(() => new ManualModel());
  try {
    const registered = await registerCheckout(k, newRepo(k.root, 'project', { 'base.txt': '原始内容\n' }));
    const workspaceId = registered.workspace.id;
    const catalog = (await k.call('GET', '/roles')).body;
    const work = findRole(catalog, 'kite.work');
    const review = findRole(catalog, 'kite.review');
    const noShell = await k.call('POST', '/roles', {
      role: { ...work.role, id: 'test.no-shell', title: '不开 shell', tools: { mode: 'deny', tools: ['shell'], required: [] } },
    });
    expect(noShell.status).toBe(200);

    const started = await k.call('POST', `/workspaces/${workspaceId}/operations/agent.start`, {
      operationId: 'empty-review', role: 'kite.review',
    });
    expect(started.status).toBe(200);
    const id = started.body.instanceId as string;
    const files = await k.call('POST', `/workspaces/${workspaceId}/windows`, {
      id: crypto.randomUUID(), content: { kind: 'create', definitionId: 'kite.files' },
    });
    expect(files.status).toBe(200);
    const filesGrant: OperationGrant = { operation: 'files.read', targets: { kind: 'instances', instanceIds: [files.body.target.instanceId] } };

    const operationsPath = `/instances/${id}/operation-grants`;
    const grants = async () => {
      const current = await k.call('GET', operationsPath);
      expect(current.status).toBe(200);
      return current;
    };
    let revision = (await k.call('GET', `/instances/${id}/agent-config`)).body.revision as string;
    const choose = async (roleId: string, roleRevision: string) => {
      const chosen = await k.call('PUT', `/instances/${id}/role`, { expectedRevision: revision, roleId, roleRevision });
      expect(chosen.status).toBe(200);
      expect(chosen.body.instance.config.role).toMatchObject({ id: roleId, revision: roleRevision });
      revision = chosen.body.revision;
    };

    const initial = await grants();
    expect(initial.body.grants).toEqual([]);
    expect((await k.call('PUT', operationsPath, { expectedRevision: initial.body.revision, grants: [filesGrant] })).status).toBe(200);

    await choose('kite.work', work.revision);
    const granted = await grants();
    expect(byOperation(granted.body.grants)).toEqual(byOperation([filesGrant, ...collaboration]));

    // 用户在工作角色下撤回停止，把创建收窄到只读审查。
    const narrowed = byOperation([filesGrant, ...collaboration.filter((grant) => grant.operation !== 'agent.stop')
      .map((grant) => grant.operation === 'agent.start' ? { ...grant, roleIds: ['kite.review'] } : grant)]);
    expect((await k.call('PUT', operationsPath, { expectedRevision: granted.body.revision, grants: narrowed })).status).toBe(200);
    await choose('test.no-shell', noShell.body.revision);
    expect(byOperation((await grants()).body.grants)).toEqual(narrowed);

    await choose('kite.review', review.revision);
    expect((await grants()).body.grants).toEqual([filesGrant]);
  } finally {
    await k.stop();
  }
}, 1000);

// 新需求：对话开始后（有对话记录或排队消息）不能改选角色。检查要和发送消息共用工作区锁，并认得磁盘上的对话记录：
// 消息刚落盘时回合可能还没开始，重启后对话记录还没载入内存，两处只看内存状态都会放行。
test('发出第一条消息后改选角色返回 409，回合进行中与重启后都不改变实例配置和授权', async () => {
  const root = makeTemp('roles-started-');
  const home = join(root, 'kite');
  const account = linkNewAccount(home);
  const model = new ManualModel();
  let daemon: Daemon | undefined;
  try {
    daemon = startDaemon({ home, port: 0, lightTasks: false, model: () => model });
    const request = (method: string, path: string, body?: unknown) => call(daemon!.url, method, path, body);
    const events = new Seen<Envelope>();
    daemon.kite.bus.subscribe(undefined, (event) => events.add(event));
    const checkout = await request('POST', '/checkouts', { path: newRepo(root, 'project', { 'base.txt': '原始内容\n' }) });
    expect(checkout.status).toBe(200);
    const id = await openAgent(request, checkout.body.workspace.id);
    // 改选成只读审查本会去掉协作授权，授权不变才说明拒绝发生在调整之前。
    const review = findRole((await request('GET', '/roles')).body, 'kite.review');
    const configPath = `/instances/${id}/agent-config`;
    const operations = await request('GET', `/instances/${id}/operation-grants`);
    const execution = await request('GET', `/instances/${id}/execution-grants`);
    expect(operations.body.grants).toEqual(expect.arrayContaining(collaboration));
    const rejectedRole = async () => {
      const config = await request('GET', configPath);
      expect(config.status).toBe(200);
      const rejected = await request('PUT', `/instances/${id}/role`, {
        expectedRevision: config.body.revision, roleId: 'kite.review', roleRevision: review.revision,
      });
      expect(rejected.status).toBe(409);
      expect(rejected.body.error).toContain('对话开始后');
      expect((await request('GET', configPath)).body).toEqual(config.body);
      expect((await request('GET', `/instances/${id}/operation-grants`)).body).toEqual(operations.body);
      expect((await request('GET', `/instances/${id}/execution-grants`)).body).toEqual(execution.body);
      return config.body;
    };

    expect((await request('POST', `/threads/${id}/messages`, { text: '先看看项目' })).status).toBe(200);
    const during = await rejectedRole();
    expect(during.instance.config.role.id).toBe('kite.work');
    const first = await model.call(1);
    first.response.complete();
    await events.wait((event) => event.type === 'idle' && event.threadId === id);
    await daemon.stop();
    daemon = undefined;

    daemon = startDaemon({ home, port: 0, lightTasks: false, model: () => model });
    const reopened = await rejectedRole();
    expect(reopened.instance.config.role.id).toBe('kite.work');
    expect(model.calls.values).toHaveLength(1);
  } finally {
    await daemon?.stop();
    account.stop();
    rmSync(root, { recursive: true, force: true });
  }
}, 1000);

// 新需求：三个旧定义合并为 kite.agent。Store 构造时把旧定义的实例改指代理并按角色补上约束，按定义的授权改成按角色；
// 迁移结果还要和角色目录、能力计算、授权读取接上，只有拿旧数据重开才看得出合起来对不对。
test('旧库重开后旧定义的实例指向代理并补上角色，按定义的授权改成按角色', async () => {
  const root = makeTemp('roles-legacy-');
  const home = join(root, 'kite');
  const account = linkNewAccount(home);
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

    // 改写成接口改造前的数据：旧定义 ID、没有 config.role、按定义授权。
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
    } finally {
      db.close();
    }

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
  } finally {
    await daemon?.stop();
    account.stop();
    rmSync(root, { recursive: true, force: true });
  }
}, 1000);
