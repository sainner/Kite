/** 宿主登记的 MCP 工具快照；模型名称绑定实例，权限仍在每次调用时核验。 */
import { createHash } from 'node:crypto';
import type { Tool as McpTool } from '@modelcontextprotocol/client';
import { z } from 'zod';
import type { PluginInstance } from './model.ts';
import type { OperationGrant } from './operation-contract.ts';
import { KiteError } from './errors.ts';

const digest = z.string().regex(/^[a-f0-9]{64}$/);
export const pluginToolSourceSchema = z.object({
  modelName: z.string().regex(/^[a-zA-Z0-9_-]{1,64}$/), instanceId: z.string().min(1), toolName: z.string().min(1),
  packageRevision: digest, toolRevision: digest,
}).strict();
const bindingSchema = pluginToolSourceSchema.extend({ description: z.string(), parameters: z.record(z.string(), z.json()) }).strict();
const bindingsSchema = z.array(bindingSchema);
const uiSchema = z.object({ visibility: z.array(z.enum(['model', 'app'])).optional() }).passthrough();
export type PluginToolBinding = z.infer<typeof bindingSchema>;
export type PluginToolSource = z.infer<typeof pluginToolSourceSchema>;
export function pluginToolSource({ modelName, instanceId, toolName, packageRevision, toolRevision }: PluginToolBinding): PluginToolSource {
  return { modelName, instanceId, toolName, packageRevision, toolRevision };
}
export const pluginToolBindings = (instance: PluginInstance): PluginToolBinding[] => bindingsSchema.parse(instance.config.pluginTools ?? []);
export const toolRevision = (tool: McpTool): string => createHash('sha256').update(JSON.stringify(tool)).digest('hex');

export function toolVisible(tool: McpTool, audience: 'model' | 'app'): boolean {
  const ui = uiSchema.safeParse(tool._meta?.ui ?? {});
  return ui.success && (ui.data.visibility === undefined || ui.data.visibility.includes(audience));
}

export function bindPluginTool(instance: PluginInstance, tool: McpTool): PluginToolBinding {
  const packageRevision = digest.parse(instance.config.packageRevision);
  const revision = toolRevision(tool);
  const identity = createHash('sha256').update(JSON.stringify([instance.id, tool.name, packageRevision, revision])).digest('hex').slice(0, 24);
  return bindingSchema.parse({ instanceId: instance.id, toolName: tool.name, packageRevision, toolRevision: revision,
    modelName: `plugin_${identity}_${tool.name.replace(/[^a-zA-Z0-9_-]/g, '_').slice(0, 24)}`,
    description: `插件实例 ${instance.title}（${instance.id}）的 ${tool.name}。${tool.description ?? ''}`, parameters: tool.inputSchema });
}

export function pluginToolGranted(binding: Pick<PluginToolBinding, 'instanceId' | 'toolName'>, grants: OperationGrant[]): boolean {
  return grants.some((grant) => grant.operation === 'plugin.call' && grant.instanceId === binding.instanceId && grant.tools.includes(binding.toolName));
}

/** 旧声明保留在目录里；撤回授权只改变请求允许的工具子集。 */
export function mergePluginTools(previous: PluginToolBinding[], selected: PluginToolBinding[], frozen: boolean): PluginToolBinding[] {
  if (!frozen) return selected;
  if (selected.some((binding) => !previous.some((old) => old.modelName === binding.modelName))) {
    throw new KiteError('会话已经固定工具声明；添加或更换插件工具请创建新会话', 409);
  }
  return previous;
}
