/**
 * 工作区现况（docs/实例操作.md「工作区现况」）：公共变量 workspace.instances 的取值。名单变了不重发基础上下文（见 notifiedVariables），
 * 由两个后端在请求边界和上次给代理的名单比，变了补一条通知，见 harness/context/notifications.ts 的 instancesChangedContext。
 */
import { instanceAgent } from './agents/definition.ts';
import { effectiveTools } from './context-variables.ts';
import type { PluginInstance, ThreadContext } from './model.ts';
import { agentMonitor, monitorDefinitionId } from './monitor/monitors.ts';
import { operationContracts, type ListOperation } from './operations/contract.ts';
import type { InstanceOperations } from './operations/operations.ts';
import { agentDefinitionId } from './plugins/definitions.ts';
import { previewConfig, previewDefinitionId } from './preview/state.ts';
import { portKey } from './preview/targets.ts';
import type { Store } from './store.ts';
import { exitResult, terminalState } from './terminal/state.ts';
import { adoptedCommand, terminalDefinitionId } from './terminal/terminals.ts';

/** 算进现况的几种实例：叫什么、代理用哪个 list 操作看它；名单按这个顺序排。 */
const kinds: Record<string, { name: string; list: ListOperation | 'preview.list' }> = {
  [agentDefinitionId]: { name: '代理', list: 'agent.list' },
  [terminalDefinitionId]: { name: '终端', list: 'terminal.list' },
  [previewDefinitionId]: { name: '预览', list: 'preview.list' },
  [monitorDefinitionId]: { name: 'monitor', list: 'monitor.list' },
};
const order = Object.keys(kinds);

export class WorkspaceInstances {
  constructor(private host: { store: Store; operations: Pick<InstanceOperations, 'grants' | 'listRange'> }) {}

  /** 这个代理调对应 list 工具看得到的本工作区实例，每行一项；没有时为空。代理转到后台的命令与 Line 的收件箱不算。 */
  roster(thread: ThreadContext): string {
    const sees = this.viewer(thread);
    return this.host.store.instances(thread.workspaceId).filter((instance) => instance.status === 'open' && instance.id !== thread.id && sees(instance))
      .sort((a, b) => order.indexOf(a.definitionId) - order.indexOf(b.definitionId) || a.createdAt - b.createdAt)
      .map((instance) => this.line(instance, thread.id)).join('\n');
  }

  /** 有这个 list 工具（配置允许且获得授权），按范围列的还要在这项授权的范围内。 */
  private viewer(thread: ThreadContext): (instance: PluginInstance) => boolean {
    const tools = new Set(effectiveTools(instanceAgent(thread), this.host.store.workspaceConstraints(thread.workspaceId)?.tools, thread.workspace.cwd));
    const granted = new Set(this.host.operations.grants(thread.id).grants.map((grant) => grant.operation));
    const ranges = new Map<ListOperation, (target: PluginInstance) => boolean>();
    const inRange = (list: ListOperation, instance: PluginInstance) => {
      if (!ranges.has(list)) ranges.set(list, this.host.operations.listRange(thread, list));
      return ranges.get(list)!(instance);
    };
    return (instance) => {
      const kind = kinds[instance.definitionId];
      if (!kind || !granted.has(kind.list) || !tools.has(operationContracts[kind.list].tool)) return false;
      if (instance.definitionId === terminalDefinitionId && adoptedCommand(instance)) return false;
      if (instance.definitionId === monitorDefinitionId && !agentMonitor(instance)) return false;
      return kind.list === 'preview.list' || inRange(kind.list, instance);
    };
  }

  /** 实例 ID 前后的写法 instancesChangedContext 要认，改时一起改。 */
  private line(instance: PluginInstance, viewer: string): string {
    const process = terminalState(instance);
    const port = instance.definitionId === previewDefinitionId ? this.host.store.targetPort(instance.workspaceId, portKey(previewConfig(instance))) : undefined;
    const state = !process ? '' : process.phase === 'running' ? '，在跑' : `，已结束（${exitResult(process)}）`;
    return `- ${kinds[instance.definitionId]!.name}「${instance.title}」：实例 ID ${instance.id}${port !== undefined ? `，端口 ${port}` : ''}${state}`
      + (instance.origin?.instanceId === viewer ? '，你开的' : '');
  }
}
