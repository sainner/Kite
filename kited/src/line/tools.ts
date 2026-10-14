/**
 * Line 的管理工具。目标范围是账号目录里的全部工作区，调用经 Peers 直达目标工作机。授权全部在 Line 所在机器：
 * 动作须在 Line 实例的 line 授权白名单里；停止、归档、创建、流转是必问动作，执行前在 Line 的线程上挂起等用户批准，
 * 与审批模式无关（docs/工具审批与提问.md）。
 */
import { z } from 'zod';
import { KiteError } from '../errors.ts';
import type { InputVia, JsonObject, Tool, ToolResult } from '../harness/types.ts';
import type { MachineSummary } from '../kite.ts';
import { operationGrantsSchema, type LineAction } from '../operations/contract.ts';
import type { Store } from '../store.ts';
import type { ApprovalDecision, ApprovalRequest } from '../waiting.ts';
import { PeerError, type Peers } from './peers.ts';

const id = z.string().min(1);
const statusArgs = z.object({ machine: id.optional() }).strict();
const controlArgs = z.object({ action: z.enum(['send', 'resume', 'stop', 'archive']), machine: id, threadId: id.optional(), workspaceId: id.optional(),
  text: z.string().trim().min(1).max(20_000).optional() }).strict();
const workspaceArgs = z.object({ action: z.enum(['create', 'transfer']), machine: id.optional(), project: id.optional(), name: z.string().max(200).optional(),
  prompt: z.string().trim().min(1).max(20_000).optional(), workspaceId: id.optional(), from: id.optional(), to: id.optional(),
  allowMaterials: z.boolean().optional() }).strict();

type ToolContext = Parameters<Tool['execute']>[1];

export interface LineToolOptions {
  store: Store;
  peers: Peers;
  machine: string;
  instanceId: string;
  /** 在 Line 的线程上挂起，等用户批准这一次或拒绝；会话停止时为 undefined。 */
  approve(request: ApprovalRequest, signal: AbortSignal): Promise<ApprovalDecision | undefined>;
}

export function lineTools(options: LineToolOptions): Tool[] {
  const { store, peers, machine, instanceId } = options;
  const via: InputVia = { kind: 'line', machine, instance: instanceId };

  const allowed = (action: LineAction) => {
    const grants = operationGrantsSchema.parse(store.instance(instanceId)?.config.grants ?? []);
    if (!grants.some((grant) => grant.operation === 'line' && grant.actions.includes(action))) throw new KiteError(`Line 未获准执行 ${action}，请用户在操作授权里打开`);
  };
  /** 必问动作：用户批准这一次才往下执行，拒绝或会话停止都不执行。 */
  const mustAsk = async (tool: string, target: string, context: ToolContext) => {
    const decision = await options.approve({ tool, target, reason: '停止、归档、创建与流转是必问的动作，每次都须经你批准', mustAsk: true }, context.signal);
    if (decision === 'deny') throw new KiteError(`用户拒绝了：${target}`);
    if (decision !== 'once') throw new KiteError(`会话已停止，没有执行：${target}`);
  };
  const run = async (work: () => Promise<unknown>): Promise<ToolResult> => {
    try { return { status: 'success', output: JSON.stringify(await work()) }; }
    catch (error) {
      if (error instanceof PeerError) return { status: 'error', output: JSON.stringify({ error: error.message, status: error.status }) };
      if (error instanceof KiteError) return { status: 'error', output: error.message };
      throw error;
    }
  };
  const tool = <T extends z.ZodType>(name: string, description: string, schema: T, execute: (args: z.infer<T>, context: ToolContext) => Promise<unknown>): Tool => ({
    name, description, parameters: z.toJSONSchema(schema) as JsonObject,
    validate(value) {
      const parsed = schema.safeParse(value);
      if (!parsed.success) throw new Error(`参数无效：${parsed.error.issues.map((issue) => issue.message).join('；')}`);
    },
    execute: (value, context) => run(() => execute(schema.parse(value), context)),
  });
  const operationId = (context: ToolContext) => {
    if (!context.callId || !context.turnId) throw new KiteError('Line 工具缺少宿主调用 ID');
    return `line:${instanceId}:${context.turnId}:${context.callId}`;
  };

  return [
    tool('line_status', '查看账号下各工作机的工作区、线程执行状态和在等用户回应的提问或审批。machine 只看一台；离线或连不上的工作机标明原因。', statusArgs, async (args) => {
      allowed('status');
      const machines = (await peers.machines()).filter((entry) => !args.machine || entry.id === args.machine);
      return Promise.all(machines.map(async (entry) => {
        if (!entry.online) return { machine: entry.id, name: entry.name, online: false };
        try {
          const summary = await peers.call<MachineSummary>(entry.id, 'GET', '/summary');
          return { machine: entry.id, name: entry.name, online: true, workspaces: summary.workspaces };
        } catch (error) { return { machine: entry.id, name: entry.name, online: true, error: (error as Error).message }; }
      }));
    }),
    tool('line_control', [
      '管理一个线程：send 发送你自己的说明（来源记为 Kite、经 Line），resume 继续暂停的线程，stop 停止，archive 归档线程（threadId）或独立工作区（workspaceId）。',
      'stop 与 archive 执行前会等用户批准，用户拒绝时不执行。',
    ].join(''), controlArgs, async (args, context) => {
      allowed(args.action);
      const thread = () => { if (!args.threadId) throw new KiteError(`${args.action} 需要 threadId`); return args.threadId; };
      switch (args.action) {
        case 'send':
          if (!args.text) throw new KiteError('send 需要 text');
          return peers.call(args.machine, 'POST', `/threads/${thread()}/messages`, { body: { text: args.text, id: operationId(context) }, via, timeoutMs: 120_000 });
        case 'resume':
          return peers.call(args.machine, 'POST', `/threads/${thread()}/resume`, { body: { operationId: operationId(context) }, via });
        case 'stop':
          await mustAsk('line_control', `停止工作机 ${args.machine} 上的线程 ${thread()}`, context);
          return peers.call(args.machine, 'POST', `/threads/${thread()}/interrupt`, { body: { id: operationId(context) }, via, timeoutMs: 120_000 });
        case 'archive':
          if (args.workspaceId) {
            await mustAsk('line_control', `归档工作机 ${args.machine} 上的工作区 ${args.workspaceId}`, context);
            return peers.call(args.machine, 'POST', `/workspaces/${args.workspaceId}/archive`, { body: {}, via, timeoutMs: 120_000 });
          }
          await mustAsk('line_control', `归档工作机 ${args.machine} 上的线程 ${thread()}`, context);
          return peers.call(args.machine, 'POST', `/instances/${thread()}/archive`, { via, timeoutMs: 120_000 });
      }
    }),
    tool('line_workspace', [
      'create：在 machine 上为 project 建独立工作区，可带 name 与第一条消息 prompt；那台工作机没有检出时会先 clone。',
      'transfer：把 workspaceId 从 from 工作机流转到 to 工作机，源工作区须所有线程空闲；公开或看不出是否公开的仓库要用户同意推流转材料后传 allowMaterials。',
      '两者执行前都会等用户批准，用户拒绝时不执行。',
    ].join(''), workspaceArgs, async (args, context) => {
      allowed(args.action);
      if (args.action === 'create') {
        if (!args.machine || !args.project) throw new KiteError('create 需要 machine 与 project');
        await mustAsk('line_workspace', `在工作机 ${args.machine} 上为项目 ${args.project} 创建工作区`, context);
        const model = await peers.call(args.machine, 'POST', '/workspaces', { body: { project: args.project, ...(args.name ? { name: args.name } : {}),
          ...(args.prompt ? { prompt: args.prompt } : {}) }, via, timeoutMs: 30 * 60_000 });
        return { workspaceId: model.workspace.id, status: model.workspace.status, cwd: model.workspace.cwd };
      }
      if (!args.workspaceId || !args.from || !args.to || args.from === args.to) throw new KiteError('transfer 需要 workspaceId 与不同的 from、to');
      await mustAsk('line_workspace', `把工作区 ${args.workspaceId} 从工作机 ${args.from} 流转到 ${args.to}`, context);
      const model = await peers.call(args.from, 'GET', `/workspaces/${args.workspaceId}`);
      const handover = await peers.call(args.from, 'POST', `/workspaces/${args.workspaceId}/handover`, {
        body: args.allowMaterials ? { allowMaterials: true } : {}, via, timeoutMs: 10 * 60_000 });
      const restored = await peers.call(args.to, 'POST', '/workspaces/restore', {
        body: { project: model.project.id, workspaceId: args.workspaceId, operationId: operationId(context) }, via, timeoutMs: 30 * 60_000 });
      // 源机下次核对执行权时也会冻结；这里立即核对，失败不影响已完成的流转。
      await peers.call(args.from, 'POST', `/workspaces/${args.workspaceId}/lease/check`, { via }).catch(() => {});
      return { workspaceId: args.workspaceId, epoch: handover.epoch + 1, machine: args.to, status: restored.workspace.status };
    }),
  ];
}
