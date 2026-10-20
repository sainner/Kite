/** agent 配置绑定到实例；定义目录更新不会改写已有实例的配置。 */
import { createHash } from 'node:crypto';
import { z } from 'zod';
import { KiteError } from '../errors.ts';
import { contextDefinitionSchema } from '../harness/context/assembler.ts';
import { runtimeOfModel } from './models.ts';
import type { PluginInstance } from '../model.ts';
import { lineToolNames, operationToolNames } from '../operations/contract.ts';

export const agentDefinitionSchema = z.object({
  runtime: z.enum(['harness', 'claude']),
  model: z.object({ model: z.string().trim().min(1), reasoning: z.string().trim().min(1) }).strict(),
  tools: z.array(z.enum(['read', 'patch', 'shell', 'credentials', 'question', ...operationToolNames, ...lineToolNames])).refine((tools) => new Set(tools).size === tools.length, '工具名重复'),
  context: contextDefinitionSchema.refine((context) => context.scene === 'thread.create', '基础上下文须使用 thread.create 场景'),
}).strict();
export type AgentDefinition = z.infer<typeof agentDefinitionSchema>;

export function parseAgentDefinition(value: unknown): AgentDefinition {
  const parsed = agentDefinitionSchema.safeParse(value);
  if (!parsed.success) throw new KiteError(`agent 配置无效：${parsed.error.issues.map((issue) => issue.message).join('；')}`);
  return parsed.data;
}

export function bindAgentDefinition(definition: AgentDefinition): AgentDefinition {
  const bound = parseAgentDefinition(definition);
  bound.model.model = (bound.runtime === 'claude' ? process.env.KITE_CLAUDE_MODEL : process.env.KITE_MODEL) ?? bound.model.model;
  return parseAgentDefinition(bound);
}

export const claudeReasoning = ['default', 'low', 'medium', 'high', 'xhigh', 'max'];

/** 换用指定模型，后端随模型的厂商确定；Claude 的思考强度另有档位。 */
export function chooseAgentModel(agent: AgentDefinition, model?: AgentDefinition['model']): AgentDefinition {
  const chosen = parseAgentDefinition({ ...agent, ...(model ? { model, runtime: runtimeOfModel(model.model) } : {}) });
  if (chosen.runtime === 'claude' && !claudeReasoning.includes(chosen.model.reasoning)) throw new KiteError('Claude 思考强度无效');
  return chosen;
}

export const agentRevision = (agent: AgentDefinition): string =>
  createHash('sha256').update(JSON.stringify(agent)).digest('hex');

export function instanceAgent(instance: PluginInstance): AgentDefinition {
  return parseAgentDefinition(instance.config.agent);
}
