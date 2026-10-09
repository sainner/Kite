/** 配置入口共用能力声明；后端名称不进入 App 的编辑条件。模型目录随 SDK 升级手动维护，不在运行时向上游查询。 */
import type { AgentDefinition } from './definition.ts';
import { agentModels } from './models.ts';

const reasoning = ['low', 'medium', 'high', 'xhigh', 'max'];

export function configurationBoundary(runtime: AgentDefinition['runtime']) { return runtime === 'claude' ? 'idle' : 'request'; }

export function agentCapabilities(agent: AgentDefinition) {
  const models = (agent.runtime === 'claude' ? agentModels.claude : agentModels.models)
    .map((model) => ({ id: model.id, title: model.tier, name: model.name, maxContextWindow: model.maxContextWindow, reasoning }));
  return { models, tools: agent.tools, configurationBoundary: configurationBoundary(agent.runtime),
    toolCatalogBoundary: agent.runtime === 'claude' ? 'idle' : 'session' };
}
