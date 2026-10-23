/** 内置插件和以后登记的插件共用定义目录；宿主从这里校验实例与视图。 */
import { KiteError } from '../errors.ts';
import type { AgentDefinition } from '../agents/definition.ts';
import { defaultContextDefinition } from '../harness/context/project.ts';
import { operationContracts, operationToolNames, type OperationName } from '../operations/contract.ts';
import { defaultAgentModel } from '../agents/models.ts';
import { monitorDefinitionId } from '../monitor/monitors.ts';
import { terminalDefinitionId } from '../terminal/terminals.ts';
import { previewDefinitionId } from '../preview/state.ts';
import { filesDefinitionId } from '../workspace/files.ts';

export interface PluginDefinition {
  id: string;
  title: string;
  /** 一句话的用途，创建实例时显示；只有内置定义有。 */
  description?: string;
  /** window 随窗口回收；persistent 独立存续，不用时归档；process 进程运行中独立存续，结束后没有窗口就回收。 */
  lifetime: 'window' | 'persistent' | 'process';
  views: { id: string; title: string; renderer: string; resourceUri?: string }[];
  defaultView: string;
  agent?: AgentDefinition;
  runtime?: 'bun';
  revision?: string;
  operations: OperationName[];
}

export const agentDefinitionId = 'kite.agent';

type AgentTool = AgentDefinition['tools'][number];
const operationTitle = (tool: AgentTool) => Object.values(operationContracts).find((contract) => contract.tool === tool)?.title ?? tool;

/** 代理插件声明的全部工具，带界面上的名称与分组；角色和代理配置按组列出，顺序即界面顺序。协作工具的名称取自操作声明。 */
export const agentToolCatalog: { name: AgentTool; title: string; group: string }[] = [
  { name: 'read', title: '读取文件', group: '文件与命令' },
  { name: 'skill', title: '加载 skill', group: '文件与命令' },
  { name: 'patch', title: '修改文件', group: '文件与命令' },
  { name: 'shell', title: '运行命令', group: '文件与命令' },
  { name: 'terminal_list', title: operationTitle('terminal_list'), group: '文件与命令' },
  { name: 'terminal_read', title: operationTitle('terminal_read'), group: '文件与命令' },
  { name: 'terminal_stop', title: operationTitle('terminal_stop'), group: '文件与命令' },
  { name: 'preview_open', title: operationTitle('preview_open'), group: '预览' },
  { name: 'preview_action', title: operationTitle('preview_action'), group: '预览' },
  { name: 'preview_inspect', title: operationTitle('preview_inspect'), group: '预览' },
  { name: 'preview_read', title: operationTitle('preview_read'), group: '预览' },
  { name: 'preview_list', title: operationTitle('preview_list'), group: '预览' },
  { name: 'preview_stop', title: operationTitle('preview_stop'), group: '预览' },
  { name: 'credentials', title: '列出密钥引用', group: '凭据' },
  { name: 'question', title: '向用户提问', group: '用户交接' },
  ...operationToolNames.filter((name) => !name.startsWith('terminal_') && !name.startsWith('preview_'))
    .map((name) => ({ name, title: operationTitle(name), group: name.startsWith('monitor_') ? '监视' : '代理协作' })),
  { name: 'line_status', title: '查看全部工作区', group: '个人 agent' },
  { name: 'line_handle', title: '代处理收件箱', group: '个人 agent' },
  { name: 'line_relay', title: '转达用户的话', group: '个人 agent' },
  { name: 'line_control', title: '管理线程', group: '个人 agent' },
  { name: 'line_workspace', title: '创建与流转工作区', group: '个人 agent' },
];

/** 代理插件声明的全部工具，是角色、项目约束与实例配置逐层筛选的全集。 */
export const agentTools: AgentDefinition['tools'] = agentToolCatalog.map(({ name }) => name);

/** 定义上的 agent 只标明这是代理插件；提示词、工具规则与默认模型由角色决定。 */
const agent: AgentDefinition = {
  runtime: 'harness', model: { model: defaultAgentModel, reasoning: 'medium' },
  tools: agentTools, context: defaultContextDefinition,
};

const definitions: PluginDefinition[] = [
  { id: agentDefinitionId, title: '代理', description: '与 agent 协作', lifetime: 'persistent', defaultView: 'conversation',
    agent, operations: ['agent.send', 'agent.resume', 'agent.stop', 'agent.merge'], views: [{ id: 'conversation', title: '代理窗口', renderer: 'conversation' }] },
  /** 看工作区的文件、本工作区运行中的网页和互联网，见 workspace/files.ts 的 pageSchema。 */
  { id: filesDefinitionId, title: '浏览', description: '查看文件、运行中的网页和互联网', lifetime: 'window', defaultView: 'files', operations: ['files.list', 'files.search', 'files.read', 'files.diff', 'files.state', 'files.select'], views: [
    { id: 'files', title: '浏览', renderer: 'files' },
  ] },
  /** 一个实例一个 PTY 会话，见 terminal/terminals.ts。 */
  { id: terminalDefinitionId, title: '终端', description: '在工作目录执行命令', lifetime: 'process', defaultView: 'terminal',
    operations: ['terminal.read', 'terminal.stop'], views: [{ id: 'terminal', title: '终端', renderer: 'terminal' }] },
  /** 一个实例是一种目标跑起来的全部进程加画面，见 preview/previews.ts；输出视图就是终端画面。 */
  { id: previewDefinitionId, title: '预览', description: '运行项目的预览目标并查看', lifetime: 'process', defaultView: 'screen',
    operations: ['preview.select', 'preview.action', 'preview.inspect', 'preview.read', 'preview.stop'], views: [
      { id: 'screen', title: '画面', renderer: 'preview' }, { id: 'grid', title: '并排', renderer: 'preview-grid' }, { id: 'output', title: '输出', renderer: 'terminal' },
    ] },
  /** 由代理的 monitor_start 或启用 Line 时由宿主创建，界面不能直接新建；Line 的那个视图就是收件箱。 */
  { id: monitorDefinitionId, title: '监视', lifetime: 'persistent', defaultView: 'timeline',
    operations: ['monitor.stop', 'monitor.read', 'monitor.delegate', 'monitor.dismiss', 'monitor.hosting'],
    views: [{ id: 'timeline', title: '时间线', renderer: 'monitor' }] },
];

export const pluginDefinitions = (): readonly PluginDefinition[] => structuredClone(definitions);

export function pluginDefinition(id: string): PluginDefinition {
  const definition = definitions.find((d) => d.id === id);
  if (!definition) throw new KiteError(`没有这个插件定义：${id}`, 404);
  return structuredClone(definition);
}

export function pluginView(definitionId: string, viewId: string): PluginDefinition['views'][number] {
  const view = pluginDefinition(definitionId).views.find((v) => v.id === viewId);
  if (!view) throw new KiteError(`插件未声明这个视图：${viewId}`);
  return view;
}
