/** 场景及可用变量的唯一目录。这里只描述契约；触发、取值和投递由业务调用方负责。 */
export const contextScenes = {
  'thread.title': {
    title: '生成会话标题',
    variables: [
      { name: 'thread.title', title: '当前标题' },
      { name: 'thread.messages', title: '近期对话正文' },
    ],
  },
  'thread.plugin_tools_changed': {
    title: '插件工具授权变更',
    variables: [{ name: 'plugin.tools', title: '当前获准的插件工具' }],
  },
  'thread.create': {
    title: '创建会话',
    variables: [
      { name: 'environment.cwd', title: '工作目录' },
      { name: 'environment.date', title: '当前日期（UTC）' },
      { name: 'project.documents', title: '项目规则与记忆索引' },
    ],
  },
  'thread.file_changes': {
    title: '会话中文件变化',
    variables: [
      { name: 'files.changes', title: '变化文件列表' },
      { name: 'files.origin', title: '变化来源' },
    ],
  },
  'thread.configuration_changed': {
    title: '会话配置变更',
    variables: [
      { name: 'agent.revision', title: '配置版本' },
      { name: 'agent.model', title: '模型' },
      { name: 'agent.reasoning', title: '推理强度' },
      { name: 'agent.tools', title: '允许的工具' },
      { name: 'agent.max_requests_per_turn', title: '回合请求预算' },
    ],
  },
  'thread.context_updated': {
    title: '基础上下文更新',
    variables: [{ name: 'context.instructions', title: '更新后的基础上下文' }],
  },
  'thread.execution_permissions_changed': {
    title: '执行授权变更',
    variables: [
      { name: 'execution.revision', title: '授权版本' },
      { name: 'execution.grants', title: '当前执行授权' },
    ],
  },
} as const;

export type ContextScene = keyof typeof contextScenes;
export type ContextVariable<S extends ContextScene> = (typeof contextScenes)[S]['variables'][number]['name'];
