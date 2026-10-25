/** 实例配置、执行授权和操作授权的版本校验与通知；控制队列及运行时生命周期由 Kite 提供。 */
import { randomUUID } from 'node:crypto';
import { z } from 'zod';
import { agentCapabilities, agentModelCatalog, configurationBoundary } from './agents/capabilities.ts';
import { agentRevision, chooseAgentModel, claudeReasoning, instanceAgent, parseAgentDefinition, type AgentDefinition } from './agents/definition.ts';
import { KiteError } from './errors.ts';
import { applyExecutionGrants, approvalModes, defaultProjectExecution, effectiveApprovalMode, effectiveExecution, executionRevision, instanceApprovalMode,
  instanceExecutionChanges, normalizeExecutionChanges, type ApprovalMode, type ExecutionChanges, type ProjectExecution } from './execution/grants.ts';
import { harnessPolicy } from './execution/policy.ts';
import { assembleContext } from './harness/context/assembler.ts';
import {
  agentConfigurationContext, agentConfigurationContextDefinition,
  executionPermissionsContext, executionPermissionsContextDefinition, pluginToolsContext, pluginToolsContextDefinition,
} from './harness/context/notifications.ts';
import type { Kite } from './kite.ts';
import type { AgentInstance, PluginInstance, ThreadContext } from './model.ts';
import { roleOperationGrants, type OperationGrant } from './operations/contract.ts';
import { agentToolCatalog } from './plugins/definitions.ts';
import { pluginToolBindings, pluginToolGranted, type PluginToolBinding } from './plugins/tools.ts';
import { effectiveTools, threadVariables } from './context-variables.ts';
import { checkTools, instanceRole, roleAgent, toolLimits, type ProjectToolRule, type RoleBinding, type RoleSelection } from './roles.ts';
import type { Runtime } from './runtime.ts';
import { instanceMcp } from './mcp/tools.ts';
import { serverNamesSchema } from './mcp/names.ts';

/** 实例上记住的预置脚本内容最多留这么多份。 */
const MAX_TRUSTED_SCRIPTS = 50;

/** 代理实例上「允许并记住」过的预置脚本（预览目标、.kite/check）内容的摘要（contentHash）。 */
export const trustedScripts = (instance: Pick<PluginInstance, 'config'>): string[] =>
  z.array(z.string()).catch([]).parse(instance.config.trustedScripts);

type ConfigurationServices = Pick<Kite, 'store' | 'home' | 'skillSources' | 'workspace' | 'operations' | 'plugins' | 'catalog' | 'contextTemplates' | 'roles' | 'history'
  | 'terminals' | 'mcp'>;

interface ConfigurationControl {
  run<T>(workspaceId: string, action: () => Promise<T>): Promise<T>;
  context(id: string): ThreadContext;
  openThread(id: string): ThreadContext;
  runtime(thread: AgentInstance): Promise<Runtime | undefined>;
  switchRuntime(id: string, agent: AgentDefinition, commit: () => void): Promise<void>;
  changed(workspaceId: string): void;
}

export class InstanceConfiguration {

  constructor(private kite: ConfigurationServices, private control: ConfigurationControl) {}

  async configureOperationGrants(id: string, expectedRevision: string, value: unknown) {
    const instance = this.kite.store.instance(id);
    if (!instance) throw new KiteError('没有这个实例', 404);
    if (instance.status !== 'open' || this.kite.workspace(instance.workspaceId).workspace.status !== 'open') throw new KiteError('实例或工作区尚未打开', 409);
    if (this.kite.operations.grants(id).revision !== expectedRevision) throw new KiteError('授权已变化，请重新读取后修改', 409);
    const grants = this.kite.operations.validateGrants(instance, value);
    const retained = pluginToolBindings(instance).filter((binding) => pluginToolGranted(binding, grants));
    const reuseBindings = grants.every((grant) => grant.operation !== 'plugin.call'
      || grant.tools.every((name) => retained.some((binding) => binding.instanceId === grant.instanceId && binding.toolName === name)));
    // MCP 发现可能回调工作区能力；不能占着工作区控制队列等待插件。
    // 撤权保留已有声明，不等待被保留的插件响应，避免故障插件阻塞权限收回。
    const selected = reuseBindings ? retained : await this.kite.plugins.bindings(grants);
    return this.control.run(instance.workspaceId, async () => {
      const current = this.kite.store.instance(id);
      if (!current) throw new KiteError('没有这个实例', 404);
      if (current.status !== 'open' || this.kite.workspace(current.workspaceId).workspace.status !== 'open') throw new KiteError('实例或工作区尚未打开', 409);
      const { revision } = this.kite.operations.grants(id);
      if (revision !== expectedRevision) throw new KiteError('授权已变化，请重新读取后修改', 409);
      this.kite.operations.validateGrants(current, grants);
      this.saveOperationGrants(current, grants, selected);
      this.control.changed(current.workspaceId);
      return this.kite.operations.grants(id);
    });
  }

  private saveOperationGrants(instance: PluginInstance, grants: OperationGrant[], selected: PluginToolBinding[]): void {
    const previous = pluginToolBindings(instance);
    const isAgent = !!this.kite.catalog.get(instance.definitionId).agent;
    // 会话中途新授权的插件工具：自研 harness 经 tool_search 加载，Claude 在下次启动进程后经 ToolSearch 加载，都不用新建会话。
    const names = (bindings: PluginToolBinding[]) => JSON.stringify(bindings.map((binding) => binding.modelName));
    const changed = names(previous) !== names(selected);
    const config = { ...instance.config, grants, pluginTools: selected };
    this.kite.store.setInstanceConfig(instance.id, config, isAgent && changed ? {
      id: randomUUID(), kind: 'plugin.tools.changed', source: 'host', authority: 'instruction',
      context: assembleContext(pluginToolsContext(this.variables({ ...this.control.context(instance.id), config }),
        this.kite.contextTemplates.get(pluginToolsContextDefinition.id, pluginToolsContextDefinition.scene).definition)).snapshot,
    } : undefined);
  }

  /** 由实例回收在工作区锁和删除事务内调用。 */
  revokeInstanceGrants(target: PluginInstance): void {
    for (const instance of this.kite.store.instances(target.workspaceId)) {
      if (instance.id === target.id) continue;
      const { grants: previous } = this.kite.operations.grants(instance.id);
      const grants = previous.flatMap((grant): OperationGrant[] => {
        if (grant.operation === 'plugin.call' && grant.instanceId === target.id) return [];
        if ('targets' in grant && grant.targets.kind === 'instances') {
          const instanceIds = grant.targets.instanceIds.filter((id) => id !== target.id);
          return instanceIds.length ? [{ ...grant, targets: { kind: 'instances', instanceIds } } as OperationGrant] : [];
        }
        return [grant];
      });
      if (JSON.stringify(previous) === JSON.stringify(grants)) continue;
      this.saveOperationGrants(instance, grants, pluginToolBindings(instance).filter((binding) => pluginToolGranted(binding, grants)));
    }
  }

  /** grants 是实例在项目基础上的增减，effective 是三层合成后生效的，project 是项目的基础与边界。 */
  executionGrants(id: string) {
    const instance = this.control.context(id);
    const grants = instanceExecutionChanges(instance);
    const project = this.projectExecution(instance.workspaceId);
    return { grants, revision: executionRevision(grants), effective: effectiveExecution(grants, project).grants, project: project ?? defaultProjectExecution() };
  }
  configureExecutionGrants(id: string, expectedRevision: string, value: unknown) {
    return this.control.run(this.control.context(id).workspaceId, async () => {
      const instance = this.control.openThread(id);
      const { revision } = this.executionGrants(id);
      if (revision !== expectedRevision) throw new KiteError('执行授权已变化，请重新读取后修改', 409);
      const grants = await normalizeExecutionChanges(value);
      if (executionRevision(grants) === revision) return this.executionGrants(id);
      const runtime = await this.control.runtime(instance);
      if (runtime?.busy || runtime?.state === 'stopping') throw new KiteError('请先停止实例，再修改执行授权', 409);
      // 转到后台的命令按旧授权跑在沙箱里，收紧之前要先停下（Agent与插件契约 7.2）。
      if (this.kite.terminals.owned(id).length) throw new KiteError('这个代理转到后台的命令还在运行，请先停下再修改执行授权', 409);
      const base = await harnessPolicy({ cwd: instance.workspace.cwd, env: process.env, home: this.kite.home, repository: instance.checkout.path });
      applyExecutionGrants(base, instance.workspace.cwd, effectiveExecution(grants, this.projectExecution(instance.workspaceId)));
      this.saveExecutionGrants(instance, grants);
      return this.executionGrants(id);
    });
  }
  /**
   * 「允许并记住」：在实例上追加一台主机或一条沙箱外命令，是「运行中不能改执行授权」的例外；在后续连接与调用生效，
   * 不重放已失败的命令，授权变化照常通知模型。实例原先去掉过的同一项一并恢复。
   */
  remember(id: string, key: 'network' | 'unsandboxed', value: string): Promise<void> {
    return this.control.run(this.control.context(id).workspaceId, async () => {
      const instance = this.control.openThread(id);
      const current = instanceExecutionChanges(instance);
      const grants = await normalizeExecutionChanges({ ...current, add: { ...current.add, [key]: [...current.add[key], value] },
        remove: { ...current.remove, [key]: current.remove[key].filter((item) => item !== value) } });
      if (executionRevision(grants) !== executionRevision(current)) this.saveExecutionGrants(instance, grants);
    });
  }
  /** 预置脚本的「允许并记住」：把脚本内容的摘要记在实例上，同样内容的再起不问；只留最近的 MAX_TRUSTED_SCRIPTS 份。 */
  rememberScript(id: string, digest: string): Promise<void> {
    return this.control.run(this.control.context(id).workspaceId, async () => {
      const instance = this.control.openThread(id);
      const trusted = trustedScripts(instance);
      if (trusted.includes(digest)) return;
      this.kite.store.setInstanceConfig(instance.id, { ...instance.config, trustedScripts: [...trusted, digest].slice(-MAX_TRUSTED_SCRIPTS) });
      this.control.changed(instance.workspaceId);
    });
  }
  private saveExecutionGrants(instance: ThreadContext, grants: ExecutionChanges): void {
    const config = { ...instance.config, execution: grants };
    this.kite.store.setInstanceConfig(instance.id, config, this.executionNotice(`instance:${instance.id}`, { ...instance, config }));
    this.control.changed(instance.workspaceId);
  }
  /** 执行授权变更通知；版本与正文取三层合成后生效的授权。 */
  private executionNotice(source: string, thread: ThreadContext, project = this.projectExecution(thread.workspaceId)) {
    const effective = effectiveExecution(instanceExecutionChanges(thread), project).grants;
    return {
      id: randomUUID(), kind: 'execution.permissions.changed', source, authority: 'instruction',
      context: assembleContext(executionPermissionsContext(executionRevision(effective),
        threadVariables(thread, { ...this.constraints(thread.workspaceId), execution: project }, this.kite.skillSources, this.kite.mcp),
        this.kite.contextTemplates.get(executionPermissionsContextDefinition.id, executionPermissionsContextDefinition.scene).definition)).snapshot,
    } as const;
  }

  /** mode 是实例的选择，effective 是按项目上限收紧后实际用的。 */
  approvalMode(id: string) {
    const instance = this.control.context(id);
    const project = this.projectExecution(instance.workspaceId);
    const mode = instanceApprovalMode(instance);
    return { mode, effective: effectiveApprovalMode(mode, project), max: project?.approval ?? 'allow_all' };
  }
  /** 审批模式在下一次越界请求时生效，运行中也可以改。 */
  configureApprovalMode(id: string, value: unknown) {
    const parsed = z.object({ mode: z.enum(approvalModes) }).strict().safeParse(value);
    if (!parsed.success) throw new KiteError('审批模式无效');
    const { mode } = parsed.data;
    return this.control.run(this.control.context(id).workspaceId, async () => {
      const instance = this.control.openThread(id);
      if (instanceApprovalMode(instance) !== mode) {
        this.kite.store.setInstanceConfig(id, { ...instance.config, approval: mode });
        this.control.changed(instance.workspaceId);
      }
      return this.approvalMode(id);
    });
  }

  /** 这台工作机装的服务与此刻的连接状态，给开关列表用。 */
  private mcpCatalog() {
    return this.kite.mcp.list().map(({ name, config, status }) => ({ name, description: config.description, phase: status.phase }));
  }
  /** 实例打开的 MCP 服务（可以有本机没装的，装上后生效）、项目禁用的，以及这台工作机装的。 */
  mcpSettings(id: string) {
    const thread = this.control.context(id);
    return { servers: instanceMcp(thread), denied: this.constraints(thread.workspaceId)?.mcp?.deny ?? [], available: this.mcpCatalog() };
  }
  /** 开关 MCP 服务：运行中也能改，下一次请求按新的给工具，基础上下文里的服务清单随之更新。 */
  configureMcpSettings(id: string, value: unknown) {
    const parsed = z.object({ servers: serverNamesSchema }).strict().safeParse(value);
    if (!parsed.success) throw new KiteError(`MCP 服务开关请求无效：${parsed.error.issues.map((issue) => issue.message).join('；')}`);
    const { servers } = parsed.data;
    return this.control.run(this.control.context(id).workspaceId, async () => {
      const instance = this.control.openThread(id);
      if (JSON.stringify(instanceMcp(instance)) !== JSON.stringify(servers)) {
        const { mcp: _mcp, ...config } = instance.config;
        this.kite.store.setInstanceConfig(id, servers.length ? { ...config, mcp: servers } : config);
        this.control.changed(instance.workspaceId);
      }
      // 新打开、生效的服务在后台先连上，下一次请求就有它的工具。
      void this.kite.mcp.ensure(this.kite.mcp.effective(servers, this.constraints(instance.workspaceId)?.mcp?.deny));
      return this.mcpSettings(id);
    });
  }

  agentConfig(id: string) {
    this.control.context(id);
    const instance = this.kite.store.instance(id)!;
    const agent = instanceAgent(instance);
    return { instance, revision: agentRevision(agent), configurationBoundary: configurationBoundary(agent.runtime) };
  }
  /** 项目当前的约束，以账号级数据为准，这里读本机缓存。 */
  private constraints(workspaceId: string) {
    return this.kite.store.workspaceConstraints(workspaceId);
  }
  private projectRule(workspaceId: string) {
    return this.constraints(workspaceId)?.tools;
  }
  private projectExecution(workspaceId: string): ProjectExecution | undefined {
    return this.constraints(workspaceId)?.execution;
  }
  /** 通知里的公共变量取 thread 给出的变化之后的状态。 */
  private variables(thread: ThreadContext) {
    return threadVariables(thread, this.constraints(thread.workspaceId), this.kite.skillSources, this.kite.mcp);
  }
  /** 这个代理可开的工具：代理插件声明的全部工具，经创建时角色的规则约束；项目约束另作实时过滤。 */
  private toolLimits(instance: PluginInstance) {
    return toolLimits(instanceRole(instance)?.tools, this.projectRule(instance.workspaceId));
  }
  /** 实例可以开代理插件的全部工具（项目禁的划掉），角色给的是默认值。 */
  agentCapabilities(id: string) {
    const thread = this.control.context(id);
    const role = this.toolLimits(thread);
    const all = toolLimits(undefined, this.projectRule(thread.workspaceId));
    return agentCapabilities(instanceAgent(thread).runtime, { allowed: all.allowed, defaults: role.allowed, required: role.required, blocked: all.blocked });
  }
  /** 新代理的草稿还没有实例：给出模型目录、工具的界面名称与分组、这台工作机的 MCP 服务，以及各角色在这个工作区可开的工具、被项目禁用的工具与默认打开的服务；必需工具被禁的角色附上原因。 */
  agentOptions(workspaceId: string) {
    const project = this.projectRule(workspaceId);
    const all = toolLimits(undefined, project);
    return { ...agentModelCatalog(), toolCatalog: agentToolCatalog,
      mcp: { available: this.mcpCatalog(), denied: this.kite.store.workspaceConstraints(workspaceId)?.mcp?.deny ?? [] },
      roles: this.kite.roles.list().map(({ role, revision }) => {
      const limits = toolLimits(role.tools, project);
      return { id: role.id, revision, tools: all.allowed, defaults: limits.allowed, required: limits.required, blocked: all.blocked,
        ...(role.mcp?.length ? { mcp: role.mcp } : {}),
        ...(limits.missing.length ? { unavailable: `项目约束禁用了必需的 ${limits.missing.join('、')}` } : {}) };
    }) };
  }
  /** 项目约束变化后，有效工具或生效的执行授权随之改变的代理在下一次请求收到对应的通知。 */
  constraintsChanged(projectId: string, before?: { tools?: ProjectToolRule; execution?: ProjectExecution }) {
    const after = this.kite.store.projectConstraints(projectId);
    for (const workspace of this.kite.store.workspaces(projectId).filter((workspace) => workspace.status === 'open')) {
      for (const instance of this.kite.store.threads(workspace.id).filter((thread) => thread.status === 'open')) {
        const agent = instanceAgent(instance);
        if (JSON.stringify(effectiveTools(agent, before?.tools)) !== JSON.stringify(effectiveTools(agent, after?.tools))) {
          this.kite.store.setInstanceConfig(instance.id, instance.config, this.configurationNotice('host', this.control.context(instance.id), agent, after?.tools));
        }
        const changes = instanceExecutionChanges(instance);
        if (JSON.stringify(effectiveExecution(changes, before?.execution).grants) !== JSON.stringify(effectiveExecution(changes, after?.execution).grants)) {
          this.kite.store.setInstanceConfig(instance.id, instance.config, this.executionNotice('host', this.control.context(instance.id), after?.execution));
        }
      }
      this.control.changed(workspace.id);
    }
  }
  /** 配置变化通知；告诉模型的工具已按项目约束过滤，被禁的不算可用。 */
  private configurationNotice(source: string, thread: ThreadContext, agent: AgentDefinition, project: ProjectToolRule | undefined) {
    return {
      id: randomUUID(), kind: 'agent.configuration.changed', source, authority: 'instruction',
      context: assembleContext(agentConfigurationContext(agentRevision(agent),
        threadVariables({ ...thread, config: { ...thread.config, agent } }, { ...this.constraints(thread.workspaceId), tools: project },
          this.kite.skillSources, this.kite.mcp),
        this.kite.contextTemplates.get(agentConfigurationContextDefinition.id, agentConfigurationContextDefinition.scene).definition)).snapshot,
    } as const;
  }
  configureAgent(id: string, expectedRevision: string, value: unknown) {
    return this.updateAgentConfiguration(id, expectedRevision, value);
  }
  /** 改选角色：提示词、工具、执行授权、审批模式、默认模型与协作授权一起换成角色的，并记下新的角色约束。只在还没有对话时可用。 */
  configureRole(id: string, expectedRevision: string, selection: RoleSelection) {
    const thread = this.control.context(id);
    const bound = roleAgent(this.kite.roles.get(selection.id, selection.revision), {}, this.projectRule(thread.workspaceId));
    return this.updateAgentConfiguration(id, expectedRevision, bound.agent, bound.role,
      { execution: bound.execution, approval: bound.approval, mcp: bound.mcp });
  }
  private updateAgentConfiguration(id: string, expectedRevision: string, value: unknown, role?: RoleBinding,
    defaults?: { execution?: ExecutionChanges; approval: ApprovalMode; mcp: string[] }) {
    return this.control.run(this.control.context(id).workspaceId, async () => {
      this.control.openThread(id);
      const snapshot = this.agentConfig(id);
      const { instance, revision } = snapshot;
      if (revision !== expectedRevision) throw new KiteError('配置已变化，请重新读取后修改', 409);
      // 换提示词等于换了一个代理，已有对话是在旧角色下进行的；与发送消息共用工作区锁，检查与保存之间不会插进新消息。
      if (role) {
        const { records, pending } = await this.kite.history(id);
        if (records.length || pending.length) throw new KiteError('对话开始后不能改选角色，请新建代理', 409);
      }
      const current = instanceAgent(instance);
      const requested = parseAgentDefinition(value);
      // 后端由模型推出；模型没换时沿用原后端，环境变量覆盖的目录外模型不会被误判为换了厂商。
      const agent = requested.model.model === current.model.model ? { ...requested, runtime: current.runtime } : chooseAgentModel(requested, requested.model);
      const runtimeChanged = agent.runtime !== this.control.context(id).runtime;
      if (agent.runtime === 'claude') {
        const running = await this.control.runtime(this.control.context(id));
        if (running?.busy || running?.state === 'stopping') throw new KiteError('请先停止会话，再修改 Claude 配置', 409);
        if (!claudeReasoning.includes(agent.model.reasoning)) throw new KiteError('Claude 思考强度无效');
      }
      checkTools(agent.tools, role ? toolLimits(role.tools) : this.toolLimits(instance));
      const nextRevision = agentRevision(agent);
      const roleChanged = role !== undefined && JSON.stringify(role) !== JSON.stringify(instanceRole(instance));
      if (nextRevision === revision && !roleChanged) return snapshot;
      const notification = this.configurationNotice(`instance:${id}`, this.control.context(id), agent, this.projectRule(instance.workspaceId));
      const save = () => this.kite.store.transaction(() => {
        if (runtimeChanged) this.kite.store.setThreadRuntime(id, agent.runtime);
        // 换角色时执行授权与审批模式重置为新角色的：角色没给执行授权就不增不减，审批模式已按角色与默认解析好。
        const { approval: _approval, execution: _execution, mcp: _mcp, ...config } = instance.config;
        this.kite.store.setInstanceConfig(id, { ...(role ? config : instance.config), agent,
          ...(role ? { role, grants: roleOperationGrants(instance.definitionId, this.kite.operations.grants(id).grants,
            toolLimits(instanceRole(instance)?.tools).allowed, toolLimits(role.tools).allowed),
          ...(defaults?.execution ? { execution: defaults.execution } : {}), ...(defaults ? { approval: defaults.approval } : {}),
          ...(defaults?.mcp.length ? { mcp: defaults.mcp } : {}) } : {}) },
          nextRevision === revision ? undefined : notification);
      });
      if (runtimeChanged) await this.control.switchRuntime(id, agent, save);
      else save();
      this.control.changed(instance.workspaceId);
      return this.agentConfig(id);
    });
  }
}
