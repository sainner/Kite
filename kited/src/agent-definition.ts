/** agent 配置绑定到实例；定义目录更新不会改写已有实例的配置。 */
import { createHash } from 'node:crypto';
import { z } from 'zod';
import { KiteError } from './errors.ts';
import { contextDefinitionSchema } from './harness/context/assembler.ts';
import type { PluginInstance, Workspace } from './model.ts';
import { operationToolNames } from './operation-contract.ts';
import type { ContextDefinition } from './harness/context/types.ts';

export const agentDefinitionSchema = z.object({
  runtime: z.literal('harness'),
  model: z.object({ model: z.string().trim().min(1), reasoning: z.string().trim().min(1) }).strict(),
  tools: z.array(z.enum(['read', 'patch', 'shell', ...operationToolNames])).refine((tools) => new Set(tools).size === tools.length, '工具名重复'),
  context: contextDefinitionSchema.refine((context) => context.scene === 'thread.create', '基础上下文须使用 thread.create 场景'),
  maxRequestsPerTurn: z.number().int().positive(),
}).strict();
export type AgentDefinition = z.infer<typeof agentDefinitionSchema>;

export function parseAgentDefinition(value: unknown): AgentDefinition {
  const parsed = agentDefinitionSchema.safeParse(value);
  if (!parsed.success) throw new KiteError(`agent 配置无效：${parsed.error.issues.map((issue) => issue.message).join('；')}`);
  return parsed.data;
}

export function bindAgentDefinition(definition: AgentDefinition, kind: Workspace['kind']): AgentDefinition {
  const bound = parseAgentDefinition(definition);
  bound.model.model = process.env.KITE_MODEL ?? bound.model.model;
  bound.context = bindAgentContext(bound.context, kind);
  return parseAgentDefinition(bound);
}

export function bindAgentContext(definition: ContextDefinition, kind: Workspace['kind']): ContextDefinition {
  const context = contextDefinitionSchema.parse(definition);
  if (kind === 'worktree') context.blocks.push({
    type: 'paragraph', id: 'worktree', title: '工作树边界', parts: [{ type: 'text',
      text: '当前目录是 Kite 为这个工作区创建的独立工作树，请在这里完成工作，不要切回主文件夹修改。Kite 在工具批次和回合结束后保存快照，由用户决定采纳或回退。不要自行删除工作树或分支。' }],
  });
  return contextDefinitionSchema.parse(context);
}

export const agentRevision = (agent: AgentDefinition): string =>
  createHash('sha256').update(JSON.stringify(agent)).digest('hex');

export function instanceAgent(instance: PluginInstance): AgentDefinition {
  return parseAgentDefinition(instance.config.agent);
}
