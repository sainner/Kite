/** 实例与窗口的创建、请求去重及随窗口回收；工作区控制队列由 Kite 提供。 */
import { randomUUID } from 'node:crypto';
import { rmSync } from 'node:fs';
import { join } from 'node:path';
import { KiteError } from './errors.ts';
import type { Kite } from './kite.ts';
import type { OpenWindowRequest, PluginInstance, Thread, Workspace, WorkspaceWindow } from './model.ts';
import { defaultOperationGrants, operationContracts } from './operations/contract.ts';
import { defaultRoleId, roleAgent, toolLimits, type RoleChoice } from './roles.ts';

/** 新代理在本机草稿里选好的角色与初始参数，创建时一次写入实例配置；省略 revision 时用角色的最新版本。 */
export interface AgentChoice extends RoleChoice {
  role?: { id: string; revision?: string };
}

type InstanceServices = Pick<Kite, 'store' | 'home' | 'catalog' | 'workspace' | 'plugins' | 'roles'>;

interface InstanceControl {
  run<T>(workspaceId: string, action: () => Promise<T>): Promise<T>;
  changed(workspaceId: string): void;
  revokeGrants(instance: PluginInstance): void;
}

export class InstanceLifecycle {
  constructor(private kite: InstanceServices, private control: InstanceControl) {}

  /** projectId 供尚未入库的新工作区使用，其余情况从工作区查出。 */
  newInstance(workspaceId: string, definitionId: string, title: string, kind: Workspace['kind'], choice: AgentChoice = {}, projectId?: string): PluginInstance {
    const definition = this.kite.catalog.get(definitionId);
    const project = definition.agent && this.kite.store.projectConstraints(projectId ?? this.kite.workspace(workspaceId).project.id)?.tools;
    const bound = definition.agent && roleAgent(definition.agent, this.kite.roles.get(choice.role?.id ?? defaultRoleId, choice.role?.revision), kind, choice, project);
    // 协作操作的默认授权只给角色允许使用对应工具的代理，例如只读审查不带。
    const permitted = bound && toolLimits(definition.agent!.tools, bound.role.tools).allowed;
    const grants = permitted ? defaultOperationGrants(definitionId).filter((grant) => permitted.includes(operationContracts[grant.operation].tool ?? '')) : [];
    return { id: randomUUID(), workspaceId, definitionId, title,
      config: bound ? { ...bound, grants, execution: definition.execution } : definition.runtime === 'bun' ? { packageRevision: definition.revision, grants: [] } : {}, state: {},
      presentation: 'window', status: 'open', createdAt: Date.now() };
  }

  newWindow(instance: PluginInstance, id: string = randomUUID(), viewId = this.kite.catalog.get(instance.definitionId).defaultView): WorkspaceWindow {
    if (!viewId) throw new KiteError('此插件没有窗口视图，请创建后台实例');
    return { id, workspaceId: instance.workspaceId, target: { instanceId: instance.id, viewId }, state: 'open', createdAt: Date.now() };
  }

  /** 新实例和首窗口原子登记；空会话不启动模型。 */
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
        const titles = new Set(model.instances.filter((p) => p.definitionId === definition.id).map((p) => p.title));
        let number = 1;
        while (titles.has(`${definition.title} ${number}`)) number++;
        created = this.newInstance(workspaceId, definition.id, definition.agent ? '新代理' : `${definition.title} ${number}`, model.workspace.kind);
        if (definition.agent) thread = { instanceId: created.id, runtime: definition.agent.runtime, nativeId: randomUUID() };
        window = this.newWindow(created, request.id);
      } else {
        const instance = this.kite.store.instance(content.instanceId);
        if (!instance || instance.workspaceId !== workspaceId) throw new KiteError('工作区内没有这个实例', 404);
        if (instance.status !== 'open') throw new KiteError('实例已经归档', 409);
        if (!this.kite.catalog.get(instance.definitionId).views.some((view) => view.id === content.viewId)) throw new KiteError('插件未声明这个视图');
        window = this.newWindow(instance, request.id, content.viewId);
      }
      const { target } = window;
      const existing = model.windows.find((w) => w.target.instanceId === target.instanceId && w.target.viewId === target.viewId);
      window = existing ?? window;
      this.kite.store.openWindow(window, { id: request.id, content: key }, created, thread);
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
      const instance = { ...this.newInstance(workspaceId, definitionId, title ?? definition.title, workspace.kind), id, presentation: 'background' as const };
      this.kite.store.addInstance(instance);
      this.control.changed(workspaceId);
      return instance;
    });
  }

  closeWindow(workspaceId: string, id: string): Promise<void> {
    return this.control.run(workspaceId, async () => {
      if (this.kite.workspace(workspaceId).workspace.status !== 'open') throw new KiteError('工作区尚未打开', 409);
      const window = this.kite.store.window(id);
      if (!window || window.workspaceId !== workspaceId) throw new KiteError('工作区内没有这个窗口', 404);
      if (window.state === 'closed') return;
      const instance = this.kite.store.instance(window.target.instanceId)!;
      const definition = this.kite.catalog.get(instance.definitionId);
      const collect = definition.lifetime === 'window'
        && !this.kite.store.windows(workspaceId).some((other) => other.id !== id && other.target.instanceId === instance.id);
      if (collect) {
        const release = await this.kite.plugins.closeInstance(instance.id);
        try {
          rmSync(join(this.kite.home, 'sessions', instance.id), { recursive: true, force: true });
          this.kite.store.transaction(() => {
            this.kite.store.closeWindow(id);
            this.control.revokeGrants(instance);
            this.kite.store.deleteInstance(instance.id);
          });
        } finally { release(); }
      } else this.kite.store.closeWindow(id);
      this.control.changed(workspaceId);
    });
  }
}
