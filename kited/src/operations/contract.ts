/** 实例操作的公开声明；宿主与模型工具共用 schema，调用身份不属于参数。 */
import { z } from 'zod';
import { diffID, fileDiffSchema } from '../workspace/file-diffs.ts';
import { fileSelectionSchema, readFileArgs } from '../workspace/files.ts';

const id = z.string().min(1);
const text = z.string().refine((value) => !!value.trim(), '内容不能为空');
const input = z.object({ id, text, source: z.enum(['human', 'kite']) }).strict();
const target = z.object({ operationId: id, instanceId: id }).strict();
const ok = z.object({ ok: z.literal(true) }).strict();
const summary = z.object({
  instanceId: id, definitionId: id, title: z.string(), presentation: z.enum(['window', 'inline', 'background']),
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
    title: '创建 agent', description: '在当前工作区创建 agent 实例。省略 prompt 只创建空会话；共享工作区已有线程运行时不能启动另一线程。',
    tool: 'agent_start', effect: 'create', retry: 'receipt',
    input: z.object({ operationId: id, definitionId: id, title: text.optional(), prompt: text.optional(),
      presentation: z.enum(['window', 'inline', 'background']).default('window') }).strict(),
    output: z.object({ instanceId: id, windowId: id.optional() }).strict(),
  },
  'agent.list': {
    title: '查询 agent', description: '查询当前工作区的 agent 实例、执行状态及获准操作；不会唤醒会话。',
    tool: 'agent_list', effect: 'read', retry: 'read',
    input: z.object({}).strict(), output: z.object({ agents: z.array(summary) }).strict(),
  },
  'agent.send': {
    title: '发送消息', description: '向获准的 agent 实例发送消息。消息落盘后返回；共享工作区的执行互斥仍然适用。',
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
} as const;

export type OperationName = keyof typeof operationContracts;
export type OperationInput<N extends OperationName> = z.infer<(typeof operationContracts)[N]['input']>;
export type OperationCaller = { kind: 'ui' } | {
  kind: 'model' | 'plugin'; instanceId: string; turnId?: string; callId?: string;
};

const targets = z.discriminatedUnion('kind', [
  z.object({ kind: z.literal('created') }).strict(),
  z.object({ kind: z.literal('instances'), instanceIds: z.array(id) }).strict(),
]);
export const operationGrantsSchema = z.array(z.discriminatedUnion('operation', [
  z.object({ operation: z.literal('plugin.call'), instanceId: id, tools: z.array(id).min(1) }).strict(),
  z.object({ operation: z.literal('agent.start'), definitionIds: z.array(id) }).strict(),
  z.object({ operation: z.literal('agent.list') }).strict(),
  ...(['agent.send', 'agent.resume', 'agent.stop'] as const).map((operation) => z.object({ operation: z.literal(operation), targets }).strict()),
  ...(['files.list', 'files.read', 'files.diff', 'files.state', 'files.select'] as const).map((operation) => z.object({ operation: z.literal(operation),
    targets: z.object({ kind: z.literal('instances'), instanceIds: z.array(id) }).strict() }).strict()),
]));
export type OperationGrant = z.infer<typeof operationGrantsSchema>[number];

/** 仅宿主登记的编码定义获得默认授权；自定义 manifest 不能自行授予。 */
export function defaultOperationGrants(definitionId: string): OperationGrant[] {
  return ['kite.agent.coding', 'kite.agent.claude'].includes(definitionId) ? [
    { operation: 'agent.list' }, { operation: 'agent.start', definitionIds: ['kite.agent.coding', 'kite.agent.review', 'kite.agent.claude'] },
    { operation: 'agent.send', targets: { kind: 'created' } },
    { operation: 'agent.resume', targets: { kind: 'created' } },
    { operation: 'agent.stop', targets: { kind: 'created' } },
  ] : [];
}

export const operationToolNames = ['agent_start', 'agent_list', 'agent_send', 'agent_resume', 'agent_stop'] as const;
const failure = z.object({ error: z.string(), outcome: z.enum(['denied', 'failed', 'cancelled', 'unknown']) }).strict();

export function operationCatalog() {
  return Object.entries(operationContracts).map(([name, contract]) => ({
    name, title: contract.title, description: contract.description, effect: contract.effect, retry: contract.retry,
    callers: contract.tool || name === 'plugin.call' ? ['ui', 'model', 'plugin'] : ['ui', 'plugin'], cancellation: '提交前可取消；提交后等待确定结果，不撤销已执行的动作',
    input: z.toJSONSchema(contract.input), output: z.toJSONSchema(contract.output), error: z.toJSONSchema(failure),
  }));
}
