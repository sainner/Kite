/**
 * 线程向用户的上报：模型用 report 工具提出，用户的答复作为人的输入送回线程。
 * 状态按凭据推进：答复保存是 answered，输入落到线程是 delivered，纳入模型请求是 incorporated，纳入后的回合结束是 closed；
 * 纳入与退回从两个后端的原生事件得知，不从界面状态推断。
 */
import { randomUUID } from 'node:crypto';
import { z } from 'zod';
import { KiteError } from './errors.ts';
import type { Bus, KiteEvent } from './events.ts';
import type { JsonObject, Tool } from './harness/types.ts';
import type { Report, ReportAnswer } from './model.ts';
import type { Store } from './store.ts';

const reportArguments = z.object({
  kind: z.enum(['question', 'confirm', 'done', 'blocked', 'withdraw']),
  text: z.string().trim().min(1).max(20_000),
  refs: z.array(z.string().trim().min(1).max(2048)).max(20).optional(),
}).strict();

export const reportAnswerRequest = z.object({
  id: z.string().min(1).max(200),
  text: z.string().trim().min(1).max(100_000).optional(),
  decision: z.enum(['yes', 'no']).optional(),
  note: z.string().trim().min(1).max(100_000).optional(),
}).strict();
export type ReportAnswerRequest = z.infer<typeof reportAnswerRequest>;
export const reportCloseRequest = z.object({ outcome: z.enum(['accepted', 'dismissed']) }).strict();

const description = [
  '向用户提出需要处理的事项，用户不必盯着对话也能看到。kind：question 需要用户回答才能继续；confirm 需要用户决定同意或不同意；',
  'done 你认为任务已完成，请用户验收；blocked 无法继续，说明卡在哪里；withdraw 撤回自己尚未答复的上报（问题已自行解决时），text 写原因。',
  'text 写给用户看：背景、结论和需要用户做的决定。refs 可列相关文件或差异的引用，如 src/a.ts:10-20、src/a.ts:diff_a81。',
  '提出 question、confirm、blocked 后结束本回合等待答复，答复会作为用户消息送来；同一时间只能有一个未答复的上报。',
].join('');

/** 尚未结束、仍归线程处理的状态；归档时一并结束。 */
const unsettled = ['open', 'answered', 'delivered', 'incorporated'] as const;

/** 确认类答复给模型的正文；其余直接用用户原文。 */
function answerText(answer: ReportAnswer): string {
  if (!answer.decision) return answer.text!;
  return [answer.decision === 'yes' ? '同意。' : '不同意。', answer.note].filter(Boolean).join('\n\n');
}

const sameAnswer = (a: ReportAnswer, b: Omit<ReportAnswer, 'at'>) =>
  a.inputId === b.inputId && a.text === b.text && a.decision === b.decision && a.note === b.note;

/** 已结束或已答复的上报再收到不同的答复或关闭时，带上当前状态返回 409。 */
export class ReportConflict extends KiteError {
  constructor(message: string, readonly report: Report) { super(message, 409); }
}

export interface ReportHost {
  store: Store;
  bus: Bus;
  /** 把答复作为人的输入送到线程；同一输入 ID 与正文重复送达只去重。送不到时抛错，上报停在 answered。 */
  deliver(threadId: string, text: string, inputId: string, via?: ReportAnswer['via']): Promise<unknown>;
  /** 工作区控制锁：答复与关闭在锁内保存，和交接互斥。投递另取锁，须在锁外调用。 */
  control<T>(workspaceId: string, action: () => Promise<T>): Promise<T>;
}

export class Reports {
  /** 进行中的投递，同一上报不并发送两次。 */
  private delivering = new Map<string, Promise<void>>();

  constructor(private host: ReportHost) {
    host.bus.subscribe(undefined, (event) => this.observe(event));
  }

  list(threadId: string): Report[] { return this.host.store.reports(threadId); }

  get(threadId: string, id: string): Report {
    const report = this.host.store.report(id);
    if (!report || report.threadId !== threadId) throw new KiteError('这个线程没有这条上报', 404);
    return report;
  }

  /** 线程自己的 report 工具；回合与调用 ID 由宿主提供，同一调用重试返回同一条上报。 */
  tool(threadId: string): Tool {
    return {
      name: 'report', description, parameters: z.toJSONSchema(reportArguments) as JsonObject,
      validate(value) {
        const parsed = reportArguments.safeParse(value);
        if (!parsed.success) throw new Error(`参数无效：${parsed.error.issues.map((issue) => issue.message).join('；')}`);
      },
      execute: async (value, context) => {
        if (!context.callId || !context.turnId) throw new Error('上报缺少宿主调用 ID');
        try {
          const report = this.create(threadId, reportArguments.parse(value), `${context.turnId}:${context.callId}`);
          return { status: 'success', output: JSON.stringify(report ? { reportId: report.id, status: report.status } : { withdrawn: true }) };
        } catch (error) {
          if (error instanceof KiteError) return { status: 'error', output: error.message };
          throw error;
        }
      },
    };
  }

  private create(threadId: string, args: z.infer<typeof reportArguments>, origin: string): Report | undefined {
    const store = this.host.store;
    return store.transaction(() => {
      const existing = store.reportByOrigin(threadId, origin);
      if (existing) return existing;
      const open = store.reports(threadId).find((report) => report.status === 'open');
      if (args.kind === 'withdraw') {
        if (!open) throw new KiteError('没有尚未答复的上报可撤回');
        store.moveReport(open.id, ['open'], 'superseded', { closure: { at: Date.now(), reason: args.text } });
        this.changed(open.id);
        return undefined;
      }
      if (open) throw new KiteError(`已有尚未答复的上报 ${open.id}；等用户答复，或先用 kind: withdraw 撤回`);
      const now = Date.now();
      const report: Report = { id: randomUUID(), threadId, workspaceId: store.instance(threadId)!.workspaceId, kind: args.kind,
        text: args.text, refs: args.refs ?? [], status: 'open', createdAt: now, updatedAt: now };
      store.addReport(report, origin);
      this.changed(report.id);
      return report;
    });
  }

  /** 保存答复后立即尝试投递；投递失败不影响已保存的答复，之后在工作区空闲或重试同一答复时再送。 */
  async answer(threadId: string, id: string, request: ReportAnswerRequest, via?: ReportAnswer['via']): Promise<Report> {
    const report = this.get(threadId, id);
    const confirm = report.kind === 'confirm';
    if (confirm && (!request.decision || request.text !== undefined)) throw new KiteError('确认类上报用 decision 答复，可附 note');
    if (!confirm && (!request.text || request.decision !== undefined || request.note !== undefined)) throw new KiteError('这类上报用 text 答复');
    const answer = { inputId: request.id, ...(request.text ? { text: request.text } : {}),
      ...(request.decision ? { decision: request.decision } : {}), ...(request.note ? { note: request.note } : {}), ...(via ? { via } : {}) };
    const saved = await this.host.control(report.workspaceId, async () => {
      this.assertOpen(report.workspaceId);
      return this.host.store.transaction(() => {
        if (this.host.store.moveReport(id, ['open'], 'answered', { answer: { ...answer, at: Date.now() } })) return true;
        const current = this.host.store.report(id)!;
        if (current.answer && sameAnswer(current.answer, answer)) return false;
        throw new ReportConflict(current.status === 'open' ? '上报已变化，请刷新后重试' : '这条上报已答复或已结束', current);
      });
    });
    if (saved) this.changed(id);
    await this.deliver(id);
    return this.host.store.report(id)!;
  }

  /** 用户关闭 done（接受）或 blocked（不再处理）；同样的关闭重复提交返回当前状态。 */
  close(threadId: string, id: string, outcome: 'accepted' | 'dismissed'): Promise<Report> {
    const report = this.get(threadId, id);
    const expected = report.kind === 'done' ? 'accepted' : report.kind === 'blocked' ? 'dismissed' : undefined;
    if (!expected) throw new KiteError('只能关闭 done 或 blocked 上报；question 与 confirm 需要答复');
    if (outcome !== expected) throw new KiteError(report.kind === 'done' ? 'done 上报关闭为 accepted；退回请答复说明' : 'blocked 上报关闭为 dismissed');
    return this.host.control(report.workspaceId, async () => {
      this.assertOpen(report.workspaceId);
      if (this.host.store.moveReport(id, ['open'], 'closed', { closure: { at: Date.now(), outcome } })) {
        this.changed(id);
        return this.host.store.report(id)!;
      }
      const current = this.host.store.report(id)!;
      if (current.status === 'closed' && current.closure?.outcome === outcome) return current;
      throw new ReportConflict('这条上报已答复或已结束', current);
    });
  }

  /**
   * 答复与关闭只在工作区打开时接受。交接时封存的材料不带之后的改动，冻结的副本也不再推进；
   * 这时收下答复，目标机上的上报仍是 open，答复就丢了。在锁内检查，和交接互斥。
   */
  private assertOpen(workspaceId: string): void {
    const status = this.host.store.workspace(workspaceId)?.status;
    if (status === 'open') return;
    throw new KiteError(status === 'handing_off' ? '工作区正在交给另一台工作机，接管后请到新宿主答复'
      : status === 'transferred' ? '工作区已流转到另一台工作机，请到新宿主答复' : '工作区没有打开，暂不能处理上报', 409);
  }

  /** 线程收到不是答复的人类输入：尚未答复的上报不再追问，之后到达的答复会被拒绝。 */
  inputReceived(threadId: string, inputId: string): void {
    if (this.host.store.reportByInput(threadId, inputId)) return;
    const open = this.host.store.reports(threadId).find((report) => report.status === 'open');
    if (open && this.host.store.moveReport(open.id, ['open'], 'superseded', { closure: { at: Date.now(), reason: '线程收到了别的用户输入' } })) {
      this.changed(open.id);
    }
  }

  /** 线程或工作区归档：未结束的上报关闭并记原因，尚未纳入请求的答复正文退还给答复方。 */
  archive(threadIds: readonly string[], reason: string): void {
    for (const threadId of threadIds) for (const report of this.host.store.reports(threadId)) {
      if (!(unsettled as readonly string[]).includes(report.status)) continue;
      const returned = report.answer && (report.status === 'answered' || report.status === 'delivered') ? answerText(report.answer) : undefined;
      if (this.host.store.moveReport(report.id, [report.status], 'archived', { closure: { at: Date.now(), reason, ...(returned ? { returned } : {}) } })) {
        this.changed(report.id);
      }
    }
  }

  /** 补送已保存但还没送到的答复：服务启动时全部，线程回到空闲时只看同一工作区（执行互斥是最常见的阻碍）。 */
  async retry(workspaceId?: string): Promise<void> {
    const pending = workspaceId ? this.host.store.workspaceReports(workspaceId, ['answered']) : this.host.store.reportsInStatus(['answered']);
    for (const report of pending) await this.deliver(report.id);
  }

  private deliver(id: string): Promise<void> {
    const running = this.delivering.get(id);
    if (running) return running;
    const delivery = (async () => {
      const report = this.host.store.report(id);
      if (report?.status !== 'answered' || !report.answer) return;
      try { await this.host.deliver(report.threadId, answerText(report.answer), report.answer.inputId, report.answer.via); }
      catch { return; }
      if (this.host.store.moveReport(id, ['answered'], 'delivered')) this.changed(id);
    })().finally(() => this.delivering.delete(id));
    this.delivering.set(id, delivery);
    return delivery;
  }

  /** 纳入的凭据：harness 的请求开始记录列出的输入，Claude 由 SDK 确认交接后的输入状态。 */
  private observe(event: KiteEvent): void {
    if (!('threadId' in event)) return;
    const threadId = event.threadId;
    if (event.type === 'harness' && event.event.type === 'record') {
      const record = event.event.record;
      if (record.type === 'request.started') for (const inputId of record.inputIds) this.incorporated(threadId, inputId);
      if (record.type === 'input.cancelled') this.returned(threadId, record.inputId);
      if (record.type === 'thread.stopped') for (const input of record.returned) this.returned(threadId, input.id);
    } else if (event.type === 'claude.control') {
      for (const entry of event.state.inputs) {
        if ((entry.status === 'active' || entry.status === 'done') && entry.delivered) this.incorporated(threadId, entry.input.id);
        if (entry.status === 'cancelled' && !entry.delivered) this.returned(threadId, entry.input.id);
      }
    } else if (event.type === 'idle') {
      // 回合结束指正常完成；停止或失败后答复仍在上下文里，等下一个完成的回合再收口，归档时记为 archived。
      if (event.completed) for (const report of this.host.store.reports(threadId)) {
        if (report.status === 'incorporated' && this.host.store.moveReport(report.id, ['incorporated'], 'closed', { closure: { at: Date.now() } })) {
          this.changed(report.id);
        }
      }
      const workspaceId = this.host.store.instance(threadId)?.workspaceId;
      if (workspaceId) void this.retry(workspaceId);
    }
  }

  /** 投递与纳入可能先后颠倒：输入落盘后请求随即开始，投递的收尾还没把状态改成 delivered。 */
  private incorporated(threadId: string, inputId: string): void {
    const report = this.host.store.reportByInput(threadId, inputId);
    if (report && this.host.store.moveReport(report.id, ['answered', 'delivered'], 'incorporated')) this.changed(report.id);
  }

  /** 答复在纳入前被撤回或随停止退还：正文回到答复方的草稿，上报重新等待答复。 */
  private returned(threadId: string, inputId: string): void {
    const report = this.host.store.reportByInput(threadId, inputId);
    if (report && this.host.store.moveReport(report.id, ['answered', 'delivered'], 'open', { answer: null })) this.changed(report.id);
  }

  private changed(id: string): void {
    const report = this.host.store.report(id)!;
    this.host.bus.emit({ type: 'report.changed', workspaceId: report.workspaceId, threadId: report.threadId, report });
  }
}
