/** 可序列化的组装定义：界面直接编辑这棵树，宿主只提供变量值，不在模板里执行代码。 */
import type { ContextScene } from './scenes.ts';

export type ContextPart =
  | { type: 'text'; text: string }
  | { type: 'variable'; name: string };

export interface ContextBranch {
  id: string;
  title: string;
  blocks: ContextBlock[];
}

export type ContextBlock =
  | { type: 'paragraph'; id: string; title: string; parts: ContextPart[] }
  | {
    type: 'condition'; id: string; title: string; variable: string;
    /** 按变量文本精确匹配；未命中时使用 otherwise。分支可递归嵌套。 */
    cases: Array<ContextBranch & { equals: string }>;
    otherwise: ContextBranch;
  };

export interface ContextDefinition {
  version: 2;
  id: string;
  title: string;
  scene: ContextScene;
  blocks: ContextBlock[];
  /** 需要独立输入材料的场景，与规则一同编辑和保存。 */
  input?: ContextBlock[];
}

export interface ContextBinding {
  text: string;
  /** 宿主提供的来源；文件内容已在 text 中，历史预览不重新读磁盘。 */
  sources?: Array<{ path: string; sha256: string }>;
}

export interface ContextSource {
  definition: ContextDefinition;
  bindings: Record<string, ContextBinding>;
}

export interface ContextSnapshot {
  /** 定义和变量值的内容摘要。同一份内容在会话中只保存一次。 */
  id: string;
  definition: ContextDefinition;
  bindings: Record<string, ContextBinding>;
}

export type ResolvedContextBlock =
  | {
    type: 'paragraph'; id: string; text: string;
    parts: Array<{ type: 'text'; text: string } | ({ type: 'variable'; name: string } & ContextBinding)>;
  }
  | { type: 'condition'; id: string; branchId: string; blocks: ResolvedContextBlock[] };

export interface ContextAssembly {
  instructions: string;
  input?: string;
  /** 定义保留全部页签，这里只记录实际选择的分支及 chip 的展开值。 */
  blocks: ResolvedContextBlock[];
  inputBlocks?: ResolvedContextBlock[];
  snapshot: ContextSnapshot;
}
