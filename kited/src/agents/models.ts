/** 共用的模型能力清单；maxContextWindow 是最大能力，不代表某次运行采用的窗口。 */
import catalog from '../../../shared/agent-models.json';
import type { RuntimeKind } from '../model.ts';

export const agentModels = catalog;
export const defaultAgentModel = catalog.models.find((model) => model.tier === catalog.defaultTier)!.id;

/** 界面只按厂商分类模型；Claude 受政策限制只能经 Claude Code 订阅使用，其余厂商都由自研 harness 执行。 */
export const modelVendors = [
  { id: 'openai', title: 'OpenAI', runtime: 'harness', models: catalog.models },
  { id: 'anthropic', title: 'Anthropic', runtime: 'claude', models: catalog.claude },
] as const satisfies readonly { id: string; title: string; runtime: RuntimeKind; models: readonly unknown[] }[];

/** 后端由所选模型推出；目录外的模型（如环境变量覆盖）按自研 harness 处理。 */
export function runtimeOfModel(model: string): RuntimeKind {
  return catalog.claude.some((entry) => entry.id === model) ? 'claude' : 'harness';
}
