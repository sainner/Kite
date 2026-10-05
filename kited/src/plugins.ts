/** 内置插件和以后登记的插件共用定义目录；宿主从这里校验实例与视图。 */
import { KiteError } from './errors.ts';
import type { AgentDefinition } from './agent-definition.ts';
import { defaultContextDefinition } from './harness/context/project.ts';
import { operationToolNames, type OperationName } from './operation-contract.ts';
import type { ExecutionGrants } from './execution-grants.ts';
import { defaultAgentModel } from './agent-models.ts';

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

const coding: AgentDefinition = {
  runtime: 'harness', model: { model: defaultAgentModel, reasoning: 'medium' },
  tools: ['read', 'patch', 'shell', ...operationToolNames], context: defaultContextDefinition, maxRequestsPerTurn: 50,
};
const review: AgentDefinition = {
  ...coding, tools: ['read'], context: { ...defaultContextDefinition, id: 'kite.review', title: '只读审查', blocks: [
    { type: 'paragraph', id: 'identity', title: '审查职责', parts: [{ type: 'text',
      text: '你是 Kite 的只读审查助手。使用简体中文，读取用户指定的文件，报告有证据的问题、影响与修改建议。当前只有 read 工具；需要目录或 diff 时请用户提供，不声称已执行修改或检查命令。' }] },
    ...defaultContextDefinition.blocks.filter((block) => ['environment', 'project-rules', 'documents'].includes(block.id)),
  ] },
};

const definitions: PluginDefinition[] = [
  { id: 'kite.agent.coding', title: '代理', lifetime: 'persistent', defaultView: 'conversation',
    execution: { workspace: 'write', read: [], write: [], network: [] },
    agent: coding, operations: ['agent.send', 'agent.resume', 'agent.stop'], views: [{ id: 'conversation', title: '会话', renderer: 'conversation' }] },
  { id: 'kite.agent.review', title: '只读审查', lifetime: 'persistent', defaultView: 'conversation',
    execution: { workspace: 'read', read: [], write: [], network: [] },
    agent: review, operations: ['agent.send', 'agent.resume', 'agent.stop'], views: [{ id: 'conversation', title: '会话', renderer: 'conversation' }] },
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
