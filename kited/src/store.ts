/** 只持久化产品对象和 kited 自己保存的账号用量；会话正文在 journal，快照在 Git，执行状态由 runtime 管理。 */
import { Database } from 'bun:sqlite';
import { randomUUID } from 'node:crypto';
import { hostname } from 'node:os';
import type { AgentInstance, Checkout, Machine, PluginInstance, Project, Thread, ThreadContext, Workspace, WorkspaceModel, WorkspaceStatus, WorkspaceWindow } from './model.ts';
import type { ThreadNotification } from './harness/types.ts';
import { defaultContextDefinition } from './harness/context/project.ts';
import type { Template } from './context-templates.ts';
import type { HourlyUsage, UsageDay, UsageStore } from './account-usage.ts';
import type { TemplateEmblem } from './template-emblems.ts';
import type { Role } from './roles.ts';
import type { ProjectConstraints } from './account-data/registry.ts';

export interface ThreadTitle {
  title: string;
  mode: 'auto' | 'manual';
  revision: string;
  generatedAt: number | null;
  through: string | null;
}

const WORKSPACES = `create table if not exists workspaces (
  id text primary key, checkout_id text not null references checkouts(id), name text not null, cwd text not null,
  branch text not null, base text not null,
  status text not null check (status in ('preparing', 'open', 'failed', 'archived', 'handing_off', 'transferred')), created_at integer not null,
  epoch integer not null default 1 check (epoch >= 1), behind integer, pull_request text
);`;

// 没有远程的项目 remote 为空，各工作机上的检出互为远程。
const projectsTable = (name: string) => `create table if not exists ${name} (
  id text primary key, name text not null, remote text, created_at integer not null
);`;
const checkoutsTable = (name: string) => `create table if not exists ${name} (
  id text primary key, project_id text not null references projects(id), machine_id text not null references machine(id),
  path text not null, remote text, created_at integer not null,
  unique(machine_id, path)
);`;
const SCHEMA = `
create table if not exists machine (
  slot integer primary key check (slot = 1), id text not null unique, name text not null, created_at integer not null
);
${projectsTable('projects')}
${checkoutsTable('checkouts')}
${WORKSPACES}
create unique index if not exists workspace_cwd on workspaces(cwd) where status != 'transferred';
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
  id text primary key, template text not null
);
-- 角色的点阵签名，沿用创建会话模板时期的表名。
create table if not exists template_emblems (
  template_id text primary key, emblem text not null
);
create table if not exists roles (
  id text primary key, role text not null
);
-- 没有远程的项目交出工作区时记下接收方：同一次交接（epoch）只交给一台，别的目标再来通知时拒绝。
create table if not exists workspace_receivers (
  workspace_id text primary key, epoch integer not null, machine text not null
);
-- 项目约束以账号级数据为准，这里是本机缓存。
create table if not exists project_constraints (
  project_id text primary key, constraints text not null
);
create table if not exists usage_hours (
  account text not null, day text not null, hour integer not null, tokens integer not null,
  cost real not null, unpriced integer not null, primary key(account, day, hour)
);
`;
const projectOf = (r: any): Project => ({ id: r.id, name: r.name, remote: r.remote, createdAt: r.created_at });
const checkoutOf = (r: any): Checkout => ({
  id: r.id, projectId: r.project_id, machineId: r.machine_id, path: r.path, remote: r.remote, createdAt: r.created_at,
});
const workspaceOf = (r: any): Workspace => ({
  id: r.id, epoch: r.epoch, checkoutId: r.checkout_id, name: r.name, cwd: r.cwd, branch: r.branch, base: r.base,
  status: r.status, createdAt: r.created_at, behind: r.behind, pullRequest: r.pull_request ? JSON.parse(r.pull_request) : null,
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
/** 随工作区流转的表，按外键依赖的先后排列。 */
const workspaceTables = ['workspaces', 'plugin_instances', 'threads', 'thread_titles', 'workspace_windows', 'window_requests',
  'instance_notifications', 'operation_receipts'] as const;
export type WorkspaceRows = Record<(typeof workspaceTables)[number], Array<Record<string, unknown>>>;

export class Store implements UsageStore {
  private db: Database;
  readonly machine: Machine;
  transaction<T>(action: () => T): T { return this.db.transaction(action)(); }
  constructor(path: string) {
    this.db = new Database(path, { create: true, strict: true });
    this.db.exec('pragma journal_mode = wal; pragma foreign_keys = on;');
    this.dropRootWorkspaces();
    this.dropLocalProjects();
    this.dropUnpricedUsage();
    this.dropBareContextTemplates();
    this.relaxRemotes();
    this.db.exec(SCHEMA);
    this.mergeAgentDefinitions();
    this.splitProjectDocuments();
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
   * 去掉根工作区之前的库：工作区有 kind 列，检出是用户的文件夹。在研期间不迁移：还没有检出就重建工作区表，否则请用户清掉旧数据。
   */
  private dropRootWorkspaces(): void {
    const columns = this.db.query("select name from pragma_table_info('workspaces')").all() as Array<{ name: string }>;
    if (!columns.some((c) => c.name === 'kind')) return;
    if (this.db.query('select 1 from checkouts limit 1').get()) {
      throw new Error('数据库是去掉根工作区之前的格式，检出还是用户的文件夹：请先删除 KITE_HOME 下 kite.db 里的检出与工作区记录，再重新添加项目');
    }
    this.db.exec('drop table workspaces');
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
   * 用量折算金额之前的表没有 cost 列。在研期间不迁移：直接重建，下次查询时从本机会话记录重扫，已被清理的记录不再计入。
   */
  private dropUnpricedUsage(): void {
    const columns = this.db.query("select name from pragma_table_info('usage_hours')").all() as Array<{ name: string }>;
    if (columns.length && !columns.some((c) => c.name === 'cost')) this.db.exec('drop table usage_hours');
  }

  /**
   * 模板带上辅助生成的模型之前，表里只存组装定义。在研期间不迁移：直接重建，改过的模板回到默认；账号里的旧格式副本同步时被跳过。
   */
  private dropBareContextTemplates(): void {
    const columns = this.db.query("select name from pragma_table_info('context_templates')").all() as Array<{ name: string }>;
    if (columns.some((c) => c.name === 'definition')) this.db.exec('drop table context_templates');
  }

  /**
   * 没有远程的项目出现之前，项目与检出的 remote 不能为空：照 SQLite 改表的步骤换成新表，其他表的外键按名字引用，不受影响。
   */
  private relaxRemotes(): void {
    const remote = (this.db.query("select \"notnull\" as required from pragma_table_info('projects') where name = 'remote'").get() as { required: number } | null);
    if (!remote?.required) return;
    this.rebuild('放开项目远程', `${projectsTable('projects_next')}
      insert into projects_next select id, name, remote, created_at from projects;
      drop table projects; alter table projects_next rename to projects;
      ${checkoutsTable('checkouts_next')}
      insert into checkouts_next select id, project_id, machine_id, path, remote, created_at from checkouts;
      drop table checkouts; alter table checkouts_next rename to checkouts;`);
  }

  /** 照 SQLite 改表的步骤换表：关外键，在事务里执行，核对外键再打开。 */
  private rebuild(what: string, sql: string): void {
    this.db.exec('pragma foreign_keys = off');
    try {
      this.db.transaction(() => {
        this.db.exec(sql);
        if (this.db.query('pragma foreign_key_check').all().length) throw new Error(`${what}后外键不一致`);
      })();
    } finally { this.db.exec('pragma foreign_keys = on'); }
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

  /**
   * 项目规则与记忆索引拆成两个变量之前，实例里拷贝的提示词引用 project.documents。在研期间就地改写：
   * 按它选择的条件换成默认角色里规则与记忆索引两段，段落里的引用换成规则加记忆索引。会话记录里的旧快照照原样还原，不改。
   */
  private splitProjectDocuments(): void {
    const rows = this.db.query(`select id, config from plugin_instances where config like '%"project.documents"%'`).all() as
      Array<{ id: string; config: string }>;
    const materials = defaultContextDefinition.blocks.filter((block) => block.id === 'rules' || block.id === 'memory');
    const rewrite = (blocks: any[]): any[] => blocks.flatMap((block) => {
      if (block.type === 'condition') {
        if (block.variable === 'project.documents') return structuredClone(materials);
        return [{ ...block, cases: block.cases.map((branch: any) => ({ ...branch, blocks: rewrite(branch.blocks) })),
          otherwise: { ...block.otherwise, blocks: rewrite(block.otherwise.blocks) } }];
      }
      return [{ ...block, parts: block.parts.flatMap((part: any) => part.type === 'variable' && part.name === 'project.documents'
        ? [{ type: 'variable', name: 'project.rules' }, { type: 'text', text: '\n\n' }, { type: 'variable', name: 'project.memory' }] : [part]) }];
    });
    this.db.transaction(() => {
      for (const row of rows) {
        const config = JSON.parse(row.config);
        if (!config.agent?.context) continue;
        config.agent.context.blocks = rewrite(config.agent.context.blocks);
        this.db.query('update plugin_instances set config = ? where id = ?').run(JSON.stringify(config), row.id);
      }
    })();
  }

  mergeUsageHours(account: string, usage: HourlyUsage): void {
    const upsert = this.db.query(`insert into usage_hours values (?, ?, ?, ?, ?, ?) on conflict(account, day, hour) do update set
      tokens = excluded.tokens, cost = excluded.cost, unpriced = excluded.unpriced
      where excluded.tokens >= tokens`);
    this.db.transaction(() => {
      for (const [day, hours] of usage) {
        hours.tokens.forEach((tokens, hour) => {
          if (tokens > 0) upsert.run(account, day, hour, tokens, hours.cost[hour]!, hours.unpriced[hour]!);
        });
      }
    })();
  }

  usageDays(account: string): UsageDay[] {
    const rows = this.db.query('select day, hour, tokens, cost, unpriced from usage_hours where account = ? order by day')
      .all(account) as Array<{ day: string; hour: number; tokens: number; cost: number; unpriced: number }>;
    const days = new Map<string, UsageDay>();
    for (const row of rows) {
      const day = days.get(row.day)
        ?? { date: row.day, tokens: 0, hours: Array<number>(24).fill(0), cost: 0, costHours: Array<number>(24).fill(0), unpriced: 0 };
      day.tokens += row.tokens;
      day.hours[row.hour]! += row.tokens;
      day.cost += row.cost;
      day.costHours[row.hour]! += row.cost;
      day.unpriced += row.unpriced;
      days.set(row.day, day);
    }
    return [...days.values()];
  }

  projects(): Project[] { return this.db.query('select * from projects order by created_at, id').all().map(projectOf); }
  contextTemplates(): Template[] {
    return this.db.query('select template from context_templates order by id').all()
      .map((row: any) => JSON.parse(row.template));
  }
  contextTemplate(id: string): Template | undefined {
    const row = this.db.query('select template from context_templates where id = ?').get(id) as { template: string } | null;
    return row ? JSON.parse(row.template) : undefined;
  }
  templateEmblem(id: string): TemplateEmblem | undefined {
    const row = this.db.query('select emblem from template_emblems where template_id = ?').get(id) as { emblem: string } | null;
    return row ? JSON.parse(row.emblem) : undefined;
  }
  templateEmblems(): Array<{ id: string; emblem: TemplateEmblem }> {
    return this.db.query('select template_id, emblem from template_emblems order by template_id').all()
      .map((row: any) => ({ id: row.template_id, emblem: JSON.parse(row.emblem) }));
  }
  projectConstraints(projectId: string): ProjectConstraints | undefined {
    const row = this.db.query('select constraints from project_constraints where project_id = ?').get(projectId) as { constraints: string } | null;
    return row ? JSON.parse(row.constraints) : undefined;
  }
  /** 工作区所在项目的约束，按工作区直接查，不必组装整个工作区模型。 */
  workspaceConstraints(workspaceId: string): ProjectConstraints | undefined {
    const row = this.db.query(`select p.constraints from workspaces w join checkouts c on c.id = w.checkout_id
      join project_constraints p on p.project_id = c.project_id where w.id = ?`).get(workspaceId) as { constraints: string } | null;
    return row ? JSON.parse(row.constraints) : undefined;
  }
  saveProjectConstraints(projectId: string, constraints: ProjectConstraints): void {
    this.db.query('insert into project_constraints values (?, ?) on conflict(project_id) do update set constraints = excluded.constraints')
      .run(projectId, JSON.stringify(constraints));
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
  deleteRole(id: string): void {
    this.db.query('delete from roles where id = ?').run(id);
  }
  saveRole(role: Role): void {
    this.db.query('insert into roles values (?, ?) on conflict(id) do update set role = excluded.role').run(role.id, JSON.stringify(role));
  }
  saveContextTemplate(template: Template): void {
    this.db.query('insert into context_templates values (?, ?) on conflict(id) do update set template = excluded.template')
      .run(template.definition.id, JSON.stringify(template));
  }
  project(id: string): Project | null {
    const r = this.db.query('select * from projects where id = ?').get(id);
    return r ? projectOf(r) : null;
  }
  /** 项目在本机的检出，连同本机的项目记录一起建立。项目名称与远程以登记表为准。 */
  addCheckout(project: Project, checkout: Checkout): void {
    this.db.transaction(() => {
      this.saveProject(project);
      this.db.query('insert into checkouts values (?, ?, ?, ?, ?, ?)')
        .run(checkout.id, checkout.projectId, checkout.machineId, checkout.path, checkout.remote, checkout.createdAt);
    })();
  }
  saveProject(project: Project): void {
    this.db.query('insert into projects values (?, ?, ?, ?) on conflict(id) do update set name = excluded.name, remote = excluded.remote')
      .run(project.id, project.name, project.remote, project.createdAt);
  }
  /** 登记表把 from 并入了 to：本机的检出改挂到 to，from 的本机记录删掉。 */
  mergeProject(from: string, to: Project): void {
    this.db.transaction(() => {
      this.saveProject(to);
      this.db.query('update checkouts set project_id = ? where project_id = ?').run(to.id, from);
      // 保留的项目在本机还没有约束缓存时接过并入项目的，合并后不会有一段时间没有约束；资源库同步随后按登记表对齐。
      this.db.query('update or ignore project_constraints set project_id = ? where project_id = ?').run(to.id, from);
      this.db.query('delete from project_constraints where project_id = ?').run(from);
      this.db.query('delete from projects where id = ?').run(from);
    })();
  }
  /** 登记表删掉了项目：本机的检出、约束缓存与项目记录一起删；工作区的行由调用方先删（deleteWorkspaceRows）。 */
  removeProject(id: string): void {
    this.db.transaction(() => {
      this.db.query('delete from checkouts where project_id = ?').run(id);
      this.db.query('delete from project_constraints where project_id = ?').run(id);
      this.db.query('delete from projects where id = ?').run(id);
    })();
  }
  setCheckoutRemote(id: string, remote: string | null): void {
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
  addWorkspace(w: Workspace, firstAgent?: { agent: AgentInstance; window: WorkspaceWindow }): void {
    this.db.transaction(() => {
      this.db.query(`insert into workspaces (id, checkout_id, name, cwd, branch, base, status, created_at, epoch, behind, pull_request)
        values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`)
        .run(w.id, w.checkoutId, w.name, w.cwd, w.branch, w.base, w.status, w.createdAt, w.epoch, w.behind,
          w.pullRequest ? JSON.stringify(w.pullRequest) : null);
      if (firstAgent) this.addAgent(firstAgent.agent, firstAgent.window);
    })();
  }
  /** 执行权流转走：本地记录改为 transferred。receiver 是交给的那台（没有远程的项目）。 */
  freezeWorkspace(id: string, receiver?: { epoch: number; machine: string }): void {
    this.db.transaction(() => {
      this.setWorkspaceStatus(id, 'transferred');
      if (receiver) this.db.query('insert or replace into workspace_receivers values (?, ?, ?)').run(id, receiver.epoch, receiver.machine);
    })();
  }
  /** 主线比工作区分支多出的提交数；没变时返回 false。 */
  setWorkspaceBehind(id: string, behind: number | null): boolean {
    return this.db.query('update workspaces set behind = ? where id = ? and behind is not ?').run(behind, id, behind).changes > 0;
  }
  setWorkspacePullRequest(id: string, pullRequest: Workspace['pullRequest']): void {
    this.db.query('update workspaces set pull_request = ? where id = ?').run(pullRequest ? JSON.stringify(pullRequest) : null, id);
  }
  /** 工作区在这一 epoch 交给了哪台；没有记录时为 undefined。 */
  workspaceReceiver(id: string, epoch: number): string | undefined {
    return (this.db.query('select machine from workspace_receivers where workspace_id = ? and epoch = ?').get(id, epoch) as { machine: string } | null)?.machine;
  }
  setWorkspaceEpoch(id: string, epoch: number): void {
    this.db.query('update workspaces set epoch = ? where id = ?').run(epoch, id);
  }
  setWorkspaceStatus(id: string, status: WorkspaceStatus): void {
    this.db.query('update workspaces set status = ? where id = ?').run(status, id);
  }
  renameWorkspace(id: string, name: string): void {
    this.db.query('update workspaces set name = ? where id = ?').run(name, id);
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
  /** 非代理实例与可选的首窗口原子创建。 */
  addPluginInstance(instance: PluginInstance, window?: WorkspaceWindow): void {
    this.db.transaction(() => {
      this.addInstance(instance);
      if (window) this.addWindow(window);
    })();
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
  /**
   * 工作区流转的原始行：工作区及其实例、线程、标题、窗口、窗口请求、通知与操作收据。
   * 操作收据按请求里的工作区或调用方实例归属。
   */
  exportWorkspaceRows(id: string): WorkspaceRows {
    const instances = `select id from plugin_instances where workspace_id = ?`;
    const all = (sql: string, ...values: string[]) => this.db.query(sql).all(...values) as Array<Record<string, unknown>>;
    return {
      workspaces: all('select * from workspaces where id = ?', id),
      plugin_instances: all('select * from plugin_instances where workspace_id = ? order by created_at, id', id),
      threads: all(`select * from threads where instance_id in (${instances})`, id),
      thread_titles: all(`select * from thread_titles where instance_id in (${instances})`, id),
      workspace_windows: all('select * from workspace_windows where workspace_id = ?', id),
      window_requests: all('select * from window_requests where workspace_id = ?', id),
      instance_notifications: all(`select * from instance_notifications where instance_id in (${instances}) order by seq`, id),
      operation_receipts: all(`select * from operation_receipts where json_extract(request, '$.workspaceId') = ?
        or caller in (select 'model:' || id from plugin_instances where workspace_id = ? union select 'plugin:' || id from plugin_instances where workspace_id = ?)`, id, id, id),
    };
  }
  /**
   * 导入流转来的原始行。workspace 覆盖工作区行里随机器变化的列；通知只导入游标之后、尚未交接的，
   * 并在本库重新编号到游标之后（序号全库自增，两台机器各自计数）。
   */
  importWorkspaceRows(rows: WorkspaceRows, workspace: Record<string, unknown>, cursors: Map<string, number>): void {
    this.transaction(() => {
      for (const table of workspaceTables) {
        for (const raw of rows[table]) {
          let row = table === 'workspaces' ? { ...raw, ...workspace } : raw;
          if (table === 'instance_notifications') {
            const cursor = cursors.get(row.instance_id as string) ?? 0;
            if ((row.seq as number) <= cursor) continue;
            const max = (this.db.query('select coalesce(max(seq), 0) as max from instance_notifications').get() as { max: number }).max;
            row = { ...row, seq: Math.max(max, cursor) + 1 };
          }
          this.insertRow(table, row);
        }
      }
    });
  }
  /**
   * 原样插回本库先前导出的行，用于流转接管失败时还原本机原有的冻结或归档记录：不改写列，通知保持原序号
   * （它们本来就在这个库里，删掉的只是这次导入）。
   */
  restoreWorkspaceRows(rows: WorkspaceRows): void {
    this.transaction(() => {
      for (const table of workspaceTables) for (const row of rows[table]) this.insertRow(table, row);
    });
  }
  /** 操作收据不随工作区删除，重复的忽略。 */
  private insertRow(table: (typeof workspaceTables)[number], row: Record<string, unknown>): void {
    const columns = Object.keys(row);
    this.db.query(`insert ${table === 'operation_receipts' ? 'or ignore ' : ''}into ${table} (${columns.join(', ')}) values (${columns.map(() => '?').join(', ')})`)
      .run(...columns.map((column) => row[column] as string | number | null));
  }
  /** 工作区内结果尚未确认的操作（进行中或崩溃后缺结果）。 */
  unfinishedOperations(workspaceId: string): number {
    return (this.db.query(`select count(*) as count from operation_receipts where result is null and json_extract(request, '$.workspaceId') = ?`)
      .get(workspaceId) as { count: number }).count;
  }
  /** 删掉一个工作区的全部行，用于流转失败时清理半成品，或用流转回来的材料替换本机冻结的旧记录。 */
  deleteWorkspaceRows(id: string): void {
    const instances = `select id from plugin_instances where workspace_id = ?`;
    this.transaction(() => {
      this.db.query(`delete from instance_notifications where instance_id in (${instances})`).run(id);
      this.db.query(`delete from thread_titles where instance_id in (${instances})`).run(id);
      this.db.query(`delete from threads where instance_id in (${instances})`).run(id);
      this.db.query('delete from window_requests where workspace_id = ?').run(id);
      this.db.query('delete from workspace_windows where workspace_id = ?').run(id);
      this.db.query('delete from plugin_instances where workspace_id = ?').run(id);
      this.db.query('delete from workspaces where id = ?').run(id);
    });
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
