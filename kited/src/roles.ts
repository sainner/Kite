/** 角色：代理的提示词、工具约束、默认模型与预算。创建代理时拷贝进实例配置，之后修改角色不影响已有代理。 */
import { z } from 'zod';
import { agentDefinitionSchema, bindAgentDefinition, chooseAgentModel, claudeReasoning, type AgentDefinition } from './agents/definition.ts';
import { defaultAgentModel, modelVendors, runtimeOfModel } from './agents/models.ts';
import { allTools, missingRequired, permittedTools, toolRuleSchema, type ToolRule } from './agents/tool-policy.ts';
import { revisionOf } from './account-data/store.ts';
import { KiteError } from './errors.ts';
import { contextDefinitionSchema } from './harness/context/assembler.ts';
import { defaultContextDefinition } from './harness/context/project.ts';
import type { ContextDefinition } from './harness/context/types.ts';
import type { PluginInstance } from './model.ts';
import { agentTools } from './plugins/definitions.ts';
import { lineToolNames } from './operations/contract.ts';
import { approvalModes, bindRoleExecution, defaultApprovalMode, executionChangesSchema, type ApprovalMode } from './execution/grants.ts';
import type { Store } from './store.ts';

export const roleSchema = z.object({
  version: z.literal(1),
  id: z.string().trim().min(1),
  title: z.string().trim().min(1),
  /** 提示词沿用创建会话场景的组装定义，ID 与名称随角色。 */
  context: contextDefinitionSchema,
  tools: toolRuleSchema,
  /** 执行授权在项目基础上的增减，新建代理时拷进实例。 */
  execution: executionChangesSchema.optional(),
  /** 新建代理的默认审批模式，项目上限仍然适用；不设时跟随工作机的默认。 */
  approval: z.enum(approvalModes).optional(),
  model: agentDefinitionSchema.shape.model,
  maxRequestsPerTurn: z.number().int().positive(),
}).strict();
export type Role = z.infer<typeof roleSchema>;
/** defaultRevision 只有内置角色有，是默认内容的版本；与 revision 不同就是改过，可以恢复默认。 */
export interface RoleSnapshot { role: Role; revision: string; defaultRevision?: string }
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
export interface RoleChoice { model?: AgentDefinition['model']; tools?: AgentDefinition['tools']; maxRequestsPerTurn?: number; approval?: ApprovalMode }

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

/** 实例可以开角色没给的工具（项目约束另作实时过滤），但不能关闭角色必需的工具。 */
export function checkTools(tools: readonly string[], limits: ReturnType<typeof toolLimits>): void {
  const unknown = tools.filter((name) => !universe.includes(name));
  if (unknown.length) throw new KiteError(`代理插件没有这些工具：${unknown.join('、')}`);
  const off = limits.required.filter((name) => !tools.includes(name));
  if (off.length) throw new KiteError(`不能关闭角色必需的工具：${off.join('、')}`);
}

/** 新代理的初始配置：角色给默认值，草稿的选择覆盖它们；后端由模型推出。必需工具被项目约束禁用时角色不可用。 */
export function roleAgent({ role, revision }: RoleSnapshot, choice: RoleChoice = {}, project?: ProjectToolRule) {
  const limits = toolLimits(role.tools, project);
  if (limits.missing.length) throw new KiteError(`角色「${role.title}」需要的工具被项目约束禁用：${limits.missing.join('、')}`);
  // 角色允许的工具是代理插件声明工具的子集；被项目禁掉的也留在配置里，约束放宽后恢复。
  const tools = choice.tools ?? limits.allowed as AgentDefinition['tools'];
  checkTools(tools, limits);
  const agent = chooseAgentModel(bindAgentDefinition({ runtime: runtimeOfModel(role.model.model), model: role.model, tools,
    context: role.context, maxRequestsPerTurn: choice.maxRequestsPerTurn ?? role.maxRequestsPerTurn }), choice.model);
  const binding: RoleBinding = { id: role.id, revision, tools: role.tools };
  // 审批模式依次取草稿的选择、角色的默认、工作机的默认，解析好写进实例，App 照实例配置显示。
  const approval = choice.approval ?? role.approval ?? defaultApprovalMode;
  return { agent, role: binding, ...(role.execution ? { execution: bindRoleExecution(role.execution) } : {}), approval };
}
const defaultModel = { model: defaultAgentModel, reasoning: 'medium' };
const reviewTools: ToolRule = { mode: 'allow', tools: ['read'], required: ['read'] };
const reviewContext: ContextDefinition = { ...defaultContextDefinition, id: 'kite.review', title: '只读审查', blocks: [
  { type: 'paragraph', id: 'identity', title: '审查职责', parts: [{ type: 'text',
    text: '你是 Kite 的只读审查助手。使用简体中文，读取用户指定的文件，报告有证据的问题、影响与修改建议。只审查不修改；需要的材料工具拿不到时（如目录或 diff）请用户提供，不声称执行过修改或检查。' }] },
  ...defaultContextDefinition.blocks.filter((block) => ['environment', 'references', 'project-rules', 'worktree-boundary', 'rules', 'memory'].includes(block.id)),
] };
export const lineRoleId = 'kite.line';
const lineTools: ToolRule = { mode: 'allow', tools: ['read', 'patch', 'question', 'monitor_start', 'monitor_list', 'monitor_stop', ...lineToolNames], required: ['line_status'] };
const lineContext: ContextDefinition = { ...defaultContextDefinition, id: lineRoleId, title: 'Line', blocks: [
  { type: 'paragraph', id: 'identity', title: 'Line 的职责', parts: [{ type: 'text', text: [
    '你是 Line，用户的个人 agent，统一协调账号下各项目的工作区，减少用户巡视进度、搬运上下文、转发问答和记挂事项的负担。使用简体中文。',
    '你不亲自写代码、做研究或跑测试，这些交给各项目里的代理。',
    '- 轮到用户的事（等用户回应的审批和提问、用户离开期间结束的回合、失败）由宿主汇集在用户的收件箱里，用户直接处理；只有用户点了代处理或开了托管，事项才交给你。',
    '- 做判断前先用 line_status 核对最新状态。',
    '- 交给你的事项按用户的习惯处理：审批批准或拒绝，提问替用户回答；回合结束的读最后的回复，做完了给用户一句总结，代理在回复里提了问题就替用户回答，只是进度汇报就清掉；失败的能处理就处理，否则留给用户。拿不准的留给用户并写明原因。',
    '- 需要用户知道或决定的事写在你的回复里，说清是哪台工作机、哪个项目、哪个线程的什么事。',
    '- 停止、归档、创建、流转要用户批准，用户拒绝时不要换别的办法绕过。',
    '- 要记挂的事用 monitor_start 约个时刻醒来（用户设定的每日巡视也这样约），要盯着某件事就开一个命令来源的 monitor。一句「收到」不收尾任何事：集成、推送、归档仍是各自的显式操作。',
    '- 你的记忆以用户为中心，在本项目的 .kite/memory/ 下：用户的偏好、做决定的习惯、各项目的轻重缓急、以前怎么处理过类似的事项，以及每次代处理的决定与理由。各项目的专业经验留在项目自己的记忆里，你不收集。用 read 和 patch 维护。',
  ].join('\n') }] },
  ...defaultContextDefinition.blocks.filter((block) => ['environment', 'project-rules', 'rules', 'memory'].includes(block.id)),
] };
const builtinRoles: Role[] = [
  // 工作角色不带 Line 的管理工具：它们的目标范围是整个账号。
  { version: 1, id: defaultRoleId, title: defaultContextDefinition.title, context: defaultContextDefinition,
    tools: { mode: 'deny', tools: [...lineToolNames], required: [] }, model: defaultModel, maxRequestsPerTurn: 50 },
  { version: 1, id: 'kite.review', title: reviewContext.title, context: reviewContext, tools: reviewTools, model: defaultModel, maxRequestsPerTurn: 50 },
  { version: 1, id: lineRoleId, title: 'Line', context: lineContext, tools: lineTools, model: defaultModel, maxRequestsPerTurn: 30 },
];

const snapshot = (role: Role): RoleSnapshot => ({ role, revision: revisionOf(role) });
/** 点阵签名只随提示词变化，改工具或模型不让签名过期。 */
export const contextRevision = (role: Role): string => revisionOf(role.context);

export class Roles {
  /**
   * 内置角色的默认内容。账号只存自建的和改过的内置角色，没改过的跟随 kited 版本的默认；
   * 本机缓存是账号的镜像，账号里有的才存，写账号时据此给出期望的版本。
   */
  private readonly builtins: Map<string, Role>;

  constructor(private store: Store) {
    this.builtins = new Map(builtinRoles.map((role) => [role.id, this.parse(role)]));
  }

  list(): RoleSnapshot[] {
    const ids = new Set([...this.builtins.keys(), ...this.store.roles().map((role) => role.id)]);
    return [...ids].sort().map((id) => this.entry(this.current(id)!));
  }

  /** 账号里拉来的版本直接替换本机缓存，等于默认的也照存；内容不合本机契约的跳过。返回看到的内容是否有变化。 */
  cache(value: unknown): boolean {
    const role = this.parse(value);
    const stored = this.store.role(role.id);
    if (stored && snapshot(stored).revision === snapshot(role).revision) return false;
    const before = this.current(role.id);
    this.store.saveRole(role);
    return !before || snapshot(before).revision !== snapshot(role).revision;
  }

  /** 账号里这一项的版本：本机缓存是账号的镜像，没有缓存副本的内置角色在账号里也没有，是 null。 */
  accountRevision(id: string): string | null {
    const stored = this.store.role(id);
    return stored ? snapshot(stored).revision : null;
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
    const value = this.entry(role);
    if (revision !== undefined && revision !== value.revision) throw new KiteError('角色已更新，请刷新后重新选择', 409);
    return value;
  }

  /** 内置角色的默认内容，恢复默认时按它保存。 */
  builtin(id: string): Role {
    const role = this.builtins.get(id);
    if (!role) throw new KiteError('自建角色没有默认内容');
    return role;
  }

  /** 新建前的校验，结果先写进账号级数据再存本机：内置角色只能修改，同 ID 已有不同内容时冲突，相同内容重复保存是幂等的。 */
  validateNew(value: unknown): Role {
    const role = this.parse(value);
    if (this.builtins.has(role.id)) throw new KiteError('内置角色不能新建，请直接修改', 409);
    this.assertNew(role);
    return role;
  }

  /** role 已经过 validateNew；写账号期间同 ID 的角色可能已经同步过来，事务里再核对一次。 */
  create(role: Role): RoleSnapshot {
    return this.store.transaction(() => {
      this.assertNew(role);
      this.store.saveRole(role);
      return this.entry(role);
    });
  }

  /** 修改前的校验，结果先写进账号级数据再存本机。 */
  validate(id: string, expectedRevision: string, value: unknown): Role {
    const role = this.parse(value);
    if (id !== role.id) throw new KiteError('角色 ID 与请求目标不一致');
    this.get(id, expectedRevision);
    return role;
  }

  /**
   * role 已经过 validate，账号里已写入或删掉；写账号期间账号推来的同步可能已更新本机缓存，事务里再核对一次版本，
   * 已是这次的内容就不再核对。本机缓存随账号：等于默认的已从账号删掉，本机也不留。
   */
  update(expectedRevision: string, role: Role): RoleSnapshot {
    return this.store.transaction(() => {
      const value = this.entry(role);
      if (this.get(role.id).revision !== value.revision) this.get(role.id, expectedRevision);
      if (this.isDefault(role)) this.store.deleteRole(role.id);
      else this.store.saveRole(role);
      return value;
    });
  }

  /** 和默认内容一样的内置角色不算改过，账号里不留副本。 */
  isDefault(role: Role): boolean {
    const builtin = this.builtins.get(role.id);
    return !!builtin && snapshot(builtin).revision === snapshot(role).revision;
  }

  private assertNew(role: Role): void {
    const stored = this.store.role(role.id);
    if (stored && snapshot(stored).revision !== snapshot(role).revision) throw new KiteError('角色 ID 已存在，请另存为新角色', 409);
  }

  private current(id: string): Role | undefined { return this.store.role(id) ?? this.builtins.get(id); }

  private entry(role: Role): RoleSnapshot {
    const builtin = this.builtins.get(role.id);
    return { ...snapshot(role), ...(builtin ? { defaultRevision: snapshot(builtin).revision } : {}) };
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
    if (!modelVendors.some((vendor) => vendor.models.some((model) => model.id === role.model.model))) throw new KiteError('角色的默认模型不在模型目录中');
    if (runtimeOfModel(role.model.model) === 'claude' && !claudeReasoning.includes(role.model.reasoning)) throw new KiteError('Claude 思考强度无效');
    return { ...role, context: { ...role.context, id: role.id, title: role.title } };
  }
}
