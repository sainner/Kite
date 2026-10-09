/** 只持久化产品对象和 kited 自己保存的账号用量；会话正文在 journal，快照在 Git，执行状态由 runtime 管理。 */
import { Database } from 'bun:sqlite';
import { randomUUID } from 'node:crypto';
import { hostname } from 'node:os';
import type { AgentInstance, Checkout, Machine, PluginInstance, Project, Thread, ThreadContext, Workspace, WorkspaceModel, WorkspaceStatus, WorkspaceWindow } from './model.ts';
import type { ThreadNotification } from './harness/types.ts';
import type { ContextDefinition } from './harness/context/types.ts';
import type { HourlyUsage, UsageDay, UsageStore } from './account-usage.ts';
import type { TemplateEmblem } from './template-emblems.ts';
import type { Role } from './roles.ts';

export interface ThreadTitle {
  title: string;
  mode: 'auto' | 'manual';
  revision: string;
  generatedAt: number | null;
  through: string | null;
}

const SCHEMA = `
create table if not exists machine (
  slot integer primary key check (slot = 1), id text not null unique, name text not null, created_at integer not null
);
create table if not exists projects (
  id text primary key, name text not null, remote text not null, created_at integer not null
);
create table if not exists checkouts (
  id text primary key, project_id text not null references projects(id), machine_id text not null references machine(id),
  path text not null, remote text not null, created_at integer not null,
  unique(machine_id, path)
);
create table if not exists workspaces (
  id text primary key, checkout_id text not null references checkouts(id), name text not null, cwd text not null unique,
  kind text not null check (kind in ('root', 'worktree')), branch text, base text,
  status text not null check (status in ('preparing', 'open', 'failed', 'archived')), created_at integer not null,
  check ((kind = 'root' and branch is null and base is null) or (kind = 'worktree' and branch is not null and base is not null))
);
create unique index if not exists root_workspace on workspaces(checkout_id) where kind = 'root';
create table if not exists plugin_instances (
  id text primary key, workspace_id text not null references workspaces(id), definition_id text not null, title text not null,
  config text not null, state text not null, presentation text not null check (presentation in ('window', 'inline', 'background')),
  status text not null check (status in ('open', 'archived')), created_at integer not null, origin text
);
create table if not exists threads (
  instance_id text primary key references plugin_instances(id),
  runtime text not null check (runtime in ('claude', 'harness')), native_id text not null
);
create table if not exists thread_titles (
  instance_id text primary key references threads(instance_id) on delete cascade,
  mode text not null check (mode in ('auto', 'manual')), revision text not null,
  generated_at integer, through_record text
);
create table if not exists workspace_windows (
  id text primary key, workspace_id text not null references workspaces(id),
  -- 关闭记录和收据比业务实例活得更久，目标 ID 不设置级联外键。
  instance_id text not null, view_id text not null,
  state text not null check (state in ('open', 'closed')), created_at integer not null
);
create unique index if not exists plugin_view_window on workspace_windows(instance_id, view_id) where state = 'open';
create table if not exists window_requests (
  id text primary key, workspace_id text not null references workspaces(id),
  window_id text not null references workspace_windows(id), content text not null
);
create table if not exists instance_notifications (
  seq integer primary key autoincrement, id text not null unique,
  instance_id text not null references plugin_instances(id), notification text not null
);
create index if not exists instance_notification_order on instance_notifications(instance_id, seq);
create table if not exists operation_receipts (
  caller text not null, id text not null, request text not null, result text,
  primary key(caller, id)
);
create table if not exists context_templates (
  id text primary key, definition text not null
);
-- 角色的点阵签名，沿用创建会话模板时期的表名。
create table if not exists template_emblems (
  template_id text primary key, emblem text not null
);
create table if not exists roles (
  id text primary key, role text not null
);
create table if not exists usage_hours (
  account text not null, day text not null, hour integer not null, tokens integer not null, primary key(account, day, hour)
);
`;
const projectOf = (r: any): Project => ({ id: r.id, name: r.name, remote: r.remote, createdAt: r.created_at });
const checkoutOf = (r: any): Checkout => ({
  id: r.id, projectId: r.project_id, machineId: r.machine_id, path: r.path, remote: r.remote, createdAt: r.created_at,
});
const workspaceOf = (r: any): Workspace => ({
  id: r.id, checkoutId: r.checkout_id, name: r.name, cwd: r.cwd, kind: r.kind, branch: r.branch, base: r.base,
  status: r.status, createdAt: r.created_at,
});
const threadOf = (r: any): Thread => ({ instanceId: r.instance_id, runtime: r.runtime, nativeId: r.native_id });
const instanceOf = (r: any): PluginInstance => ({
  id: r.id, workspaceId: r.workspace_id, definitionId: r.definition_id, title: r.title,
  config: JSON.parse(r.config), state: JSON.parse(r.state), presentation: r.presentation, status: r.status, createdAt: r.created_at,
  ...(r.origin ? { origin: JSON.parse(r.origin) } : {}),
});
const agentOf = (r: any): AgentInstance => ({ ...instanceOf(r), ...threadOf(r) });
const windowOf = (r: any): WorkspaceWindow => ({
  id: r.id, workspaceId: r.workspace_id, target: { instanceId: r.instance_id, viewId: r.view_id },
  state: r.state, createdAt: r.created_at,
});

export class Store implements UsageStore {
  private db: Database;
  readonly machine: Machine;
  transaction<T>(action: () => T): T { return this.db.transaction(action)(); }
  constructor(path: string) {
    this.db = new Database(path, { create: true, strict: true });
    this.db.exec('pragma journal_mode = wal; pragma foreign_keys = on;');
    this.dropLocalProjects();
    this.db.exec(SCHEMA);
    this.mergeAgentDefinitions();
    // 同一个数据库只属于一台工作机服务。端口、地址和主机名变化都不重建身份。
    this.machine = this.db.transaction(() => {
      const saved = this.db.query('select id, name, created_at from machine where slot = 1').get() as
        { id: string; name: string; created_at: number } | null;
      if (saved) return { id: saved.id, name: saved.name, createdAt: saved.created_at };
      const machine: Machine = { id: randomUUID(), name: hostname(), createdAt: Date.now() };
      this.db.query('insert into machine values (1, ?, ?, ?)').run(machine.id, machine.name, machine.createdAt);
      return machine;
    })();
  }

  /**
   * 项目改以远程为身份前的库没有 remote 列。在研期间不做迁移：表是空的就重建，否则请用户清掉旧数据。
   */
  private dropLocalProjects(): void {
    const columns = this.db.query("select name from pragma_table_info('projects')").all() as Array<{ name: string }>;
    if (!columns.length || columns.some((c) => c.name === 'remote')) return;
    const used = this.db.query('select 1 from checkouts limit 1').get();
    if (used) throw new Error('数据库里有项目改以远程为身份之前登记的检出，请删除 KITE_HOME 下的 kite.db 后重新登记');
    this.db.exec('drop table checkouts; drop table projects;');
  }

  /**
   * 三个内置 agent 定义合并为「代理」，差别改由角色表达。在研期间只把已有实例改指新定义，
   * 补上当时定义对应的角色约束，并把按定义授权的 agent.start 改为按角色授权。
   */
  private mergeAgentDefinitions(): void {
    const roles: Record<string, string> = { 'kite.agent.coding': 'kite.work', 'kite.agent.claude': 'kite.work', 'kite.agent.review': 'kite.review' };
    const rows = this.db.query(`select id, definition_id, config from plugin_instances
      where definition_id in ('kite.agent.coding', 'kite.agent.claude', 'kite.agent.review') or config like '%"definitionIds"%'`).all() as
      Array<{ id: string; definition_id: string; config: string }>;
    this.db.transaction(() => {
      for (const row of rows) {
        const config = JSON.parse(row.config);
        config.grants = (config.grants ?? []).map((grant: any) => grant.operation === 'agent.start' && grant.definitionIds
          ? { operation: 'agent.start', roleIds: [...new Set<string>(grant.definitionIds.map((id: string) => roles[id] ?? id))] } : grant);
        const legacy = roles[row.definition_id];
        if (legacy && config.agent && !config.role) config.role = { id: config.agent.context?.id ?? legacy, revision: '',
          tools: legacy === 'kite.review' ? { mode: 'allow', tools: ['read'], required: ['read'] } : { mode: 'deny', tools: [], required: [] } };
        this.db.query('update plugin_instances set definition_id = ?, config = ? where id = ?')
          .run(legacy ? 'kite.agent' : row.definition_id, JSON.stringify(config), row.id);
      }
    })();
  }

  mergeUsageHours(account: string, usage: HourlyUsage): void {
    const upsert = this.db.query('insert into usage_hours values (?, ?, ?, ?) on conflict(account, day, hour) do update set tokens = max(tokens, excluded.tokens)');
    this.db.transaction(() => {
      for (const [day, hours] of usage) hours.forEach((tokens, hour) => { if (tokens > 0) upsert.run(account, day, hour, tokens); });
    })();
  }

  usageDays(account: string): UsageDay[] {
    const rows = this.db.query('select day, hour, tokens from usage_hours where account = ? order by day').all(account) as Array<{ day: string; hour: number; tokens: number }>;
    const days = new Map<string, UsageDay>();
    for (const row of rows) {
      const day = days.get(row.day) ?? { date: row.day, tokens: 0, hours: Array<number>(24).fill(0) };
      day.tokens += row.tokens;
      day.hours![row.hour]! += row.tokens;
      days.set(row.day, day);
    }
    return [...days.values()];
  }

  projects(): Project[] { return this.db.query('select * from projects order by created_at, id').all().map(projectOf); }
  contextTemplates(): ContextDefinition[] {
    return this.db.query('select definition from context_templates order by id').all()
      .map((row: any) => JSON.parse(row.definition));
  }
  contextTemplate(id: string): ContextDefinition | undefined {
    const row = this.db.query('select definition from context_templates where id = ?').get(id) as { definition: string } | null;
    return row ? JSON.parse(row.definition) : undefined;
  }
  templateEmblem(id: string): TemplateEmblem | undefined {
    const row = this.db.query('select emblem from template_emblems where template_id = ?').get(id) as { emblem: string } | null;
    return row ? JSON.parse(row.emblem) : undefined;
  }
  saveTemplateEmblem(id: string, emblem: TemplateEmblem): void {
    this.db.query('insert into template_emblems values (?, ?) on conflict(template_id) do update set emblem = excluded.emblem')
      .run(id, JSON.stringify(emblem));
  }
  deleteContextTemplate(id: string): void {
    this.db.query('delete from context_templates where id = ?').run(id);
  }
  roles(): Role[] {
    return this.db.query('select role from roles order by id').all().map((row: any) => JSON.parse(row.role));
  }
  role(id: string): Role | undefined {
    const row = this.db.query('select role from roles where id = ?').get(id) as { role: string } | null;
    return row ? JSON.parse(row.role) : undefined;
  }
  saveRole(role: Role): void {
    this.db.query('insert into roles values (?, ?) on conflict(id) do update set role = excluded.role').run(role.id, JSON.stringify(role));
  }
  saveContextTemplate(definition: ContextDefinition): void {
    this.db.query('insert into context_templates values (?, ?) on conflict(id) do update set definition = excluded.definition')
      .run(definition.id, JSON.stringify(definition));
  }
  project(id: string): Project | null {
    const r = this.db.query('select * from projects where id = ?').get(id);
    return r ? projectOf(r) : null;
  }
  /** 已有项目可添加检出；新项目、检出与根工作区在同一事务中建立。项目名称与远程以登记表为准。 */
  register(project: Project, checkout: Checkout, root: Workspace): void {
    this.db.transaction(() => {
      this.saveProject(project);
      this.db.query('insert into checkouts values (?, ?, ?, ?, ?, ?)')
        .run(checkout.id, checkout.projectId, checkout.machineId, checkout.path, checkout.remote, checkout.createdAt);
      this.addWorkspace(root);
    })();
  }
  saveProject(project: Project): void {
    this.db.query('insert into projects values (?, ?, ?, ?) on conflict(id) do update set name = excluded.name, remote = excluded.remote')
      .run(project.id, project.name, project.remote, project.createdAt);
  }
  setCheckoutRemote(id: string, remote: string): void {
    this.db.query('update checkouts set remote = ? where id = ?').run(remote, id);
  }
  checkouts(projectId?: string): Checkout[] {
    return this.db.query('select * from checkouts where (? is null or project_id = ?) order by created_at, id')
      .all(projectId ?? null, projectId ?? null).map(checkoutOf);
  }
  checkout(id: string): Checkout | null {
    const r = this.db.query('select * from checkouts where id = ?').get(id);
    return r ? checkoutOf(r) : null;
  }
  workspaces(projectId?: string): Workspace[] {
    return this.db.query(`select w.* from workspaces w join checkouts c on c.id = w.checkout_id
      where (? is null or c.project_id = ?) order by w.created_at, w.id`)
      .all(projectId ?? null, projectId ?? null).map(workspaceOf);
  }
  workspace(id: string): Workspace | null {
    const r = this.db.query('select * from workspaces where id = ?').get(id);
    return r ? workspaceOf(r) : null;
  }
  rootWorkspaceModel(checkoutId: string): WorkspaceModel | null {
    const r = this.db.query("select * from workspaces where checkout_id = ? and kind = 'root'").get(checkoutId);
    return r ? this.modelOf(workspaceOf(r)) : null;
  }
  addWorkspace(w: Workspace, firstAgent?: { agent: AgentInstance; window: WorkspaceWindow }): void {
    this.db.transaction(() => {
      this.db.query('insert into workspaces values (?, ?, ?, ?, ?, ?, ?, ?, ?)')
        .run(w.id, w.checkoutId, w.name, w.cwd, w.kind, w.branch, w.base, w.status, w.createdAt);
      if (firstAgent) this.addAgent(firstAgent.agent, firstAgent.window);
    })();
  }
  setWorkspaceStatus(id: string, status: WorkspaceStatus): void {
    this.db.query('update workspaces set status = ? where id = ?').run(status, id);
  }
  threads(workspaceId?: string): AgentInstance[] {
    return this.db.query(`select i.*, t.* from threads t join plugin_instances i on i.id = t.instance_id
      where (? is null or i.workspace_id = ?) order by i.created_at, i.id`)
      .all(workspaceId ?? null, workspaceId ?? null).map(agentOf);
  }
  thread(id: string): AgentInstance | null {
    const row = this.db.query('select i.*, t.* from threads t join plugin_instances i on i.id = t.instance_id where i.id = ?').get(id);
    return row ? agentOf(row) : null;
  }
  addInstance(instance: PluginInstance): void {
    this.db.query('insert into plugin_instances values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)')
      .run(instance.id, instance.workspaceId, instance.definitionId, instance.title, JSON.stringify(instance.config),
        JSON.stringify(instance.state), instance.presentation, instance.status, instance.createdAt, instance.origin ? JSON.stringify(instance.origin) : null);
  }
  private addThread(thread: Thread): void {
    this.db.query('insert into threads values (?, ?, ?)').run(thread.instanceId, thread.runtime, thread.nativeId);
  }
  setThreadRuntime(id: string, runtime: Thread['runtime']): void {
    this.db.query('update threads set runtime = ? where instance_id = ?').run(runtime, id);
  }
  /** 实例身份、会话专有记录与可选窗口原子创建。 */
  addAgent(agent: AgentInstance, window?: WorkspaceWindow): void {
    this.db.transaction(() => {
      this.addInstance(agent);
      this.addThread(agent);
      if (window) this.addWindow(window);
    })();
  }
  archiveInstance(id: string): void {
    this.db.transaction(() => {
      this.db.query("update plugin_instances set status = 'archived' where id = ?").run(id);
      this.db.query("update workspace_windows set state = 'closed' where instance_id = ?").run(id);
    })();
  }
  renameInstance(id: string, title: string): void {
    const current = this.threadTitle(id);
    if (current) this.saveThreadTitle(id, current.revision, { ...current, title });
    else this.db.query('update plugin_instances set title = ? where id = ?').run(title, id);
  }
  threadTitle(id: string): ThreadTitle | null {
    const row = this.db.query(`select i.title, t.mode, t.revision, t.generated_at, t.through_record
      from threads h join plugin_instances i on i.id = h.instance_id
      left join thread_titles t on t.instance_id = h.instance_id where h.instance_id = ?`).get(id) as
      { title: string; mode: ThreadTitle['mode'] | null; revision: string | null; generated_at: number | null; through_record: string | null } | null;
    return row ? { title: row.title, mode: row.mode ?? 'auto', revision: row.revision ?? 'initial',
      generatedAt: row.generated_at, through: row.through_record } : null;
  }
  /** 标题与生成进度原子保存；手动修改和切回自动都会使旧生成结果失效。 */
  saveThreadTitle(id: string, expectedRevision: string, next: Omit<ThreadTitle, 'revision'>): boolean {
    return this.db.transaction(() => {
      if (this.threadTitle(id)?.revision !== expectedRevision) return false;
      this.db.query('update plugin_instances set title = ? where id = ?').run(next.title, id);
      this.db.query(`insert into thread_titles values (?, ?, ?, ?, ?)
        on conflict(instance_id) do update set mode = excluded.mode, revision = excluded.revision,
        generated_at = excluded.generated_at, through_record = excluded.through_record`)
        .run(id, next.mode, randomUUID(), next.generatedAt, next.through);
      return true;
    })();
  }
  setInstanceState(id: string, state: PluginInstance['state']): void {
    this.db.query('update plugin_instances set state = ? where id = ?').run(JSON.stringify(state), id);
  }
  /** 配置和对应通知同事务提交；线程 journal 单独记录在哪次请求纳入了通知。 */
  setInstanceConfig(id: string, config: PluginInstance['config'], notification?: Omit<ThreadNotification, 'sequence'>): void {
    this.db.transaction(() => {
      this.db.query('update plugin_instances set config = ? where id = ?').run(JSON.stringify(config), id);
      if (notification) this.db.query('insert into instance_notifications (id, instance_id, notification) values (?, ?, ?)')
        .run(notification.id, id, JSON.stringify(notification));
    })();
  }
  instanceNotifications(id: string, after: number): ThreadNotification[] {
    return this.db.query('select seq, notification from instance_notifications where instance_id = ? and seq > ? order by seq')
      .all(id, after).map((row: any) => ({ ...JSON.parse(row.notification), sequence: row.seq }));
  }
  operationReceipt(caller: string, id: string): { request: string; result: string | null } | null {
    return this.db.query('select request, result from operation_receipts where caller = ? and id = ?').get(caller, id) as
      { request: string; result: string | null } | null;
  }
  beginOperation(caller: string, id: string, request: string): void {
    this.db.query('insert into operation_receipts values (?, ?, ?, null)').run(caller, id, request);
  }
  finishOperation(caller: string, id: string, result: unknown): void {
    this.db.query('update operation_receipts set result = ? where caller = ? and id = ?').run(JSON.stringify(result), caller, id);
  }
  archiveWorkspace(id: string): void {
    this.db.transaction(() => {
      this.setWorkspaceStatus(id, 'archived');
      this.db.query("update plugin_instances set status = 'archived' where workspace_id = ?").run(id);
      this.db.query("update workspace_windows set state = 'closed' where workspace_id = ?").run(id);
    })();
  }
  instances(workspaceId: string): PluginInstance[] {
    return this.db.query('select * from plugin_instances where workspace_id = ? order by created_at, id').all(workspaceId).map(instanceOf);
  }
  instance(id: string): PluginInstance | null {
    const row = this.db.query('select * from plugin_instances where id = ?').get(id);
    return row ? instanceOf(row) : null;
  }
  hasInstanceWindows(id: string): boolean {
    return this.db.query('select 1 from workspace_windows where instance_id = ? limit 1').get(id) !== null;
  }
  windows(workspaceId: string): WorkspaceWindow[] {
    return this.db.query("select * from workspace_windows where workspace_id = ? and state = 'open' order by created_at, id")
      .all(workspaceId).map(windowOf);
  }
  window(id: string): WorkspaceWindow | null {
    const row = this.db.query('select * from workspace_windows where id = ?').get(id);
    return row ? windowOf(row) : null;
  }
  windowRequest(id: string): { workspaceId: string; windowId: string; content: string } | null {
    const row = this.db.query('select * from window_requests where id = ?').get(id) as any;
    return row ? { workspaceId: row.workspace_id, windowId: row.window_id, content: row.content } : null;
  }
  private addWindow(w: WorkspaceWindow): void {
    this.db.query('insert into workspace_windows values (?, ?, ?, ?, ?, ?)')
      .run(w.id, w.workspaceId, w.target.instanceId, w.target.viewId, w.state, w.createdAt);
  }
  /** 即使打开的是已有窗口，也保存操作收据；迟到重试不能复活已关闭的窗口。 */
  openWindow(w: WorkspaceWindow, request: { id: string; content: string }, instance?: PluginInstance, thread?: Thread): void {
    this.db.transaction(() => {
      if (instance) this.addInstance(instance);
      if (thread) this.addThread(thread);
      if (!this.window(w.id)) this.addWindow(w);
      this.db.query('insert into window_requests values (?, ?, ?, ?)').run(request.id, w.workspaceId, w.id, request.content);
    })();
  }
  closeWindow(id: string): void {
    this.db.query("update workspace_windows set state = 'closed' where id = ?").run(id);
  }
  /** 关闭窗口及请求收据保留原目标 ID；业务实例、配置和状态不再保留。 */
  deleteInstance(id: string): void {
    this.db.query('delete from instance_notifications where instance_id = ?').run(id);
    this.db.query('delete from plugin_instances where id = ?').run(id);
  }
  /** 执行上下文只需要父级关系，不读取同级线程和插件窗口。 */
  private contextOf(workspace: Workspace) {
    const checkout = this.checkout(workspace.checkoutId)!;
    const project = this.project(checkout.projectId)!;
    return { machine: this.machine, project, checkout, workspace };
  }
  private modelOf(workspace: Workspace): WorkspaceModel {
    return { ...this.contextOf(workspace),
      threads: this.db.query(`select t.* from threads t join plugin_instances i on i.id = t.instance_id
        where i.workspace_id = ? order by i.created_at, i.id`).all(workspace.id).map(threadOf),
      instances: this.instances(workspace.id), windows: this.windows(workspace.id) };
  }
  workspaceModel(id: string): WorkspaceModel | null {
    const workspace = this.workspace(id);
    return workspace ? this.modelOf(workspace) : null;
  }
  workspaceModels(projectId?: string): WorkspaceModel[] {
    const workspaces = this.workspaces(projectId);
    if (!workspaces.length) return [];
    const checkouts = new Map(this.checkouts(projectId).map((c) => [c.id, c]));
    const projects = new Map((projectId ? [this.project(projectId)!] : this.projects()).map((p) => [p.id, p]));
    // 列表一次读齐关联记录，避免每个工作区重复查询；项目过滤同时约束子记录。
    const threads = this.db.query(`select i.workspace_id, t.* from threads t join plugin_instances i on i.id = t.instance_id
      join workspaces w on w.id = i.workspace_id join checkouts c on c.id = w.checkout_id
      where (? is null or c.project_id = ?) order by i.created_at, i.id`)
      .all(projectId ?? null, projectId ?? null).map((r: any) => ({ workspaceId: r.workspace_id as string, thread: threadOf(r) }));
    const instances = this.db.query(`select p.* from plugin_instances p
      join workspaces w on w.id = p.workspace_id join checkouts c on c.id = w.checkout_id
      where (? is null or c.project_id = ?) order by p.created_at, p.id`)
      .all(projectId ?? null, projectId ?? null).map(instanceOf);
    const windows = this.db.query(`select p.* from workspace_windows p
      join workspaces w on w.id = p.workspace_id join checkouts c on c.id = w.checkout_id
      where p.state = 'open' and (? is null or c.project_id = ?) order by p.created_at, p.id`)
      .all(projectId ?? null, projectId ?? null).map(windowOf);
    const threadsByWorkspace = Map.groupBy(threads, (t) => t.workspaceId);
    const instancesByWorkspace = Map.groupBy(instances, (p) => p.workspaceId);
    const windowsByWorkspace = Map.groupBy(windows, (p) => p.workspaceId);
    return workspaces.map((workspace) => {
      const checkout = checkouts.get(workspace.checkoutId)!;
      return { machine: this.machine, project: projects.get(checkout.projectId)!, checkout, workspace,
        threads: (threadsByWorkspace.get(workspace.id) ?? []).map(({ thread }) => thread),
        instances: instancesByWorkspace.get(workspace.id) ?? [], windows: windowsByWorkspace.get(workspace.id) ?? [] };
    });
  }
  threadContext(id: string): ThreadContext | null {
    const thread = this.thread(id);
    if (!thread) return null;
    return { ...thread, ...this.contextOf(this.workspace(thread.workspaceId)!) };
  }
  close(): void { this.db.close(); }
}
