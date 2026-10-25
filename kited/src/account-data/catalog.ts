/** 一台工作机的目录摘要：项目、检出与工作区，只有导航用的字段，不含会话、实例、插件配置和文件内容；随账号级数据在工作机之间同步。 */
import type { Checkout, Machine, Project, Workspace } from '../model.ts';

export interface CatalogSnapshot {
  machine: Machine;
  projects: Project[];
  checkouts: Checkout[];
  /** 同一工作区 ID 可能出现在几台工作机上，epoch 最高且未冻结的是当前宿主，其余为已流转的冻结记录。 */
  workspaces: Workspace[];
  /** 本机承载 Line 的工作区（Line 实例未归档、工作区开放）；账号下只有一个 Line，其他工作机启用前据此拒绝。 */
  line?: string;
}
