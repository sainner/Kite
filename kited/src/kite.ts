/** 工作区负责文件、快照和采纳；线程负责模型执行及独立的对话记录。 */
import type { CompactionRequest, Input, InputVia, StopRequest } from './harness/types.ts';
import { randomUUID } from 'node:crypto';
import { existsSync, mkdirSync, readdirSync, writeFileSync } from 'node:fs';
import { FileDiffStore } from './workspace/file-diffs.ts';
import { join, relative } from 'node:path';
import { KiteError } from './errors.ts';
import { type AdoptResult, Bus, type PushOutcome } from './events.ts';
import { hasUnmerged, mainline, mergeBack } from './workspace/mainline.ts';
import { CheckoutManagement } from './workspace/checkout-management.ts';
import { AccountClient } from './account-client.ts';
import { commitAll, isDirty } from './workspace/git.ts';
import { currentBranch, fetchBranch, originAccess, pushBranch, type CheckoutSync, type RemoteAccess } from './workspace/remote.ts';
import { openRuntime, type Runtime, type RuntimeOptions } from './runtime.ts';
import { capture, changesBetween, findSnapshot, list, restore, type Snapshot } from './workspace/snapshots.ts';
import { compactTemplate } from './harness/compaction.ts';
import type { Store } from './store.ts';
import type { AgentInstance, Checkout, Machine, OpenWindowRequest, PluginInstance, Project, ThreadContext, Workspace, WorkspaceModel, WorkspaceStatus, WorkspaceWindow } from './model.ts';
import { PluginCatalog } from './plugins/catalog.ts';
import { PluginHost } from './plugins/host.ts';
import { InstanceConfiguration } from './instance-configuration.ts';
import { handOff } from './handoff/handoff.ts';
import { instanceAgent, type AgentDefinition } from './agents/definition.ts';
import { InstanceLifecycle, type AgentChoice } from './instance-lifecycle.ts';
import { ContextTemplates } from './context-templates.ts';
import { defaultRoleId, instanceRole, lineRoleId, Roles, type RoleSelection, type RoleSnapshot } from './roles.ts';
import { LibrarySync, type LibraryChanges } from './library-sync.ts';
import { agentDefinitionId, agentToolCatalog, agentTools } from './plugins/definitions.ts';
import { addWorktree, removeWorktree, runSetup } from './workspace/worktrees.ts';
import {
  agentConfigurationContextDefinition, contextUpdateContextDefinition, executionPermissionsContextDefinition, fileChangesContextDefinition,
  pluginToolsContextDefinition,
} from './harness/context/notifications.ts';
import { applyExecutionGrants, instanceApprovalMode, instanceExecutionGrants } from './execution/grants.ts';
import { harnessPolicy } from './execution/policy.ts';
import { commandEnvironment } from './execution/sandbox.ts';
import { monitorConfig, monitorDefinitionId, monitorEventsContextDefinition, Monitors } from './monitor/monitors.ts';
import { InstanceOperations } from './operations/operations.ts';
import { OperationReceipts } from './operations/receipts.ts';
import { lineGrant, type OperationGrant, type OperationInput } from './operations/contract.ts';
import { Peers } from './line/peers.ts';
import { LineMonitor, lineMonitorContextDefinition } from './line/monitor.ts';
import { lineTools } from './line/tools.ts';
import { LINE_AGENTS } from './line/project.ts';
import { Attention } from './line/attention.ts';
import { userHome } from './paths.ts';
import type { Network } from './network.ts';
import { WorkspaceFiles, fileSelection } from './workspace/files.ts';
import { TranscriptFeed } from './transcript/feed.ts';
import { TranscriptHistory } from './transcript/history.ts';
import type { DisplayState, History, ThreadActivity } from './transcript/protocol.ts';
import { LightTasks } from './light-tasks.ts';
import { ThreadTitles, titleTemplate } from './thread-titles.ts';
import { emblemTemplate, TemplateEmblems } from './template-emblems.ts';
import { ChatGPTModel } from './harness/chatgpt.ts';
import { readSubscriptionCredentials } from './harness/auth.ts';
import { SubscriptionLogins } from './subscription-logins.ts';
import { ModelAccounts, readModelAccounts } from './model-accounts.ts';
import { agentModelCatalog } from './agents/capabilities.ts';
import { TokenCounter } from './token-counts.ts';
import { VoiceSessions, voiceTemplate } from './voice/sessions.ts';
import { type Waiting, Waits } from './waiting.ts';
import { readLease, remoteLeases } from './workspace/lease.ts';
import { WorkspaceTransfers } from './transfer/transfers.ts';
import { MIN_FREE_BYTES, readEnvironment, type Environment } from './environment.ts';
import { runtimeOfModel } from './agents/models.ts';

export interface ThreadView extends ThreadContext { runner: Runtime['state']; busy: boolean }

export interface MachineSummary {
  machine: { id: string; name: string };
  workspaces: Array<{
    id: string; epoch: number; status: WorkspaceStatus; kind: Workspace['kind']; name: string; project: { id: string; name: string };
    threads: Array<{ id: string; title: string; role: string | null; phase: string; busy: boolean; waitingForResume: boolean;
      lastOutcome?: string; failure?: string; recovery?: string; waiting?: Waiting;
      /** 这台工作机实时看到的最近一次回合结束时间；重启后要等下一次回合结束才有。 */
      settledAt?: number;
      /** 最近一条输入是 Line 自己的说明：这一回合是 Line 发起的工作，结果交给 Line。 */
      byLine?: true }>;
  }>;
}
const firstLine = (text: string) => text.trim().split('\n')[0]!.trim() || '（空消息）';
const titleOf = (prompt: string) => firstLine(prompt).slice(0, 80);

const PUSH_ATTEMPTS = 3;

function conflictPrompt(branch: string, files: string[]): string {
  return [`Kite 正在把工作区的改动合回主线。主线（本机或远程）有了新提交，把它合进 ${branch} 时这些文件冲突了：`,
    ...files.map((f) => `- ${f}`), '',
    '请直接编辑这些文件解决冲突，保留双方意图，并删除全部冲突标记；需要删除的文件直接删除。',
    'Git 元数据由 Kite 管理，不要运行 git add 或 git commit。本回合正常结束后，Kite 会提交合并并继续合回主线。'].join('\n');
}

export class Kite {
  readonly events = new TranscriptFeed();
  readonly subscriptionLogins: SubscriptionLogins;
  readonly modelAccounts: ModelAccounts;
  readonly operations: InstanceOperations;
  readonly receipts: OperationReceipts;
  readonly catalog: PluginCatalog;
  readonly contextTemplates: ContextTemplates;
  readonly roles: Roles;
  readonly library: LibrarySync;
  readonly plugins: PluginHost;
  readonly lightTasks?: LightTasks;
  readonly titles?: ThreadTitles;
  readonly emblems: TemplateEmblems;
  readonly tokenCounts: TokenCounter;
  readonly voice: VoiceSessions;
  readonly waits: Waits;
  readonly transfers: WorkspaceTransfers;
  /** Line 调用同账号的工作机。 */
  readonly peers: Peers;
  /** Line 的 monitor；daemon 服务起来后启动。 */
  readonly monitor: LineMonitor;
  /** 正在关注 Kite 的设备；Line 所在的工作机据此决定通知与收件箱。 */
  readonly attention: Attention;
  /** 代理用 monitor_start 开的 monitor；Line 的那个由 monitor（LineMonitor）负责。 */
  readonly monitors: Monitors;
  /** 最近一条输入是 Line 自己说明的线程；只在内存里，重启后按用户的工作对待。 */
  private lineWork = new Set<string>();
  /** 服务起来后才知道本机监听地址与组网，Line 调本机和别的工作机时用。 */
  private serving?: { url: string; network?: Network };
  private readonly transcripts: TranscriptHistory;
  private readonly configuration: InstanceConfiguration;
  private readonly instances: InstanceLifecycle;
  private readonly checkoutManagement: CheckoutManagement;
  private runners = new Map<string, Runtime>();
  private openingRunners = new Map<string, Promise<Runtime>>();
  private queues = new Map<string, Promise<unknown>>();
  private preparations = new Map<string, AbortController>();
  private stopping = false;
  private turnLabels = new Map<string, string>();
  private adoptAfterTurn = new Set<string>();
  private leaseSync?: Promise<void>;
  /** 含锁外网络操作的项目任务，关闭时仍需等待它们完成登记。 */
  private projectOperations = new Set<Promise<unknown>>();

  constructor(readonly store: Store, readonly home: string, readonly bus: Bus, private options: RuntimeOptions = {},
    readonly account = new AccountClient(() => undefined)) {
    this.checkoutManagement = new CheckoutManagement(store, home, account, bus, (key, action) => this.serial(key, action));
    this.subscriptionLogins = new SubscriptionLogins(home);
    this.modelAccounts = new ModelAccounts(home, (modelAccounts) => bus.emit({ type: 'model-accounts.changed', modelAccounts }),
      (home) => readModelAccounts(home, { usage: store, apiKeys: async () => this.account.linked ? this.account.apiKeys() : [] }));
    this.catalog = new PluginCatalog(join(home, 'plugins'));
    this.roles = new Roles(store);
    this.contextTemplates = new ContextTemplates(store, [
      titleTemplate, compactTemplate, emblemTemplate,
      agentConfigurationContextDefinition, contextUpdateContextDefinition, executionPermissionsContextDefinition, fileChangesContextDefinition,
      pluginToolsContextDefinition, voiceTemplate, lineMonitorContextDefinition, monitorEventsContextDefinition,
    ]);
    this.library = new LibrarySync({ account, store, roles: this.roles, templates: this.contextTemplates, catalog: this.catalog,
      changed: (changes) => this.libraryChanged(changes) });
    this.receipts = new OperationReceipts(store);
    this.operations = new InstanceOperations(this);
    this.waits = new Waits((threadId, waiting) => bus.emit({ type: 'waiting', threadId, ...(waiting ? { waiting } : {}) }));
    this.plugins = new PluginHost(this);
    this.peers = new Peers({ account, self: () => ({ id: store.machine.id, name: store.machine.name, url: this.serving?.url }),
      proxyPort: () => this.serving?.network?.status().httpProxyPort, ...(options.peers ? { directory: options.peers.directory } : {}) });
    this.monitor = new LineMonitor({ store, peers: this.peers,
      line: () => this.lineInstance(), inbox: () => this.lineInbox(true), deliver: (threadId, text, inputId) => this.send(threadId, text, inputId, 'kite'),
      template: () => this.contextTemplates.get(lineMonitorContextDefinition.id, 'line.monitor').definition,
      focused: () => this.attention.devices().length > 0,
      notify: (notification) => bus.emit({ type: 'line.notification', notification }),
      changed: () => bus.emit({ type: 'line.inbox' }) });
    this.attention = new Attention((devices) => this.monitor.attention(devices.length > 0));
    // 本机的等待与回合变化很快读一轮，远程工作机靠定时读取。
    bus.subscribe((event) => event.type === 'waiting' || event.type === 'idle', () => this.monitor.nudge());
    this.monitors = new Monitors({ store, home, env: commandEnvironment(process.env),
      policy: async (target) => {
        const { workspace, checkout } = this.workspace(target.workspaceId);
        return applyExecutionGrants(await harnessPolicy({ cwd: workspace.cwd, env: process.env, home, repository: checkout.path }), workspace.cwd,
          instanceExecutionGrants(target));
      },
      deliver: (threadId, text, inputId) => this.send(threadId, text, inputId, 'kite'),
      template: () => this.contextTemplates.get(monitorEventsContextDefinition.id, 'monitor.events').definition,
      run: (workspaceId, action) => this.control(workspaceId, action),
      changed: (workspaceId) => this.changed(workspaceId),
      updated: (workspaceId, instanceId) => bus.emit({ type: 'monitor.changed', workspaceId, instanceId }),
      ...(options.monitorWakeDelayMs !== undefined ? { wakeDelayMs: options.monitorWakeDelayMs } : {}) });
    // 工作区开放、交接、冻结、归档与代理归档都会改变 monitor 能不能运行。
    bus.subscribe((event) => event.type === 'workspace.changed' || event.type === 'thread.changed', () => this.monitors.soon());
    this.transfers = new WorkspaceTransfers({
      store, home, account,
      control: (id, action) => this.control(id, action),
      workspace: (id) => this.workspace(id),
      threadState: (id) => this.threadState(id),
      stopThread: (thread) => this.stopThread(thread),
      closePlugins: (id) => this.closeExtensions(id),
      snapshot: (workspace, label) => this.snapshot(workspace, [], label),
      setStatus: (id, status) => this.setWorkspaceStatus(id, status),
      changed: (id) => this.changed(id),
      removed: (id) => bus.emit({ type: 'workspace.changed', workspaceId: id, status: 'archived' }),
      environment: (projectId) => this.environment(projectId),
      ensureCheckout: (projectId) => this.ensureCheckout(projectId),
      freeze: (id) => this.freeze(id),
      beforeHandover: (id) => this.isLineWorkspace(id) ? this.saveLineScene(id) : Promise.resolve(),
    });
    this.configuration = new InstanceConfiguration(this, {
      run: (workspaceId, action) => this.control(workspaceId, action),
      context: (id) => this.context(id), openThread: (id) => this.openThread(id),
      runtime: (thread) => this.runnerForManagement(thread),
      switchRuntime: (id, agent, commit) => this.switchRuntime(id, agent, commit),
      changed: (workspaceId) => this.changed(workspaceId),
    });
    this.instances = new InstanceLifecycle(this, {
      run: (workspaceId, action) => this.control(workspaceId, action),
      changed: (workspaceId) => this.changed(workspaceId),
      revokeGrants: (instance) => this.configuration.revokeInstanceGrants(instance),
    });
    this.tokenCounts = new TokenCounter({ apiKeys: async () => this.account.linked ? this.account.apiKeys() : [] });
    this.voice = new VoiceSessions({
      keys: async () => this.account.linked ? this.account.speechKeys() : [],
      template: () => this.contextTemplates.get(voiceTemplate.id, voiceTemplate.scene),
      history: (id) => this.history(id),
    });
    if (options.lightTasks !== false && process.env.KITE_LIGHT_TASKS !== '0') {
      const light = options.lightTasks;
      this.lightTasks = new LightTasks({
        model: light?.model ?? (({ id, model }) => new ChatGPTModel({
          model: model.model, reasoning: model.reasoning, threadId: id,
          credentials: () => readSubscriptionCredentials(join(home, 'auth', 'chatgpt', 'auth.json')),
          observeLimits: (headers) => this.modelAccounts.observeChatGPT(headers),
        })),
        timeoutMs: light?.timeoutMs,
        onResult: light?.onResult ?? (({ usage, ...result }) => console.info('[轻任务]', JSON.stringify({
          ...result, ...(usage ? { usage: { inputTokens: usage.input_tokens, outputTokens: usage.output_tokens,
            totalTokens: usage.total_tokens } } : {}),
        }))),
      });
      this.titles = new ThreadTitles(store, this.lightTasks, this.contextTemplates, {
        history: (id) => this.history(id), changed: (thread) => this.threadChanged(thread),
      });
    }
    this.emblems = new TemplateEmblems(store, this.roles, this.contextTemplates, this.lightTasks,
      () => bus.emit({ type: 'roles.changed' }), (id, emblem) => this.library.publish('emblem', id, emblem));
    for (const w of store.workspaces()) if (w.status === 'preparing') store.setWorkspaceStatus(w.id, 'failed');
    this.transcripts = new TranscriptHistory(store, home, bus, this.events);
  }

  machine(): Machine { return this.store.machine; }
  /**
   * 资源库的写入先到账号服务，成功后存本机；没加入账号时报错。期望的版本按本机缓存给出，缓存里没有就是账号里也没有。
   * 改回与默认一样的内置内容从账号删掉，不留一份等于默认的副本，否则 kited 升级换了默认后它会被当成改过的内容。
   */
  async updateContextTemplate(id: string, expectedRevision: string, template: unknown) {
    const valid = this.contextTemplates.validate(id, expectedRevision, template);
    const base = this.contextTemplates.accountRevision(id);
    if (this.contextTemplates.isDefault(valid)) await this.library.remove('template', id, base);
    else await this.library.write('template', id, valid, base);
    const saved = this.contextTemplates.update(expectedRevision, valid);
    this.bus.emit({ type: 'context-templates.changed' });
    return saved;
  }
  /** 恢复默认就是保存默认内容。 */
  resetContextTemplate(id: string, expectedRevision: string) {
    return this.updateContextTemplate(id, expectedRevision, this.contextTemplates.builtin(id));
  }
  /** 角色列表带上点阵签名状态，以及角色编辑器要用的代理插件全部工具（连同界面名称与分组）、提示词变量和模型目录。 */
  roleCatalog() {
    return { roles: this.roles.list().map((role) => this.emblems.decorate(role)), tools: agentTools, toolCatalog: agentToolCatalog,
      variables: this.contextTemplates.sceneVariables('thread.create'), ...agentModelCatalog() };
  }
  async createRole(value: unknown) {
    const role = this.roles.validateNew(value);
    await this.library.write('role', role.id, role, null);
    return this.roleSaved(this.roles.create(role));
  }
  async updateRole(id: string, expectedRevision: string, value: unknown) {
    const role = this.roles.validate(id, expectedRevision, value);
    const base = this.roles.accountRevision(id);
    if (this.roles.isDefault(role)) await this.library.remove('role', id, base);
    else await this.library.write('role', id, role, base);
    return this.roleSaved(this.roles.update(expectedRevision, role));
  }
  /** 只有内置角色能恢复默认；签名照常随提示词更新，手改过的保留。 */
  resetRole(id: string, expectedRevision: string) {
    return this.updateRole(id, expectedRevision, this.roles.builtin(id));
  }
  /** 插件包先存到账号资源库，再装到本机；其他工作机用到时再下载。 */
  async installPlugin(raw: unknown) {
    const value = this.catalog.validate(raw);
    await this.library.write('plugin', value.id, value, null);
    return this.catalog.install(value);
  }
  private libraryChanged(changes: LibraryChanges) {
    if (changes.roles) this.bus.emit({ type: 'roles.changed' });
    if (changes.templates) this.bus.emit({ type: 'context-templates.changed' });
    for (const { projectId, before } of changes.constraints) this.configuration.constraintsChanged(projectId, before);
  }
  /** 角色保存后通知各端刷新，并随提示词更新点阵签名。 */
  private roleSaved(saved: RoleSnapshot) {
    this.bus.emit({ type: 'roles.changed' });
    this.emblems.roleSaved(saved);
    return this.emblems.decorate(saved);
  }
  projects(): Project[] { return this.store.projects(); }
  checkouts(projectId?: string): Checkout[] { return this.store.checkouts(projectId); }
  /** 登记任务包含锁外 clone，停机时仍要等它完成登记。 */
  registerCheckout(request: { path: string; remote?: undefined } | { remote: string; path?: string }): Promise<WorkspaceModel> {
    return this.projectOperation(() => this.checkoutManagement.register(request));
  }
  syncProjects(): Promise<void> {
    if (!this.account.linked || this.stopping) return Promise.resolve();
    return this.projectOperation(() => this.checkoutManagement.syncProjects());
  }
  checkoutSync(id: string): Promise<CheckoutSync> { return this.checkoutManagement.sync(id); }
  pushCheckout(id: string, message?: string): Promise<CheckoutSync> {
    this.assertRunning();
    return this.checkoutManagement.push(id, message);
  }
  /** 客户端读取的工作区列表；载入过的代理附活动摘要。 */
  workspaces(projectId?: string): Array<WorkspaceModel & { threads: Array<WorkspaceModel['threads'][number] & { activity?: ThreadActivity }> }> {
    return this.store.workspaceModels(projectId).map((model) => ({ ...model, threads: model.threads.map((thread) => {
      const activity = this.transcripts.activity(thread.instanceId);
      return activity ? { ...thread, activity } : thread;
    }) }));
  }
  /**
   * 这台工作机的状态汇总，供 Line 查询与 monitor 核对：未归档的工作区、其中线程的执行状态与等你回应的对象。
   * 线程状态从显示投影读，首次读取会载入历史，不启动执行。
   */
  async summary(): Promise<MachineSummary> {
    const workspaces = await Promise.all(this.store.workspaceModels().filter((model) => model.workspace.status !== 'archived').map(async (model) => ({
      id: model.workspace.id, epoch: model.workspace.epoch, status: model.workspace.status, kind: model.workspace.kind, name: model.workspace.name,
      project: { id: model.project.id, name: model.project.name },
      threads: await Promise.all(model.instances.filter((instance) => instance.status === 'open' && this.store.thread(instance.id)).map(async (instance) => {
        const state = await this.threadState(instance.id);
        const settledAt = this.transcripts.activity(instance.id)?.settledAt;
        return { id: instance.id, title: instance.title, role: (instanceRole(instance)?.id ?? null), phase: state.phase, busy: state.busy,
          waitingForResume: state.waitingForResume, ...(state.lastOutcome ? { lastOutcome: state.lastOutcome.kind } : {}),
          ...(state.lastOutcome?.kind === 'failed' ? { failure: state.lastOutcome.message } : {}),
          ...(state.recovery ? { recovery: state.recovery.message } : {}), ...(state.waiting ? { waiting: state.waiting } : {}),
          ...(settledAt !== undefined ? { settledAt } : {}), ...(this.lineWork.has(instance.id) ? { byLine: true as const } : {}) };
      })),
    })));
    return { machine: { id: this.store.machine.id, name: this.store.machine.name }, workspaces };
  }
  workspace(id: string): WorkspaceModel {
    const model = this.store.workspaceModel(id);
    if (!model) throw new KiteError(`没有这个工作区：${id}`, 404);
    return model;
  }
  private context(id: string): ThreadContext {
    const thread = this.store.threadContext(id);
    if (!thread) throw new KiteError(`没有这个线程：${id}`, 404);
    return thread;
  }
  thread(id: string): ThreadView {
    const r = this.runners.get(id);
    return { ...this.context(id), runner: r?.state ?? 'closed', busy: r?.busy ?? false };
  }
  private assertRunning(): void { if (this.stopping) throw new KiteError('kited 正在关闭', 503); }
  private openThread(id: string): ThreadContext {
    const t = this.context(id);
    if (t.status !== 'open' || t.workspace.status !== 'open') throw new KiteError('线程或工作区尚未打开，不能执行', 409);
    return t;
  }
  private changed(workspaceId: string): void {
    this.bus.emit({ type: 'workspace.changed', workspaceId, status: this.store.workspace(workspaceId)!.status });
  }
  private threadChanged(t: AgentInstance): void {
    this.bus.emit({ type: 'thread.changed', workspaceId: t.workspaceId, threadId: t.id, status: t.status });
  }
  private setWorkspaceStatus(id: string, status: WorkspaceStatus): void {
    this.store.setWorkspaceStatus(id, status);
    this.changed(id);
  }
  private serial<T>(key: string, fn: () => Promise<T>): Promise<T> {
    const next = (this.queues.get(key) ?? Promise.resolve()).then(fn, fn);
    const tail = next.catch(() => {}).finally(() => {
      // 后续任务可能已经接上队列，只移除仍由本任务占据的尾项。
      if (this.queues.get(key) === tail) this.queues.delete(key);
    });
    this.queues.set(key, tail);
    return next;
  }
  private projectOperation<T>(fn: () => Promise<T>): Promise<T> {
    this.assertRunning();
    const pending = Promise.resolve().then(fn).finally(() => this.projectOperations.delete(pending));
    this.projectOperations.add(pending);
    return pending;
  }
  /** 文件操作和线程控制共用工作区锁；模型回合不持锁，忙闲由 runtime 明确报告。 */
  private control<T>(workspace: string, fn: () => Promise<T>): Promise<T> {
    this.assertRunning();
    return this.serial(`workspace:${workspace}`, async () => { this.assertRunning(); return fn(); });
  }
  private controlThread<T>(id: string, fn: () => Promise<T>): Promise<T> {
    return this.control(this.context(id).workspaceId, fn);
  }
  private newThread(workspaceId: string, prompt: string, kind: Workspace['kind'], choice: AgentChoice, projectId?: string): AgentInstance {
    const instance = this.instances.newInstance(workspaceId, agentDefinitionId, titleOf(prompt), kind, choice, projectId);
    return { ...instance, instanceId: instance.id, runtime: instanceAgent(instance).runtime, nativeId: randomUUID() };
  }

  /** 可以先建空工作区；带首条消息时，准备完成才启动首个线程。via 是经 Line 创建：首条消息是 Line 的说明。 */
  async createWorkspace(checkoutId: string, name: string, prompt?: string, role?: RoleSelection, via?: InputVia): Promise<WorkspaceModel> {
    this.assertRunning();
    const c = this.checkoutManagement.get(checkoutId);
    if (prompt !== undefined && !prompt.trim()) throw new KiteError('第一条消息不能为空');
    const base = await this.serial(`checkout:${c.id}`, () => mainline(c));
    this.assertRunning();
    const id = randomUUID();
    const w: Workspace = { id, epoch: 1, checkoutId: c.id, name: name.trim() || (prompt ? titleOf(prompt) : '新工作区'),
      cwd: join(this.home, 'worktrees', c.projectId, id), kind: 'worktree', branch: `kite/${id}`, base,
      status: 'preparing', createdAt: Date.now() };
    const t = prompt === undefined ? undefined : this.newThread(id, prompt, w.kind, { role }, c.projectId);
    this.store.addWorkspace(w, t ? { agent: t, window: this.instances.newWindow(t) } : undefined);
    this.prepare(w, c, t && { thread: t, prompt: prompt!, via });
    this.changed(id);
    if (t) this.threadChanged(t);
    return this.workspace(id);
  }

  /** 在这台工作机为项目建工作区前的环境；项目在本机没有检出时，按账号登记表里的远程算 clone 位置。 */
  async environment(projectId: string): Promise<Environment> {
    const checkout = this.store.checkouts(projectId)[0];
    const remote = checkout ? undefined : this.store.project(projectId)?.remote ?? (await this.registeredProject(projectId)).remote;
    return readEnvironment(this.home, this.store.machine, checkout, remote);
  }
  private async registeredProject(projectId: string) {
    const project = (await this.account.projects()).find((p) => p.id === projectId);
    if (!project) throw new KiteError('账号里没有这个项目', 404);
    return project;
  }

  /** 按项目建工作区：先检查环境，不满足就不建；本机没有检出时自动 clone 到默认位置并登记，检出保留。 */
  async createProjectWorkspace(projectId: string, name: string, prompt?: string, role?: RoleSelection, via?: InputVia): Promise<WorkspaceModel> {
    this.assertRunning();
    if (prompt !== undefined && !prompt.trim()) throw new KiteError('第一条消息不能为空');
    const environment = await this.environment(projectId);
    const model = this.roles.get(role?.id ?? defaultRoleId, role?.revision).role.model.model;
    const login = environment.logins[runtimeOfModel(model) === 'claude' ? 'claude' : 'chatgpt'];
    if (login.status !== 'ready') throw new KiteError(`这台工作机不能运行所选模型：${login.message}`, 409);
    if (Math.min(environment.disk.worktrees, environment.disk.checkout) < MIN_FREE_BYTES) {
      throw new KiteError('这台工作机的磁盘剩余空间不足 1 GB', 409);
    }
    return this.createWorkspace((await this.ensureCheckout(projectId)).id, name, prompt, role, via);
  }

  /** 本机该项目的检出；没有时 clone 到默认位置并登记，检出保留。 */
  private async ensureCheckout(projectId: string): Promise<Checkout> {
    const existing = this.store.checkouts(projectId)[0];
    if (existing) return existing;
    const cloned = await this.registerCheckout({ remote: (await this.registeredProject(projectId)).url });
    if (cloned.project.id !== projectId) throw new KiteError('clone 下来的仓库登记成了另一个项目', 409);
    return cloned.checkout;
  }

  /** 准备失败的工作区重跑准备：工作树还在就只重跑 setup；不自动重跑。 */
  retrySetup(id: string): Promise<WorkspaceModel> {
    return this.control(id, async () => {
      const { workspace: w, checkout } = this.workspace(id);
      if (w.kind !== 'worktree' || w.status !== 'failed') throw new KiteError('只有准备失败的独立工作区可以重跑准备', 409);
      this.setWorkspaceStatus(id, 'preparing');
      this.prepare(w, checkout, undefined, true);
      return this.workspace(id);
    });
  }

  /**
   * 建工作树、跑 setup、存初始快照后开放；带首条消息的线程在开放后才收到它。失败或被打断时工作区为 failed。
   * 重跑时工作树若没建成，先清掉残留的登记与分支：准备失败的工作区从未开放，分支上没有用户的改动。
   */
  private prepare(w: Workspace, c: Checkout, first?: { thread: AgentInstance; prompt: string; via?: InputVia }, retry = false): void {
    const { id } = w;
    const t = first?.thread;
    const controller = new AbortController();
    this.preparations.set(id, controller);
    void this.serial(`workspace:${id}`, async () => {
      try {
        if (retry && !existsSync(w.cwd)) await removeWorktree(c.path, w.cwd, w.branch!);
        if (!existsSync(w.cwd)) await addWorktree(c.path, w.cwd, w.branch!, w.base!);
        controller.signal.throwIfAborted();
        const setup = await runSetup(c.path, w.cwd, join(this.home, 'workspaces', id, 'setup.log'), this.home, controller.signal);
        this.bus.emit({ type: 'workspace.setup', workspaceId: id, originThreadId: t?.id, exit: setup?.exit ?? null, log: setup?.tail ?? '' });
        if (setup && setup.exit !== 0) throw new KiteError(`初始化脚本退出码 ${setup.exit}`);
        await this.snapshot(w, [], '工作区开始', t?.id);
        controller.signal.throwIfAborted();
        this.setWorkspaceStatus(id, 'open');
        if (first) {
          await this.sendInput(this.context(first.thread.id), { id: randomUUID(), text: first.prompt,
            ...(first.via ? { source: 'kite' as const, via: first.via } : { source: 'human' as const }) }, () => controller.signal.throwIfAborted());
        }
      } catch (e) {
        this.bus.emit({ type: 'workspace.error', workspaceId: id, originThreadId: t?.id, message: (e as Error).message });
        this.setWorkspaceStatus(id, 'failed');
      }
    }).finally(() => this.preparations.delete(id));
  }

  /** 新会话的草稿只在 App 本地；第一条消息连同草稿里选好的参数一次创建实例、会话和窗口。
   * windowId 与 messageId 由 App 生成：窗口经事件先到时 App 认得出是草稿变成的那个，第一条消息也和草稿里显示的是同一条。 */
  createThread(workspaceId: string, prompt: string, choice: AgentChoice = {}, windowId?: string, messageId?: string): Promise<ThreadView> {
    return this.control(workspaceId, async () => {
      const { workspace } = this.workspace(workspaceId);
      if (workspace.status !== 'open') throw new KiteError('工作区尚未打开', 409);
      if (!prompt.trim()) throw new KiteError('第一条消息不能为空');
      if (windowId && this.store.window(windowId)) throw new KiteError('窗口 ID 已使用', 409);
      await this.snapshot(workspace, [], '线程开始');
      const t = this.newThread(workspaceId, prompt, workspace.kind, choice);
      this.store.addAgent(t, this.instances.newWindow(t, windowId));
      this.threadChanged(t);
      await this.sendInput(this.context(t.id), { id: messageId ?? randomUUID(), text: prompt, source: 'human' });
      return this.thread(t.id);
    });
  }

  /** 操作层只登记实例；有首条消息时才打开执行资源，窗口由 presentation 决定。 */
  startAgent(workspaceId: string, input: OperationInput<'agent.start'>, origin?: PluginInstance['origin'], check: () => void = () => {}): Promise<{ instanceId: string; windowId?: string }> {
    return this.control(workspaceId, async () => {
      check();
      const { workspace } = this.workspace(workspaceId);
      if (workspace.status !== 'open') throw new KiteError('工作区尚未打开', 409);
      if (input.prompt !== undefined) await this.snapshot(workspace, [], '线程开始');
      check();
      const instance = this.instances.newInstance(workspaceId, agentDefinitionId, input.title ?? (input.prompt ? titleOf(input.prompt) : '新代理'), workspace.kind,
        { role: { id: input.role ?? defaultRoleId } });
      instance.presentation = input.presentation;
      instance.origin = origin;
      if (origin && instanceExecutionGrants(this.store.instance(origin.instanceId)!).workspace === 'read') {
        instance.config.execution = { ...instanceExecutionGrants(instance), workspace: 'read' };
      }
      const agent: AgentInstance = { ...instance, instanceId: instance.id, runtime: instanceAgent(instance).runtime, nativeId: randomUUID() };
      const window = instance.presentation === 'window' ? this.instances.newWindow(instance) : undefined;
      this.store.addAgent(agent, window);
      if (input.title !== undefined) this.store.saveThreadTitle(agent.id, 'initial', {
        title: instance.title, mode: 'manual', generatedAt: null, through: null,
      });
      this.threadChanged(agent);
      this.changed(workspaceId);
      if (input.prompt !== undefined) await this.sendInput(this.context(agent.id), {
        id: input.operationId, text: input.prompt, source: origin ? 'kite' : 'human',
      });
      return { instanceId: instance.id, ...(window ? { windowId: window.id } : {}) };
    });
  }

  selectFile(input: OperationInput<'files.select'>, check: () => void) {
    const instance = this.store.instance(input.instanceId)!;
    return this.control(instance.workspaceId, async () => {
      check();
      const current = this.store.instance(instance.id)!;
      const { workspace } = this.workspace(current.workspaceId);
      if (workspace.status !== 'open') throw new KiteError('工作区尚未打开', 409);
      if (fileSelection(current.state).revision !== input.expectedRevision) throw new KiteError('所选文件已变化，请刷新后重试', 409);
      let path: string | null = null;
      if (input.path !== null) {
        try {
          const files = new WorkspaceFiles(workspace.cwd);
          const target = files.resolve(input.path);
          path = relative(files.root, target);
          if (input.diffId) {
            const diff = new FileDiffStore(join(this.home, 'diffs', workspace.id)).read(input.diffId);
            if (!diff.files.some((file) => file.path === path)) throw new KiteError('这份差异中没有指定文件', 404);
          } else files.text(target);
        }
        catch (error) {
          if (error instanceof KiteError) throw error;
          throw new KiteError(`无法选择文件：${error instanceof Error ? error.message : String(error)}`);
        }
      }
      const state = { path, revision: randomUUID(), ...(path && input.diffId ? { diffId: input.diffId } : {}) };
      this.store.setInstanceState(current.id, state);
      this.changed(current.workspaceId);
      return state;
    });
  }

  configureOperationGrants(id: string, expectedRevision: string, value: unknown) {
    return this.configuration.configureOperationGrants(id, expectedRevision, value);
  }
  executionGrants(id: string) { return this.configuration.executionGrants(id); }
  approvalMode(id: string) { return this.configuration.approvalMode(id); }
  configureApprovalMode(id: string, value: unknown) { return this.configuration.configureApprovalMode(id, value); }
  configureExecutionGrants(id: string, expectedRevision: string, value: unknown) {
    return this.configuration.configureExecutionGrants(id, expectedRevision, value);
  }

  async openWindow(workspaceId: string, request: OpenWindowRequest): Promise<WorkspaceWindow> {
    if (request.content.kind === 'create') await this.library.ensurePlugin(request.content.definitionId);
    return this.instances.openWindow(workspaceId, request);
  }

  async createPluginInstance(workspaceId: string, id: string, definitionId: string, title?: string) {
    await this.library.ensurePlugin(definitionId);
    return this.instances.createPluginInstance(workspaceId, id, definitionId, title);
  }

  closeWindow(workspaceId: string, id: string): Promise<void> {
    return this.instances.closeWindow(workspaceId, id);
  }

  agentConfig(id: string) { return this.configuration.agentConfig(id); }
  agentCapabilities(id: string) { return this.configuration.agentCapabilities(id); }
  agentOptions(workspaceId: string) { return this.configuration.agentOptions(workspaceId); }
  configureAgent(id: string, expectedRevision: string, value: unknown) {
    return this.configuration.configureAgent(id, expectedRevision, value);
  }
  configureRole(id: string, expectedRevision: string, role: RoleSelection) {
    return this.configuration.configureRole(id, expectedRevision, role);
  }

  threadTitle(id: string) {
    this.context(id);
    return this.store.threadTitle(id)!;
  }
  async regenerateThreadTitle(id: string, expectedRevision: string) {
    const { completion } = await this.controlThread(id, async () => {
      const thread = this.openThread(id);
      if (!this.titles) throw new KiteError('这台工作机未启用轻任务', 503);
      const current = this.store.threadTitle(id)!;
      // 推进版本使更早的在途结果失效；失败时仍保留原题、模式和生成进度。
      if (!this.store.saveThreadTitle(id, expectedRevision, current)) throw new KiteError('标题已变化，请刷新后重试', 409);
      this.threadChanged(thread);
      return { completion: this.titles.regenerate(id) };
    });
    // 模型请求不占用工作区控制锁，用户仍可继续主会话。
    await completion;
    return this.threadTitle(id);
  }
  configureThreadTitle(id: string, expectedRevision: string, input: { mode: 'auto' } | { mode: 'manual'; title: string }) {
    return this.controlThread(id, async () => {
      const thread = this.openThread(id);
      const current = this.store.threadTitle(id)!;
      const title = input.mode === 'manual' ? input.title.trim() : current.title;
      if (!title || title.length > 80 || /[\r\n]/.test(title)) throw new KiteError('标题须为 1～80 字符的单行文本');
      if (!this.store.saveThreadTitle(id, expectedRevision, { title, mode: input.mode, generatedAt: null, through: null })) {
        throw new KiteError('标题已变化，请刷新后重试', 409);
      }
      this.threadChanged(thread);
      if (input.mode === 'auto') void this.titles?.refresh(id);
      return this.store.threadTitle(id)!;
    });
  }
  async history(id: string): Promise<History> { return (await this.transcripts.load(this.context(id))).snapshot(); }
  async threadState(id: string): Promise<DisplayState> { return (await this.transcripts.load(this.context(id))).state(); }
  historyNow(id: string): History { return this.transcripts.snapshot(id); }
  /** 线程最后一回合的回复：最后一条输入之后的正文，供 Line 读取；太长时保留结尾。 */
  async reply(id: string) {
    const state = await this.threadState(id);
    const records = this.transcripts.snapshot(id).records;
    const texts: string[] = [];
    let at: number | undefined;
    for (let index = records.length - 1; index >= 0; index--) {
      const record = records[index]!;
      if (record.id.startsWith('input:')) break;
      if (record.block.type === 'text' && record.block.text.trim()) { texts.unshift(record.block.text); at ??= record.at; }
    }
    const text = texts.join('\n\n');
    return { threadId: id, phase: state.phase, busy: state.busy, ...(state.lastOutcome ? { lastOutcome: state.lastOutcome } : {}),
      ...(state.waiting ? { waiting: state.waiting } : {}),
      ...(text ? { reply: { text: text.length > 20_000 ? `…${text.slice(-20_000)}` : text, at } } : {}) };
  }
  /** Line 线程里用户的一条消息：给了输入 ID 就取那条，否则取最近的一条；不是用户的消息时没有。 */
  private async userMessage(lineId: string, inputId?: string): Promise<{ id: string; text: string } | undefined> {
    const records = (await this.history(lineId)).records;
    const record = inputId === undefined ? records.findLast((entry) => entry.block.type === 'human')
      : records.find((entry) => entry.id === `input:${inputId}`);
    return record?.block.type === 'human' ? { id: record.block.id, text: record.block.text } : undefined;
  }
  /**
   * 调用方持有工作区控制锁，发送与切换不能同时通过状态检查。先把上下文追加到目标后端的原生记录再保存后端；
   * 保存失败后重试只会导入尚未导入的部分。
   */
  private async switchRuntime(id: string, agent: AgentDefinition, commit: () => void): Promise<void> {
    if (!(await this.threadState(id)).capabilities.switchRuntime) {
      throw new KiteError('请先停止会话、处理排队消息并确认执行结果，再切换后端', 409);
    }
    const runner = await this.runnerForManagement(this.context(id));
    if (runner?.busy || runner?.recovery) throw new KiteError('请先停止会话并确认执行结果，再切换后端', 409);
    await runner?.shutdown();
    this.runners.delete(id);
    try { await handOff({ home: this.home, thread: this.context(id), to: agent.runtime, model: agent.model.model }); }
    catch (error) { throw new KiteError(`上下文翻译失败，后端未切换：${(error as Error).message}`, 409); }
    commit();
    await this.transcripts.reset(this.context(id));
  }
  private runner(t: ThreadContext): Promise<Runtime> {
    const existing = this.runners.get(t.id);
    if (existing) return Promise.resolve(existing);
    // 同一线程只打开一个 runtime；并发的打开请求共用同一次初始化，不依赖调用方持有工作区锁。
    let opening = this.openingRunners.get(t.id);
    if (!opening) {
      opening = this.openRunner(t).finally(() => this.openingRunners.delete(t.id));
      this.openingRunners.set(t.id, opening);
    }
    return opening;
  }
  private async openRunner(t: ThreadContext): Promise<Runtime> {
    const { id, workspaceId, workspace, title } = t;
    await this.transcripts.load(t);
    const r = await openRuntime(t, {
      home: this.home, account: this.account, repository: t.checkout.path, options: this.options,
      chatgptLimits: (headers) => this.modelAccounts.observeChatGPT(headers),
      events: {
        emit: (event) => {
          if (event.type === 'sdk' && event.message.type === 'rate_limit_event') this.modelAccounts.observeClaude(event.message.rate_limit_info);
          this.bus.emit({ ...event, threadId: id });
        },
        label: (text) => this.turnLabels.set(id, firstLine(text)),
        snapshot: (ids) => this.snapshot(workspace, ids, this.turnLabels.get(id) ?? title, id),
        idle: (completed) => {
          this.bus.emit({ type: 'idle', threadId: id, completed });
          if (completed && !this.stopping) {
            if (this.adoptAfterTurn.delete(id)) {
              this.adopt(workspaceId, id, true).catch((e) => this.bus.emit({ type: 'workspace.error', workspaceId, originThreadId: id, message: `自动采纳失败：${(e as Error).message}` }));
            }
            if (instanceRole(this.context(id))?.id === lineRoleId) void this.saveLineScene(workspaceId);
          }
        },
      },
      current: () => this.context(id),
      notifications: (after) => this.store.instanceNotifications(id, after),
      // Line 的管理工具只声明给 Line 角色的实例，免得每个代理的请求都带着它们的说明。
      operations: { tools: [...this.operations.tools(id), this.waits.question(id),
        ...(instanceRole(t)?.id === lineRoleId ? lineTools({ store: this.store, peers: this.peers, machine: this.store.machine.id, instanceId: id,
          monitor: this.monitor, message: (inputId) => this.userMessage(id, inputId),
          approve: (request, signal) => this.waits.approve(id, request, signal) }) : [])],
      prepare: (instance) => this.operations.prepareTools(instance) },
      contextUpdateTemplate: () => this.contextTemplates.get(contextUpdateContextDefinition.id, contextUpdateContextDefinition.scene).definition,
      compactionTemplates: () => ({
        compact: this.contextTemplates.get(compactTemplate.id, compactTemplate.scene).definition,
        fileChanges: this.contextTemplates.get(fileChangesContextDefinition.id, fileChangesContextDefinition.scene).definition,
      }),
      compactionFiles: ({ from, to }) => changesBetween(workspace.cwd, workspaceId, from, to),
      toolConstraint: () => this.store.projectConstraints(t.project.id)?.tools,
      network: () => instanceApprovalMode(this.context(id)) === 'allowlist' ? undefined : (target, signal) => this.askNetwork(id, target, signal),
    });
    this.runners.set(id, r);
    return r;
  }
  /**
   * 命令要连接执行授权之外的主机：按实例此刻的审批模式放行、拒绝或在线程上问人；「允许并记住」把它加进网络许可，
   * 记不住（如线程已归档）也放行这一次。
   */
  private async askNetwork(id: string, target: { host: string; port?: number }, signal: AbortSignal): Promise<boolean> {
    const mode = instanceApprovalMode(this.context(id));
    if (mode !== 'ask') return mode === 'allow_all';
    const host = target.host.includes(':') ? `[${target.host}]` : target.host;
    const domain = target.port === undefined ? host : `${host}:${target.port}`;
    const decision = await this.waits.approve(id, { tool: 'shell', target: domain, reason: '命令要连接网络许可之外的主机', mustAsk: false }, signal);
    if (decision === 'remember') {
      await this.configuration.rememberNetwork(id, domain).catch((error) => console.error(`[审批] 记住网络许可失败：${(error as Error).message}`));
    }
    return decision === 'once' || decision === 'remember';
  }
  /** 恢复检查只打开 journal，不执行旧输入。 */
  private async runnerForManagement(t: AgentInstance): Promise<Runtime | undefined> {
    return this.runners.get(t.id) ?? (t.status === 'open' && existsSync(join(this.home, 'sessions', t.id))
      ? await this.runner(this.context(t.id)) : undefined);
  }
  /** 动整个工作区的操作（回退、采纳）要求全员空闲；线程之间的启动、发送与继续默认并行，见 docs/工作区并行.md。 */
  private async assertIdle(workspaceId: string): Promise<void> {
    for (const t of this.store.threads(workspaceId)) {
      if (t.status === 'archived') continue;
      const r = await this.runnerForManagement(t);
      if (r?.busy || r?.recovery) throw new KiteError('工作区有线程正在工作或等待恢复确认', 409);
    }
  }
  send(id: string, text: string, inputId: string = randomUUID(), source: Input['source'] = 'human', check: () => void = () => {},
    via?: Input['via']): Promise<{ id: string }> {
    if (!text.trim()) throw new KiteError('消息不能为空');
    if (!inputId) throw new KiteError('消息 id 不能为空');
    return this.controlThread(id, async () => {
      check();
      const t = this.openThread(id);
      await this.sendInput(t, { id: inputId, text, source, ...(via ? { via } : {}) }, check);
      return { id: inputId };
    });
  }
  private async sendInput(thread: ThreadContext, input: Input, check: () => void = () => {}): Promise<void> {
    const runner = await this.runner(thread);
    check();
    await runner.send(input);
    // Line 自己的说明让这一回合成为 Line 的工作；用户的消息（含经 Line 转达的原文）收回给用户。
    if (input.via && input.source === 'kite') this.lineWork.add(thread.id);
    else if (input.source === 'human') this.lineWork.delete(thread.id);
    // 还没有标题记录（没起过名、没手动改过）时，用第一条消息作标题
    if (this.store.threadTitle(thread.id)?.revision === 'initial') {
      this.store.renameInstance(thread.id, titleOf(input.text));
      this.threadChanged(thread);
    }
    // 输入受理后即与主会话并行，标题材料包含尚未交给主模型的排队消息。
    void this.titles?.refresh(thread.id);
  }
  cancel(id: string, inputId: string): Promise<void> {
    return this.controlThread(id, async () => {
      const r = await this.runner(this.openThread(id));
      if (!r.cancel) throw new KiteError('这个后端不支持撤回排队消息', 409);
      await r.cancel(inputId);
    });
  }
  async interrupt(id: string, request?: StopRequest, check: () => void = () => {}): Promise<{ returned: Input[] }> {
    // 只在锁内冻结队列；停止工具与收尾期间仍允许其他控制请求得到明确拒绝。
    const { completion } = await this.controlThread(id, async () => {
      check();
      this.preparations.get(this.context(id).workspaceId)?.abort();
      const r = await this.runner(this.context(id));
      check();
      this.adoptAfterTurn.delete(id);
      return { completion: r.interrupt(request) };
    });
    return { returned: await completion };
  }
  resume(id: string, check: () => void = () => {}): Promise<void> {
    return this.controlThread(id, async () => {
      check();
      const t = this.openThread(id);
      const r = await this.runner(t);
      check();
      if (!r.resume) throw new KiteError('这个后端通过发消息继续', 409);
      await r.resume();
    });
  }
  /** 压缩不改文件，不要求同一工作区的其他线程空闲；模型请求在锁外进行，结果经显示事件送达。 */
  compact(id: string, request: CompactionRequest): Promise<void> {
    return this.controlThread(id, async () => {
      const r = await this.runner(this.openThread(id));
      if (!r.compact) throw new KiteError('这个后端暂不支持压缩上下文', 409);
      try { await r.compact(request); }
      catch (error) { throw new KiteError((error as Error).message, 409); }
    });
  }
  revertCompaction(id: string, compactionId: string): Promise<void> {
    return this.controlThread(id, async () => {
      const r = await this.runner(this.openThread(id));
      if (!r.revertCompaction) throw new KiteError('这个后端暂不支持压缩上下文', 409);
      try { await r.revertCompaction(compactionId); }
      catch (error) { throw new KiteError((error as Error).message, 409); }
    });
  }
  recover(id: string): Promise<void> {
    return this.controlThread(id, async () => {
      const r = await this.runner(this.openThread(id));
      if (!r.recover) throw new KiteError('这个后端不支持恢复确认', 409);
      await r.recover();
    });
  }

  private snapshot(w: Workspace, toolUseIds: string[], label: string, threadId?: string): Promise<void> {
    return this.serial(`snap:${w.id}`, async () => {
      const r = await capture(w.cwd, w.id, label, toolUseIds, threadId);
      if (r.created) this.bus.emit({ type: 'workspace.snapshot', workspaceId: w.id, originThreadId: threadId, commit: r.commit, changedFiles: r.changedFiles, label });
    });
  }
  snapshots(id: string): Promise<Snapshot[]> { const m = this.workspace(id); return list(m.checkout.path, id); }
  restore(id: string, commit: string): Promise<void> {
    return this.control(id, async () => {
      const { workspace: w, checkout } = this.workspace(id);
      if (w.status !== 'open') throw new KiteError('工作区尚未打开', 409);
      await this.assertIdle(id);
      const full = await findSnapshot(checkout.path, id, commit);
      if (!full) throw new KiteError('找不到这个工作区的快照', 404);
      await this.serial(`snap:${id}`, async () => {
        const { safety, current, label } = await restore(w.cwd, id, full);
        for (const [snapshot, title] of [[safety, '回退前自动保存'], [current, label]] as const) {
          if (snapshot.created) this.bus.emit({ type: 'workspace.snapshot', workspaceId: id,
            commit: snapshot.commit, label: title, changedFiles: snapshot.changedFiles });
        }
      });
      this.changed(id);
    });
  }
  /** afterResolution：线程处理冲突的回合已正常结束，由宿主提交其结果；这次仍失败不再转交，避免往复。 */
  adopt(id: string, originThreadId?: string, afterResolution = false): Promise<AdoptResult> {
    return this.control(id, async () => {
      const { workspace: w, checkout } = this.workspace(id);
      const threads = this.store.threads(id);
      if (w.kind === 'root' || w.status !== 'open') throw new KiteError('只能采纳已打开的独立工作区', 409);
      await this.assertIdle(id);
      const result = await this.serial(`checkout:${checkout.id}`, async (): Promise<AdoptResult> => {
        if (await isDirty(checkout.path)) throw new KiteError('检出现场有未提交的改动，先在现场提交或清理后再集成', 409);
        const branch = await currentBranch(checkout.path);
        if (!branch) throw new KiteError('检出现场不在任何分支上，先切回主线分支再集成', 409);
        // 拿不到远程时照常合回本地主线，结果里报告推送失败。
        let access: RemoteAccess | undefined;
        let offline: string | undefined;
        try { access = await originAccess(checkout.path, this.account); }
        catch (error) { offline = (error as Error).message; }
        // 推送被拒说明远程刚有新提交：重新拉取、合并后再推，冲突同样留在工作区。
        for (let attempt = 1; ; attempt++) {
          let upstream: string | null = null;
          // 用跟踪分支名合并，合并提交的说明里写的是 origin/<分支> 而不是一串哈希。
          if (access) {
            try { if (await fetchBranch(checkout.path, branch, access)) upstream = `origin/${branch}`; }
            catch (error) { offline = (error as Error).message; }
          }
          const r = await mergeBack(checkout, w.cwd, w.name, { stageResolved: afterResolution, upstream });
          if (r.status === 'conflict') {
            const t = threads.findLast((t) => t.status === 'open');
            // 手动重试遗留冲突同样转交，处理回合被打断后仍能继续。
            if (!afterResolution && t) {
              this.adoptAfterTurn.add(t.id);
              await this.sendInput(this.context(t.id), { id: randomUUID(), text: conflictPrompt(w.branch!, r.files), source: 'kite' });
            }
            return { status: 'conflict', files: r.files };
          }
          const adopted = (push: PushOutcome): AdoptResult => ({ status: 'adopted', commit: r.commit, push });
          const failed = (message: string) => adopted({ status: 'failed', message });
          if (!access || offline) return failed(offline ?? '无法访问远程');
          try { if (await pushBranch(checkout.path, branch, access) === 'pushed') return adopted({ status: 'pushed' }); }
          catch (error) { return failed((error as Error).message); }
          if (attempt === PUSH_ATTEMPTS) return failed('远程持续有新的提交，推送多次被拒，请稍后再集成');
        }
      });
      this.bus.emit({ type: 'workspace.adopt', workspaceId: id, originThreadId, result });
      return result;
    });
  }
  private async stopThread(t: AgentInstance): Promise<void> {
    const r = await this.runnerForManagement(t);
    this.adoptAfterTurn.delete(t.id);
    if (r) { await r.shutdown(); this.runners.delete(t.id); }
    this.turnLabels.delete(t.id);
  }
  /** 归档保留会话与业务数据，停止执行并关闭它的窗口；随窗口回收的实例关闭窗口即可。 */
  archiveInstance(id: string): Promise<void> {
    const instance = this.store.instance(id);
    if (!instance) throw new KiteError(`没有这个实例：${id}`, 404);
    const definition = this.catalog.get(instance.definitionId);
    if (definition.agent) return this.archiveThread(id);
    if (definition.id === monitorDefinitionId && 'system' in monitorConfig(instance)) throw new KiteError('Line 的收件箱随 Line 存在，不能单独归档', 409);
    if (definition.lifetime === 'window') throw new KiteError('此实例随窗口回收，关闭窗口即可');
    return this.control(instance.workspaceId, async () => {
      if (this.store.instance(id)!.status === 'archived') return;
      const release = await this.plugins.closeInstance(id);
      try { this.store.archiveInstance(id); } finally { release(); }
      this.changed(instance.workspaceId);
    });
  }
  private archiveThread(id: string): Promise<void> {
    const t = this.context(id);
    this.preparations.get(t.workspaceId)?.abort();
    return this.control(t.workspaceId, async () => {
      const current = this.context(id);
      if (current.status === 'archived') return;
      await this.stopThread(current);
      this.store.archiveInstance(id);
      this.threadChanged({ ...current, status: 'archived' });
    });
  }
  archiveWorkspace(id: string, force = false): Promise<void> {
    const model = this.workspace(id);
    if (model.workspace.kind === 'root') throw new KiteError('根工作区属于检出，不能按独立工作树归档', 409);
    this.preparations.get(id)?.abort();
    return this.control(id, async () => {
      const { workspace: w, checkout } = this.workspace(id);
      const threads = this.store.threads(id);
      if (w.status === 'archived') return;
      // 先检查再停止，拒绝归档时不打断正在工作的线程；停止期间写入的改动再检查一次。
      const assertMerged = async () => {
        if (!force && await hasUnmerged(checkout.path, w.cwd)) throw new KiteError('工作区有没合回主线的改动；确定丢弃就加 force', 409);
      };
      await assertMerged();
      for (const t of threads) if (t.status !== 'archived') await this.stopThread(t);
      await assertMerged();
      if (existsSync(w.cwd)) await this.snapshot(w, [], '归档前保存');
      const releasePlugins = await this.closeExtensions(id);
      try {
        await removeWorktree(checkout.path, w.cwd, w.branch!);
        this.store.archiveWorkspace(id);
      } finally { releasePlugins(); }
      for (const t of threads) if (t.status !== 'archived') this.threadChanged({ ...t, status: 'archived' });
      this.changed(id);
    });
  }
  /** 服务起来后由 daemon 告知本机监听地址与组网，Line 据此调用本机与别的工作机。 */
  listening(serving: { url: string; network?: Network }): void { this.serving = serving; }

  /** 本机上的 Line 实例（未归档、在打开的工作区里）。账号下只有一个 Line，多个 Line 不在当前范围。 */
  lineInstance(): AgentInstance | undefined {
    return this.store.threads().find((thread) => thread.status === 'open' && instanceRole(thread)?.id === lineRoleId
      && this.store.workspace(thread.workspaceId)?.status === 'open');
  }
  /** Line 的 monitor 实例（收件箱）；ensure 时没有就补建一个，带窗口。 */
  lineInbox(ensure = false): PluginInstance | undefined {
    const line = this.lineInstance();
    if (!line) return undefined;
    const found = this.store.instances(line.workspaceId).find((instance) => instance.definitionId === monitorDefinitionId
      && instance.status === 'open' && 'system' in monitorConfig(instance));
    if (found || !ensure) return found;
    const inbox = this.newLineInbox(line);
    this.store.addPluginInstance(inbox, this.instances.newWindow(inbox));
    this.changed(line.workspaceId);
    return inbox;
  }
  private newLineInbox(line: Pick<AgentInstance, 'id' | 'workspaceId'>): PluginInstance {
    return { id: randomUUID(), workspaceId: line.workspaceId, definitionId: monitorDefinitionId, title: '收件箱',
      config: { monitor: { target: line.id, system: 'line' } }, state: {}, presentation: 'window', status: 'open', createdAt: Date.now() };
  }
  /** 工作区交接、冻结或归档前停下插件进程与 monitor 的来源；monitor 的来源不算结束，工作区再开放时重新开始。 */
  private async closeExtensions(workspaceId: string): Promise<() => void> {
    await this.monitors.closeWorkspace(workspaceId);
    return this.plugins.closeWorkspace(workspaceId);
  }
  private isLineWorkspace(workspaceId: string): boolean {
    return this.store.threads(workspaceId).some((thread) => thread.status === 'open' && instanceRole(thread)?.id === lineRoleId);
  }

  /**
   * 启用 Line：在这台工作机建一个 Kite 托管项目（放在 ~/code/kite-line），以它的根工作区承载 Line 代理，
   * 带上账号范围的 line 授权。本机已有 Line 时返回它所在的工作区。
   */
  async enableLine(): Promise<WorkspaceModel> {
    const existing = this.lineInstance();
    if (existing) return this.workspace(existing.workspaceId);
    const folder = join(userHome(), 'code', 'kite-line');
    const registered = this.store.checkouts().find((checkout) => checkout.path === folder);
    if (!registered) {
      if (existsSync(folder) && readdirSync(folder).length) throw new KiteError(`${folder} 已有内容，请移走后再启用 Line`, 409);
      mkdirSync(join(folder, '.kite', 'memory'), { recursive: true });
      writeFileSync(join(folder, 'AGENTS.md'), LINE_AGENTS);
      writeFileSync(join(folder, '.kite', 'memory', 'MEMORY.md'), '');
    }
    const model = registered ? this.store.rootWorkspaceModel(registered.id)! : await this.registerCheckout({ path: folder });
    return this.control(model.workspace.id, async () => {
      const instance = this.instances.newInstance(model.workspace.id, agentDefinitionId, 'Line', 'root', { role: { id: lineRoleId } }, model.project.id);
      instance.config.grants = [...(instance.config.grants as OperationGrant[]), lineGrant];
      const agent: AgentInstance = { ...instance, instanceId: instance.id, runtime: instanceAgent(instance).runtime, nativeId: randomUUID() };
      this.store.addAgent(agent, this.instances.newWindow(agent));
      const inbox = this.newLineInbox(agent);
      this.store.addPluginInstance(inbox, this.instances.newWindow(inbox));
      this.store.saveThreadTitle(agent.id, 'initial', { title: 'Line', mode: 'manual', generatedAt: null, through: null });
      this.threadChanged(agent);
      this.changed(model.workspace.id);
      return this.workspace(model.workspace.id);
    });
  }

  /**
   * Line 的根工作区由宿主在回合结束与交接前提交并推送现场：这是「根工作区不自动提交」的例外，只适用于 Line 的项目。
   * 失败只记日志，下次再推。
   */
  private async saveLineScene(workspaceId: string): Promise<void> {
    const { workspace: w, checkout } = this.workspace(workspaceId);
    if (w.kind !== 'root' || (w.status !== 'open' && w.status !== 'handing_off')) return;
    try {
      await this.serial(`checkout:${checkout.id}`, async () => {
        if (await isDirty(checkout.path)) await commitAll(checkout.path, ['-m', 'Line：保存记忆与待办']);
        const branch = await currentBranch(checkout.path);
        if (!branch) return;
        if (await pushBranch(checkout.path, branch, await originAccess(checkout.path, this.account)) === 'rejected') {
          throw new KiteError('远程有新的提交，Line 的现场没有推上去');
        }
      });
    } catch (error) { console.error(`[Line] 保存现场失败：${(error as Error).message}`); }
  }

  /**
   * 联网后核对本机持有的工作区：远程 lease 的 epoch 更高且机器不是自己，本地记录冻结。从未流转过的没有 lease；
   * 查不到远程时按仍持有继续，所以接管默认要求源机先进入可交接状态。
   */
  syncLeases(): Promise<void> {
    // 远程不通时一轮可能很久，上一轮没完就不叠加新的一轮。
    this.leaseSync ??= this.checkLeases().finally(() => { this.leaseSync = undefined; });
    return this.leaseSync;
  }
  private async checkLeases(): Promise<void> {
    if (this.stopping) return;
    const held = this.store.workspaces().filter((w) => w.status !== 'transferred' && w.status !== 'archived');
    for (const checkout of this.store.checkouts()) {
      const local = held.filter((w) => w.checkoutId === checkout.id);
      if (!local.length || !existsSync(checkout.path)) continue;
      let leases: Map<string, string>;
      let access: RemoteAccess;
      try {
        access = await originAccess(checkout.path, this.account);
        leases = await remoteLeases(checkout.path, access);
      } catch { continue; }
      for (const w of local) {
        const commit = leases.get(w.id);
        if (!commit) continue;
        try {
          const lease = await readLease(checkout.path, w.id, commit, access);
          if (lease.machine !== this.store.machine.id && lease.epoch > w.epoch) await this.freeze(w.id);
        } catch (error) { console.error(`[执行权] 核对工作区 ${w.id} 失败：${(error as Error).message}`); }
      }
    }
  }

  /** 执行权已在别的机器：停下本地线程与插件，本机多出的改动存成快照留给人合并，记录冻结；根工作区给检出另建一个。 */
  private freeze(id: string): Promise<void> {
    this.preparations.get(id)?.abort();
    return this.control(id, async () => {
      const { workspace: w, checkout } = this.workspace(id);
      if (w.status === 'transferred' || w.status === 'archived') return;
      for (const t of this.store.threads(id)) if (t.status !== 'archived') await this.stopThread(t);
      if (existsSync(w.cwd)) await this.snapshot(w, [], '流转后本机留下的改动');
      const release = await this.closeExtensions(id);
      const root: Workspace | undefined = w.kind === 'root' ? { id: randomUUID(), epoch: 1, checkoutId: checkout.id, name: w.name,
        cwd: w.cwd, kind: 'root', branch: null, base: null, status: 'open', createdAt: Date.now() } : undefined;
      try { this.store.freezeWorkspace(id, root); } finally { release(); }
      this.changed(id);
      if (root) this.changed(root.id);
    });
  }

  async shutdown(): Promise<void> {
    this.stopping = true;
    await Promise.all([this.titles?.close(), this.emblems.close(), this.lightTasks?.close(), this.subscriptionLogins.close(), this.library.close()]);
    await this.monitor.stop();
    await this.monitors.close();
    await this.plugins.close();
    await this.operations.close();
    for (const c of this.preparations.values()) c.abort();
    await Promise.allSettled(this.projectOperations);
    await Promise.allSettled([...this.queues.values(), ...this.openingRunners.values()]);
    await Promise.all([...this.runners.values()].map((r) => r.shutdown()));
  }
}
