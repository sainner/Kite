/** App、工作机和独立终端共用的模型清单；每个等级只列当前选定版本。 */
import catalog from '../../../shared/agent-models.json';

export const agentModels = catalog;
export const defaultAgentModel = catalog.models.find((model) => model.tier === catalog.defaultTier)!.id;
