/** 内置插件和以后登记的插件共用定义目录；宿主从这里校验实例与视图。 */
import { KiteError } from '../errors.ts';
import type { AgentDefinition } from '../agents/definition.ts';
import { defaultContextDefinition } from '../harness/context/project.ts';
import { operationContracts, operationToolNames, type OperationName } from '../operations/contract.ts';
import type { ExecutionGrants } from '../execution/grants.ts';
import { defaultAgentModel } from '../agents/models.ts';

export interface PluginDefinition {
  id: string;
  title: string;
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
  ...operationToolNames.map((name) => ({ name, title: operationTitle(name), group: '代理协作' })),
];

/** 代理插件声明的全部工具，是角色、项目约束与实例配置逐层筛选的全集。 */
export const agentTools: AgentDefinition['tools'] = agentToolCatalog.map(({ name }) => name);

/** 定义上的 agent 只标明这是代理插件；提示词、工具规则与默认模型由角色决定。 */
const agent: AgentDefinition = {
  runtime: 'harness', model: { model: defaultAgentModel, reasoning: 'medium' },
  tools: agentTools, context: defaultContextDefinition, maxRequestsPerTurn: 50,
};

const definitions: PluginDefinition[] = [
  { id: agentDefinitionId, title: '代理', lifetime: 'persistent', defaultView: 'conversation',
    execution: { workspace: 'write', read: [], write: [], network: [] },
    agent, operations: ['agent.send', 'agent.resume', 'agent.stop'], views: [{ id: 'conversation', title: '代理窗口', renderer: 'conversation' }] },
  { id: 'kite.files', title: '文件', lifetime: 'window', defaultView: 'files', operations: ['files.list', 'files.read', 'files.diff', 'files.state', 'files.select'], views: [
    { id: 'files', title: '文件', renderer: 'files' },
  ] },
  { id: 'kite.terminal', title: '终端', lifetime: 'window', defaultView: 'terminal', operations: [], views: [{ id: 'terminal', title: '终端', renderer: 'terminal' }] },
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
