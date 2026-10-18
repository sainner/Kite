/**
 * Line 的管理工具。目标范围是账号目录里的全部工作区，调用经 Peers 直达目标工作机。授权全部在 Line 所在机器：
 * 动作须在 Line 实例的 line 授权白名单里；停止、归档、创建、流转是必问动作，执行前在 Line 的线程上挂起等用户批准，
 * 与审批模式无关（docs/工具审批与提问.md）。代处理只能处理交给 Line 的收件箱事项，不能处理 Line 自己发起的请求。
 */
import { z } from 'zod';
import { KiteError } from '../errors.ts';
import type { InputVia, JsonObject, Tool, ToolResult } from '../harness/types.ts';
import type { MachineSummary } from '../kite.ts';
import { operationGrantsSchema, type LineAction } from '../operations/contract.ts';
import type { Store } from '../store.ts';
import type { DisplayState } from '../transcript/protocol.ts';
import type { ApprovalDecision, ApprovalRequest } from '../waiting.ts';
import { type LineMonitor, where } from './monitor.ts';
import { PeerError, type Peers } from './peers.ts';

const id = z.string().min(1);
const reason = z.string().trim().min(1).max(2000);
const statusArgs = z.object({ machine: id.optional(), threadId: id.optional() }).strict();
const handleArgs = z.object({ item: id, decision: z.enum(['once', 'deny', 'done', 'leave']).optional(),
  answers: z.array(z.object({ selected: z.array(z.string().min(1)).max(4).optional(), other: z.string().trim().min(1).max(20_000).optional() }).strict())
    .min(1).max(4).optional(), reason }).strict();
const relayArgs = z.object({ machine: id, threadId: id, from: id.optional() }).strict();
const controlArgs = z.object({ action: z.enum(['send', 'resume', 'stop', 'archive']), machine: id, threadId: id.optional(), workspaceId: id.optional(),
  text: z.string().trim().min(1).max(20_000).optional() }).strict();
const workspaceArgs = z.object({ action: z.enum(['create', 'transfer']), machine: id.optional(), project: id.optional(),
  prompt: z.string().trim().min(1).max(20_000).optional(), workspaceId: id.optional(), from: id.optional(), to: id.optional(),
  force: z.boolean().optional() }).strict();

type ToolContext = Parameters<Tool['execute']>[1];

export interface LineToolOptions {
  store: Store;
  peers: Peers;
  machine: string;
  instanceId: string;
  monitor: LineMonitor;
  /** Line 线程里用户的一条消息；省略 ID 时是最近的一条。 */
  message(inputId?: string): Promise<{ id: string; text: string } | undefined>;
  /** 在 Line 的线程上挂起，等用户批准这一次或拒绝；会话停止时为 undefined。 */
  approve(request: ApprovalRequest, signal: AbortSignal): Promise<ApprovalDecision | undefined>;
}

export function lineTools(options: LineToolOptions): Tool[] {
  const { store, peers, machine, instanceId, monitor } = options;
  const via: InputVia = { kind: 'line', machine, instance: instanceId };

  const allowed = (action: LineAction) => {
    const grants = operationGrantsSchema.parse(store.instance(instanceId)?.config.grants ?? []);
    if (!grants.some((grant) => grant.operation === 'line' && grant.actions.includes(action))) throw new KiteError(`Line 未获准执行 ${action}，请用户在 Line 的协作授权里打开`);
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

  const when = (at: number) => new Date(at).toLocaleString('zh-CN', { hour12: false, timeZoneName: 'short' });

  return [
    tool('line_status', [
      '查看账号下各工作机的工作区、线程执行状态、在等用户回应的提问或审批，以及用户的收件箱。machine 只看一台；离线或连不上的工作机标明原因。',
      '带 machine 与 threadId 时只读那个线程最后一回合的回复。',
    ].join(''), statusArgs, async (args, context) => {
      allowed('status');
      if (args.threadId) {
        if (!args.machine) throw new KiteError('读线程的回复要写 machine');
        return peers.call(args.machine, 'GET', `/threads/${args.threadId}/reply`, { signal: context.signal });
      }
      const machines = (await peers.machines()).filter((entry) => !args.machine || entry.id === args.machine);
      const states = await Promise.all(machines.map(async (entry) => {
        if (!entry.online) return { machine: entry.id, name: entry.name, online: false };
        try {
          const summary = await peers.call<MachineSummary>(entry, 'GET', '/summary', { signal: context.signal });
          return { machine: entry.id, name: entry.name, online: true, workspaces: summary.workspaces };
        } catch (error) { return { machine: entry.id, name: entry.name, online: true, error: (error as Error).message }; }
      }));
      const inbox = monitor.inbox().items.map(({ waiting: _, ...item }) => ({ ...item, where: where(item) }));
      return { now: when(Date.now()), machines: states, inbox };
    }),
    tool('line_handle', [
      '了结收件箱里交给你处理的一项（用户点了代处理或在托管中）。item 是事项 ID。',
      '审批：decision 为 once（批准这一次）或 deny（拒绝），不能替用户允许并记住。提问：answers 按问题顺序，每项写 selected（选项标签）或 other（自己写的回答）。',
      '回合结束与失败：读过回复、回答或继续之后用 done 清掉。拿不准的用 leave 留给用户。reason 写明依据，会给用户看。',
      '没交给你的、你自己发起的请求都不能处理。',
    ].join(''), handleArgs, async (args, context) => {
      allowed('reply');
      const item = monitor.claim(args.item);
      if (args.decision === 'leave') {
        monitor.leave(item.id, args.reason);
        return { item: item.id, result: '已留给用户' };
      }
      const waiting = item.waiting;
      if (waiting && item.thread) {
        if (waiting.kind === 'secret') throw new KiteError('密钥请求只能由用户填写，用 leave 留给用户');
        let body: Record<string, unknown>;
        if (waiting.kind === 'approval') {
          if (args.decision !== 'once' && args.decision !== 'deny') throw new KiteError('审批只能批准这一次（once）或拒绝（deny）');
          body = { decision: args.decision, reason: args.reason };
        } else {
          if (!args.answers) throw new KiteError('回答提问要写 answers');
          body = { answers: args.answers, reason: args.reason };
        }
        try { await peers.call(item.machine.id, 'POST', `/threads/${item.thread.id}/waiting/${waiting.id}`, { body, via, signal: context.signal }); }
        catch (error) {
          if (error instanceof PeerError && error.status === 409) throw new KiteError('这一项已被回应或作废，不用再处理');
          throw error;
        }
        monitor.resolve(item.id, waiting.kind === 'approval' ? args.decision! : 'answered', args.reason);
        return { item: item.id, result: waiting.kind === 'approval' ? (args.decision === 'once' ? '已批准这一次' : '已拒绝') : '已回答' };
      }
      if (args.decision !== 'done') throw new KiteError('这一项读完、处理完之后用 done 清掉，拿不准用 leave');
      monitor.resolve(item.id, 'done', args.reason);
      return { item: item.id, result: '已清掉' };
    }),
    tool('line_relay', [
      '把用户在你线程里说的话照原文转达给另一个线程：线程有没回答的提问时作为最早那个提问的「其他」回答，否则作为一条用户消息（经你转达）。',
      'from 是用户那条消息的输入 ID，省略时取用户最近的一条。不要改写用户原文，你自己的补充说明另用 line_control send。线程在等审批时不能转达。',
    ].join(''), relayArgs, async (args, context) => {
      allowed('reply');
      const message = await options.message(args.from);
      if (!message) throw new KiteError(args.from ? `你的线程里没有用户的这条消息：${args.from}` : '你的线程里还没有用户的消息');
      const key = `${message.id}:${args.machine}:${args.threadId}`;
      const done = monitor.relayed(key);
      if (done) return { relayed: done, duplicate: true };
      const state = await peers.call<DisplayState>(args.machine, 'GET', `/threads/${args.threadId}/state`, { signal: context.signal });
      if (state.waiting?.kind === 'approval') throw new KiteError('这个线程在等审批，用户的话不能当作批准；请用户在收件箱里回应，或把这一项交给你代处理');
      const question = state.asks?.find((ask) => ask.kind === 'question');
      if (question?.kind === 'question') {
        await peers.call(args.machine, 'POST', `/threads/${args.threadId}/waiting/${question.id}`, {
          body: { answers: question.questions.map(() => ({ other: message.text })) }, via, signal: context.signal });
        monitor.markRelayed(key, 'answered');
        return { relayed: 'answered' };
      }
      await peers.call(args.machine, 'POST', `/threads/${args.threadId}/messages`, { body: { text: message.text, id: `relay:${key}`, relay: true }, via, signal: context.signal, timeoutMs: 120_000 });
      monitor.markRelayed(key, 'sent');
      return { relayed: 'sent' };
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
          return peers.call(args.machine, 'POST', `/threads/${thread()}/messages`, { body: { text: args.text, id: operationId(context) }, via, signal: context.signal, timeoutMs: 120_000 });
        case 'resume':
          return peers.call(args.machine, 'POST', `/threads/${thread()}/resume`, { body: { operationId: operationId(context) }, via, signal: context.signal });
        case 'stop':
          await mustAsk('line_control', `停止工作机 ${args.machine} 上的线程 ${thread()}`, context);
          return peers.call(args.machine, 'POST', `/threads/${thread()}/interrupt`, { body: { id: operationId(context) }, via, signal: context.signal, timeoutMs: 120_000 });
        case 'archive':
          if (args.workspaceId) {
            await mustAsk('line_control', `归档工作机 ${args.machine} 上的工作区 ${args.workspaceId}`, context);
            return peers.call(args.machine, 'POST', `/workspaces/${args.workspaceId}/archive`, { body: {}, via, signal: context.signal, timeoutMs: 120_000 });
          }
          await mustAsk('line_control', `归档工作机 ${args.machine} 上的线程 ${thread()}`, context);
          return peers.call(args.machine, 'POST', `/instances/${thread()}/archive`, { via, signal: context.signal, timeoutMs: 120_000 });
      }
    }),
    tool('line_workspace', [
      'create：在 machine 上为 project 建独立工作区，可带第一条消息 prompt，工作区跟着代理的标题起名；那台工作机没有检出时会先 clone。',
      'transfer：把 workspaceId 从 from 工作机流转到 to 工作机，源工作区须所有线程空闲，两台都要在线。',
      'from 已经丢失（用户确认过）时传 force：to 用手上的副本强制接管，不联系 from，副本落后的部分会丢；from 回来后自己冻结旧记录。',
      '两者执行前都会等用户批准，用户拒绝时不执行。',
    ].join(''), workspaceArgs, async (args, context) => {
      allowed(args.action);
      if (args.action === 'create') {
        if (!args.machine || !args.project) throw new KiteError('create 需要 machine 与 project');
        await mustAsk('line_workspace', `在工作机 ${args.machine} 上为项目 ${args.project} 创建工作区`, context);
        const model = await peers.call(args.machine, 'POST', '/workspaces', { body: { project: args.project, ...(args.prompt ? { prompt: args.prompt } : {}) },
          via, signal: context.signal, timeoutMs: 30 * 60_000 });
        return { workspaceId: model.workspace.id, status: model.workspace.status, cwd: model.workspace.cwd };
      }
      if (!args.workspaceId || !args.from || !args.to || args.from === args.to) throw new KiteError('transfer 需要 workspaceId 与不同的 from、to');
      if (args.force) {
        await mustAsk('line_workspace', `工作机 ${args.from} 已丢失，在 ${args.to} 上用副本强制接管工作区 ${args.workspaceId}`, context);
        // from 不在线，项目由 to 从自己手上的副本里取。
        const restored = await peers.call(args.to, 'POST', '/workspaces/restore', {
          body: { workspaceId: args.workspaceId, operationId: operationId(context), force: true },
          via, signal: context.signal, timeoutMs: 30 * 60_000 });
        return { workspaceId: args.workspaceId, machine: args.to, status: restored.workspace.status };
      }
      await mustAsk('line_workspace', `把工作区 ${args.workspaceId} 从工作机 ${args.from} 流转到 ${args.to}`, context);
      // 源机交接、通知目标还原，没成就撤回，见 Kite.transferWorkspace。
      return await peers.call(args.from, 'POST', `/workspaces/${args.workspaceId}/transfer`, {
        body: { to: args.to, operationId: operationId(context) }, via, signal: context.signal, timeoutMs: 30 * 60_000 });
    }),
  ];
}
