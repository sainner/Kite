/** 工作区负责文件、快照和采纳；线程负责模型执行及独立的对话记录。 */
import type { Input, StopRequest } from './harness/types.ts';
import { randomUUID } from 'node:crypto';
import { existsSync } from 'node:fs';
import { FileDiffStore } from './workspace/file-diffs.ts';
import { join, relative } from 'node:path';
import { KiteError } from './errors.ts';
import { type AdoptResult, Bus, type PushOutcome } from './events.ts';
import { hasUnmerged, mainline, mergeBack } from './workspace/mainline.ts';
import { cloneRemote, cloneTarget, register } from './workspace/projects.ts';
import { AccountClient } from './account-client.ts';
import { normalizeRemote } from './remote-url.ts';
import { commitAll, git, isAncestor, isDirty } from './workspace/git.ts';
import { checkoutSync, currentBranch, fetchBranch, originAccess, originURL, pushBranch, type CheckoutSync, type RemoteAccess } from './workspace/remote.ts';
import { openRuntime, type Runtime, type RuntimeOptions } from './runtime.ts';
import { capture, findSnapshot, list, restore, type Snapshot } from './workspace/snapshots.ts';
import type { Store } from './store.ts';
import type { AgentInstance, Checkout, Machine, OpenWindowRequest, PluginInstance, Project, RuntimeKind, ThreadContext, Workspace, WorkspaceModel, WorkspaceStatus, WorkspaceWindow } from './model.ts';
import { PluginCatalog } from './plugins/catalog.ts';
import { PluginHost } from './plugins/host.ts';
import { InstanceConfiguration } from './instance-configuration.ts';
import { InstanceLifecycle } from './instance-lifecycle.ts';
import { ContextTemplates, type ContextTemplateSelection } from './context-templates.ts';
import { addWorktree, removeWorktree, runSetup } from './workspace/worktrees.ts';
import {
  agentConfigurationContextDefinition, contextUpdateContextDefinition, executionPermissionsContextDefinition, pluginToolsContextDefinition,
} from './harness/context/notifications.ts';
import { instanceExecutionGrants } from './execution/grants.ts';
import { InstanceOperations } from './operations/operations.ts';
import { OperationReceipts } from './operations/receipts.ts';
import type { OperationInput } from './operations/contract.ts';
import { WorkspaceFiles, fileSelection } from './workspace/files.ts';
import { TranscriptFeed } from './transcript/feed.ts';
import { TranscriptHistory } from './transcript/history.ts';
import type { DisplayState, History } from './transcript/protocol.ts';
import { LightTasks } from './light-tasks.ts';
import { ThreadTitles, titleTemplate } from './thread-titles.ts';
import { ChatGPTModel } from './harness/chatgpt.ts';
import { readSubscriptionCredentials } from './harness/auth.ts';
import { agentModels } from './agents/models.ts';

export interface ThreadView extends ThreadContext { runner: Runtime['state']; busy: boolean }
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
  readonly operations: InstanceOperations;
  readonly receipts: OperationReceipts;
  readonly catalog: PluginCatalog;
  readonly contextTemplates: ContextTemplates;
  readonly plugins: PluginHost;
  readonly lightTasks?: LightTasks;
  readonly titles?: ThreadTitles;
  private readonly transcripts: TranscriptHistory;
  private readonly configuration: InstanceConfiguration;
  private readonly instances: InstanceLifecycle;
  private runners = new Map<string, Runtime>();
  private openingRunners = new Map<string, Promise<Runtime>>();
  private queues = new Map<string, Promise<unknown>>();
  private preparations = new Map<string, AbortController>();
  private stopping = false;
  private turnLabels = new Map<string, string>();
  private adoptAfterTurn = new Set<string>();
  /** 正在 clone 的目标目录，clone 期间不持登记锁。 */
  private cloning = new Set<string>();
  /** 含锁外网络操作的项目任务，关闭时仍需等待它们完成登记。 */
  private projectOperations = new Set<Promise<unknown>>();

  constructor(readonly store: Store, readonly home: string, readonly bus: Bus, private options: RuntimeOptions = {},
    readonly account = new AccountClient(() => undefined)) {
    this.catalog = new PluginCatalog(join(home, 'plugins'));
    this.contextTemplates = new ContextTemplates(store, [
      ...this.catalog.definitions().flatMap((definition) => definition.agent ? [definition.agent.context] : []),
      titleTemplate,
      agentConfigurationContextDefinition, contextUpdateContextDefinition, executionPermissionsContextDefinition, pluginToolsContextDefinition,
    ]);
    this.receipts = new OperationReceipts(store);
    this.operations = new InstanceOperations(this);
    this.plugins = new PluginHost(this);
    this.configuration = new InstanceConfiguration(this, {
      run: (workspaceId, action) => this.control(workspaceId, action),
      context: (id) => this.context(id), openThread: (id) => this.openThread(id),
      runtime: (thread) => this.runnerForManagement(thread),
      changed: (workspaceId) => this.changed(workspaceId),
    });
    this.instances = new InstanceLifecycle(this, {
      run: (workspaceId, action) => this.control(workspaceId, action),
      changed: (workspaceId) => this.changed(workspaceId),
      revokeGrants: (instance) => this.configuration.revokeInstanceGrants(instance),
    });
    if (options.lightTasks !== false && process.env.KITE_LIGHT_TASKS !== '0') {
      const light = options.lightTasks;
      this.lightTasks = new LightTasks({
        model: light?.model ?? (({ id }) => new ChatGPTModel({
          model: process.env.KITE_LIGHT_MODEL ?? agentModels.models.find((model) => model.tier === 'luna')!.id,
          reasoning: process.env.KITE_LIGHT_REASONING ?? 'low', threadId: id,
          credentials: () => readSubscriptionCredentials(join(home, 'auth', 'chatgpt', 'auth.json')),
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
    for (const w of store.workspaces()) if (w.status === 'preparing') store.setWorkspaceStatus(w.id, 'failed');
    this.transcripts = new TranscriptHistory(store, home, bus, this.events);
  }

  machine(): Machine { return this.store.machine; }
  projects(): Project[] { return this.store.projects(); }
  checkouts(projectId?: string): Checkout[] { return this.store.checkouts(projectId); }
  /** 登记本机文件夹（path）或 clone 远程（remote，path 可选）。 */
  registerCheckout(request: { path: string; remote?: undefined } | { remote: string; path?: string }): Promise<WorkspaceModel> {
    return this.projectOperation(async () => {
      // realpath 和目录重叠检查也在锁内，两个别名不能登记出重复检出。
      const registered = (model: WorkspaceModel) => {
        this.bus.emit({ type: 'checkout.changed', projectId: model.project.id, checkoutId: model.checkout.id });
        this.changed(model.workspace.id);
        return model;
      };
      if (request.remote === undefined) {
        return this.serial('register', async () => registered(await register(this.store, this.home, this.account, request.path, { cloning: this.cloning })));
      }
      // clone 可能很久，放在登记锁外；目标目录先占位，其他登记不能与它重叠。
      const { remote, path } = request;
      const dest = await this.serial('register', async () => {
        const dest = cloneTarget(this.store, this.home, remote, path, this.cloning);
        this.cloning.add(dest);
        return dest;
      });
      try {
        const project = await cloneRemote(this.account, remote, dest);
        return await this.serial('register', async () => {
          this.cloning.delete(dest);
          return registered(await register(this.store, this.home, this.account, dest, { cloned: project, cloning: this.cloning }));
        });
      } finally { this.cloning.delete(dest); }
    });
  }
  /**
   * 按账号的项目登记表更新本机项目。远程迁移后把各检出的 origin 改到新地址，
   * 目录上报随 checkout.changed 带上新远程，账号服务据此删除托管仓库。
   */
  syncProjects(): Promise<void> {
    if (!this.account.linked || this.stopping) return Promise.resolve();
    // 登记表在锁外取，账号服务不通时不挡住本机登记。
    return this.projectOperation(async () => {
      const projects = await this.account.projects();
      await this.serial('register', async () => {
        const registered = new Map(projects.map((p) => [p.id, p]));
        for (const project of this.store.projects()) {
          const latest = registered.get(project.id);
          if (!latest) continue;
          if (latest.remote !== project.remote || latest.name !== project.name) {
            this.store.saveProject({ ...project, name: latest.name, remote: latest.remote });
          }
          for (const checkout of this.store.checkouts(project.id)) {
            if (checkout.remote === latest.remote || !existsSync(checkout.path)) continue;
            try {
              const origin = await originURL(checkout.path);
              if (!origin || normalizeRemote(origin) !== latest.remote) await git(checkout.path, ['remote', 'set-url', 'origin', latest.url]);
            } catch (error) {
              console.error(`[项目同步] 更新 ${checkout.path} 的 origin 失败：${(error as Error).message}`);
              continue;
            }
            this.store.setCheckoutRemote(checkout.id, latest.remote);
            this.bus.emit({ type: 'checkout.changed', projectId: project.id, checkoutId: checkout.id });
          }
        }
      });
    });
  }
  /** 现场与远程的关系，基于最近一次拉取的结果。只读，不排在集成与推送的网络操作后面。 */
  checkoutSync(id: string): Promise<CheckoutSync> { return checkoutSync(this.checkoutOf(id).path); }
  /**
   * 现场的「提交并推送」，由用户触发。远程落后时把现场改动提交（message 为提交说明）后推送；
   * 远程领先而现场没有新东西时快进；两边都有新东西时不在现场合并，请用户新建工作区处理。
   */
  pushCheckout(id: string, message?: string): Promise<CheckoutSync> {
    this.assertRunning();
    const c = this.checkoutOf(id);
    return this.serial(`checkout:${c.id}`, async () => {
      const branch = await currentBranch(c.path);
      if (!branch) throw new KiteError('检出现场不在任何分支上，先切回主线分支', 409);
      const dirty = await isDirty(c.path);
      if (dirty && !message?.trim()) throw new KiteError('现场有未提交的改动，请填写提交说明', 400);
      const access = await originAccess(c.path, this.account);
      const upstream = await fetchBranch(c.path, branch, access);
      const head = await mainline(c);
      if (upstream && !(await isAncestor(c.path, upstream, head))) {
        if (dirty || !(await isAncestor(c.path, head, upstream))) {
          throw new KiteError('远程有新的提交，和现场的改动分叉了。请新建工作区，在工作区里集成', 409);
        }
        await git(c.path, ['merge', '-q', '--ff-only', upstream]);
        return checkoutSync(c.path);
      }
      if (dirty) await commitAll(c.path, ['-m', message!.trim()]);
      if (await pushBranch(c.path, branch, access) === 'rejected') throw new KiteError('远程刚有新的提交，请重试', 409);
      return checkoutSync(c.path);
    });
  }
  private checkoutOf(id: string): Checkout {
    const c = this.store.checkout(id);
    if (!c) throw new KiteError(`没有这个检出：${id}`, 404);
    return c;
  }
  workspaces(projectId?: string): WorkspaceModel[] { return this.store.workspaceModels(projectId); }
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
  private newThread(workspaceId: string, prompt: string, runtime: RuntimeKind, kind: Workspace['kind'], template?: ContextTemplateSelection): AgentInstance {
    const instance = this.instances.newInstance(workspaceId, runtime === 'claude' ? 'kite.agent.claude' : 'kite.agent.coding', titleOf(prompt), kind, template);
    return { ...instance, instanceId: instance.id, runtime, nativeId: randomUUID() };
  }

  /** 可以先建空工作区；带首条消息时，准备完成才启动首个线程。 */
  async createWorkspace(checkoutId: string, name: string, prompt?: string, runtime: RuntimeKind = 'harness', template?: ContextTemplateSelection): Promise<WorkspaceModel> {
    this.assertRunning();
    const c = this.checkoutOf(checkoutId);
    if (prompt !== undefined && !prompt.trim()) throw new KiteError('第一条消息不能为空');
    const base = await this.serial(`checkout:${c.id}`, () => mainline(c));
    this.assertRunning();
    const id = randomUUID();
    const w: Workspace = { id, checkoutId: c.id, name: name.trim() || (prompt ? titleOf(prompt) : '新工作区'),
      cwd: join(this.home, 'worktrees', c.projectId, id), kind: 'worktree', branch: `kite/${id}`, base,
      status: 'preparing', createdAt: Date.now() };
    const t = prompt === undefined ? undefined : this.newThread(id, prompt, runtime, w.kind, template);
    this.store.addWorkspace(w, t ? { agent: t, window: this.instances.newWindow(t) } : undefined);
    const controller = new AbortController();
    this.preparations.set(id, controller);
    void this.serial(`workspace:${id}`, async () => {
      try {
        await addWorktree(c.path, w.cwd, w.branch!, base);
        controller.signal.throwIfAborted();
        const setup = await runSetup(c.path, w.cwd, join(this.home, 'workspaces', id, 'setup.log'), controller.signal);
        this.bus.emit({ type: 'workspace.setup', workspaceId: id, originThreadId: t?.id, exit: setup?.exit ?? null, log: setup?.tail ?? '' });
        if (setup && setup.exit !== 0) throw new KiteError(`初始化脚本退出码 ${setup.exit}`);
        await this.snapshot(w, [], '工作区开始', t?.id);
        controller.signal.throwIfAborted();
        this.setWorkspaceStatus(id, 'open');
        if (t) {
          await this.sendInput(this.context(t.id), { id: randomUUID(), text: prompt!, source: 'human' },
            () => controller.signal.throwIfAborted());
        }
      } catch (e) {
        this.bus.emit({ type: 'workspace.error', workspaceId: id, originThreadId: t?.id, message: (e as Error).message });
        this.setWorkspaceStatus(id, 'failed');
      }
    }).finally(() => this.preparations.delete(id));
    this.changed(id);
    if (t) this.threadChanged(t);
    return this.workspace(id);
  }

  createThread(workspaceId: string, prompt: string, runtime: RuntimeKind = 'harness', template?: ContextTemplateSelection): Promise<ThreadView> {
    return this.control(workspaceId, async () => {
      const { workspace } = this.workspace(workspaceId);
      if (workspace.status !== 'open') throw new KiteError('工作区尚未打开', 409);
      if (!prompt.trim()) throw new KiteError('第一条消息不能为空');
      await this.assertIdle(workspaceId);
      await this.snapshot(workspace, [], '线程开始');
      const t = this.newThread(workspaceId, prompt, runtime, workspace.kind, template);
      this.store.addAgent(t, this.instances.newWindow(t));
      this.threadChanged(t);
      await this.sendInput(this.context(t.id), { id: randomUUID(), text: prompt, source: 'human' });
      return this.thread(t.id);
    });
  }

  /** 操作层只登记实例；有首条消息时才打开执行资源，窗口由 presentation 决定。 */
  startAgent(workspaceId: string, input: OperationInput<'agent.start'>, origin?: PluginInstance['origin'], check: () => void = () => {}): Promise<{ instanceId: string; windowId?: string }> {
    return this.control(workspaceId, async () => {
      check();
      const { workspace } = this.workspace(workspaceId);
      if (workspace.status !== 'open') throw new KiteError('工作区尚未打开', 409);
      const definition = this.catalog.get(input.definitionId);
      if (!definition.agent) throw new KiteError('只能通过 agent.start 创建 agent');
      if (input.prompt !== undefined) {
        await this.assertIdle(workspaceId);
        await this.snapshot(workspace, [], '线程开始');
      }
      check();
      const instance = this.instances.newInstance(workspaceId, definition.id, input.title ?? (input.prompt ? titleOf(input.prompt) : '新会话'), workspace.kind);
      instance.presentation = input.presentation;
      instance.origin = origin;
      if (origin && instanceExecutionGrants(this.store.instance(origin.instanceId)!).workspace === 'read') {
        instance.config.execution = { ...instanceExecutionGrants(instance), workspace: 'read' };
      }
      const agent: AgentInstance = { ...instance, instanceId: instance.id, runtime: definition.agent.runtime, nativeId: randomUUID() };
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
  configureExecutionGrants(id: string, expectedRevision: string, value: unknown) {
    return this.configuration.configureExecutionGrants(id, expectedRevision, value);
  }

  openWindow(workspaceId: string, request: OpenWindowRequest): Promise<WorkspaceWindow> {
    return this.instances.openWindow(workspaceId, request);
  }

  createPluginInstance(workspaceId: string, id: string, definitionId: string, title?: string) {
    return this.instances.createPluginInstance(workspaceId, id, definitionId, title);
  }

  closeWindow(workspaceId: string, id: string): Promise<void> {
    return this.instances.closeWindow(workspaceId, id);
  }

  agentConfig(id: string) { return this.configuration.agentConfig(id); }
  agentCapabilities(id: string) { return this.configuration.agentCapabilities(id); }
  configureAgent(id: string, expectedRevision: string, value: unknown) {
    return this.configuration.configureAgent(id, expectedRevision, value);
  }
  configureContextTemplate(id: string, expectedRevision: string, template: ContextTemplateSelection) {
    return this.configuration.configureContextTemplate(id, expectedRevision, template);
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
      home: this.home, repository: t.checkout.path, options: this.options,
      events: {
        emit: (event) => this.bus.emit({ ...event, threadId: id }),
        label: (text) => this.turnLabels.set(id, firstLine(text)),
        snapshot: (ids) => this.snapshot(workspace, ids, this.turnLabels.get(id) ?? title, id),
        idle: (completed) => {
          this.bus.emit({ type: 'idle', threadId: id });
          if (completed && !this.stopping) {
            if (this.adoptAfterTurn.delete(id)) {
              this.adopt(workspaceId, id, true).catch((e) => this.bus.emit({ type: 'workspace.error', workspaceId, originThreadId: id, message: `自动采纳失败：${(e as Error).message}` }));
            }
          }
        },
      },
      current: () => this.context(id),
      notifications: (after) => this.store.instanceNotifications(id, after),
      operations: { tools: this.operations.tools(id), prepare: (instance) => this.operations.prepareTools(instance) },
      contextUpdateTemplate: () => this.contextTemplates.get(contextUpdateContextDefinition.id, contextUpdateContextDefinition.scene).definition,
    });
    this.runners.set(id, r);
    return r;
  }
  /** 恢复检查只打开 journal，不执行旧输入；共享 cwd 的并行执行在工具调度接入后开放。 */
  private async runnerForManagement(t: AgentInstance): Promise<Runtime | undefined> {
    return this.runners.get(t.id) ?? (t.status === 'open' && existsSync(join(this.home, 'sessions', t.id))
      ? await this.runner(this.context(t.id)) : undefined);
  }
  private async assertIdle(workspaceId: string, except?: string): Promise<void> {
    for (const t of this.store.threads(workspaceId)) {
      if (t.status === 'archived' || t.id === except) continue;
      const r = await this.runnerForManagement(t);
      if (r?.busy || r?.recovery) throw new KiteError('工作区有线程正在工作或等待恢复确认', 409);
    }
  }
  send(id: string, text: string, inputId: string = randomUUID(), source: Input['source'] = 'human', check: () => void = () => {}): Promise<{ id: string }> {
    if (!text.trim()) throw new KiteError('消息不能为空');
    if (!inputId) throw new KiteError('消息 id 不能为空');
    return this.controlThread(id, async () => {
      check();
      const t = this.openThread(id);
      await this.assertIdle(t.workspaceId, id);
      await this.sendInput(t, { id: inputId, text, source }, check);
      return { id: inputId };
    });
  }
  private async sendInput(thread: ThreadContext, input: Input, check: () => void = () => {}): Promise<void> {
    const runner = await this.runner(thread);
    check();
    await runner.send(input);
    if (thread.title === '新会话' && this.store.threadTitle(thread.id)?.mode === 'auto') {
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
      await this.assertIdle(t.workspaceId, id);
      const r = await this.runner(t);
      check();
      if (!r.resume) throw new KiteError('这个后端通过发消息继续', 409);
      await r.resume();
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
      const r = await capture(w.cwd, w.id, label, toolUseIds);
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
  archiveThread(id: string): Promise<void> {
    const t = this.context(id);
    this.preparations.get(t.workspaceId)?.abort();
    return this.control(t.workspaceId, async () => {
      const current = this.context(id);
      if (current.status === 'archived') return;
      await this.stopThread(current);
      this.store.archiveThread(id);
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
      const releasePlugins = await this.plugins.closeWorkspace(id);
      try {
        await removeWorktree(checkout.path, w.cwd, w.branch!);
        this.store.archiveWorkspace(id);
      } finally { releasePlugins(); }
      for (const t of threads) if (t.status !== 'archived') this.threadChanged({ ...t, status: 'archived' });
      this.changed(id);
    });
  }
  async shutdown(): Promise<void> {
    this.stopping = true;
    await Promise.all([this.titles?.close(), this.lightTasks?.close()]);
    await this.plugins.close();
    await this.operations.close();
    for (const c of this.preparations.values()) c.abort();
    await Promise.allSettled(this.projectOperations);
    await Promise.allSettled([...this.queues.values(), ...this.openingRunners.values()]);
    await Promise.all([...this.runners.values()].map((r) => r.shutdown()));
  }
}
