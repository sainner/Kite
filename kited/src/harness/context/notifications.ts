/**
 * 通知正文复用场景、段落和变量契约；来源、权限与投递时机由宿主决定。
 * values 是宿主给的公共变量，取变化之后的状态，通知在生成时取值并随通知固定。
 */
import { bindContext, sceneValues } from './assembler.ts';
import type { ContextAssembly, ContextDefinition, ContextSource, ContextValues } from './types.ts';

export const pluginToolsContextDefinition: ContextDefinition = {
  version: 2, id: 'kite.plugin-tools', title: '插件工具授权变更', scene: 'thread.plugin_tools_changed',
  blocks: [{ type: 'paragraph', id: 'tools', title: '当前插件工具', parts: [
    { type: 'text', text: '宿主已更新插件工具授权。当前获准的插件实例与工具：' },
    { type: 'variable', name: 'plugin.tools' },
    { type: 'text', text: '。工具列表里还没有的，先用工具搜索加载再调用；不在这里的工具已经撤回，不要再调用。' },
  ] }],
};

export function pluginToolsContext(values: ContextValues, definition: ContextDefinition = pluginToolsContextDefinition): ContextSource {
  if (definition.scene !== 'thread.plugin_tools_changed') throw new Error('插件工具通知须使用 thread.plugin_tools_changed 场景');
  return bindContext(definition, values);
}

export const executionPermissionsContextDefinition: ContextDefinition = {
  version: 2, id: 'kite.execution-permissions', title: '执行授权变更', scene: 'thread.execution_permissions_changed',
  blocks: [{ type: 'paragraph', id: 'permissions', title: '当前权限', parts: [
    { type: 'text', text: '宿主已将执行授权更新为 ' },
    { type: 'variable', name: 'execution.revision' },
    { type: 'text', text: '。当前授权：' },
    { type: 'variable', name: 'execution.grants' },
    { type: 'text', text: '。workspace 表示工作目录的读写权限，read / write 是额外路径，network 是允许访问的域名和端口。read / patch 仍限当前工作目录；额外路径通过 shell 访问。' },
  ] }],
};

export function executionPermissionsContext(
  revision: string, values: ContextValues, definition: ContextDefinition = executionPermissionsContextDefinition,
): ContextSource {
  if (definition.scene !== 'thread.execution_permissions_changed') throw new Error('执行授权通知须使用 thread.execution_permissions_changed 场景');
  return bindContext(definition, { ...values, ...sceneValues<'thread.execution_permissions_changed'>({ 'execution.revision': revision }) });
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
      { type: 'text', text: '。' },
    ],
  }],
};

export const fileChangesContextDefinition: ContextDefinition = {
  version: 2, id: 'kite.file-changes', title: '会话中文件变化', scene: 'thread.file_changes',
  blocks: [{ type: 'paragraph', id: 'changes', title: '净变化', parts: [
    { type: 'text', text: '在被压缩的那段对话期间，工作区文件有以下净变化（' },
    { type: 'variable', name: 'files.origin' },
    { type: 'text', text: '）：\n' },
    { type: 'variable', name: 'files.changes' },
  ] }],
};

export function fileChangesContext(
  changes: string, origin: string, values: ContextValues = {}, definition: ContextDefinition = fileChangesContextDefinition,
): ContextSource {
  if (definition.scene !== 'thread.file_changes') throw new Error('文件变化通知须使用 thread.file_changes 场景');
  return bindContext(definition, { ...values, ...sceneValues<'thread.file_changes'>({ 'files.changes': changes, 'files.origin': origin }) });
}

export const contextUpdateContextDefinition: ContextDefinition = {
  version: 2, id: 'kite.context-update', title: '基础上下文更新', scene: 'thread.context_updated',
  blocks: [
    {
      type: 'paragraph', id: 'replacement', title: '生效范围',
      parts: [{ type: 'text', text: '基础上下文已更新。以下内容从本次请求起替代先前的基础上下文：' }],
    },
    {
      type: 'paragraph', id: 'instructions', title: '更新内容',
      parts: [{ type: 'variable', name: 'context.instructions' }],
    },
  ],
};

export function agentConfigurationContext(
  revision: string, values: ContextValues, definition: ContextDefinition = agentConfigurationContextDefinition,
): ContextSource {
  if (definition.scene !== 'thread.configuration_changed') throw new Error('配置变更通知须使用 thread.configuration_changed 场景');
  return bindContext(definition, { ...values, ...sceneValues<'thread.configuration_changed'>({ 'agent.revision': revision }) });
}

export function contextUpdateContext(
  instructions: string, values: ContextValues = {}, definition: ContextDefinition = contextUpdateContextDefinition,
): ContextSource {
  if (definition.scene !== 'thread.context_updated') throw new Error('基础上下文更新通知须使用 thread.context_updated 场景');
  return bindContext(definition, { ...values, ...sceneValues<'thread.context_updated'>({ 'context.instructions': instructions }) });
}


export const instancesChangedContextDefinition: ContextDefinition = {
  version: 2, id: 'kite.instances-changed', title: '工作区现况变化', scene: 'thread.instances_changed',
  blocks: [
    { type: 'paragraph', id: 'change', title: '变化', parts: [
      { type: 'text', text: '工作区里你用得上的实例有变化：\n' }, { type: 'variable', name: 'instances.change' },
    ] },
    { type: 'condition', id: 'current', title: '现在的名单', variable: 'workspace.instances',
      cases: [{ id: 'current-none', title: '没有', equals: '', blocks: [
        { type: 'paragraph', id: 'current-empty', title: '没有', parts: [{ type: 'text', text: '现在没有你用得上的实例。' }] },
      ] }],
      otherwise: { id: 'current-some', title: '有', blocks: [
        { type: 'paragraph', id: 'current-list', title: '名单', parts: [
          { type: 'text', text: '现在的名单，替代先前给你的：\n' }, { type: 'variable', name: 'workspace.instances' },
        ] },
      ] } },
    { type: 'paragraph', id: 'guidance', title: '处理方式', parts: [{ type: 'text', text: '这是告知，不用回应。' }] },
  ],
};

/** 基础上下文里的工作区现况；模板没用这个变量时为 undefined，不跟踪变化。 */
export const rosterOf = (assembly: ContextAssembly): string | undefined => assembly.snapshot.bindings['workspace.instances']?.text;

/**
 * 工作区现况从 previous 变成 current 时给代理的通知：多了、变了、不在了的各一行，附上新的名单；代理自己开的实例出现时它从工具结果里已经知道，
 * 不算，只有这种变化时为 undefined。两个后端在请求边界、基础上下文没有整份重发时调用。
 * 名单每行的写法见 workspace-instances.ts 的 line，按「实例 ID」后面的编号对上前后两份。
 */
export function instancesChangedContext(
  previous: string, current: string, values: ContextValues = {}, definition: ContextDefinition = instancesChangedContextDefinition,
): ContextSource | undefined {
  if (definition.scene !== 'thread.instances_changed') throw new Error('工作区现况通知须使用 thread.instances_changed 场景');
  const items = (roster: string) => new Map(roster.split('\n').filter(Boolean).map((line) => {
    const item = line.replace(/^- /, '');
    return [/实例 ID ([^，\s]+)/.exec(item)?.[1] ?? item, item];
  }));
  const before = items(previous);
  const after = items(current);
  const changes = [
    ...[...after].flatMap(([id, item]) => before.get(id) === item || !before.has(id) && item.endsWith('，你开的') ? []
      : [`- ${before.has(id) ? '变了' : '多了'}：${item}`]),
    ...[...before].flatMap(([id, item]) => after.has(id) ? [] : [`- 不在了：${/^.*?实例 ID [^，\s]+/.exec(item)?.[0] ?? item}`]),
  ];
  if (!changes.length) return undefined;
  return bindContext(definition, { ...values, ...sceneValues<'thread.instances_changed'>({ 'instances.change': changes.join('\n') }),
    'workspace.instances': () => ({ text: current }) });
}
