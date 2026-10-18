/**
 * 公共变量与场景的唯一目录。这里只描述契约；触发、取值和投递由业务调用方负责。说明给编辑器显示，写清变量里是什么、什么时候为空、什么时候变化。
 * 公共变量按层分，开放某一层的场景都能引用该层全部变量，含义与格式处处一致；场景专有变量是某种用途才有的材料。
 * input 的场景模板分指令与材料两部分，其他场景只有正文。
 */

/**
 * 公共变量只收变化不频繁的状态：基础上下文每次请求重新组装，正文一变就追加整份更新。
 * 随工具批次变化的（未提交改动、diff、检查结果、快照、排队输入）不放这里，由工具按需读取。
 */
export const contextLayers = {
  environment: {
    title: '环境',
    variables: [
      { name: 'environment.date', title: '当前日期（UTC）', description: '取值时的 UTC 日期，如 2026-01-31；每天变化。' },
      { name: 'machine.name', title: '工作机', description: '工作机的名称；工作区流转到别的工作机后变化。' },
    ],
  },
  project: {
    title: '项目',
    variables: [
      { name: 'project.name', title: '项目名称', description: '项目的名称。' },
      { name: 'project.remote', title: '项目远程', description: '项目远程仓库的归一化地址，如 github.com/owner/repo；仓库迁移后变化。' },
      { name: 'project.rules', title: '项目规则', description: '从仓库根目录到工作目录逐级找到的 AGENTS.md 全文，由外到内，每份前面注明路径；一个都没有时为空，文件修改后变化。' },
      { name: 'project.memory', title: '记忆索引', description: '从仓库根目录到工作目录逐级找到的 .kite/memory/MEMORY.md 全文，由外到内，每份前面注明路径；一个都没有时为空，文件修改后变化。' },
    ],
  },
  workspace: {
    title: '工作区',
    variables: [
      { name: 'environment.cwd', title: '工作目录', description: '代理工作目录的真实路径；工作区流转到别的工作机后可能变化。' },
      { name: 'workspace.name', title: '工作区名称', description: '工作区的名称。' },
      { name: 'workspace.branch', title: '当前分支', description: '工作目录当前所在的分支；分离 HEAD 或不在 Git 仓库里时为空，切换分支后变化。' },
    ],
  },
  agent: {
    title: '代理',
    variables: [
      { name: 'agent.title', title: '会话标题', description: '会话现在的标题，纯文本；生成新标题或改名后变化。' },
      { name: 'agent.role', title: '角色', description: '创建代理时所选角色的名称；之后修改角色不影响。' },
      { name: 'agent.model', title: '模型', description: '当前模型的标识；修改配置后变化。' },
      { name: 'agent.reasoning', title: '推理强度', description: '当前推理强度；修改配置后变化。' },
      { name: 'agent.tools', title: '允许的工具', description: '允许的工具名称，已按项目约束过滤，用顿号分隔；一个都没有时是「无」，修改配置或项目约束后变化。' },
      { name: 'agent.max_requests_per_turn', title: '回合请求预算', description: '每回合最多发几次模型请求；修改配置后变化。' },
      { name: 'execution.grants', title: '执行授权', description: '工作目录、额外读写路径与网络访问的当前授权，JSON 格式；修改执行授权后变化。' },
      { name: 'plugin.tools', title: '插件工具', description: '已授权的插件工具及目标实例，JSON 格式；全部撤回时是 []，修改授权后变化。' },
    ],
  },
} as const;

const allLayers = ['environment', 'project', 'workspace', 'agent'] as const;

/** 场景的 layers 是开放的公共变量层；取不到某一层的场景不开放该层，不用空值代替。 */
export const contextScenes = {
  'thread.title': {
    title: '生成会话标题',
    input: true,
    layers: allLayers,
    variables: [
      { name: 'title.current', title: '当前标题', description: '会话现在的标题，写成带引号的 JSON 字符串；还没有标题时是 ""。' },
      { name: 'title.messages', title: '近期对话正文', description: '近三天里最多 20 轮的请求和回复末尾，代码块略去，JSON 格式。' },
    ],
  },
  'workspace.pull_request': {
    title: '起草 PR',
    input: true,
    // 集成是工作区的操作，没有某个代理。
    layers: ['environment', 'project', 'workspace'],
    variables: [
      { name: 'pull_request.commits', title: '提交说明', description: '工作区分支相对远程主线的提交说明，每条以「- 」开头，合并提交略去；最多 6000 字。' },
      { name: 'pull_request.files', title: '改动文件', description: '相对远程主线改动的文件与增减行数（git diff --stat）；最多 6000 字。' },
    ],
  },
  'workspace.naming': {
    title: '生成工作区名称',
    input: true,
    // 名字概括的是几个代理，不属于其中某一个。
    layers: ['environment', 'project', 'workspace'],
    variables: [
      { name: 'naming.current', title: '当前名称', description: '工作区现在的名称，写成带引号的 JSON 字符串。' },
      { name: 'naming.agents', title: '各代理的标题', description: '工作区里用户开的各个代理（不含别的代理起的子代理）现在的标题，按创建先后排，JSON 字符串数组。' },
    ],
  },
  'thread.compact': {
    title: '压缩上下文',
    input: true,
    layers: allLayers,
    variables: [
      { name: 'compaction.range', title: '压缩范围', description: '这次压缩覆盖的对话，如「从会话开头到现在」。只在摘要指令里有值，摘要包装里为空。' },
      { name: 'compaction.summary', title: '摘要正文', description: '模型写好的摘要。只在摘要包装里有值，摘要指令里为空。' },
    ],
  },
  'thread.voice': {
    title: '语音识别',
    input: true,
    // 新会话还没有线程，只有环境层取得到。
    layers: ['environment'],
    variables: [
      { name: 'voice.messages', title: '近期对话', description: '最近的请求和回复，每段以「用户：」或「agent：」开头、空行分隔，代码不略去，从最近往前取到 6000 字；新会话还没有对话时为空。' },
    ],
  },
  'template.emblem': {
    title: '生成点阵签名',
    input: true,
    // 面向资源库里的角色，没有工作区和代理。
    layers: ['environment'],
    variables: [
      { name: 'template.title', title: '角色名称', description: '要设计签名的角色名称。' },
      { name: 'template.content', title: '角色提示词', description: '角色提示词的提纲：每段以【段落名称】开头，变量写成 {变量标识}，条件列出各分支；最多 6000 字，没有内容时是「（空）」。' },
    ],
  },
  'thread.plugin_tools_changed': {
    title: '插件工具授权变更',
    layers: allLayers,
    variables: [],
  },
  'thread.create': {
    title: '创建会话',
    layers: allLayers,
    variables: [],
  },
  'thread.file_changes': {
    title: '会话中文件变化',
    layers: allLayers,
    variables: [
      { name: 'files.changes', title: '变化文件列表', description: '被压缩的那段对话期间有净变化的文件和增减行数。' },
      { name: 'files.origin', title: '变化来源', description: '一句话说明变化来自谁，如包括 agent 自己与其他来源的改动。' },
    ],
  },
  'thread.configuration_changed': {
    title: '会话配置变更',
    layers: allLayers,
    variables: [{ name: 'agent.revision', title: '配置版本', description: '新配置的版本号。' }],
  },
  'thread.context_updated': {
    title: '基础上下文更新',
    layers: allLayers,
    variables: [{ name: 'context.instructions', title: '更新后的基础上下文', description: '重新组装的完整基础正文，替代先前发过的那份。' }],
  },
  'line.monitor': {
    title: 'Line 的唤醒',
    layers: allLayers,
    variables: [
      { name: 'monitor.delegated', title: '交给 Line 的事项', description: '用户点了代处理或托管中交给 Line 的收件箱事项，每项一段：方括号里是事项 ID，写明工作机、项目、线程，审批带工具、目标与原因，提问带问题与选项；没有时为空。' },
      { name: 'monitor.results', title: 'Line 发起的工作的结果', description: 'Line 发过说明或创建的线程结束了回合或失败，每行一条；没有时为空。' },
      { name: 'monitor.briefing', title: '回来时的简报', description: '用户离开够久后回到 Kite 时有值：离开多久、要写简报的要求，以及离开期间进收件箱的事项；其余时候为空。' },
    ],
  },
  'monitor.events': {
    title: 'monitor 的事件',
    layers: allLayers,
    variables: [
      { name: 'monitor.title', title: '监视的标题', description: '代理开 monitor 时写的标题，说明在盯什么。' },
      { name: 'monitor.id', title: 'monitor 的实例 ID', description: '用 monitor_stop 停掉它时用的 ID。' },
      { name: 'monitor.events', title: '新事件', description: '还没交给代理的事件，每条一行，带时刻；来源结束的事件写明原因。至少一条。' },
    ],
  },
  'terminal.exit': {
    title: '后台命令结束',
    layers: allLayers,
    variables: [
      { name: 'terminal.title', title: '命令的说明', description: '转到后台的命令在 shell 工具里写的 description。' },
      { name: 'terminal.id', title: '终端的实例 ID', description: '后台终端的实例 ID，结束时没有窗口就已回收。' },
      { name: 'terminal.result', title: '结果', description: '退出码，被停下时是停下的原因。' },
      { name: 'terminal.output', title: '输出的末尾', description: '最后约 3000 个字符的输出；没有输出时写明。' },
    ],
  },
  'thread.execution_permissions_changed': {
    title: '执行授权变更',
    layers: allLayers,
    variables: [{ name: 'execution.revision', title: '授权版本', description: '新执行授权的版本号。' }],
  },
} as const;

export type ContextScene = keyof typeof contextScenes;
export type ContextLayer = keyof typeof contextLayers;
/** 场景专有变量。 */
export type ContextVariable<S extends ContextScene> = (typeof contextScenes)[S]['variables'][number]['name'];
export type PublicVariable = (typeof contextLayers)[ContextLayer]['variables'][number]['name'];
export type LayerVariable<L extends ContextLayer> = (typeof contextLayers)[L]['variables'][number]['name'];

export interface SceneVariable { name: string; title: string; description: string; group: string; layer?: ContextLayer }

/** 场景可引用的全部变量：专有变量在前，公共变量按层排在后面；group 是编辑器分组显示的名称，公共变量另带所在的层。 */
export function sceneVariables(scene: ContextScene): SceneVariable[] {
  const { variables, layers } = contextScenes[scene];
  return [
    ...variables.map((variable) => ({ ...variable, group: '场景材料' })),
    ...layers.flatMap((layer) => contextLayers[layer].variables.map((variable) => ({ ...variable, group: contextLayers[layer].title, layer }))),
  ];
}

export const isPublicVariable = (name: string): name is PublicVariable =>
  Object.values(contextLayers).some((layer) => layer.variables.some((variable) => variable.name === name));
