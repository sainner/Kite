/** 共用的模型能力清单；maxContextWindow 是最大能力，不代表某次运行采用的窗口。 */
import catalog from '../../../shared/agent-models.json';

export const agentModels = catalog;
export const defaultAgentModel = catalog.models.find((model) => model.tier === catalog.defaultTier)!.id;
