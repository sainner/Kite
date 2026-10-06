/** 通知正文复用场景、段落和变量契约；来源、权限与投递时机由宿主决定。 */
import type { ContextVariable } from './scenes.ts';
import type { ContextBinding, ContextDefinition, ContextSource } from './types.ts';
import type { ExecutionGrants } from '../../execution/grants.ts';
import type { PluginToolSource } from '../../plugins/tools.ts';

export const pluginToolsContextDefinition: ContextDefinition = {
  version: 2, id: 'kite.plugin-tools', title: '插件工具授权变更', scene: 'thread.plugin_tools_changed',
  blocks: [{ type: 'paragraph', id: 'tools', title: '当前插件工具', parts: [
    { type: 'text', text: '宿主已更新插件工具授权。当前获准的工具及目标实例：' },
    { type: 'variable', name: 'plugin.tools' },
    { type: 'text', text: '。请使用 modelName 调用对应工具。撤回授权立即阻止新的执行，已有执行结果保留；本通知不会撤销已经提交的动作。' },
  ] }],
};

export function pluginToolsContext(tools: PluginToolSource[], definition: ContextDefinition = pluginToolsContextDefinition): ContextSource {
  if (definition.scene !== 'thread.plugin_tools_changed') throw new Error('插件工具通知须使用 thread.plugin_tools_changed 场景');
  return { definition, bindings: {
    'plugin.tools': { text: JSON.stringify(tools) },
  } satisfies Record<ContextVariable<'thread.plugin_tools_changed'>, ContextBinding> };
}

export const executionPermissionsContextDefinition: ContextDefinition = {
  version: 2, id: 'kite.execution-permissions', title: '执行授权变更', scene: 'thread.execution_permissions_changed',
  blocks: [{ type: 'paragraph', id: 'permissions', title: '当前权限', parts: [
    { type: 'text', text: '宿主已将执行授权更新为 ' },
    { type: 'variable', name: 'execution.revision' },
    { type: 'text', text: '。当前授权：' },
    { type: 'variable', name: 'execution.grants' },
    { type: 'text', text: '。workspace 表示工作目录的读写权限，read / write 是额外路径，network 是允许访问的域名和端口。系统工具链保持只读，宿主数据与 Git 元数据的保护继续生效。read / patch 仍限当前工作目录；额外路径通过 shell 访问。旧命令不会重放，已产生的改动保留。' },
  ] }],
};

export function executionPermissionsContext(
  revision: string, grants: ExecutionGrants, definition: ContextDefinition = executionPermissionsContextDefinition,
): ContextSource {
  if (definition.scene !== 'thread.execution_permissions_changed') throw new Error('执行授权通知须使用 thread.execution_permissions_changed 场景');
  return { definition, bindings: {
    'execution.revision': { text: revision }, 'execution.grants': { text: JSON.stringify(grants) },
  } satisfies Record<ContextVariable<'thread.execution_permissions_changed'>, ContextBinding> };
}

export const agentConfigurationContextDefinition: ContextDefinition = {
  version: 2, id: 'kite.agent-configuration', title: '会话配置变更', scene: 'thread.configuration_changed',
  blocks: [{
    type: 'paragraph', id: 'configuration', title: '当前配置',
    parts: [
      { type: 'text', text: 'agent 配置已更新为 ' },
      { type: 'variable', name: 'agent.revision' },
      { type: 'text', text: '。当前模型：' },
      { type: 'variable', name: 'agent.model' },
      { type: 'text', text: '，推理强度：' },
      { type: 'variable', name: 'agent.reasoning' },
      { type: 'text', text: '；允许工具：' },
      { type: 'variable', name: 'agent.tools' },
      { type: 'text', text: '；每回合最多 ' },
      { type: 'variable', name: 'agent.max_requests_per_turn' },
      { type: 'text', text: ' 次模型请求。上下文如有变化，由随后的基础上下文更新说明。' },
    ],
  }],
};

export const contextUpdateContextDefinition: ContextDefinition = {
  version: 2, id: 'kite.context-update', title: '基础上下文更新', scene: 'thread.context_updated',
  blocks: [
    {
      type: 'paragraph', id: 'replacement', title: '生效范围',
      parts: [{ type: 'text', text: '基础上下文已更新。以下内容从本次请求起替代先前的基础上下文，已有对话和执行结果仍然有效：' }],
    },
    {
      type: 'paragraph', id: 'instructions', title: '更新内容',
      parts: [{ type: 'variable', name: 'context.instructions' }],
    },
  ],
};

export function agentConfigurationContext(
  configuration: { revision: string; model: string; reasoning: string; tools: readonly string[]; maxRequestsPerTurn: number },
  definition: ContextDefinition = agentConfigurationContextDefinition,
): ContextSource {
  if (definition.scene !== 'thread.configuration_changed') throw new Error('配置变更通知须使用 thread.configuration_changed 场景');
  const bindings = {
    'agent.revision': { text: configuration.revision },
    'agent.model': { text: configuration.model },
    'agent.reasoning': { text: configuration.reasoning },
    'agent.tools': { text: configuration.tools.join('、') || '无' },
    'agent.max_requests_per_turn': { text: String(configuration.maxRequestsPerTurn) },
  } satisfies Record<ContextVariable<'thread.configuration_changed'>, ContextBinding>;
  return { definition, bindings };
}

export function contextUpdateContext(
  instructions: string, definition: ContextDefinition = contextUpdateContextDefinition,
): ContextSource {
  if (definition.scene !== 'thread.context_updated') throw new Error('基础上下文更新通知须使用 thread.context_updated 场景');
  const bindings = {
    'context.instructions': { text: instructions },
  } satisfies Record<ContextVariable<'thread.context_updated'>, ContextBinding>;
  return { definition, bindings };
}
