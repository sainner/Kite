/**
 * 回合中途等人回应（docs/工具审批与提问.md）：代理用 question 工具提问，或宿主在越界请求与必问动作执行前请用户批准。
 * 等待对象挂在这次工具调用上，只存在内存里，回应作为调用结果交回模型，回合接着往下走。停止时按未回答、未批准处理；
 * 服务重启时随调用一起作废，由恢复约定把调用记为结果未知，之后的回应因对不上当前等待而被拒绝。
 */
import { randomUUID } from 'node:crypto';
import { z } from 'zod';
import { KiteError } from './errors.ts';
import type { InputVia, JsonObject, Tool, ToolResult } from './harness/types.ts';

const option = z.object({
  label: z.string().trim().min(1).max(100),
  description: z.string().trim().min(1).max(1000),
}).strict();
const question = z.object({
  question: z.string().trim().min(1).max(4000),
  options: z.array(option).min(2).max(4).refine((options) => new Set(options.map((o) => o.label)).size === options.length, '同一问题的选项标签不能重复'),
  multiSelect: z.boolean(),
}).strict();
const questionArguments = z.object({ questions: z.array(question).min(1).max(4) }).strict();
export type Question = z.infer<typeof question>;

/** Line 代处理时写明的理由，随结果交回模型。 */
const reason = z.string().trim().min(1).max(2000).optional();
/** 对提问的回应：按问题顺序，每项是选中的选项标签，或用户写的「其他」，多选时两者可以并存。 */
const answersRequest = z.object({
  answers: z.array(z.object({
    selected: z.array(z.string().min(1).max(100)).max(4).optional(),
    other: z.string().trim().min(1).max(20_000).optional(),
  }).strict()).min(1).max(4),
  reason,
}).strict();
const decisionRequest = z.object({ decision: z.enum(['once', 'remember', 'deny']), reason }).strict();

/** 审批：tool 与 target 说明要做什么，reason 说明为什么要问；必问的动作每次都问，不接受「允许并记住」。 */
export interface ApprovalRequest { tool: string; target: string; reason: string; mustAsk: boolean }
export type ApprovalDecision = 'once' | 'remember' | 'deny';
type WaitingRequest = { kind: 'question'; questions: Question[] } | ({ kind: 'approval' } & ApprovalRequest);
export type Waiting = { id: string; since: number } & WaitingRequest;

const description = [
  '向用户提问，等用户回答后本回合接着往下走。需要用户在几个具体做法之间拍板、补充偏好或澄清含糊的要求时用。',
  '一次 1 到 4 个问题；每个问题写问题正文 question、2 到 4 个选项（label 简短，description 说明选它意味着什么），',
  'multiSelect 为 true 时可多选。用户总能选「其他」写自己的回答，不要自己加「其他」选项；推荐某个选项时把它放在第一个，并在 label 末尾注明（推荐）。',
  '结果是每个问题选中的选项标签，或用户写的「其他」原文。不问也能做好的事不要问；也可以把问题写在回复里结束回合。',
].join('');

const issues = (error: z.ZodError) => error.issues.map((issue) => issue.message).join('；');

/** 回应对不上当前等待（已回应、已作废或从未有过），带上线程当前的等待返回 409。 */
export class WaitingConflict extends KiteError {
  constructor(readonly waiting: Waiting | null) { super('这个等待已回应或已作废', 409); }
}

export class Waits {
  /** 每个线程同时最多一个等待：等待都挂在排他的工具调用上。settle 收到 undefined 表示会话停止。 */
  private waits = new Map<string, { waiting: Waiting; settle(response: unknown): void }>();

  constructor(private changed: (threadId: string, waiting: Waiting | undefined) => void) {}

  current(threadId: string): Waiting | undefined { return this.waits.get(threadId)?.waiting; }

  /** 线程自己的 question 工具。 */
  question(threadId: string): Tool {
    return {
      name: 'question', description, parameters: z.toJSONSchema(questionArguments) as JsonObject,
      validate(value) {
        const parsed = questionArguments.safeParse(value);
        if (!parsed.success) throw new Error(`参数无效：${issues(parsed.error)}`);
      },
      execute: async (value, { signal }): Promise<ToolResult> => {
        try {
          const result = await this.wait(threadId, { kind: 'question', questions: questionArguments.parse(value).questions }, signal);
          if (result === skipped) return { status: 'success', output: '用户没有回答，跳过了这些问题，直接发了一条新消息，见随后的输入。' };
          return result ? { status: 'success', output: JSON.stringify(result) } : { status: 'error', output: '会话已停止，用户没有回答。' };
        } catch (error) {
          if (error instanceof KiteError) return { status: 'error', output: error.message };
          throw error;
        }
      },
    };
  }

  /** 请用户批准一次越界或必问的请求；会话停止时返回 undefined。 */
  async approve(threadId: string, request: ApprovalRequest, signal: AbortSignal): Promise<ApprovalDecision | undefined> {
    return await this.wait(threadId, { kind: 'approval', ...request }, signal) as ApprovalDecision | undefined;
  }

  private wait(threadId: string, request: WaitingRequest, signal: AbortSignal): Promise<unknown> {
    if (this.waits.has(threadId)) throw new KiteError('这个线程已有一项在等用户回应');
    const waiting: Waiting = { id: randomUUID(), since: Date.now(), ...request };
    return new Promise((resolve) => {
      const settle = (response: unknown) => {
        signal.removeEventListener('abort', stopped);
        this.waits.delete(threadId);
        this.changed(threadId, undefined);
        resolve(response);
      };
      const stopped = () => settle(undefined);
      this.waits.set(threadId, { waiting, settle });
      this.changed(threadId, waiting);
      if (signal.aborted) stopped();
      else signal.addEventListener('abort', stopped, { once: true });
    });
  }

  /**
   * 回应线程当前的等待；对不上时 409，回应内容与等待不符时 400。via 是代用户处理的 Line：提问的结果写明由 Line 代答及理由，
   * 审批的记录留在 Line 的收件箱。
   */
  respond(threadId: string, id: string, value: unknown, via?: InputVia): void {
    const entry = this.waits.get(threadId);
    if (entry?.waiting.id !== id) throw new WaitingConflict(entry?.waiting ?? null);
    if (entry.waiting.kind === 'approval') return entry.settle(decisionOf(value, entry.waiting.mustAsk));
    const answers = answersOf(entry.waiting.questions, value);
    const why = (value as { reason?: string }).reason;
    entry.settle({ answers, ...(via ? { answeredBy: 'Line', ...(why ? { reason: why } : {}) } : {}) });
  }

  /**
   * 用户没回应、直接发了一条新消息（新消息已先排进输入）：提问按跳过、审批按拒绝交回，新消息在下一次请求里随结果送到。
   * 对不上当前等待（已回应或已作废）时什么也不做。
   */
  skip(threadId: string, id: string): void {
    const entry = this.waits.get(threadId);
    if (entry?.waiting.id !== id) return;
    entry.settle(entry.waiting.kind === 'approval' ? 'deny' satisfies ApprovalDecision : skipped);
  }
}

/** 提问被跳过时交回的结果，见 Waits.skip。 */
const skipped = Symbol('skipped');

/** 提问的结果交给模型：每个问题带上原文，以及选中的标签或「其他」原文。 */
function answersOf(questions: Question[], value: unknown) {
  const parsed = answersRequest.safeParse(value);
  if (!parsed.success) throw new KiteError(`回答无效：${issues(parsed.error)}`);
  const { answers } = parsed.data;
  if (answers.length !== questions.length) throw new KiteError(`要回答全部 ${questions.length} 个问题`);
  return questions.map((q, index) => {
    const { selected = [], other } = answers[index]!;
    const labels = new Set(q.options.map((o) => o.label));
    if (new Set(selected).size !== selected.length || selected.some((label) => !labels.has(label))) {
      throw new KiteError(`第 ${index + 1} 个问题选了不存在或重复的选项`);
    }
    const count = selected.length + (other ? 1 : 0);
    if (q.multiSelect ? count === 0 : count !== 1) throw new KiteError(`第 ${index + 1} 个问题${q.multiSelect ? '至少选一项' : '只能选一项或写「其他」'}`);
    return { question: q.question, ...(selected.length ? { selected } : {}), ...(other ? { other } : {}) };
  });
}

function decisionOf(value: unknown, mustAsk: boolean): ApprovalDecision {
  const parsed = decisionRequest.safeParse(value);
  if (!parsed.success) throw new KiteError(`审批无效：${issues(parsed.error)}`);
  if (mustAsk && parsed.data.decision === 'remember') throw new KiteError('必问的动作每次都要问，只能批准这一次或拒绝');
  return parsed.data.decision;
}
