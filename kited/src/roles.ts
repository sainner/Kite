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
import { agentTools } from './plugins/definitions.ts';
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

/** 项目约束里的工具规则，没有必需项。 */
export type ProjectToolRule = Pick<ToolRule, 'mode' | 'tools'>;

export const defaultRoleId = 'kite.work';
/** 代理插件声明的全部工具，角色的规则只能引用其中的名字。 */
const universe: readonly string[] = agentTools;

export function instanceRole(instance: PluginInstance): RoleBinding | undefined {
  return instance.config.role as RoleBinding | undefined;
}

/**
 * 角色规则从 universe 里决定实例能开的上限（allowed），写进实例配置；
 * 项目约束是实时过滤，不写进配置，收紧或放宽都立即作用于有效集（permitted），blocked 是被项目禁掉的那些。
 */
export function toolLimits(rule: Pick<ToolRule, 'mode' | 'tools' | 'required'> = allTools, project?: ProjectToolRule) {
  const allowed = permittedTools(universe, [rule]);
  const permitted = project ? permittedTools(allowed, [project]) : allowed;
  return { allowed, blocked: allowed.filter((name) => !permitted.includes(name)), required: rule.required,
    missing: missingRequired(rule.required, permitted) };
}

export function checkTools(tools: readonly string[], limits: ReturnType<typeof toolLimits>): void {
  const extra = tools.filter((name) => !limits.allowed.includes(name));
  if (extra.length) throw new KiteError(`工具超出角色允许的范围：${extra.join('、')}`);
  const off = limits.required.filter((name) => !tools.includes(name));
  if (off.length) throw new KiteError(`不能关闭角色必需的工具：${off.join('、')}`);
}

/** 新代理的初始配置：角色给默认值，草稿的选择覆盖它们；后端由模型推出。必需工具被项目约束禁用时角色不可用。 */
export function roleAgent({ role, revision }: RoleSnapshot, kind: Workspace['kind'], choice: RoleChoice = {}, project?: ProjectToolRule) {
  const limits = toolLimits(role.tools, project);
  if (limits.missing.length) throw new KiteError(`角色「${role.title}」需要的工具被项目约束禁用：${limits.missing.join('、')}`);
  // 角色允许的工具是代理插件声明工具的子集；被项目禁掉的也留在配置里，约束放宽后恢复。
  const tools = choice.tools ?? limits.allowed as AgentDefinition['tools'];
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
  /** 内置角色的默认内容。本机与账号只存自建的和改过的内置角色，没改过的跟随 kited 版本的默认。 */
  private readonly builtins: Map<string, Role>;

  constructor(private store: Store) {
    this.builtins = new Map(builtinRoles.map((role) => [role.id, this.parse(role)]));
    store.transaction(() => {
      for (const role of store.roles()) if (this.isDefault(role)) store.deleteRole(role.id);
    });
  }

  list(): RoleSnapshot[] {
    const ids = new Set([...this.builtins.keys(), ...this.store.roles().map((role) => role.id)]);
    return [...ids].sort().map((id) => snapshot(this.current(id)!));
  }

  /** 账号里拉来的版本直接替换本机缓存；内容不合本机契约的跳过，返回是否有变化。 */
  cache(value: unknown): boolean {
    const role = this.parse(value);
    const saved = this.current(role.id);
    if (saved && snapshot(saved).revision === snapshot(role).revision) return false;
    this.save(role);
    return true;
  }

  /** 账号里已经没有的从缓存去掉，内置角色退回默认；返回是否有变化。 */
  keep(ids: ReadonlySet<string>): boolean {
    const gone = this.store.roles().filter((role) => !ids.has(role.id));
    for (const role of gone) this.store.deleteRole(role.id);
    return gone.length > 0;
  }

  get(id: string, revision?: string): RoleSnapshot {
    const role = this.current(id);
    if (!role) throw new KiteError('角色不存在，请刷新列表', 404);
    const value = snapshot(role);
    if (revision !== undefined && revision !== value.revision) throw new KiteError('角色已更新，请刷新后重新选择', 409);
    return value;
  }

  /** role 已经过 parse。 */
  create(role: Role): RoleSnapshot {
    return this.store.transaction(() => {
      const saved = this.current(role.id);
      if (saved && snapshot(saved).revision !== snapshot(role).revision) throw new KiteError('角色 ID 已存在，请另存为新角色', 409);
      if (!saved) this.store.saveRole(role);
      return snapshot(role);
    });
  }

  /** 修改前的校验，结果先写到账号服务再存本机。 */
  validate(id: string, expectedRevision: string, value: unknown): Role {
    const role = this.parse(value);
    if (id !== role.id) throw new KiteError('角色 ID 与请求目标不一致');
    this.get(id, expectedRevision);
    return role;
  }

  /** role 已经过 validate；写账号期间账号推来的同步可能已更新本机缓存，事务里再核对一次版本，已是这次的内容就不再核对。 */
  update(expectedRevision: string, role: Role): RoleSnapshot {
    return this.store.transaction(() => {
      const value = snapshot(role);
      if (this.get(role.id).revision !== value.revision) {
        this.get(role.id, expectedRevision);
        this.save(role);
      }
      return value;
    });
  }

  private current(id: string): Role | undefined { return this.store.role(id) ?? this.builtins.get(id); }

  /** 改回与默认一样的内置角色不算改过，不留副本。 */
  private save(role: Role) {
    if (this.isDefault(role)) this.store.deleteRole(role.id);
    else this.store.saveRole(role);
  }

  private isDefault(role: Role): boolean {
    const builtin = this.builtins.get(role.id);
    return !!builtin && snapshot(builtin).revision === snapshot(role).revision;
  }

  parse(value: unknown): Role {
    const parsed = roleSchema.safeParse(value);
    if (!parsed.success) throw new KiteError(`角色无效：${parsed.error.issues.map((issue) => issue.message).join('；')}`);
    const role = parsed.data;
    if (role.context.scene !== 'thread.create') throw new KiteError('角色的提示词须使用创建会话场景');
    const unknown = [...role.tools.tools, ...role.tools.required].filter((name) => !universe.includes(name));
    if (unknown.length) throw new KiteError(`角色引用了不存在的工具：${unknown.join('、')}`);
    const excluded = missingRequired(role.tools.required, permittedTools(universe, [role.tools]));
    if (excluded.length) throw new KiteError(`必需工具被角色自己的规则排除了：${excluded.join('、')}`);
    if (![...agentModels.models, ...agentModels.claude].some((model) => model.id === role.model.model)) throw new KiteError('角色的默认模型不在模型目录中');
    if (runtimeOfModel(role.model.model) === 'claude' && !claudeReasoning.includes(role.model.reasoning)) throw new KiteError('Claude 思考强度无效');
    return { ...role, context: { ...role.context, id: role.id, title: role.title } };
  }
}
