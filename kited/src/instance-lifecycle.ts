/** 实例与窗口的创建、请求去重及随窗口回收；工作区控制队列由 Kite 提供。 */
import { randomUUID } from 'node:crypto';
import { rmSync } from 'node:fs';
import { join } from 'node:path';
import { KiteError } from './errors.ts';
import type { Kite } from './kite.ts';
import { numberedTitle, type OpenWindowRequest, type PluginInstance, type Thread, type WorkspaceWindow } from './model.ts';
import { roleOperationGrants } from './operations/contract.ts';
import { defaultRoleId, roleAgent, toolLimits, type RoleChoice } from './roles.ts';
import { instanceAgent } from './agents/definition.ts';
import { monitorDefinitionId } from './monitor/monitors.ts';
import { terminalDefinitionId } from './terminal/terminals.ts';

/** 新代理在本机草稿里选好的角色与初始参数，创建时一次写入实例配置；省略 revision 时用角色的最新版本。 */
export interface AgentChoice extends RoleChoice {
  role?: { id: string; revision?: string };
}

type InstanceServices = Pick<Kite, 'store' | 'home' | 'catalog' | 'workspace' | 'plugins' | 'roles' | 'terminals'>;

interface InstanceControl {
  run<T>(workspaceId: string, action: () => Promise<T>): Promise<T>;
  changed(workspaceId: string): void;
  revokeGrants(instance: PluginInstance): void;
}

export class InstanceLifecycle {
  constructor(private kite: InstanceServices, private control: InstanceControl) {}

  /** projectId 供尚未入库的新工作区使用，其余情况从工作区查出。 */
  newInstance(workspaceId: string, definitionId: string, title: string, choice: AgentChoice = {}, projectId?: string): PluginInstance {
    const definition = this.kite.catalog.get(definitionId);
    const project = definition.agent && (projectId ? this.kite.store.projectConstraints(projectId) : this.kite.store.workspaceConstraints(workspaceId))?.tools;
    const bound = definition.agent && roleAgent(this.kite.roles.get(choice.role?.id ?? defaultRoleId, choice.role?.revision), choice, project);
    const grants = bound ? roleOperationGrants(definitionId, [], [], toolLimits(bound.role.tools).allowed) : [];
    // 执行授权取角色的，角色没给就是在项目基础上不增不减；审批模式总写入解析好的。项目的基础与边界不拷进实例，每次按项目此刻的约束合成。
    const config = bound ? { agent: bound.agent, role: bound.role, grants, ...(bound.execution ? { execution: bound.execution } : {}), approval: bound.approval }
      : definition.runtime === 'bun' ? { packageRevision: definition.revision, grants: [] } : {};
    return { id: randomUUID(), workspaceId, definitionId, title, config, state: {},
      presentation: 'window', status: 'open', createdAt: Date.now() };
  }

  newWindow(instance: PluginInstance, id: string = randomUUID(), viewId = this.kite.catalog.get(instance.definitionId).defaultView): WorkspaceWindow {
    if (!viewId) throw new KiteError('此插件没有窗口视图，请创建后台实例');
    return { id, workspaceId: instance.workspaceId, target: { instanceId: instance.id, viewId }, state: 'open', createdAt: Date.now() };
  }

  /** 新实例和首窗口原子登记，打开已有实例的视图时它的窗口换过去；空会话不启动模型。 */
  openWindow(workspaceId: string, request: OpenWindowRequest): Promise<WorkspaceWindow> {
    return this.control.run(workspaceId, async () => {
      const model = this.kite.workspace(workspaceId);
      if (model.workspace.status !== 'open') throw new KiteError('工作区尚未打开', 409);
      const key = JSON.stringify(request.content);
      const saved = this.kite.store.windowRequest(request.id);
      if (saved) {
        const window = this.kite.store.window(saved.windowId)!;
        if (saved.workspaceId !== workspaceId || saved.content !== key || window.state !== 'open') {
          throw new KiteError('窗口请求已使用或窗口已关闭', 409);
        }
        return window;
      }
      if (this.kite.store.window(request.id)) throw new KiteError('窗口 ID 已使用', 409);
      let created: PluginInstance | undefined;
      let thread: Thread | undefined;
      let window: WorkspaceWindow;
      const content = request.content;
      if (content.kind === 'create') {
        const definition = this.kite.catalog.get(content.definitionId);
        if (definition.id === monitorDefinitionId) throw new KiteError('monitor 由代理用 monitor_start 开启，或随 Line 创建');
        if (content.command !== undefined && definition.id !== terminalDefinitionId) throw new KiteError('只有终端能带命令新建');
        if (content.instanceId && (this.kite.store.instance(content.instanceId) || this.kite.store.hasInstanceWindows(content.instanceId))) {
          throw new KiteError('实例 ID 已使用', 409);
        }
        created = { ...this.newInstance(workspaceId, definition.id, content.title ?? (definition.agent ? '新代理'
          : numberedTitle(definition.title, model.instances.filter((p) => p.definitionId === definition.id).map((p) => p.title)))),
          ...(content.instanceId ? { id: content.instanceId } : {}) };
        if (definition.agent) thread = { instanceId: created.id, runtime: instanceAgent(created).runtime, nativeId: randomUUID() };
        window = this.newWindow(created, request.id);
      } else {
        const instance = this.kite.store.instance(content.instanceId);
        if (!instance || instance.workspaceId !== workspaceId) throw new KiteError('工作区内没有这个实例', 404);
        if (instance.status !== 'open') throw new KiteError('实例已经归档', 409);
        if (!this.kite.catalog.get(instance.definitionId).views.some((view) => view.id === content.viewId)) throw new KiteError('插件未声明这个视图');
        // 实例已有窗口时不另开：那个窗口换到请求的视图
        const existing = model.windows.find((w) => w.target.instanceId === instance.id);
        window = existing ? { ...existing, target: { instanceId: instance.id, viewId: content.viewId } } : this.newWindow(instance, request.id, content.viewId);
      }
      this.kite.store.openWindow(window, { id: request.id, content: key }, created, thread);
      if (created?.definitionId === terminalDefinitionId) this.kite.terminals.start(created, content.kind === 'create' ? content.command : undefined);
      this.control.changed(workspaceId);
      return window;
    });
  }

  createPluginInstance(workspaceId: string, id: string, definitionId: string, title?: string) {
    return this.control.run(workspaceId, async () => {
      const { workspace } = this.kite.workspace(workspaceId);
      if (workspace.status !== 'open') throw new KiteError('工作区尚未打开', 409);
      const definition = this.kite.catalog.get(definitionId);
      if (definition.runtime !== 'bun') throw new KiteError('此入口用于创建 Bun 插件实例');
      if (definition.lifetime === 'window') throw new KiteError('此插件随窗口回收，请同时创建实例和窗口');
      const existing = this.kite.store.instance(id);
      if (existing) {
        if (existing.workspaceId !== workspaceId || existing.definitionId !== definitionId || existing.title !== (title ?? definition.title)
          || existing.status !== 'open') throw new KiteError('实例 ID 已用于其他创建请求', 409);
        return existing;
      }
      if (this.kite.store.hasInstanceWindows(id)) throw new KiteError('实例 ID 已回收，不能重新使用', 409);
      const instance = { ...this.newInstance(workspaceId, definitionId, title ?? definition.title), id, presentation: 'background' as const };
      this.kite.store.addInstance(instance);
      this.control.changed(workspaceId);
      return instance;
    });
  }

  /** 随窗口回收的实例关掉窗口时回收；process 实例的进程还在跑就留着，成为没有窗口的后台进程。 */
  closeWindow(workspaceId: string, id: string): Promise<void> {
    return this.control.run(workspaceId, async () => {
      if (this.kite.workspace(workspaceId).workspace.status !== 'open') throw new KiteError('工作区尚未打开', 409);
      const window = this.kite.store.window(id);
      if (!window || window.workspaceId !== workspaceId) throw new KiteError('工作区内没有这个窗口', 404);
      if (window.state === 'closed') return;
      const instance = this.kite.store.instance(window.target.instanceId)!;
      const { lifetime } = this.kite.catalog.get(instance.definitionId);
      const collect = lifetime === 'window' || (lifetime === 'process' && !this.kite.terminals.running(instance.id));
      if (collect) {
        const release = await this.kite.plugins.closeInstance(instance.id);
        try {
          this.kite.store.transaction(() => {
            this.kite.store.closeWindow(id);
            this.collect(instance);
          });
        } finally { release(); }
      } else this.kite.store.closeWindow(id);
      this.control.changed(workspaceId);
    });
  }

  /** 回收已经没有窗口、也不再运行的实例：会话目录、指向它的授权和实例本身；实例 ID 不再复用。在控制队列里调用。 */
  collect(instance: PluginInstance): void {
    this.kite.terminals.forget(instance.id);
    rmSync(join(this.kite.home, 'sessions', instance.id), { recursive: true, force: true });
    this.kite.store.transaction(() => {
      this.control.revokeGrants(instance);
      this.kite.store.deleteInstance(instance.id);
    });
  }
}
