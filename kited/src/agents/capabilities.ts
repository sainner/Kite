/** 配置入口共用能力声明；界面按厂商分组模型，后端由模型推出。模型目录随 SDK 升级手动维护，不在运行时向上游查询。 */
import type { RuntimeKind } from '../model.ts';
import { agentToolCatalog } from '../plugins/definitions.ts';
import { modelVendors, supportsFast } from './models.ts';

export const reasoningLevels = ['low', 'medium', 'high', 'xhigh', 'max'];

export function configurationBoundary(runtime: RuntimeKind) { return runtime === 'claude' ? 'idle' : 'request'; }

/** fast 表示能开快速模式，见 supportsFast。 */
export const agentModelCatalog = () => ({
  vendors: modelVendors.map(({ id, title }) => ({ id, title })),
  models: modelVendors.flatMap((vendor) => vendor.models.map((model) => ({ id: model.id, title: model.tier, name: model.name,
    maxContextWindow: model.maxContextWindow, reasoning: reasoningLevels, fast: supportsFast(model.id), vendor: vendor.id }))),
});

/** tools 是代理能开的全部工具，defaults 是角色给的默认，required 不能关，blocked 是正被项目禁用的；toolCatalog 给出界面名称与分组。 */
export function agentCapabilities(runtime: RuntimeKind, tools: { allowed: string[]; defaults: string[]; required: string[]; blocked: string[] }) {
  return { ...agentModelCatalog(), tools: tools.allowed, defaults: tools.defaults, required: tools.required, blocked: tools.blocked, toolCatalog: agentToolCatalog,
    configurationBoundary: configurationBoundary(runtime),
    toolCatalogBoundary: runtime === 'claude' ? 'idle' : 'session' };
}
