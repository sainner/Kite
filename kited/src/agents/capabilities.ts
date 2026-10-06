/** 配置入口共用能力声明；后端名称不进入 App 的编辑条件。 */
import type { AgentDefinition } from './definition.ts';
import { agentModels } from './models.ts';
import { claudeModels } from '../claude/capabilities.ts';

export function configurationBoundary(runtime: AgentDefinition['runtime']) { return runtime === 'claude' ? 'idle' : 'request'; }

export async function agentCapabilities(agent: AgentDefinition, cwd: string) {
  const models = agent.runtime === 'claude' ? await claudeModels(cwd)
    : agentModels.models.map((model) => ({ id: model.id, title: model.tier, reasoning: ['low', 'medium', 'high', 'xhigh', 'max'] }));
  return { models, tools: agent.tools, configurationBoundary: configurationBoundary(agent.runtime),
    toolCatalogBoundary: agent.runtime === 'claude' ? 'idle' : 'session' };
}
