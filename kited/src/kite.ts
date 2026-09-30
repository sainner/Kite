import type { Input, StopRequest } from './harness/types.ts';
/** 工作区负责文件、快照和采纳；线程负责模型执行及独立的对话记录。 */
import { randomUUID } from 'node:crypto';
import { existsSync } from 'node:fs';
import { FileDiffStore } from './file-diffs.ts';
import { join, relative } from 'node:path';
import { getSessionMessages } from '@anthropic-ai/claude-agent-sdk';
import { KiteError } from './errors.ts';
import { type AdoptResult, Bus } from './events.ts';
import { hasUnmerged, mainline, mergeBack } from './mainline.ts';
import { register } from './projects.ts';
import { openRuntime, type Runtime, type RuntimeOptions } from './runtime.ts';
import { capture, findSnapshot, list, restore, type Snapshot } from './snapshots.ts';
import type { Store } from './store.ts';
import type { AgentInstance, Checkout, Machine, OpenWindowRequest, PluginInstance, Project, RuntimeKind, Thread, ThreadContext, Workspace, WorkspaceModel, WorkspaceStatus, WorkspaceWindow } from './model.ts';
import { PluginCatalog } from './plugin-catalog.ts';
import { PluginHost } from './plugin-host.ts';
import { agentRevision, bindAgentDefinition, instanceAgent, parseAgentDefinition } from './agent-definition.ts';
import { addWorktree, removeWorktree, runSetup } from './worktrees.ts';
import { readJournal } from './harness/journal.ts';
import { assembleContext } from './harness/context/assembler.ts';
import { agentConfigurationContext, executionPermissionsContext, pluginToolsContext } from './harness/context/notifications.ts';
import { harnessPolicy } from './harness/execution-policy.ts';
import { applyExecutionGrants, executionRevision, instanceExecutionGrants, normalizeExecutionGrants } from './execution-grants.ts';
import { InstanceOperations } from './operations.ts';
import { defaultOperationGrants, type OperationInput } from './operation-contract.ts';
import { mergePluginTools, pluginToolBindings, pluginToolGranted, pluginToolSource } from './plugin-tools.ts';
import { WorkspaceFiles, fileSelection } from './files.ts';
import { TranscriptFeed, TranscriptProjection, type DisplayState, type History } from './transcript.ts';

export interface ThreadView extends ThreadContext { runner: Runtime['state']; busy: boolean }
const firstLine = (text: string) => text.trim().split('\n')[0]!.trim() || '（空消息）';
const titleOf = (prompt: string) => firstLine(prompt).slice(0, 80);

function conflictPrompt(branch: string, files: string[]): string {
  return [`Kite 正在把工作区的改动合回主线。主线有了新提交，把它合进 ${branch} 时这些文件冲突了：`,
    ...files.map((f) => `- ${f}`), '',
    '请解决冲突，保留双方意图，然后 git add 并 git commit 完成合并。完成后 Kite 会自动继续合回主线。'].join('\n');
}

export class Kite {
  readonly events = new TranscriptFeed();
  readonly operations: InstanceOperations;
  readonly catalog: PluginCatalog;
  readonly plugins: PluginHost;
  private transcripts = new Map<string, TranscriptProjection>();
  private loadingTranscripts = new Map<string, Promise<TranscriptProjection>>();
  private runners = new Map<string, Runtime>();
  private queues = new Map<string, Promise<unknown>>();
  private preparations = new Map<string, AbortController>();
  private stopping = false;
  private turnLabels = new Map<string, string>();
  private adoptAfterTurn = new Set<string>();

  constructor(readonly store: Store, readonly home: string, readonly bus: Bus, private options: RuntimeOptions = {}) {
    this.catalog = new PluginCatalog(join(home, 'plugins'));
    this.operations = new InstanceOperations(this);
    this.plugins = new PluginHost(this);
    for (const w of store.workspaces()) if (w.status === 'preparing') store.setWorkspaceStatus(w.id, 'failed');
    bus.subscribe(undefined, (event) => {
      switch (event.type) {
        case 'workspace.changed':
        case 'workspace.error':
          for (const t of this.store.threads(event.workspaceId)) {
            const transcript = this.transcripts.get(t.id);
            if (event.type === 'workspace.changed') transcript?.lifecycle(event.status, t.status);
            else transcript?.workspaceError(event.message);
          }
          this.events.emit(event);
          break;
        case 'thread.changed':
          this.transcripts.get(event.threadId)?.lifecycle(this.store.workspace(event.workspaceId)!.status, event.status);
          this.events.emit(event);
          break;
        case 'checkout.changed':
        case 'workspace.setup':
        case 'workspace.snapshot':
        case 'workspace.adopt':
          this.events.emit(event);
          break;
        default:
          this.transcripts.get(event.threadId)?.accept(event);
      }
    });
  }

  machine(): Machine { return this.store.machine; }
  projects(): Project[] { return this.store.projects(); }
  checkouts(projectId?: string): Checkout[] { return this.store.checkouts(projectId); }
  registerCheckout(path: string, project?: Project): Promise<WorkspaceModel> {
    this.assertRunning();
    // realpath 和目录重叠检查也在锁内，两个别名不能登记出重复检出。
    return this.serial('register', async () => {
      const model = await register(this.store, this.home, path, project);
      this.bus.emit({ type: 'checkout.changed', projectId: model.project.id, checkoutId: model.checkout.id });
      this.changed(model.workspace.id);
      return model;
    });
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
  /** 文件操作和线程控制共用工作区锁；模型回合不持锁，忙闲由 runtime 明确报告。 */
  private control<T>(workspace: string, fn: () => Promise<T>): Promise<T> {
    this.assertRunning();
    return this.serial(`workspace:${workspace}`, async () => { this.assertRunning(); return fn(); });
  }
  private controlThread<T>(id: string, fn: () => Promise<T>): Promise<T> {
    return this.control(this.context(id).workspaceId, fn);
  }
  private newInstance(workspaceId: string, definitionId: string, title: string, kind: Workspace['kind']): PluginInstance {
    const definition = this.catalog.get(definitionId);
    return { id: randomUUID(), workspaceId, definitionId, title,
      config: definition.agent ? { agent: bindAgentDefinition(definition.agent, kind), grants: defaultOperationGrants(definitionId), execution: definition.execution } : definition.runtime === 'bun' ? { packageRevision: definition.revision, grants: [] } : {}, state: {},
      presentation: 'window', status: 'open', createdAt: Date.now() };
  }
  private newThread(workspaceId: string, prompt: string, runtime: RuntimeKind, kind: Workspace['kind']): AgentInstance {
    const instance = this.newInstance(workspaceId, 'kite.agent.coding', titleOf(prompt), kind);
    if (runtime === 'claude') instance.config = {};
    return { ...instance, instanceId: instance.id, runtime, nativeId: randomUUID() };
  }
  private newWindow(instance: PluginInstance, id: string = randomUUID(), viewId = this.catalog.get(instance.definitionId).defaultView): WorkspaceWindow {
    if (!viewId) throw new KiteError('此插件没有窗口视图，请创建后台实例');
    return { id, workspaceId: instance.workspaceId, target: { instanceId: instance.id, viewId }, state: 'open', createdAt: Date.now() };
  }

  /** 可以先建空工作区；带首条消息时，准备完成才启动首个线程。 */
  async createWorkspace(checkoutId: string, name: string, prompt?: string, runtime: RuntimeKind = 'harness'): Promise<WorkspaceModel> {
    this.assertRunning();
    const c = this.store.checkout(checkoutId);
    if (!c) throw new KiteError(`没有这个检出：${checkoutId}`, 404);
    if (prompt !== undefined && !prompt.trim()) throw new KiteError('第一条消息不能为空');
    const base = await this.serial(`checkout:${c.id}`, () => mainline(c));
    this.assertRunning();
    const id = randomUUID();
    const w: Workspace = { id, checkoutId: c.id, name: name.trim() || (prompt ? titleOf(prompt) : '新工作区'),
      cwd: join(this.home, 'worktrees', c.projectId, id), kind: 'worktree', branch: `kite/${id}`, base,
      status: 'preparing', createdAt: Date.now() };
    const t = prompt === undefined ? undefined : this.newThread(id, prompt, runtime, w.kind);
    this.store.addWorkspace(w, t ? { agent: t, window: this.newWindow(t) } : undefined);
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
          const r = await this.runner(this.context(t.id));
          controller.signal.throwIfAborted();
          await r.send({ id: randomUUID(), text: prompt!, source: 'human' });
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

  createThread(workspaceId: string, prompt: string, runtime: RuntimeKind = 'harness'): Promise<ThreadView> {
    return this.control(workspaceId, async () => {
      const { workspace } = this.workspace(workspaceId);
      if (workspace.status !== 'open') throw new KiteError('工作区尚未打开', 409);
      if (!prompt.trim()) throw new KiteError('第一条消息不能为空');
      await this.assertIdle(workspaceId);
      await this.snapshot(workspace, [], '线程开始');
      const t = this.newThread(workspaceId, prompt, runtime, workspace.kind);
      this.store.addAgent(t, this.newWindow(t));
      this.threadChanged(t);
      const r = await this.runner(this.context(t.id));
      await r.send({ id: randomUUID(), text: prompt, source: 'human' });
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
      const instance = this.newInstance(workspaceId, definition.id, input.title ?? (input.prompt ? titleOf(input.prompt) : '新会话'), workspace.kind);
      instance.presentation = input.presentation;
      instance.origin = origin;
      if (origin && instanceExecutionGrants(this.store.instance(origin.instanceId)!).workspace === 'read') {
        instance.config.execution = { ...instanceExecutionGrants(instance), workspace: 'read' };
      }
      const agent: AgentInstance = { ...instance, instanceId: instance.id, runtime: definition.agent.runtime, nativeId: randomUUID() };
      const window = instance.presentation === 'window' ? this.newWindow(instance) : undefined;
      this.store.addAgent(agent, window);
      this.threadChanged(agent);
      this.changed(workspaceId);
      if (input.prompt !== undefined) await (await this.runner(this.context(agent.id))).send({
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

  async configureOperationGrants(id: string, expectedRevision: string, value: unknown) {
    const instance = this.store.instance(id);
    if (!instance) throw new KiteError('没有这个实例', 404);
    if (instance.status !== 'open' || this.workspace(instance.workspaceId).workspace.status !== 'open') throw new KiteError('实例或工作区尚未打开', 409);
    const { revision, grants: oldGrants } = this.operations.grants(id);
    if (revision !== expectedRevision) throw new KiteError('授权已变化，请重新读取后修改', 409);
    const grants = this.operations.validateGrants(instance, value);
    if (this.store.thread(id)?.runtime === 'claude' && grants.some((grant) => grant.operation === 'plugin.call')) throw new KiteError('插件模型工具只支持 harness 会话', 409);
    const retained = pluginToolBindings(instance).filter((binding) => pluginToolGranted(binding, oldGrants) && pluginToolGranted(binding, grants));
    const reuseBindings = grants.every((grant) => grant.operation !== 'plugin.call'
      || grant.tools.every((name) => retained.some((binding) => binding.instanceId === grant.instanceId && binding.toolName === name)));
    // MCP 发现可能回调工作区能力；不能占着工作区控制队列等待插件。
    // 撤权保留已有声明，不等待被保留的插件响应，避免故障插件阻塞权限收回。
    const selected = reuseBindings ? retained : await this.plugins.bindings(grants);
    return this.control(instance.workspaceId, async () => {
      const current = this.store.instance(id)!;
      if (current.status !== 'open' || this.workspace(current.workspaceId).workspace.status !== 'open') throw new KiteError('实例或工作区尚未打开', 409);
      const { revision, grants: currentGrants } = this.operations.grants(id);
      if (revision !== expectedRevision) throw new KiteError('授权已变化，请重新读取后修改', 409);
      this.operations.validateGrants(current, grants);
      const previous = pluginToolBindings(current);
      const isAgent = !!this.catalog.get(current.definitionId).agent;
      const frozen = isAgent && (previous.length > 0 || selected.length > 0)
        && readJournal(join(this.home, 'sessions', id, 'journal.jsonl')).some((row) => row.type === 'request.configured');
      const pluginTools = mergePluginTools(previous, selected, frozen);
      const allowed = pluginTools.filter((binding) => pluginToolGranted(binding, grants)).map(pluginToolSource);
      const before = previous.filter((binding) => pluginToolGranted(binding, currentGrants)).map((binding) => binding.modelName);
      const changed = JSON.stringify(before) !== JSON.stringify(allowed.map((binding) => binding.modelName));
      this.store.setInstanceConfig(id, { ...current.config, grants, pluginTools }, isAgent && changed ? {
        id: randomUUID(), kind: 'plugin.tools.changed', source: 'host', authority: 'instruction',
        context: assembleContext(pluginToolsContext(allowed)).snapshot,
      } : undefined);
      this.changed(current.workspaceId);
      return this.operations.grants(id);
    });
  }

  executionGrants(id: string) {
    const instance = this.context(id);
    if (instance.runtime !== 'harness') throw new KiteError('此实例尚未接入执行授权', 409);
    const grants = instanceExecutionGrants(instance);
    return { grants, revision: executionRevision(grants) };
  }
  configureExecutionGrants(id: string, expectedRevision: string, value: unknown) {
    return this.controlThread(id, async () => {
      const instance = this.openThread(id);
      const { revision } = this.executionGrants(id);
      if (revision !== expectedRevision) throw new KiteError('执行授权已变化，请重新读取后修改', 409);
      const grants = await normalizeExecutionGrants(value);
      const nextRevision = executionRevision(grants);
      if (nextRevision === revision) return { grants, revision };
      const runtime = await this.runnerForManagement(instance);
      if (runtime?.busy || runtime?.recovery || runtime?.state === 'stopping') throw new KiteError('请先停止实例并确认执行结果，再修改执行授权', 409);
      const base = await harnessPolicy({ cwd: instance.workspace.cwd, env: process.env, home: this.home, repository: instance.checkout.path });
      applyExecutionGrants(base, instance.workspace.cwd, grants);
      this.store.setInstanceConfig(id, { ...instance.config, execution: grants }, {
        id: randomUUID(), kind: 'execution.permissions.changed', source: `instance:${id}`, authority: 'instruction',
        context: assembleContext(executionPermissionsContext(nextRevision, grants)).snapshot,
      });
      this.changed(instance.workspaceId);
      return this.executionGrants(id);
    });
  }

  /** 添加只登记呈现对象；空会话不启动模型，插件窗口不决定业务资源的生死。 */
  openWindow(workspaceId: string, request: OpenWindowRequest): Promise<WorkspaceWindow> {
    return this.control(workspaceId, async () => {
      const model = this.workspace(workspaceId);
      if (model.workspace.status !== 'open') throw new KiteError('工作区尚未打开', 409);
      const key = JSON.stringify(request.content);
      const saved = this.store.windowRequest(request.id);
      if (saved) {
        const window = this.store.window(saved.windowId)!;
        if (saved.workspaceId !== workspaceId || saved.content !== key || window.state !== 'open') {
          throw new KiteError('窗口请求已使用或窗口已关闭', 409);
        }
        return window;
      }
      if (this.store.window(request.id)) throw new KiteError('窗口 ID 已使用', 409);
      let created: PluginInstance | undefined;
      let thread: Thread | undefined;
      let window: WorkspaceWindow;
      const content = request.content;
      if (content.kind === 'create') {
        const definition = this.catalog.get(content.definitionId);
        const number = model.instances.filter((p) => p.definitionId === definition.id).length + 1;
        created = this.newInstance(workspaceId, definition.id, definition.agent ? '新会话' : `${definition.title} ${number}`, model.workspace.kind);
        if (definition.agent) thread = { instanceId: created.id, runtime: definition.agent.runtime, nativeId: randomUUID() };
        window = this.newWindow(created, request.id);
      } else {
        const instance = this.store.instance(content.instanceId);
        if (!instance || instance.workspaceId !== workspaceId) throw new KiteError('工作区内没有这个实例', 404);
        if (instance.status !== 'open') throw new KiteError('实例已经归档', 409);
        if (!this.catalog.get(instance.definitionId).views.some((view) => view.id === content.viewId)) throw new KiteError('插件未声明这个视图');
        window = this.newWindow(instance, request.id, content.viewId);
      }
      const { target } = window;
      const existing = model.windows.find((w) => w.target.instanceId === target.instanceId && w.target.viewId === target.viewId);
      window = existing ?? window;
      this.store.openWindow(window, { id: request.id, content: key }, created, thread);
      this.changed(workspaceId);
      return window;
    });
  }

  createPluginInstance(workspaceId: string, id: string, definitionId: string, title?: string) {
    return this.control(workspaceId, async () => {
      const { workspace } = this.workspace(workspaceId);
      if (workspace.status !== 'open') throw new KiteError('工作区尚未打开', 409);
      const definition = this.catalog.get(definitionId);
      if (definition.runtime !== 'bun') throw new KiteError('此入口用于创建 Bun 插件实例');
      const existing = this.store.instance(id);
      if (existing) {
        if (existing.workspaceId !== workspaceId || existing.definitionId !== definitionId || existing.title !== (title ?? definition.title)
          || existing.status !== 'open') throw new KiteError('实例 ID 已用于其他创建请求', 409);
        return existing;
      }
      const instance = { ...this.newInstance(workspaceId, definitionId, title ?? definition.title, workspace.kind), id, presentation: 'background' as const };
      this.store.addInstance(instance);
      this.changed(workspaceId);
      return instance;
    });
  }

  closeWindow(workspaceId: string, id: string): Promise<void> {
    return this.control(workspaceId, async () => {
      if (this.workspace(workspaceId).workspace.status !== 'open') throw new KiteError('工作区尚未打开', 409);
      const window = this.store.window(id);
      if (!window || window.workspaceId !== workspaceId) throw new KiteError('工作区内没有这个窗口', 404);
      if (window.state === 'closed') return;
      this.store.closeWindow(id);
      this.changed(workspaceId);
    });
  }

  agentConfig(id: string) {
    const thread = this.context(id);
    if (thread.runtime !== 'harness') throw new KiteError('此执行后端不支持 agent 配置', 409);
    const instance = this.store.instance(id)!;
    return { instance, revision: agentRevision(instanceAgent(instance)) };
  }
  configureAgent(id: string, expectedRevision: string, value: unknown) {
    return this.controlThread(id, async () => {
      this.openThread(id);
      const { instance, revision } = this.agentConfig(id);
      if (revision !== expectedRevision) throw new KiteError('配置已变化，请重新读取后修改', 409);
      const agent = parseAgentDefinition(value);
      const declared = this.catalog.get(instance.definitionId).agent!;
      if (agent.tools.some((tool) => !declared.tools.includes(tool))) throw new KiteError('配置包含此定义未开放的工具');
      const nextRevision = agentRevision(agent);
      if (nextRevision === revision) return { instance, revision };
      this.store.setInstanceConfig(id, { ...instance.config, agent }, {
        id: randomUUID(), kind: 'agent.configuration.changed', source: `instance:${id}`, authority: 'instruction',
        context: assembleContext(agentConfigurationContext({
          revision: nextRevision, ...agent.model, tools: agent.tools, maxRequestsPerTurn: agent.maxRequestsPerTurn,
        })).snapshot,
      });
      this.changed(instance.workspaceId);
      return this.agentConfig(id);
    });
  }

  async history(id: string): Promise<History> { return (await this.transcript(this.context(id))).snapshot(); }
  async threadState(id: string): Promise<DisplayState> { return (await this.transcript(this.context(id))).state(); }
  historyNow(id: string): History {
    const t = this.transcripts.get(id);
    if (!t) throw new KiteError('请先加载线程历史', 409);
    return t.snapshot();
  }
  private transcript(t: ThreadContext): Promise<TranscriptProjection> {
    const cached = this.transcripts.get(t.id);
    if (cached) return Promise.resolve(cached);
    const loading = this.loadingTranscripts.get(t.id);
    if (loading) return loading;
    const promise = (async () => {
      const projection = new TranscriptProjection(t, this.events);
      if (t.runtime === 'harness') {
        for (const row of readJournal(join(this.home, 'sessions', t.id, 'journal.jsonl'))) projection.journal(row);
      } else {
        for (const row of await getSessionMessages(t.nativeId, { dir: t.workspace.cwd, includeSystemMessages: true })) projection.claude(row, t.createdAt);
      }
      const current = this.context(t.id);
      projection.lifecycle(current.workspace.status, current.status);
      projection.finishReplay();
      this.transcripts.set(t.id, projection);
      return projection;
    })().finally(() => this.loadingTranscripts.delete(t.id));
    this.loadingTranscripts.set(t.id, promise);
    return promise;
  }
  private async runner(t: ThreadContext): Promise<Runtime> {
    const { id, workspaceId, workspace, title } = t;
    const existing = this.runners.get(id);
    if (existing) return existing;
    await this.transcript(t);
    const r = await openRuntime(t, this.home, t.checkout.path, {
      emit: (event) => this.bus.emit({ ...event, threadId: id }),
      label: (text) => this.turnLabels.set(id, firstLine(text)),
      snapshot: (ids) => this.snapshot(workspace, ids, this.turnLabels.get(id) ?? title, id),
      idle: (completed) => {
        this.bus.emit({ type: 'idle', threadId: id });
        if (completed && !this.stopping && this.adoptAfterTurn.delete(id)) {
          this.adopt(workspaceId, id).catch((e) => this.bus.emit({ type: 'workspace.error', workspaceId, originThreadId: id, message: `自动采纳失败：${(e as Error).message}` }));
        }
      },
    }, this.options, () => this.context(id), (after) => this.store.instanceNotifications(id, after), {
      tools: this.operations.tools(id), prepare: (instance) => this.operations.prepareTools(instance),
    });
    this.runners.set(id, r);
    return r;
  }
  /** 恢复检查只打开 journal，不执行旧输入；共享 cwd 的并行执行在工具调度接入后开放。 */
  private async runnerForManagement(t: AgentInstance): Promise<Runtime | undefined> {
    return this.runners.get(t.id) ?? (t.runtime === 'harness' && t.status === 'open' && existsSync(join(this.home, 'sessions', t.id))
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
      const runner = await this.runner(t);
      check();
      await runner.send({ id: inputId, text, source });
      if (t.title === '新会话') {
        this.store.renameInstance(t.id, titleOf(text));
        this.threadChanged(t);
      }
      return { id: inputId };
    });
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
  adopt(id: string, originThreadId?: string): Promise<AdoptResult> {
    return this.control(id, async () => {
      const { workspace: w, checkout } = this.workspace(id);
      const threads = this.store.threads(id);
      if (w.kind === 'root' || w.status !== 'open') throw new KiteError('只能采纳已打开的独立工作区', 409);
      await this.assertIdle(id);
      const result = await this.serial(`checkout:${checkout.id}`, async (): Promise<AdoptResult> => {
        const r = await mergeBack(checkout, w.cwd, w.name);
        if (r.status === 'merged') return { status: 'adopted', commit: r.commit };
        const t = threads.findLast((t) => t.status === 'open');
        if (r.fresh && t) {
          this.adoptAfterTurn.add(t.id);
          await (await this.runner(this.context(t.id))).send({ id: randomUUID(), text: conflictPrompt(w.branch!, r.files), source: 'kite' });
        }
        return { status: 'conflict', files: r.files };
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
      for (const t of threads) if (t.status !== 'archived') await this.stopThread(t);
      if (!force && await hasUnmerged(checkout.path, w.cwd)) throw new KiteError('工作区有没合回主线的改动；确定丢弃就加 force', 409);
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
    await this.plugins.close();
    await this.operations.close();
    for (const c of this.preparations.values()) c.abort();
    await Promise.allSettled([...this.queues.values()]);
    await Promise.all([...this.runners.values()].map((r) => r.shutdown()));
  }
}
