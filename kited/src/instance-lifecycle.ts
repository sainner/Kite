/** 实例的创建、请求去重、视图切换与关闭回收；工作区控制队列由 Kite 提供。 */
import { randomUUID } from 'node:crypto';
import { rmSync } from 'node:fs';
import { join } from 'node:path';
import { KiteError } from './errors.ts';
import type { Kite } from './kite.ts';
import { numberedTitle, type CreateInstanceRequest, type PluginInstance, type Thread } from './model.ts';
import { roleOperationGrants } from './operations/contract.ts';
import { defaultRoleId, roleAgent, toolLimits, type RoleChoice } from './roles.ts';
import { instanceAgent } from './agents/definition.ts';
import { monitorDefinitionId } from './monitor/monitors.ts';
import { terminalDefinitionId } from './terminal/terminals.ts';
import { previewDefinitionId } from './preview/state.ts';
import { filesDefinitionId } from './workspace/files.ts';

/** 新代理在本机草稿里选好的角色与初始参数，创建时一次写入实例配置；省略 revision 时用角色的最新版本。fast 是快速模式，角色不给默认。 */
export interface AgentChoice extends RoleChoice {
  role?: { id: string; revision?: string };
  fast?: boolean;
}

type InstanceServices = Pick<Kite, 'store' | 'home' | 'catalog' | 'workspace' | 'plugins' | 'roles' | 'terminals' | 'previews' | 'pageSelection' | 'pluginGrants'>;

interface InstanceControl {
  run<T>(workspaceId: string, action: () => Promise<T>): Promise<T>;
  changed(workspaceId: string): void;
  revokeGrants(instance: PluginInstance): void;
}

export class InstanceLifecycle {
  constructor(private kite: InstanceServices, private control: InstanceControl) {}

  /** projectId 供尚未入库的新工作区使用，其余情况从工作区查出。当前视图从定义的默认视图起。 */
  newInstance(workspaceId: string, definitionId: string, title: string, choice: AgentChoice = {}, projectId?: string): PluginInstance {
    const definition = this.kite.catalog.get(definitionId);
    const project = definition.agent && (projectId ? this.kite.store.projectConstraints(projectId) : this.kite.store.workspaceConstraints(workspaceId))?.tools;
    const bound = definition.agent && roleAgent(this.kite.roles.get(choice.role?.id ?? defaultRoleId, choice.role?.revision), choice, project);
    const grants = bound ? roleOperationGrants(definitionId, [], [], toolLimits(bound.role.tools).allowed) : [];
    // 执行授权取角色的，角色没给就是在项目基础上不增不减；审批模式总写入解析好的。项目的基础与边界不拷进实例，每次按项目此刻的约束合成。
    // Bun 插件的协作授权拷定义级的。
    const config = bound ? { agent: bound.agent, role: bound.role, grants, ...(bound.execution ? { execution: bound.execution } : {}), approval: bound.approval,
      ...(bound.mcp.length ? { mcp: bound.mcp } : {}), ...(choice.fast ? { fast: true } : {}) }
      : definition.runtime === 'bun' ? { packageRevision: definition.revision, grants: this.kite.pluginGrants(definitionId).grants } : {};
    return { id: randomUUID(), workspaceId, definitionId, title, config, state: {},
      ...(definition.defaultView ? { view: definition.defaultView } : {}), status: 'open', createdAt: Date.now() };
  }

  /**
   * 新建实例：请求 ID 就是实例 ID，同一请求重试返回同一实例，ID 已用于别的内容或实例已回收时拒绝；空代理不启动模型。
   * 新建预览时，同一目标与设备已经在跑就返回那个实例、不新建，同一目标与设备只跑一份；已经结束、用户还没关的在原来的实例里重新起。
   */
  create(workspaceId: string, request: CreateInstanceRequest): Promise<PluginInstance> {
    return this.control.run(workspaceId, async () => {
      const model = this.kite.workspace(workspaceId);
      if (model.workspace.status !== 'open') throw new KiteError('工作区尚未打开', 409);
      const { id, ...content } = request;
      const key = JSON.stringify(content);
      const saved = this.kite.store.instanceRequest(id);
      if (saved) {
        const instance = this.kite.store.instance(saved.instanceId);
        if (saved.workspaceId !== workspaceId || saved.content !== key || instance?.status !== 'open') throw new KiteError('实例 ID 已用于其他内容，或实例已回收', 409);
        return instance;
      }
      if (this.kite.store.instance(id)) throw new KiteError('实例 ID 已使用', 409);
      const definition = this.kite.catalog.get(content.definitionId);
      if (definition.id === monitorDefinitionId) throw new KiteError('monitor 由代理用 monitor_start 开启，或随 Line 创建');
      if (content.command !== undefined && definition.id !== terminalDefinitionId) throw new KiteError('只有终端能带命令新建');
      if ((content.preview !== undefined) !== (definition.id === previewDefinitionId)) throw new KiteError('预览要带 preview 新建，别的插件不带');
      if (content.page !== undefined && definition.id !== filesDefinitionId) throw new KiteError('只有浏览能带网页新建');
      const resolved = content.preview && await this.kite.previews.resolve(workspaceId, content.preview);
      const existing = resolved && this.kite.previews.find(workspaceId, resolved.spec);
      // 同一目标与设备只跑一份：已经在跑就返回那个实例，已经结束的在原来的实例里重新起
      const launch = resolved && !(existing && this.kite.terminals.running(existing.id)) ? await this.kite.previews.prepare(workspaceId, resolved) : undefined;
      let created: PluginInstance | undefined;
      let thread: Thread | undefined;
      if (!existing) {
        created = { ...this.newInstance(workspaceId, definition.id, content.title
          ?? (launch ? launch.title : definition.agent ? '新代理'
            : numberedTitle(definition.title, model.instances.filter((p) => p.definitionId === definition.id).map((p) => p.title)))),
          id, ...(content.page ? { state: this.kite.pageSelection(workspaceId, content.page) } : {}),
          ...(launch ? { config: { preview: launch.spec } } : {}) };
        if (definition.agent) thread = { instanceId: created.id, runtime: instanceAgent(created).runtime, nativeId: randomUUID() };
      }
      const instance = existing ?? created!;
      this.kite.store.createInstance({ id, workspaceId, instanceId: instance.id, content: key }, created, thread);
      if (created?.definitionId === terminalDefinitionId) this.kite.terminals.start(created, { command: content.command });
      if (launch) this.kite.previews.start(instance, launch);
      this.control.changed(workspaceId);
      return instance;
    });
  }

  /** 换当前视图，须由定义声明；只改实例状态，不改变它在各设备台面上的位置。 */
  setView(id: string, viewId: string): Promise<PluginInstance> {
    const instance = this.kite.store.instance(id);
    if (!instance) throw new KiteError('没有这个实例', 404);
    return this.control.run(instance.workspaceId, async () => {
      const current = this.kite.store.instance(id);
      if (!current) throw new KiteError('没有这个实例', 404);
      if (current.status !== 'open') throw new KiteError('实例已经归档', 409);
      if (!this.kite.catalog.get(current.definitionId).views.some((view) => view.id === viewId)) throw new KiteError('插件未声明这个视图');
      if (current.view === viewId) return current;
      this.kite.store.setInstanceView(id, viewId);
      this.control.changed(current.workspaceId);
      return { ...current, view: viewId };
    });
  }

  /**
   * 关闭实例：closable 的回收；process 的进程还在跑就先停、确认结束再回收；persistent 的用归档。
   * 已经不在的实例 404；排到队列里时刚被回收的（进程恰好结束）算关闭成功。
   */
  close(id: string): Promise<void> {
    const instance = this.kite.store.instance(id);
    if (!instance) throw new KiteError('没有这个实例', 404);
    const { lifetime } = this.kite.catalog.get(instance.definitionId);
    if (lifetime === 'persistent') throw new KiteError('独立存续的实例不能关闭，请归档', 409);
    return this.control.run(instance.workspaceId, async () => {
      if (!this.kite.store.instance(id)) return;
      if (lifetime === 'process') await this.kite.terminals.stop(id, '已在界面上关闭');
      const release = await this.kite.plugins.closeInstance(id);
      try {
        const current = this.kite.store.instance(id);
        if (current) this.collect(current);
      } finally { release(); }
      this.control.changed(instance.workspaceId);
    });
  }

  /** 回收不再运行的实例：会话目录、指向它的授权和实例本身；实例 ID 不再复用。在控制队列里调用。 */
  collect(instance: PluginInstance): void {
    this.kite.terminals.forget(instance.id);
    this.kite.previews.forget(instance.id);
    rmSync(join(this.kite.home, 'sessions', instance.id), { recursive: true, force: true });
    this.kite.store.transaction(() => {
      this.control.revokeGrants(instance);
      this.kite.store.deleteInstance(instance.id);
    });
  }
}
