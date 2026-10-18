/** 共用的模型能力清单；maxContextWindow 是最大能力，不代表某次运行采用的窗口。 */
import catalog from '../../../shared/agent-models.json';
import type { RuntimeKind } from '../model.ts';

export const agentModels = catalog;
export const defaultAgentModel = catalog.models.find((model) => model.tier === catalog.defaultTier)!.id;

/**
 * 界面只按厂商分类模型；Claude 受政策限制只能经 Claude Code 订阅使用，其余厂商都由自研 harness 执行。
 * login 是工作机上运行这家模型要的登录，对应环境检查里的 logins。
 */
export const modelVendors = [
  { id: 'openai', title: 'OpenAI', runtime: 'harness', login: 'chatgpt', models: catalog.models },
  { id: 'anthropic', title: 'Anthropic', runtime: 'claude', login: 'claude', models: catalog.claude },
  { id: 'deepseek', title: 'DeepSeek', runtime: 'harness', login: 'deepseek', models: catalog.deepseek },
] as const satisfies readonly { id: string; title: string; runtime: RuntimeKind; login: string; models: readonly unknown[] }[];

export type ModelVendor = typeof modelVendors[number];

/** 目录里收了这个模型的厂商；不在目录里时为 undefined。 */
export function catalogVendor(model: string): ModelVendor | undefined {
  return modelVendors.find((vendor) => vendor.models.some((entry) => entry.id === model));
}

/** 目录外的模型（如环境变量覆盖）按 OpenAI 处理。 */
export const vendorOfModel = (model: string): ModelVendor => catalogVendor(model) ?? modelVendors[0];

/** 后端由所选模型的厂商推出。 */
export const runtimeOfModel = (model: string): RuntimeKind => vendorOfModel(model).runtime;
