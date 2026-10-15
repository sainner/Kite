/** 代理线程的公共变量：所在工作机、项目、工作区与代理实例的状态，见 harness/context/scenes.ts 的分层。 */
import { instanceAgent, type AgentDefinition } from './agents/definition.ts';
import { permittedTools } from './agents/tool-policy.ts';
import { instanceExecutionGrants } from './execution/grants.ts';
import { directoryVariables, today } from './harness/context/project.ts';
import type { LayerVariable, PublicVariable } from './harness/context/scenes.ts';
import type { ContextBinding, ContextValues } from './harness/context/types.ts';
import type { Machine, ThreadContext } from './model.ts';
import { operationGrantsSchema } from './operations/contract.ts';
import { pluginToolBindings, pluginToolGranted, pluginToolSource } from './plugins/tools.ts';
import type { ProjectToolRule } from './roles.ts';
import type { Store } from './store.ts';

/** 代理配置里的工具经项目约束实时过滤后的有效集。 */
export const effectiveTools = (agent: AgentDefinition, project: ProjectToolRule | undefined) => permittedTools(agent.tools, project ? [project] : []);

/** 环境层：所有场景都取得到。 */
export function environmentVariables(machine: Machine) {
  return { 'environment.date': today, 'machine.name': () => ({ text: machine.name }) } satisfies Record<LayerVariable<'environment'>, () => ContextBinding>;
}

/**
 * thread 是取值时的状态：生成通知时传入变化之后的配置，变量取新值。每个值在模板引用时才取。
 * constraint 是项目的工具约束，允许的工具按它过滤，与配置通知一致。
 */
export function threadVariables(thread: ThreadContext, constraint: ProjectToolRule | undefined): ContextValues {
  const text = (value: () => string) => (): ContextBinding => ({ text: value() });
  const agent = () => instanceAgent(thread);
  return {
    ...environmentVariables(thread.machine),
    ...directoryVariables(thread.workspace.cwd),
    'project.name': text(() => thread.project.name),
    'project.remote': text(() => thread.project.remote),
    'workspace.name': text(() => thread.workspace.name),
    'workspace.kind': text(() => thread.workspace.kind),
    'agent.title': text(() => thread.title),
    // 角色的名称随提示词拷进实例，之后修改角色不影响。
    'agent.role': text(() => agent().context.title),
    'agent.model': text(() => agent().model.model),
    'agent.reasoning': text(() => agent().model.reasoning),
    'agent.tools': text(() => effectiveTools(agent(), constraint).join('、') || '无'),
    'agent.max_requests_per_turn': text(() => String(agent().maxRequestsPerTurn)),
    'execution.grants': text(() => JSON.stringify(instanceExecutionGrants(thread))),
    'plugin.tools': text(() => {
      const grants = operationGrantsSchema.parse(thread.config.grants ?? []);
      return JSON.stringify(pluginToolBindings(thread).filter((binding) => pluginToolGranted(binding, grants)).map(pluginToolSource));
    }),
  } satisfies Record<PublicVariable, () => ContextBinding>;
}

/** 按线程当前保存的状态取值。 */
export function storedThreadVariables(store: Store, id: string): ContextValues {
  const thread = store.threadContext(id);
  if (!thread) throw new Error(`没有这个线程：${id}`);
  return threadVariables(thread, store.workspaceConstraints(thread.workspaceId)?.tools);
}
