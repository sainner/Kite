/** 场景及可用变量的唯一目录。这里只描述契约；触发、取值和投递由业务调用方负责。说明给编辑器显示，写清变量里是什么、什么时候为空。 */
export const contextScenes = {
  'thread.title': {
    title: '生成会话标题',
    variables: [
      { name: 'thread.title', title: '当前标题', description: '会话现在的标题，写成带引号的 JSON 字符串；还没有标题时是 ""。' },
      { name: 'thread.messages', title: '近期对话正文', description: '近三天里最多 20 轮的请求和回复末尾，代码块略去，JSON 格式。' },
    ],
  },
  'thread.compact': {
    title: '压缩上下文',
    variables: [
      { name: 'compaction.range', title: '压缩范围', description: '这次压缩覆盖的对话，如「从会话开头到现在」。只在摘要指令里有值，摘要包装里为空。' },
      { name: 'compaction.summary', title: '摘要正文', description: '模型写好的摘要。只在摘要包装里有值，摘要指令里为空。' },
    ],
  },
  'template.emblem': {
    title: '生成点阵签名',
    variables: [
      { name: 'template.title', title: '角色名称', description: '要设计签名的角色名称。' },
      { name: 'template.content', title: '角色提示词', description: '角色提示词的提纲：每段以【段落名称】开头，变量写成 {变量标识}，条件列出各分支；最多 6000 字，没有内容时是「（空）」。' },
    ],
  },
  'thread.plugin_tools_changed': {
    title: '插件工具授权变更',
    variables: [{ name: 'plugin.tools', title: '当前获准的插件工具', description: '已授权的插件工具及目标实例，JSON 格式；全部撤回时是 []。' }],
  },
  'thread.create': {
    title: '创建会话',
    variables: [
      { name: 'environment.cwd', title: '工作目录', description: '代理工作目录的真实路径。' },
      { name: 'environment.date', title: '当前日期（UTC）', description: '请求时的 UTC 日期，如 2026-01-31。' },
      { name: 'project.documents', title: '项目规则与记忆索引', description: '从仓库根目录到工作目录逐级找到的 AGENTS.md 与 .kite/memory/MEMORY.md 全文，由外到内；一个都没有时为空。' },
    ],
  },
  'thread.file_changes': {
    title: '会话中文件变化',
    variables: [
      { name: 'files.changes', title: '变化文件列表', description: '被压缩的那段对话期间有净变化的文件和增减行数。' },
      { name: 'files.origin', title: '变化来源', description: '一句话说明变化来自谁，如包括 agent 自己与其他来源的改动。' },
    ],
  },
  'thread.configuration_changed': {
    title: '会话配置变更',
    variables: [
      { name: 'agent.revision', title: '配置版本', description: '新配置的版本号。' },
      { name: 'agent.model', title: '模型', description: '当前模型的标识。' },
      { name: 'agent.reasoning', title: '推理强度', description: '当前推理强度。' },
      { name: 'agent.tools', title: '允许的工具', description: '允许的工具名称，用顿号分隔；一个都没有时是「无」。' },
      { name: 'agent.max_requests_per_turn', title: '回合请求预算', description: '每回合最多发几次模型请求。' },
    ],
  },
  'thread.context_updated': {
    title: '基础上下文更新',
    variables: [{ name: 'context.instructions', title: '更新后的基础上下文', description: '重新组装的完整基础正文，替代先前发过的那份。' }],
  },
  'thread.execution_permissions_changed': {
    title: '执行授权变更',
    variables: [
      { name: 'execution.revision', title: '授权版本', description: '新执行授权的版本号。' },
      { name: 'execution.grants', title: '当前执行授权', description: '工作目录、额外读写路径与网络访问的当前授权，JSON 格式。' },
    ],
  },
} as const;

export type ContextScene = keyof typeof contextScenes;
export type ContextVariable<S extends ContextScene> = (typeof contextScenes)[S]['variables'][number]['name'];
