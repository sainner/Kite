/** 请求配置快照保存实际设置和工具声明；不会保存模型对象、执行闭包或凭据。 */
import { createHash } from 'node:crypto';
import { z } from 'zod';
import { executionGrantsSchema } from '../execution/grants.ts';
import { pluginToolSourceSchema } from '../plugins/tools.ts';
import { contextSnapshotSchema, restoreContext } from './context/assembler.ts';
import type { RequestSettings, RequestSnapshot, ThreadNotification, ToolDefinition } from './types.ts';

const name = z.string().min(1);
const digest = z.string().regex(/^[a-f0-9]{64}$/);
export const requestSettingsSchema: z.ZodType<RequestSettings> = z.object({
  execution: z.object({ revision: digest, grants: executionGrantsSchema }).strict().optional(),
  model: z.object({ model: name, reasoning: name }).strict().optional(),
  maxRequestsPerTurn: z.number().int().positive().optional(),
  contextWindow: z.number().int().positive().optional(),
  agent: z.object({ definitionId: name, revision: digest }).strict().optional(),
  allowedTools: z.array(name).optional(),
  pluginTools: z.array(pluginToolSourceSchema).optional(),
}).strict();
export const notificationSchema: z.ZodType<ThreadNotification> = z.object({
  id: name, sequence: z.number().int().positive().optional(), kind: name, source: name,
  authority: z.enum(['instruction', 'observation']), context: contextSnapshotSchema,
}).strict().superRefine((notification, ctx) => {
  // 在消费输入和推进投递游标之前，确认选中的分支可以完整还原。
  try {
    if (!restoreContext(notification.context).instructions.length) {
      ctx.addIssue({ code: 'custom', message: '通知正文不能为空' });
    }
  } catch (error) {
    ctx.addIssue({ code: 'custom', message: `通知上下文无法还原：${String(error)}` });
  }
});
const configurationSchema = z.object({
  settings: requestSettingsSchema,
  tools: z.array(z.object({ name, description: z.string(), parameters: z.record(z.string(), z.json()) }).strict()),
}).strict();
const hash = (configuration: z.infer<typeof configurationSchema>) =>
  createHash('sha256').update(JSON.stringify(configuration)).digest('hex');

export function requestSnapshot(settings: RequestSettings, tools: ToolDefinition[]): RequestSnapshot {
  const configuration = configurationSchema.parse({ settings, tools });
  return { id: hash(configuration), ...configuration };
}

export const requestSnapshotSchema: z.ZodType<RequestSnapshot> = configurationSchema.extend({ id: digest })
  .refine(({ settings, tools, id }) => id === hash({ settings, tools }), { message: '请求配置摘要不匹配' });
