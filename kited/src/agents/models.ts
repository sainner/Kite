/** App、工作机和独立终端共用的模型清单；每个等级只列当前选定版本。 */
import catalog from '../../../shared/agent-models.json';

export const agentModels = catalog;
export const defaultAgentModel = catalog.models.find((model) => model.tier === catalog.defaultTier)!.id;

/** 请求使用的上下文窗口；Claude 消息记录的是实际型号（如 claude-opus-5-5），按档位前缀对应。 */
export function contextWindow(model: string): number | undefined {
  return (catalog.models.find((entry) => entry.id === model)
    ?? catalog.claude.find((entry) => entry.id === model || model.startsWith(`claude-${entry.tier}-`)))?.contextWindow;
}
