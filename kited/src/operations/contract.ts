/** 实例操作的公开声明；宿主与模型工具共用 schema，调用身份不属于参数。 */
import { z } from 'zod';
import { diffID, fileDiffSchema } from '../workspace/file-diffs.ts';
import { fileSelectionSchema, readFileArgs } from '../workspace/files.ts';

/**
 * Line 的管理动作与对应工具。停止、归档、创建、流转是必问动作，每次执行前等用户批准，见 line/tools.ts。
 * reply 是代处理收件箱与转达用户原话；自约唤醒用通用的 monitor_start。
 */
export const lineActions = ['status', 'reply', 'send', 'resume', 'stop', 'archive', 'create', 'transfer'] as const;
export type LineAction = (typeof lineActions)[number];
export const lineToolNames = ['line_status', 'line_handle', 'line_relay', 'line_control', 'line_workspace'] as const;
export const lineToolActions: Record<(typeof lineToolNames)[number], readonly LineAction[]> = {
  line_status: ['status'], line_handle: ['reply'], line_relay: ['reply'], line_control: ['send', 'resume', 'stop', 'archive'],
  line_workspace: ['create', 'transfer'],
};

const id = z.string().min(1);
const text = z.string().refine((value) => !!value.trim(), '内容不能为空');
export const inputVia = z.object({ kind: z.literal('line'), machine: id, instance: id }).strict();
const input = z.object({ id, text, source: z.enum(['human', 'kite']), via: inputVia.optional() }).strict();
const target = z.object({ operationId: id, instanceId: id }).strict();
const ok = z.object({ ok: z.literal(true) }).strict();
const summary = z.object({
  instanceId: id, definitionId: id, title: z.string(), role: z.object({ id, title: z.string() }).strict().nullable(), presentation: z.enum(['window', 'inline', 'background']),
  status: z.enum(['open', 'archived']), phase: z.enum(['idle', 'running', 'stopping', 'finishing']),
  busy: z.boolean(), waitingForResume: z.boolean(), recovery: z.string().nullable(), operations: z.array(id),
}).strict();

export const operationContracts = {
  'plugin.call': {
    title: '调用插件工具', description: '调用同一工作区内获准的插件实例工具。模型使用宿主登记的具体工具声明。',
    tool: null, effect: 'write', retry: 'plugin',
    input: target.extend({ tool: id, arguments: z.record(z.string(), z.unknown()) }).strict(), output: z.unknown(),
  },
  'agent.start': {
    title: '创建 agent', description: '在当前工作区按角色创建 agent 实例。role 是角色 ID，省略时用默认角色 kite.work（工作）；内置的还有 kite.review（只读审查）。省略 prompt 只创建空会话；共享工作区已有线程运行时不能启动另一线程。默认不打开窗口，由用户从创建它的 agent 处查看；只在用户要求在界面上看着它时传 presentation: window。',
    tool: 'agent_start', effect: 'create', retry: 'receipt',
    input: z.object({ operationId: id, role: id.optional(), title: text.optional(), prompt: text.optional(),
      presentation: z.enum(['window', 'inline', 'background']).default('background') }).strict(),
    output: z.object({ instanceId: id, windowId: id.optional() }).strict(),
  },
  'agent.list': {
    title: '查询 agent', description: '查询当前工作区的 agent 实例、执行状态及获准操作；不会唤醒会话。',
    tool: 'agent_list', effect: 'read', retry: 'read',
    input: z.object({}).strict(), output: z.object({ agents: z.array(summary) }).strict(),
  },
  'agent.send': {
    title: '发送消息', description: '向获准的 agent 实例发送消息。消息落盘后返回；同一工作区的线程可以同时执行。',
    tool: 'agent_send', effect: 'write', retry: 'input',
    input: target.extend({ text }).strict(), output: z.object({ id }).strict(),
  },
  'agent.resume': {
    title: '继续执行', description: '继续获准的 agent 实例。需要恢复确认时拒绝执行；不会替用户确认未知的执行结果。',
    tool: 'agent_resume', effect: 'write', retry: 'receipt', input: target, output: ok,
  },
  'agent.stop': {
    title: '停止执行', description: '停止获准的 agent 实例，等待受管执行停止并返回未消费的输入。',
    tool: 'agent_stop', effect: 'write', retry: 'stop',
    input: target.extend({ inputs: z.array(input).optional() }).strict(), output: z.object({ returned: z.array(input) }).strict(),
  },
  'files.list': {
    title: '浏览目录', description: '读取文件实例所属工作区内的一层目录，按目录优先、名称排序并分页。',
    tool: null, effect: 'read', retry: 'read',
    input: z.object({ instanceId: id, path: id.default('.'), offset: z.number().int().min(0).default(0), limit: z.number().int().min(1).max(1000).default(200) }).strict(),
    output: z.object({ path: id, entries: z.array(z.object({ name: id, path: id, kind: z.enum(['file', 'directory', 'symlink', 'other']) }).strict()),
      total: z.number().int(), nextOffset: z.number().int().nullable() }).strict(),
  },
  'files.read': {
    title: '读取文本', description: '按行读取文件实例所属工作区内的文本，与 agent 的 read 使用同一文件服务。',
    tool: null, effect: 'read', retry: 'read', input: readFileArgs.extend({ instanceId: id }).strict(),
    output: z.object({ path: id, text: z.string(), offset: z.number().int(), totalLines: z.number().int(), nextOffset: z.number().int().nullable(), version: id }).strict(),
  },
  'files.diff': {
    title: '读取历史差异', description: '读取当前工作区某次修改保存的前后内容，不受当前文件变化影响。',
    tool: null, effect: 'read', retry: 'read',
    input: z.object({ instanceId: id, diffId: diffID }).strict(), output: fileDiffSchema,
  },
  'files.state': {
    title: '读取所选文件', description: '读取文件实例共享且持久的选中文件。',
    tool: null, effect: 'read', retry: 'read', input: z.object({ instanceId: id }).strict(), output: fileSelectionSchema,
  },
  'files.select': {
    title: '选择预览文件', description: '选择工作区内的文本文件，供这个实例的所有预览窗口使用；不修改文件内容。',
    tool: null, effect: 'write', retry: 'receipt',
    input: target.extend({ expectedRevision: id, path: id.nullable(), diffId: diffID.optional() }).strict(), output: fileSelectionSchema,
  },
  'monitor.start': {
    title: '开始监视', description: [
      '开一个常驻的 monitor 盯着某件事，有事件时宿主把它们合成一条消息交给你，你空闲时开始新回合，运行中在下一次请求纳入。title 简短写清在盯什么，会出现在每次唤醒里。',
      '两种来源选一种：command 是 shell 命令，每一行标准输出是一个事件，200 毫秒内的几行合成一个，命令退出也是一个事件并结束这个来源；at（带时区的 ISO 8601 时间）或 minutes（多少分钟后）是定时，repeat 为 daily 或 weekly 时按天或按周重复。',
      '命令在你的沙箱里、按你的执行授权运行，越界直接拒绝，不能用密钥。只输出你会据此行动的行，成功和失败的信号都要覆盖（没有输出不等于成功）；grep 加 --line-buffered；轮询远程接口间隔 30 秒以上，单次失败用 || true 吞掉；等一件事完成就让命令在那时退出。',
      '事件太密（一分钟超过 60 个）会被停掉，每天最多唤醒你 40 次。工作机重启后命令重新开始，事件可能重复。不需要时用 monitor_stop 停掉。',
    ].join(''),
    tool: 'monitor_start', effect: 'create', retry: 'receipt',
    input: z.object({ operationId: id, title: z.string().trim().min(1).max(80), command: z.string().min(1).max(20_000).optional(),
      at: z.string().optional(), minutes: z.number().int().min(1).max(366 * 24 * 60).optional(), repeat: z.enum(['daily', 'weekly']).optional() }).strict(),
    output: z.object({ instanceId: id }).strict(),
  },
  'monitor.list': {
    title: '查看监视', description: '列出当前工作区里开着的 monitor：标题、来源与是否已结束、今天唤醒的次数。',
    tool: 'monitor_list', effect: 'read', retry: 'read', input: z.object({}).strict(), output: z.object({ monitors: z.array(z.unknown()) }).strict(),
  },
  'monitor.stop': {
    title: '停止监视', description: '停掉一个 monitor：停下它的来源并归档，时间线保留。',
    tool: 'monitor_stop', effect: 'write', retry: 'receipt', input: target, output: ok,
  },
  'monitor.read': {
    title: '读取 monitor', description: '读取 monitor 的来源与时间线；Line 的 monitor 返回收件箱。',
    tool: null, effect: 'read', retry: 'read', input: z.object({ instanceId: id }).strict(), output: z.unknown(),
  },
  'monitor.delegate': {
    title: '交给 Line', description: '把 Line 收件箱里的一项交给 Line 代处理，立即唤醒 Line。',
    tool: null, effect: 'write', retry: 'receipt', input: target.extend({ item: id }).strict(), output: z.unknown(),
  },
  'monitor.dismiss': {
    title: '知道了', description: '把收件箱里结束的回合移出；其余事项随原线程的状态解除才移出。',
    tool: null, effect: 'write', retry: 'receipt', input: target.extend({ item: id }).strict(), output: ok,
  },
  'monitor.hosting': {
    title: '设置托管', description: 'Line 的两种托管：按时段托管到 until（毫秒），超时托管 timeoutMinutes；null 关闭。',
    tool: null, effect: 'write', retry: 'receipt',
    input: target.extend({ until: z.number().nullable().optional(), timeoutMinutes: z.number().int().min(1).max(24 * 60).nullable().optional() }).strict(),
    output: z.object({ until: z.number().optional(), timeoutMinutes: z.number().optional() }).strict(),
  },
} as const;

export type OperationName = keyof typeof operationContracts;
export type OperationInput<N extends OperationName> = z.infer<(typeof operationContracts)[N]['input']>;
/**
 * ui 的 via 是另一台工作机上的 Line 经界面入口调用时声明的来源，只记入输入与收据，不参与授权。
 * relayed 表示 Line 照原文转达用户的话，输入来源仍是人。
 */
export type OperationCaller = { kind: 'ui'; via?: z.infer<typeof inputVia>; relayed?: boolean } | {
  kind: 'model' | 'plugin'; instanceId: string; turnId?: string; callId?: string;
};

const targets = z.discriminatedUnion('kind', [
  z.object({ kind: z.literal('created') }).strict(),
  z.object({ kind: z.literal('instances'), instanceIds: z.array(id) }).strict(),
]);
export const operationGrantsSchema = z.array(z.discriminatedUnion('operation', [
  z.object({ operation: z.literal('plugin.call'), instanceId: id, tools: z.array(id).min(1) }).strict(),
  z.object({ operation: z.literal('agent.start'), roleIds: z.array(id) }).strict(),
  z.object({ operation: z.literal('agent.list') }).strict(),
  ...(['agent.send', 'agent.resume', 'agent.stop', 'monitor.stop'] as const).map((operation) => z.object({ operation: z.literal(operation), targets }).strict()),
  z.object({ operation: z.literal('monitor.start') }).strict(),
  z.object({ operation: z.literal('monitor.list') }).strict(),
  ...(['files.list', 'files.read', 'files.diff', 'files.state', 'files.select'] as const).map((operation) => z.object({ operation: z.literal(operation),
    targets: z.object({ kind: z.literal('instances'), instanceIds: z.array(id) }).strict() }).strict()),
  /** Line 的管理动作，目标范围是工作机目录里的全部工作区；actions 是用户允许的白名单。 */
  z.object({ operation: z.literal('line'), actions: z.array(z.enum(lineActions)) }).strict(),
]));
export type OperationGrant = z.infer<typeof operationGrantsSchema>[number];

/** 授权对应的模型工具；文件、插件授权不经模型工具。 */
export function grantTools(grant: OperationGrant): string[] {
  if (grant.operation === 'line') return lineToolNames.filter((tool) => lineToolActions[tool].some((action) => grant.actions.includes(action)));
  const tool = operationContracts[grant.operation].tool;
  return tool ? [tool] : [];
}

/** 仅宿主登记的代理获得默认授权，可按内置角色创建代理；自定义 manifest 不能自行授予。 */
export function defaultOperationGrants(definitionId: string): OperationGrant[] {
  return definitionId === 'kite.agent' ? [
    { operation: 'agent.list' }, { operation: 'agent.start', roleIds: ['kite.work', 'kite.review'] },
    { operation: 'agent.send', targets: { kind: 'created' } },
    { operation: 'agent.resume', targets: { kind: 'created' } },
    { operation: 'agent.stop', targets: { kind: 'created' } },
    { operation: 'monitor.start' }, { operation: 'monitor.list' }, { operation: 'monitor.stop', targets: { kind: 'created' } },
  ] : [];
}

/** Line 实例启用时得到的管理授权；其他代理即使角色放开了 Line 的工具，也要用户另行授予。 */
export const lineGrant: OperationGrant = { operation: 'line', actions: [...lineActions] };

/**
 * 协作操作的授权只给角色允许使用对应工具的代理，例如只读审查不带。创建和改选角色都按此调整：
 * 去掉新角色用不了的；旧角色用不了、新角色能用的补上默认授权。两个角色都能用的保持原样，用户撤回的不会被补回。
 * 插件与文件授权不经模型工具，不受影响。
 */
export function roleOperationGrants(definitionId: string, grants: OperationGrant[], before: readonly string[], after: readonly string[]): OperationGrant[] {
  const usable = (grant: OperationGrant, tools: readonly string[]) => {
    const granted = grantTools(grant);
    return grant.operation !== 'line' && !granted.length || granted.some((tool) => tools.includes(tool));
  };
  const kept = grants.filter((grant) => usable(grant, after));
  return [...kept, ...defaultOperationGrants(definitionId).filter((grant) => usable(grant, after) && !usable(grant, before)
    && !kept.some((other) => other.operation === grant.operation))];
}

export const operationToolNames = ['agent_start', 'agent_list', 'agent_send', 'agent_resume', 'agent_stop', 'monitor_start', 'monitor_list', 'monitor_stop'] as const;
const failure = z.object({ error: z.string(), outcome: z.enum(['denied', 'failed', 'cancelled', 'unknown']) }).strict();

export function operationCatalog() {
  return Object.entries(operationContracts).map(([name, contract]) => ({
    name, title: contract.title, description: contract.description, effect: contract.effect, retry: contract.retry,
    callers: contract.tool || name === 'plugin.call' ? ['ui', 'model', 'plugin'] : ['ui', 'plugin'], cancellation: '提交前可取消；提交后等待确定结果，不撤销已执行的动作',
    input: z.toJSONSchema(contract.input), output: z.toJSONSchema(contract.output), error: z.toJSONSchema(failure),
  }));
}
