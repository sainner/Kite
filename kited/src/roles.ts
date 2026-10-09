/** 角色：代理的提示词、工具约束、默认模型与预算。创建代理时拷贝进实例配置，之后修改角色不影响已有代理。 */
import { createHash } from 'node:crypto';
import { z } from 'zod';
import { agentDefinitionSchema, bindAgentDefinition, chooseAgentModel, claudeReasoning, type AgentDefinition } from './agents/definition.ts';
import { agentModels, defaultAgentModel, runtimeOfModel } from './agents/models.ts';
import { allTools, missingRequired, permittedTools, toolRuleSchema, type ToolRule } from './agents/tool-policy.ts';
import { KiteError } from './errors.ts';
import { contextDefinitionSchema } from './harness/context/assembler.ts';
import { defaultContextDefinition } from './harness/context/project.ts';
import type { ContextDefinition } from './harness/context/types.ts';
import type { PluginInstance, Workspace } from './model.ts';
import type { Store } from './store.ts';

export const roleSchema = z.object({
  version: z.literal(1),
  id: z.string().trim().min(1),
  title: z.string().trim().min(1),
  /** 提示词沿用创建会话场景的组装定义，ID 与名称随角色。 */
  context: contextDefinitionSchema,
  tools: toolRuleSchema,
  model: agentDefinitionSchema.shape.model,
  maxRequestsPerTurn: z.number().int().positive(),
}).strict();
export type Role = z.infer<typeof roleSchema>;
export interface RoleSnapshot { role: Role; revision: string }
export interface RoleSelection { id: string; revision: string }

export function roleSelection(value: unknown): RoleSelection | undefined {
  if (value === undefined) return undefined;
  const parsed = z.object({ id: z.string().min(1), revision: z.string().min(1) }).strict().safeParse(value);
  if (!parsed.success) throw new KiteError('角色选择须包含 id 和 revision');
  return parsed.data;
}

/** 实例配置里记下创建时的角色与它的工具规则，作为之后修改工具的上限。 */
export interface RoleBinding { id: string; revision: string; tools: ToolRule }
/** 草稿里可调的初始参数；工具与预算只能在角色允许的范围内收窄。 */
export interface RoleChoice { model?: AgentDefinition['model']; tools?: AgentDefinition['tools']; maxRequestsPerTurn?: number }

export const defaultRoleId = 'kite.work';

export function instanceRole(instance: PluginInstance): RoleBinding | undefined {
  return instance.config.role as RoleBinding | undefined;
}

/** universe 是代理插件声明的全部工具；以后项目约束作为另一层规则加入。 */
export function toolLimits(universe: readonly string[], rule: Pick<ToolRule, 'mode' | 'tools' | 'required'> = allTools) {
  const permitted = permittedTools(universe, [rule]);
  return { permitted, required: rule.required, missing: missingRequired(rule.required, permitted) };
}

export function checkTools(tools: readonly string[], limits: ReturnType<typeof toolLimits>): void {
  const extra = tools.filter((name) => !limits.permitted.includes(name));
  if (extra.length) throw new KiteError(`工具超出角色允许的范围：${extra.join('、')}`);
  const off = limits.required.filter((name) => !tools.includes(name));
  if (off.length) throw new KiteError(`不能关闭角色必需的工具：${off.join('、')}`);
}

/** 新代理的初始配置：角色给默认值，草稿的选择覆盖它们；后端由模型推出。 */
export function roleAgent(base: AgentDefinition, { role, revision }: RoleSnapshot, kind: Workspace['kind'], choice: RoleChoice = {}) {
  const limits = toolLimits(base.tools, role.tools);
  if (limits.missing.length) throw new KiteError(`角色「${role.title}」需要的工具不可用：${limits.missing.join('、')}`);
  // 有效集是代理插件声明工具的子集
  const tools = choice.tools ?? limits.permitted as AgentDefinition['tools'];
  checkTools(tools, limits);
  const agent = chooseAgentModel(bindAgentDefinition({ runtime: runtimeOfModel(role.model.model), model: role.model, tools,
    context: role.context, maxRequestsPerTurn: choice.maxRequestsPerTurn ?? role.maxRequestsPerTurn }, kind), choice.model);
  const binding: RoleBinding = { id: role.id, revision, tools: role.tools };
  return { agent, role: binding };
}
const defaultModel = { model: defaultAgentModel, reasoning: 'medium' };
const reviewTools: ToolRule = { mode: 'allow', tools: ['read'], required: ['read'] };
const reviewContext: ContextDefinition = { ...defaultContextDefinition, id: 'kite.review', title: '只读审查', blocks: [
  { type: 'paragraph', id: 'identity', title: '审查职责', parts: [{ type: 'text',
    text: '你是 Kite 的只读审查助手。使用简体中文，读取用户指定的文件，报告有证据的问题、影响与修改建议。当前只有 read 工具；需要目录或 diff 时请用户提供，不声称已执行修改或检查命令。' }] },
  ...defaultContextDefinition.blocks.filter((block) => ['environment', 'project-rules', 'documents'].includes(block.id)),
] };
const builtinRoles: Role[] = [
  { version: 1, id: defaultRoleId, title: defaultContextDefinition.title, context: defaultContextDefinition, tools: allTools,
    model: defaultModel, maxRequestsPerTurn: 50 },
  { version: 1, id: 'kite.review', title: reviewContext.title, context: reviewContext, tools: reviewTools, model: defaultModel, maxRequestsPerTurn: 50 },
];

const snapshot = (role: Role): RoleSnapshot => ({ role, revision: createHash('sha256').update(JSON.stringify(role)).digest('hex') });
/** 点阵签名只随提示词变化，改工具或模型不让签名过期。 */
export const contextRevision = (role: Role): string => createHash('sha256').update(JSON.stringify(role.context)).digest('hex');

export class Roles {
  /** universe 是代理插件声明的全部工具，角色的规则只能引用其中的名字。 */
  constructor(private store: Store, private universe: readonly string[]) {
    store.transaction(() => {
      // 创建会话模板改由角色承载：沿用模板 ID 与正文，点阵签名按 ID 保留。
      for (const definition of store.contextTemplates().filter((definition) => definition.scene === 'thread.create')) {
        // 默认模板旧名「工作会话」，代理不再称作会话。
        const title = definition.id === defaultRoleId && definition.title === '工作会话' ? defaultContextDefinition.title : definition.title;
        if (!store.role(definition.id)) store.saveRole(this.parse({ version: 1, id: definition.id, title, context: definition,
          tools: definition.id === 'kite.review' ? reviewTools : allTools, model: defaultModel, maxRequestsPerTurn: 50 }));
        store.deleteContextTemplate(definition.id);
      }
      for (const role of builtinRoles) if (!store.role(role.id)) store.saveRole(this.parse(role));
    });
  }

  list(): RoleSnapshot[] { return this.store.roles().map(snapshot); }

  get(id: string, revision?: string): RoleSnapshot {
    const role = this.store.role(id);
    if (!role) throw new KiteError('角色不存在，请刷新列表', 404);
    const value = snapshot(role);
    if (revision !== undefined && revision !== value.revision) throw new KiteError('角色已更新，请刷新后重新选择', 409);
    return value;
  }

  create(value: unknown): RoleSnapshot {
    const role = this.parse(value);
    return this.store.transaction(() => {
      const saved = this.store.role(role.id);
      if (saved && snapshot(saved).revision !== snapshot(role).revision) throw new KiteError('角色 ID 已存在，请另存为新角色', 409);
      if (!saved) this.store.saveRole(role);
      return snapshot(role);
    });
  }

  update(id: string, expectedRevision: string, value: unknown): RoleSnapshot {
    const role = this.parse(value);
    if (id !== role.id) throw new KiteError('角色 ID 与请求目标不一致');
    return this.store.transaction(() => {
      this.get(id, expectedRevision);
      this.store.saveRole(role);
      return snapshot(role);
    });
  }

  private parse(value: unknown): Role {
    const parsed = roleSchema.safeParse(value);
    if (!parsed.success) throw new KiteError(`角色无效：${parsed.error.issues.map((issue) => issue.message).join('；')}`);
    const role = parsed.data;
    if (role.context.scene !== 'thread.create') throw new KiteError('角色的提示词须使用创建会话场景');
    const unknown = [...role.tools.tools, ...role.tools.required].filter((name) => !this.universe.includes(name));
    if (unknown.length) throw new KiteError(`角色引用了不存在的工具：${unknown.join('、')}`);
    const excluded = missingRequired(role.tools.required, permittedTools(this.universe, [role.tools]));
    if (excluded.length) throw new KiteError(`必需工具被角色自己的规则排除了：${excluded.join('、')}`);
    if (![...agentModels.models, ...agentModels.claude].some((model) => model.id === role.model.model)) throw new KiteError('角色的默认模型不在模型目录中');
    if (runtimeOfModel(role.model.model) === 'claude' && !claudeReasoning.includes(role.model.reasoning)) throw new KiteError('Claude 思考强度无效');
    return { ...role, context: { ...role.context, id: role.id, title: role.title } };
  }
}
