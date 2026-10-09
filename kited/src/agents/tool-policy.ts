/**
 * 工具的逐层约束：每层要么是白名单（只准这些），要么是黑名单（除这些外都准）。
 * 有效集 = 全集 ∩ 各层白名单 − 各层黑名单之并，禁止优先，与层的顺序无关。
 */
import { z } from 'zod';

export const toolRuleSchema = z.object({
  mode: z.enum(['allow', 'deny']),
  tools: z.array(z.string().trim().min(1)),
  /** 角色离不开的工具；被其他层去掉时这个角色不可选。 */
  required: z.array(z.string().trim().min(1)),
}).strict().refine((rule) => new Set(rule.tools).size === rule.tools.length && new Set(rule.required).size === rule.required.length, '工具名重复');
export type ToolRule = z.infer<typeof toolRuleSchema>;

export const allTools: ToolRule = { mode: 'deny', tools: [], required: [] };

export const ruleAllows = (rule: Pick<ToolRule, 'mode' | 'tools'>, name: string): boolean => (rule.mode === 'allow') === rule.tools.includes(name);

export function permittedTools(universe: readonly string[], rules: readonly Pick<ToolRule, 'mode' | 'tools'>[]): string[] {
  return universe.filter((name) => rules.every((rule) => ruleAllows(rule, name)));
}

/** 必需工具中不在有效集里的那些；非空即角色在这一处不可用。 */
export function missingRequired(required: readonly string[], permitted: readonly string[]): string[] {
  return required.filter((name) => !permitted.includes(name));
}
