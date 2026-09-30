/** 项目是逻辑身份；检出定位机器目录；工作区拥有文件和快照；线程拥有对话及执行。 */
export type CommitOwner = 'kite' | 'user';
export type WorkspaceStatus = 'preparing' | 'open' | 'failed' | 'archived';
export type RuntimeKind = 'claude' | 'harness';

/** 一个工作机服务的持久身份，随 KITE_HOME 保存；网络地址由客户端管理。 */
export interface Machine {
  id: string;
  name: string;
  createdAt: number;
}

export interface Project {
  id: string;
  name: string;
  createdAt: number;
}

export interface Checkout {
  id: string;
  projectId: string;
  machineId: string;
  path: string;
  commits: CommitOwner;
  createdAt: number;
}

export interface Workspace {
  id: string;
  checkoutId: string;
  name: string;
  cwd: string;
  kind: 'root' | 'worktree';
  /** 根工作区跟随检出当前的 HEAD，独立工作树保存创建时的分支和起点。 */
  branch: string | null;
  base: string | null;
  status: WorkspaceStatus;
  createdAt: number;
}

/** agent 实例的专有记录。主键同时引用插件实例，不另造 agent / thread 身份。 */
export interface Thread {
  instanceId: string;
  runtime: RuntimeKind;
  nativeId: string;
}

/** 共有身份、配置和持久生命周期只由实例持有。 */
export interface PluginInstance {
  id: string;
  workspaceId: string;
  definitionId: string;
  title: string;
  config: Record<string, unknown>;
  state: Record<string, unknown>;
  presentation: 'window' | 'inline' | 'background';
  status: 'open' | 'archived';
  createdAt: number;
  /** 由宿主记录创建来源，不构成级联删除关系，也不由模型参数指定。 */
  origin?: { instanceId: string; operationId: string; turnId?: string; callId?: string };
}

/** 管理和执行时联表得到的只读投影，不额外持久化共有字段。 */
export interface AgentInstance extends PluginInstance, Thread {}

export interface WindowTarget {
  instanceId: string;
  viewId: string;
}

/** 共享窗口集合由工作机保存；分栏、停靠和焦点不进入这个对象。 */
export interface WorkspaceWindow {
  id: string;
  workspaceId: string;
  target: WindowTarget;
  state: 'open' | 'closed';
  createdAt: number;
}

export interface OpenWindowRequest {
  id: string;
  content: ({ kind: 'open' } & WindowTarget) | { kind: 'create'; definitionId: string };
}

export interface WorkspaceModel {
  machine: Machine;
  project: Project;
  checkout: Checkout;
  workspace: Workspace;
  threads: Thread[];
  instances: PluginInstance[];
  windows: WorkspaceWindow[];
}

/** 执行时装配的上下文；路径只来自工作区，主目录只来自检出。 */
export interface ThreadContext extends AgentInstance {
  machine: Machine;
  project: Project;
  checkout: Checkout;
  workspace: Workspace;
}
