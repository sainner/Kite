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
import type { OperationGrant } from './operations/contract.ts';
import { mergePluginTools, pluginToolBindings, pluginToolGranted, pluginToolSource, type PluginToolBinding } from './plugins/tools.ts';
import { agentDefinitionId } from './plugins/definitions.ts';
import { checkTools, instanceRole, roleAgent, toolLimits, type RoleBinding, type RoleSelection } from './roles.ts';
import type { Runtime } from './runtime.ts';

type ConfigurationServices = Pick<Kite, 'store' | 'home' | 'workspace' | 'operations' | 'plugins' | 'catalog' | 'contextTemplates' | 'roles'>;

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
  /** 这个代理可开的工具：代理插件声明的全部工具，经创建时角色的规则约束。 */
  private toolLimits(instance: PluginInstance) {
    return toolLimits(this.kite.catalog.get(instance.definitionId).agent!.tools, instanceRole(instance)?.tools);
  }
  agentCapabilities(id: string) {
    const thread = this.control.context(id);
    return agentCapabilities(instanceAgent(thread).runtime, this.toolLimits(thread));
  }
  /** 新代理的草稿还没有实例：给出模型目录，以及各角色在这个工作区可开的工具；必需工具不可用的角色附上原因。 */
  agentOptions(workspaceId: string) {
    this.kite.workspace(workspaceId);
    const universe = this.kite.catalog.get(agentDefinitionId).agent!.tools;
    return { ...agentModelCatalog(), roles: this.kite.roles.list().map(({ role, revision }) => {
      const limits = toolLimits(universe, role.tools);
      return { id: role.id, revision, tools: limits.permitted, required: limits.required,
        ...(limits.missing.length ? { unavailable: `需要的工具不可用：${limits.missing.join('、')}` } : {}) };
    }) };
  }
  configureAgent(id: string, expectedRevision: string, value: unknown) {
    return this.updateAgentConfiguration(id, expectedRevision, () => value);
  }
  /** 改选角色：提示词、工具、默认模型与预算一起换成角色的，并记下新的角色约束。 */
  configureRole(id: string, expectedRevision: string, selection: RoleSelection) {
    const thread = this.control.context(id);
    const bound = roleAgent(this.kite.catalog.get(thread.definitionId).agent!, this.kite.roles.get(selection.id, selection.revision), thread.workspace.kind);
    return this.updateAgentConfiguration(id, expectedRevision, () => bound.agent, bound.role);
  }
  private updateAgentConfiguration(id: string, expectedRevision: string, update: (agent: AgentDefinition) => unknown, role?: RoleBinding) {
    return this.control.run(this.control.context(id).workspaceId, async () => {
      this.control.openThread(id);
      const snapshot = this.agentConfig(id);
      const { instance, revision } = snapshot;
      if (revision !== expectedRevision) throw new KiteError('配置已变化，请重新读取后修改', 409);
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
      checkTools(agent.tools, role ? toolLimits(this.kite.catalog.get(instance.definitionId).agent!.tools, role.tools) : this.toolLimits(instance));
      const nextRevision = agentRevision(agent);
      const roleChanged = role !== undefined && JSON.stringify(role) !== JSON.stringify(instanceRole(instance));
      if (nextRevision === revision && !roleChanged) return snapshot;
      const notification = {
        id: randomUUID(), kind: 'agent.configuration.changed', source: `instance:${id}`, authority: 'instruction',
        context: assembleContext(agentConfigurationContext({
          revision: nextRevision, ...agent.model, tools: agent.tools, maxRequestsPerTurn: agent.maxRequestsPerTurn,
        }, this.kite.contextTemplates.get(agentConfigurationContextDefinition.id, agentConfigurationContextDefinition.scene).definition)).snapshot,
      } as const;
      const save = () => this.kite.store.transaction(() => {
        if (runtimeChanged) this.kite.store.setThreadRuntime(id, agent.runtime);
        this.kite.store.setInstanceConfig(id, { ...instance.config, agent, ...(role ? { role } : {}) },
          nextRevision === revision ? undefined : notification);
      });
      if (runtimeChanged) await this.control.switchRuntime(id, agent, save);
      else save();
      this.control.changed(instance.workspaceId);
      return this.agentConfig(id);
    });
  }
}
