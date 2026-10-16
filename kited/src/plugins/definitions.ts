/** 内置插件和以后登记的插件共用定义目录；宿主从这里校验实例与视图。 */
import { KiteError } from '../errors.ts';
import type { AgentDefinition } from '../agents/definition.ts';
import { defaultContextDefinition } from '../harness/context/project.ts';
import { operationContracts, operationToolNames, type OperationName } from '../operations/contract.ts';
import type { ExecutionGrants } from '../execution/grants.ts';
import { defaultAgentModel } from '../agents/models.ts';
import { monitorDefinitionId } from '../monitor/monitors.ts';

export interface PluginDefinition {
  id: string;
  title: string;
  /** 一句话的用途，创建实例时显示；只有内置定义有。 */
  description?: string;
  lifetime: 'window' | 'persistent';
  views: { id: string; title: string; renderer: string; resourceUri?: string }[];
  defaultView: string;
  agent?: AgentDefinition;
  runtime?: 'bun';
  revision?: string;
  execution?: ExecutionGrants;
  operations: OperationName[];
}

export const agentDefinitionId = 'kite.agent';

type AgentTool = AgentDefinition['tools'][number];
const operationTitle = (tool: AgentTool) => Object.values(operationContracts).find((contract) => contract.tool === tool)?.title ?? tool;

/** 代理插件声明的全部工具，带界面上的名称与分组；角色和代理配置按组列出，顺序即界面顺序。协作工具的名称取自操作声明。 */
export const agentToolCatalog: { name: AgentTool; title: string; group: string }[] = [
  { name: 'read', title: '读取文件', group: '文件与命令' },
  { name: 'patch', title: '修改文件', group: '文件与命令' },
  { name: 'shell', title: '运行命令', group: '文件与命令' },
  { name: 'credentials', title: '列出密钥引用', group: '凭据' },
  { name: 'question', title: '向用户提问', group: '用户交接' },
  ...operationToolNames.map((name) => ({ name, title: operationTitle(name), group: name.startsWith('monitor_') ? '监视' : '代理协作' })),
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
  tools: agentTools, context: defaultContextDefinition, maxRequestsPerTurn: 50,
};

const definitions: PluginDefinition[] = [
  { id: agentDefinitionId, title: '代理', description: '与 agent 协作', lifetime: 'persistent', defaultView: 'conversation',
    execution: { workspace: 'write', read: [], write: [], network: [] },
    agent, operations: ['agent.send', 'agent.resume', 'agent.stop'], views: [{ id: 'conversation', title: '代理窗口', renderer: 'conversation' }] },
  { id: 'kite.files', title: '文件', description: '预览工作区文件', lifetime: 'window', defaultView: 'files', operations: ['files.list', 'files.search', 'files.read', 'files.diff', 'files.state', 'files.select'], views: [
    { id: 'files', title: '文件', renderer: 'files' },
  ] },
  { id: 'kite.terminal', title: '终端', description: '在工作目录执行命令', lifetime: 'window', defaultView: 'terminal', operations: [], views: [{ id: 'terminal', title: '终端', renderer: 'terminal' }] },
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
