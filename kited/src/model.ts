/** 项目以远程仓库为身份；检出是某台机器上 Kite 自己的裸仓库；工作区拥有文件和快照；线程拥有对话及执行。 */
/**
 * handing_off：已进入可交接状态，材料已经或正要推到远程，拒绝新的执行，目标接管前可以撤回。
 * transferred：执行权已流转到别的机器，本地记录冻结，只读历史仍可用。
 */
export type WorkspaceStatus = 'preparing' | 'open' | 'failed' | 'archived' | 'handing_off' | 'transferred';
/** 本机仍持有这个工作区：没流转走，也没归档。 */
export const holds = (workspace: { status: WorkspaceStatus }) => workspace.status !== 'transferred' && workspace.status !== 'archived';
export type RuntimeKind = 'claude' | 'harness';

/** 一个工作机服务的持久身份，随 KITE_HOME 保存；网络地址由客户端管理。 */
export interface Machine {
  id: string;
  name: string;
  createdAt: number;
}

/** 项目 ID 由项目登记表分配，同一远程总是同一个 ID。 */
export interface Project {
  id: string;
  name: string;
  /** 归一化的远程地址（`域名/owner/repo`），设了远程后随登记表更新；没有远程的项目为 null，各工作机的检出互为远程。 */
  remote: string | null;
  createdAt: number;
}

/** 检出是 <KITE_HOME>/repos/<项目>.git 的裸仓库，这台机器上该项目的工作区都从它开出工作树。 */
export interface Checkout {
  id: string;
  projectId: string;
  machineId: string;
  path: string;
  /** 检出 origin 当前指向的远程（归一化）；没有远程的项目为 null。 */
  remote: string | null;
  createdAt: number;
}

/** 提交 PR 的工作区最近一次集成：推到的远程分支、PR 页面与状态。不能自动开 PR 的平台 url 是去开 PR 的网页，没有 number。 */
export interface PullRequest {
  branch: string;
  url: string;
  number?: number;
  state: 'open' | 'merged' | 'closed';
  /** 推上去的提交：PR 合并后工作区没有新改动才算已采纳。 */
  commit: string;
}

/** 工作区 ID 创建时生成，流转到别的机器后不变；epoch 区分同一 ID 在不同机器上的记录新旧，每次接管加 1。 */
export interface Workspace {
  id: string;
  epoch: number;
  checkoutId: string;
  name: string;
  /** 名称跟着代理的标题自动起（auto），还是用户起的（manual），见 WorkspaceNames。 */
  nameMode: 'auto' | 'manual';
  cwd: string;
  /** 工作树的本地分支与开出时的主线提交。 */
  branch: string;
  base: string;
  status: WorkspaceStatus;
  createdAt: number;
  /** 主线比工作区分支多出的提交数，按最近一次拉取计算；还没算过时为 null。 */
  behind: number | null;
  pullRequest: PullRequest | null;
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

/** 共享窗口集合由工作机保存，一个实例最多一个打开的窗口，target.viewId 是它当前的视图；分栏、停靠和焦点不进入这个对象。 */
export interface WorkspaceWindow {
  id: string;
  workspaceId: string;
  target: WindowTarget;
  state: 'open' | 'closed';
  createdAt: number;
}

export interface OpenWindowRequest {
  id: string;
  /** create 的 instanceId 是新实例的 ID，App 给的话按它建（App 先按它在本机打开窗口）。 */
  content: ({ kind: 'open' } & WindowTarget) | { kind: 'create'; definitionId: string; instanceId?: string };
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
