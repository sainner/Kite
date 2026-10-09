/** 配置入口共用能力声明；界面按厂商分组模型，后端由模型推出。模型目录随 SDK 升级手动维护，不在运行时向上游查询。 */
import type { RuntimeKind } from '../model.ts';
import { modelVendors } from './models.ts';

const reasoning = ['low', 'medium', 'high', 'xhigh', 'max'];

export function configurationBoundary(runtime: RuntimeKind) { return runtime === 'claude' ? 'idle' : 'request'; }

export const agentModelCatalog = () => ({
  vendors: modelVendors.map(({ id, title }) => ({ id, title })),
  models: modelVendors.flatMap((vendor) => vendor.models.map((model) => ({ id: model.id, title: model.tier, name: model.name,
    maxContextWindow: model.maxContextWindow, reasoning, vendor: vendor.id }))),
});

/** tools 是这个代理可开的工具（角色规则内），required 是角色必需、不能关闭的，blocked 是其中正被项目约束禁用的。 */
export function agentCapabilities(runtime: RuntimeKind, tools: { allowed: string[]; required: string[]; blocked: string[] }) {
  return { ...agentModelCatalog(), tools: tools.allowed, required: tools.required, blocked: tools.blocked, configurationBoundary: configurationBoundary(runtime),
    toolCatalogBoundary: runtime === 'claude' ? 'idle' : 'session' };
}
