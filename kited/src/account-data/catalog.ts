/** 一台工作机的目录摘要：项目、检出与工作区，只有导航用的字段，不含会话、窗口、插件配置和文件内容；随账号级数据在工作机之间同步。 */
import type { Checkout, Machine, Project, Workspace } from '../model.ts';

export interface CatalogSnapshot {
  machine: Machine;
  projects: Project[];
  checkouts: Checkout[];
  /** 同一工作区 ID 可能出现在几台工作机上，epoch 最高且未冻结的是当前宿主，其余为已流转的冻结记录。 */
  workspaces: Workspace[];
}
