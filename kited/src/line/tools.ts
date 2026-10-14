/**
 * Line 的管理工具。目标范围是账号目录里的全部工作区，调用经 Peers 直达目标工作机。授权全部在 Line 所在机器：
 * 动作须在 Line 实例的 line 授权白名单里；停止、归档、创建、流转与替用户关闭上报，还须引用一条 Line 线程上
 * 用户已答复同意、且没用过的确认上报，由宿主核验后放行，模型只能引用，不能伪造。转达答复时正文由宿主
 * 从 Line 自己那条上报里照用户原文复制。
 */
import { z } from 'zod';
import { KiteError } from '../errors.ts';
import type { InputVia, JsonObject, Tool, ToolResult } from '../harness/types.ts';
import type { MachineSummary } from '../kite.ts';
import type { Report } from '../model.ts';
import { operationGrantsSchema, type LineAction } from '../operations/contract.ts';
import type { Store } from '../store.ts';
import { PeerError, type Peers } from './peers.ts';

const id = z.string().min(1);
const statusArgs = z.object({ machine: id.optional() }).strict();
const replyArgs = z.object({ machine: id, threadId: id, reportId: id, from: id, close: z.boolean().optional() }).strict();
const controlArgs = z.object({ action: z.enum(['send', 'resume', 'stop', 'archive']), machine: id, threadId: id.optional(), workspaceId: id.optional(),
  text: z.string().trim().min(1).max(20_000).optional(), confirmation: id.optional() }).strict();
const workspaceArgs = z.object({ action: z.enum(['create', 'transfer']), machine: id.optional(), project: id.optional(), name: z.string().max(200).optional(),
  prompt: z.string().trim().min(1).max(20_000).optional(), workspaceId: id.optional(), from: id.optional(), to: id.optional(),
  allowMaterials: z.boolean().optional(), confirmation: id }).strict();

/** 已有用户答复的状态：用户直接在 Line 的线程上答，不经转达。 */
const answered = (report: Report) => !!report.answer && !report.answer.via && ['answered', 'delivered', 'incorporated', 'closed'].includes(report.status);
const clip = (text: string, limit: number) => text.length > limit ? `${text.slice(0, limit)}…` : text;

export interface LineToolOptions {
  store: Store;
  peers: Peers;
  machine: string;
  instanceId: string;
}

export function lineTools(options: LineToolOptions): Tool[] {
  const { store, peers, machine, instanceId } = options;
  const via: InputVia = { kind: 'line', machine, instance: instanceId };

  const allowed = (action: LineAction) => {
    const grants = operationGrantsSchema.parse(store.instance(instanceId)?.config.grants ?? []);
    if (!grants.some((grant) => grant.operation === 'line' && grant.actions.includes(action))) throw new KiteError(`Line 未获准执行 ${action}，请用户在操作授权里打开`);
  };
  /** 核验并用掉确认上报：须是 Line 自己线程上的 confirm，用户答复同意，且没用过。 */
  const confirm = (reportId: string | undefined, action: string, target: string) => {
    if (!reportId) throw new KiteError(`${action} 需要先用 report（kind: confirm）征得用户同意，再把那条上报的 ID 填进 confirmation`);
    const report = store.report(reportId);
    if (!report || report.threadId !== instanceId || report.kind !== 'confirm') throw new KiteError('confirmation 须是你自己提出的确认上报');
    if (!answered(report) || report.answer!.decision !== 'yes') throw new KiteError('用户还没有同意这条确认上报');
    if (!store.useConfirmation(reportId, action, target)) throw new KiteError('这条确认已经用过，每条同意只能放行一次动作');
  };
  const run = async (work: () => Promise<unknown>): Promise<ToolResult> => {
    try { return { status: 'success', output: JSON.stringify(await work()) }; }
    catch (error) {
      if (error instanceof PeerError) return { status: 'error', output: JSON.stringify({ error: error.message, status: error.status,
        ...(error.body.report ? { report: error.body.report } : {}) }) };
      if (error instanceof KiteError) return { status: 'error', output: error.message };
      throw error;
    }
  };
  const tool = <T extends z.ZodType>(name: string, description: string, schema: T, execute: (args: z.infer<T>, context: { callId?: string; turnId?: string }) => Promise<unknown>): Tool => ({
    name, description, parameters: z.toJSONSchema(schema) as JsonObject,
    validate(value) {
      const parsed = schema.safeParse(value);
      if (!parsed.success) throw new Error(`参数无效：${parsed.error.issues.map((issue) => issue.message).join('；')}`);
    },
    execute: (value, context) => run(() => execute(schema.parse(value), context)),
  });
  const operationId = (context: { callId?: string; turnId?: string }) => {
    if (!context.callId || !context.turnId) throw new KiteError('Line 工具缺少宿主调用 ID');
    return `line:${instanceId}:${context.turnId}:${context.callId}`;
  };

  return [
    tool('line_status', '查看账号下各工作机的工作区、线程执行状态和未结束的上报。machine 只看一台；离线或连不上的工作机标明原因。', statusArgs, async (args) => {
      allowed('status');
      const machines = (await peers.machines()).filter((entry) => !args.machine || entry.id === args.machine);
      return Promise.all(machines.map(async (entry) => {
        if (!entry.online) return { machine: entry.id, name: entry.name, online: false };
        try {
          const summary = await peers.call<MachineSummary>(entry.id, 'GET', '/summary');
          return { machine: entry.id, name: entry.name, online: true, workspaces: summary.workspaces.map((workspace) => ({
            ...workspace, reports: workspace.reports.map((report) => ({ id: report.id, threadId: report.threadId, kind: report.kind,
              status: report.status, text: clip(report.text, 800), ...(report.refs.length ? { refs: report.refs } : {}) })) })) };
        } catch (error) { return { machine: entry.id, name: entry.name, online: true, error: (error as Error).message }; }
      }));
    }),
    tool('line_reply', [
      '把用户的答复转达给另一线程的上报：from 是你自己那条用户已答复的上报，宿主照用户原文转过去，来源记为人、经 Line 转达。',
      '目标是 confirm 时 from 也须是 confirm。close: true 表示替用户把 done（接受）或 blocked（不再处理）上报关闭，此时 from 须是用户同意的 confirm，每条只能用一次。',
    ].join(''), replyArgs, async (args) => {
      allowed('reply');
      const source = store.report(args.from);
      if (!source || source.threadId !== instanceId) throw new KiteError('from 须是你自己提出的上报');
      if (!answered(source)) throw new KiteError('这条上报还没有用户的答复');
      const reports = await peers.call<Report[]>(args.machine, 'GET', `/threads/${args.threadId}/reports`);
      const target = reports.find((report) => report.id === args.reportId);
      if (!target) throw new KiteError('目标线程没有这条上报');
      if (args.close) {
        const outcome = target.kind === 'done' ? 'accepted' : target.kind === 'blocked' ? 'dismissed' : undefined;
        if (!outcome) throw new KiteError('只能关闭 done 或 blocked 上报');
        confirm(args.from, 'close', `${args.machine}/${args.reportId}`);
        return peers.call(args.machine, 'POST', `/threads/${args.threadId}/reports/${args.reportId}/close`, { body: { outcome }, via });
      }
      const answer = source.answer!;
      let body: Record<string, unknown>;
      if (target.kind === 'confirm') {
        if (!answer.decision) throw new KiteError('目标是确认类上报，请用 report（kind: confirm）向用户征求同意，再转达');
        body = { decision: answer.decision, ...(answer.note ? { note: answer.note } : {}) };
      } else {
        if (!answer.text) throw new KiteError('目标需要文字答复，请用 report（kind: question）向用户提问，再转达');
        body = { text: answer.text };
      }
      return peers.call(args.machine, 'POST', `/threads/${args.threadId}/reports/${args.reportId}/answer`, {
        body: { id: `line:${source.id}:${target.id}`, ...body }, via, timeoutMs: 120_000 });
    }),
    tool('line_control', [
      '管理一个线程：send 发送你自己的说明（来源记为 Kite、经 Line），resume 继续暂停的线程，stop 停止，archive 归档线程（threadId）或独立工作区（workspaceId）。',
      'stop 与 archive 须带 confirmation：用户已同意的、你自己的 confirm 上报 ID。',
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
          confirm(args.confirmation, 'stop', `${args.machine}/${thread()}`);
          return peers.call(args.machine, 'POST', `/threads/${thread()}/interrupt`, { body: { id: operationId(context) }, via, timeoutMs: 120_000 });
        case 'archive':
          if (args.workspaceId) {
            confirm(args.confirmation, 'archive', `${args.machine}/${args.workspaceId}`);
            return peers.call(args.machine, 'POST', `/workspaces/${args.workspaceId}/archive`, { body: {}, via, timeoutMs: 120_000 });
          }
          confirm(args.confirmation, 'archive', `${args.machine}/${thread()}`);
          return peers.call(args.machine, 'POST', `/instances/${thread()}/archive`, { via, timeoutMs: 120_000 });
      }
    }),
    tool('line_workspace', [
      'create：在 machine 上为 project 建独立工作区，可带 name 与第一条消息 prompt；那台工作机没有检出时会先 clone。',
      'transfer：把 workspaceId 从 from 工作机流转到 to 工作机，源工作区须所有线程空闲；公开或看不出是否公开的仓库要用户同意推流转材料后传 allowMaterials。',
      '两者都须带 confirmation：用户已同意的、你自己的 confirm 上报 ID。',
    ].join(''), workspaceArgs, async (args, context) => {
      allowed(args.action);
      if (args.action === 'create') {
        if (!args.machine || !args.project) throw new KiteError('create 需要 machine 与 project');
        confirm(args.confirmation, 'create', `${args.machine}/${args.project}`);
        const model = await peers.call(args.machine, 'POST', '/workspaces', { body: { project: args.project, ...(args.name ? { name: args.name } : {}),
          ...(args.prompt ? { prompt: args.prompt } : {}) }, via, timeoutMs: 30 * 60_000 });
        return { workspaceId: model.workspace.id, status: model.workspace.status, cwd: model.workspace.cwd };
      }
      if (!args.workspaceId || !args.from || !args.to || args.from === args.to) throw new KiteError('transfer 需要 workspaceId 与不同的 from、to');
      confirm(args.confirmation, 'transfer', `${args.from}/${args.workspaceId}->${args.to}`);
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
