/** 实例配置、执行授权和操作授权的版本校验与通知；控制队列及运行时生命周期由 Kite 提供。 */
import { randomUUID } from 'node:crypto';
import { join } from 'node:path';
import { agentCapabilities, agentModelCatalog, configurationBoundary } from './agents/capabilities.ts';
import { agentRevision, chooseAgentModel, claudeReasoning, instanceAgent, parseAgentDefinition, type AgentDefinition } from './agents/definition.ts';
import { KiteError } from './errors.ts';
import { applyExecutionGrants, executionRevision, instanceExecutionGrants, normalizeExecutionGrants } from './execution/grants.ts';
import { harnessPolicy } from './execution/policy.ts';
import { assembleContext } from './harness/context/assembler.ts';
import {
  agentConfigurationContext, agentConfigurationContextDefinition,
  executionPermissionsContext, executionPermissionsContextDefinition, pluginToolsContext, pluginToolsContextDefinition,
} from './harness/context/notifications.ts';
import { JournalIndex } from './harness/journal.ts';
import type { Kite } from './kite.ts';
import type { AgentInstance, PluginInstance, ThreadContext } from './model.ts';
import { roleOperationGrants, type OperationGrant } from './operations/contract.ts';
import { mergePluginTools, pluginToolBindings, pluginToolGranted, pluginToolSource, type PluginToolBinding } from './plugins/tools.ts';
import { agentTools } from './plugins/definitions.ts';
import { permittedTools } from './agents/tool-policy.ts';
import { checkTools, instanceRole, roleAgent, toolLimits, type ProjectToolRule, type RoleBinding, type RoleSelection } from './roles.ts';
import type { Runtime } from './runtime.ts';

/** 代理配置里的工具经项目约束实时过滤后的有效集。 */
const effectiveTools = (agent: AgentDefinition, project: ProjectToolRule | undefined) => permittedTools(agent.tools, project ? [project] : []);

type ConfigurationServices = Pick<Kite, 'store' | 'home' | 'workspace' | 'operations' | 'plugins' | 'catalog' | 'contextTemplates' | 'roles' | 'history'>;

interface ConfigurationControl {
  run<T>(workspaceId: string, action: () => Promise<T>): Promise<T>;
  context(id: string): ThreadContext;
  openThread(id: string): ThreadContext;
  runtime(thread: AgentInstance): Promise<Runtime | undefined>;
  switchRuntime(id: string, agent: AgentDefinition, commit: () => void): Promise<void>;
  changed(workspaceId: string): void;
}

export class InstanceConfiguration {
  private journalIndex = new JournalIndex();

  constructor(private kite: ConfigurationServices, private control: ConfigurationControl) {}

  async configureOperationGrants(id: string, expectedRevision: string, value: unknown) {
    const instance = this.kite.store.instance(id);
    if (!instance) throw new KiteError('没有这个实例', 404);
    if (instance.status !== 'open' || this.kite.workspace(instance.workspaceId).workspace.status !== 'open') throw new KiteError('实例或工作区尚未打开', 409);
    const { revision, grants: oldGrants } = this.kite.operations.grants(id);
    if (revision !== expectedRevision) throw new KiteError('授权已变化，请重新读取后修改', 409);
    const grants = this.kite.operations.validateGrants(instance, value);
    const retained = pluginToolBindings(instance).filter((binding) => pluginToolGranted(binding, oldGrants) && pluginToolGranted(binding, grants));
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
    const frozen = isAgent && (previous.length > 0 || selected.length > 0)
      && this.journalIndex.firstConfiguration(join(this.kite.home, 'sessions', instance.id, 'journal.jsonl')) !== undefined;
    const pluginTools = mergePluginTools(previous, selected, frozen);
    const allowed = pluginTools.filter((binding) => pluginToolGranted(binding, grants)).map(pluginToolSource);
    const currentGrants = this.kite.operations.grants(instance.id).grants;
    const before = previous.filter((binding) => pluginToolGranted(binding, currentGrants)).map((binding) => binding.modelName);
    const changed = JSON.stringify(before) !== JSON.stringify(allowed.map((binding) => binding.modelName));
    this.kite.store.setInstanceConfig(instance.id, { ...instance.config, grants, pluginTools }, isAgent && changed ? {
      id: randomUUID(), kind: 'plugin.tools.changed', source: 'host', authority: 'instruction',
      context: assembleContext(pluginToolsContext(allowed,
        this.kite.contextTemplates.get(pluginToolsContextDefinition.id, pluginToolsContextDefinition.scene).definition)).snapshot,
    } : undefined);
  }

  /** 由实例回收在工作区锁和删除事务内调用；已固定的模型工具声明沿用撤权规则，避免改写历史前缀。 */
  revokeInstanceGrants(target: PluginInstance): void {
    for (const instance of this.kite.store.instances(target.workspaceId)) {
      if (instance.id === target.id) continue;
      const { grants: previous } = this.kite.operations.grants(instance.id);
      const grants = previous.flatMap((grant): OperationGrant[] => {
        if (grant.operation === 'plugin.call' && grant.instanceId === target.id) return [];
        if ('targets' in grant && grant.targets.kind === 'instances') {
          const instanceIds = grant.targets.instanceIds.filter((id) => id !== target.id);
          return instanceIds.length ? [{ ...grant, targets: { kind: 'instances', instanceIds } }] : [];
        }
        return [grant];
      });
      if (JSON.stringify(previous) === JSON.stringify(grants)) continue;
      this.saveOperationGrants(instance, grants, pluginToolBindings(instance).filter((binding) => pluginToolGranted(binding, grants)));
    }
  }

  executionGrants(id: string) {
    const instance = this.control.context(id);
    const grants = instanceExecutionGrants(instance);
    return { grants, revision: executionRevision(grants) };
  }
  configureExecutionGrants(id: string, expectedRevision: string, value: unknown) {
    return this.control.run(this.control.context(id).workspaceId, async () => {
      const instance = this.control.openThread(id);
      const { revision } = this.executionGrants(id);
      if (revision !== expectedRevision) throw new KiteError('执行授权已变化，请重新读取后修改', 409);
      const grants = await normalizeExecutionGrants(value);
      const nextRevision = executionRevision(grants);
      if (nextRevision === revision) return { grants, revision };
      const runtime = await this.control.runtime(instance);
      if (runtime?.busy || runtime?.recovery || runtime?.state === 'stopping') throw new KiteError('请先停止实例并确认执行结果，再修改执行授权', 409);
      const base = await harnessPolicy({ cwd: instance.workspace.cwd, env: process.env, home: this.kite.home, repository: instance.checkout.path });
      applyExecutionGrants(base, instance.workspace.cwd, grants);
      this.kite.store.setInstanceConfig(id, { ...instance.config, execution: grants }, {
        id: randomUUID(), kind: 'execution.permissions.changed', source: `instance:${id}`, authority: 'instruction',
        context: assembleContext(executionPermissionsContext(nextRevision, grants,
          this.kite.contextTemplates.get(executionPermissionsContextDefinition.id, executionPermissionsContextDefinition.scene).definition)).snapshot,
      });
      this.control.changed(instance.workspaceId);
      return this.executionGrants(id);
    });
  }

  agentConfig(id: string) {
    this.control.context(id);
    const instance = this.kite.store.instance(id)!;
    const agent = instanceAgent(instance);
    return { instance, revision: agentRevision(agent), configurationBoundary: configurationBoundary(agent.runtime) };
  }
  /** 项目当前的工具约束，以账号服务为准，这里读本机缓存。 */
  private projectRule(workspaceId: string) {
    return this.kite.store.workspaceConstraints(workspaceId)?.tools;
  }
  /** 这个代理可开的工具：代理插件声明的全部工具，经创建时角色的规则约束；项目约束另作实时过滤。 */
  private toolLimits(instance: PluginInstance) {
    return toolLimits(agentTools, instanceRole(instance)?.tools, this.projectRule(instance.workspaceId));
  }
  agentCapabilities(id: string) {
    const thread = this.control.context(id);
    return agentCapabilities(instanceAgent(thread).runtime, this.toolLimits(thread));
  }
  /** 新代理的草稿还没有实例：给出模型目录，以及各角色在这个工作区可开的工具与被项目禁用的工具；必需工具被禁的角色附上原因。 */
  agentOptions(workspaceId: string) {
    const project = this.projectRule(workspaceId);
    return { ...agentModelCatalog(), roles: this.kite.roles.list().map(({ role, revision }) => {
      const limits = toolLimits(agentTools, role.tools, project);
      return { id: role.id, revision, tools: limits.allowed, required: limits.required, blocked: limits.blocked,
        ...(limits.missing.length ? { unavailable: `项目约束禁用了必需的 ${limits.missing.join('、')}` } : {}) };
    }) };
  }
  /** 项目约束变化后，有效工具随之改变的代理在下一次请求收到配置通知。 */
  constraintsChanged(projectId: string, before?: ProjectToolRule) {
    const after = this.kite.store.projectConstraints(projectId)?.tools;
    for (const workspace of this.kite.store.workspaces(projectId).filter((workspace) => workspace.status === 'open')) {
      for (const instance of this.kite.store.threads(workspace.id).filter((thread) => thread.status === 'open')) {
        const agent = instanceAgent(instance);
        if (JSON.stringify(effectiveTools(agent, before)) === JSON.stringify(effectiveTools(agent, after))) continue;
        this.kite.store.setInstanceConfig(instance.id, instance.config, this.configurationNotice('host', agent, after));
      }
      this.control.changed(workspace.id);
    }
  }
  /** 配置变化通知；告诉模型的工具已按项目约束过滤，被禁的不算可用。 */
  private configurationNotice(source: string, agent: AgentDefinition, project: ProjectToolRule | undefined) {
    return {
      id: randomUUID(), kind: 'agent.configuration.changed', source, authority: 'instruction',
      context: assembleContext(agentConfigurationContext({
        revision: agentRevision(agent), ...agent.model, tools: effectiveTools(agent, project), maxRequestsPerTurn: agent.maxRequestsPerTurn,
      }, this.kite.contextTemplates.get(agentConfigurationContextDefinition.id, agentConfigurationContextDefinition.scene).definition)).snapshot,
    } as const;
  }
  configureAgent(id: string, expectedRevision: string, value: unknown) {
    return this.updateAgentConfiguration(id, expectedRevision, () => value);
  }
  /** 改选角色：提示词、工具、默认模型、预算与协作授权一起换成角色的，并记下新的角色约束。只在还没有对话时可用。 */
  configureRole(id: string, expectedRevision: string, selection: RoleSelection) {
    const thread = this.control.context(id);
    const bound = roleAgent(agentTools, this.kite.roles.get(selection.id, selection.revision), thread.workspace.kind,
      {}, this.projectRule(thread.workspaceId));
    return this.updateAgentConfiguration(id, expectedRevision, () => bound.agent, bound.role);
  }
  private updateAgentConfiguration(id: string, expectedRevision: string, update: (agent: AgentDefinition) => unknown, role?: RoleBinding) {
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
      const requested = parseAgentDefinition(update(current));
      // 后端由模型推出；模型没换时沿用原后端，环境变量覆盖的目录外模型不会被误判为换了厂商。
      const agent = requested.model.model === current.model.model ? { ...requested, runtime: current.runtime } : chooseAgentModel(requested, requested.model);
      const runtimeChanged = agent.runtime !== this.control.context(id).runtime;
      if (agent.runtime === 'claude') {
        const running = await this.control.runtime(this.control.context(id));
        if (running?.busy || running?.recovery || running?.state === 'stopping') throw new KiteError('请先停止会话并确认执行结果，再修改 Claude 配置', 409);
        if (!claudeReasoning.includes(agent.model.reasoning)) throw new KiteError('Claude 思考强度无效');
      }
      checkTools(agent.tools, role ? toolLimits(agentTools, role.tools) : this.toolLimits(instance));
      const nextRevision = agentRevision(agent);
      const roleChanged = role !== undefined && JSON.stringify(role) !== JSON.stringify(instanceRole(instance));
      if (nextRevision === revision && !roleChanged) return snapshot;
      const notification = this.configurationNotice(`instance:${id}`, agent, this.projectRule(instance.workspaceId));
      const save = () => this.kite.store.transaction(() => {
        if (runtimeChanged) this.kite.store.setThreadRuntime(id, agent.runtime);
        this.kite.store.setInstanceConfig(id, { ...instance.config, agent,
          ...(role ? { role, grants: roleOperationGrants(instance.definitionId, this.kite.operations.grants(id).grants,
            toolLimits(agentTools, instanceRole(instance)?.tools).allowed, toolLimits(agentTools, role.tools).allowed) } : {}) },
          nextRevision === revision ? undefined : notification);
      });
      if (runtimeChanged) await this.control.switchRuntime(id, agent, save);
      else save();
      this.control.changed(instance.workspaceId);
      return this.agentConfig(id);
    });
  }
}
