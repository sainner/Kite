/**
 * 等人回应（docs/工具审批与提问.md）。两种做法：
 * - 审批（Waits）阻塞回合：宿主在越界请求与必问动作执行前请用户批准，等待挂在这次工具调用上，只存在内存里，决定作为调用结果
 *   交回模型。停止时按未批准处理；服务重启时随调用一起作废，由恢复约定把调用记为结果未知。
 * - 提问与密钥请求（Asks）不阻塞：代理用 question 工具提问、用 credentials 的请求动作要密钥，工具发出请求后立即返回，请求存在库里
 *   等用户回应；回应由宿主处理后作为一条新的输入交给代理（在跑的下一次请求时纳入，空闲的就此唤醒）。代理可以收回，线程归档时撤下。
 */
import { randomUUID } from 'node:crypto';
import { z } from 'zod';
import { KiteError } from './errors.ts';
import type { InputVia, JsonObject, Tool, ToolResult } from './harness/types.ts';
import { secretLabel, secretValue } from './secrets.ts';
import type { Store } from './store.ts';

const option = z.object({
  label: z.string().trim().min(1).max(100),
  description: z.string().trim().min(1).max(1000),
}).strict();
const question = z.object({
  question: z.string().trim().min(1).max(4000),
  options: z.array(option).min(2).max(4).refine((options) => new Set(options.map((o) => o.label)).size === options.length, '同一问题的选项标签不能重复'),
  multiSelect: z.boolean(),
}).strict();
/** 提问写 questions，收回写 withdraw，二者只写一个；参数的顶层保持一个对象，各家模型接口都收。 */
const questionArguments = z.object({
  questions: z.array(question).min(1).max(4).optional(),
  withdraw: z.string().min(1).optional().describe('要收回的提问的请求 ID'),
}).strict().refine((args) => (args.questions === undefined) !== (args.withdraw === undefined), '提问写 questions，收回写 withdraw，只写一个');
export type Question = z.infer<typeof question>;

/** Line 代处理时写明的理由，随结果交给模型。 */
const reason = z.string().trim().min(1).max(2000).optional();
/** 对提问的回应：按问题顺序，每项是选中的选项标签，或用户写的「其他」，多选时两者可以并存；或不回答（deny）。 */
const questionResponse = z.union([
  z.object({
    answers: z.array(z.object({
      selected: z.array(z.string().min(1).max(100)).max(4).optional(),
      other: z.string().trim().min(1).max(20_000).optional(),
    }).strict()).min(1).max(4),
    reason,
  }).strict(),
  z.object({ decision: z.literal('deny'), reason }).strict(),
]);
const decisionRequest = z.object({ decision: z.enum(['once', 'remember', 'deny']), reason }).strict();
/** 对密钥请求的回应：按请求的顺序逐项给值（没填的为 null）与范围（默认项目专用），或拒绝。 */
const secretResponse = z.union([
  z.object({ secret: z.object({ values: z.array(secretValue.shape.value.nullable()), scope: z.enum(['project', 'account']).optional() }).strict() }).strict(),
  z.object({ decision: z.literal('deny'), reason }).strict(),
]);
export type SecretResponse = { values: Array<string | null>; scope: 'project' | 'account' } | { denied: true; reason?: string };
export type Answer = { question: string; selected?: string[]; other?: string };
export type QuestionResponse = { answers: Answer[]; reason?: string } | { denied: true; reason?: string };

/** 审批：tool 与 target 说明要做什么，reason 说明为什么要问；必问的动作每次都问，不接受「允许并记住」。 */
export interface ApprovalRequest {
  tool: string; target: string; reason: string; mustAsk: boolean;
  /** 申请在沙箱外运行这条命令：target 是命令原文，reason 是代理写的用途。 */
  outside?: boolean;
  /** 出沙箱的命令绑定的密钥引用，如 {project.ssh_pw}；没绑定时没有。 */
  secretReferences?: string[];
}
export type ApprovalDecision = 'once' | 'remember' | 'deny';
/**
 * 密钥请求里的一项：一条独立的密钥（name，带类型 secretKind），或环境变量文件 file 里的变量 key。value 是代理自己给的值，
 * exists 表示默认目标（项目专用的同名密钥，或文件里的这个变量）已经存在，保存是替换。
 */
export interface SecretWaitingItem {
  reason: string; name?: string; secretKind?: 'text' | 'file'; file?: string; key?: string; value?: string; exists: boolean;
}
type AskRequest = { kind: 'question'; questions: Question[] } | { kind: 'secret'; secrets: SecretWaitingItem[] };
/** 不阻塞回合的请求：提问，或一次要的几项密钥（用户在同一张卡片里填）。 */
export type Ask = { id: string; since: number } & AskRequest;
/** 等人回应的对象：阻塞的审批，或不阻塞的请求；线程状态里分别是 waiting 与 asks。 */
export type Waiting = Ask | ({ id: string; since: number; kind: 'approval' } & ApprovalRequest);

const description = [
  '向用户提问。需要用户在几个具体做法之间拍板、补充偏好或澄清含糊的要求时用。',
  '一次 1 到 4 个问题；每个问题写问题正文 question、2 到 4 个选项（label 简短，description 说明选它意味着什么），',
  'multiSelect 为 true 时可多选。用户总能选「其他」写自己的回答，不要自己加「其他」选项；推荐某个选项时把它放在第一个，并在 label 末尾注明（推荐）。',
  '这个工具不等回答，立即返回请求 ID；用户回答或不回答，结果会作为一条新的输入发给你。',
  '下一步取决于答案时不要猜，先做不依赖答案的事，没有就结束回合。用户在对话里直接答了这件事，就用 {withdraw: 请求 ID} 收回这个提问。',
  '不问也能做好的事不要问；也可以把问题写在回复里结束回合。',
].join('');

const issues = (error: z.ZodError) => error.issues.map((issue) => issue.message).join('；');

/** 回应对不上（已回应、已作废、已收回或从未有过），带上线程当前在等的审批返回 409。 */
export class WaitingConflict extends KiteError {
  constructor(readonly waiting: Waiting | null) { super('这一项已回应、作废或收回了', 409); }
  override details() { return { waiting: this.waiting }; }
}

/** 审批：每个线程同时最多一个，挂在排他的工具调用上。 */
export class Waits {
  /** settle 收到 undefined 表示会话停止。 */
  private waits = new Map<string, { waiting: Waiting; settle(response: unknown): void }>();

  constructor(private changed: (threadId: string, waiting: Waiting | undefined) => void) {}

  current(threadId: string): Waiting | undefined { return this.waits.get(threadId)?.waiting; }

  /** 请用户批准一次越界或必问的请求；会话停止时返回 undefined。 */
  async approve(threadId: string, request: ApprovalRequest, signal: AbortSignal): Promise<ApprovalDecision | undefined> {
    if (this.waits.has(threadId)) throw new KiteError('这个线程已有一项在等用户批准');
    const waiting: Waiting = { id: randomUUID(), since: Date.now(), kind: 'approval', ...request };
    return new Promise((resolve) => {
      const settle = (response: unknown) => {
        signal.removeEventListener('abort', stopped);
        this.waits.delete(threadId);
        this.changed(threadId, undefined);
        resolve(response as ApprovalDecision | undefined);
      };
      const stopped = () => settle(undefined);
      this.waits.set(threadId, { waiting, settle });
      this.changed(threadId, waiting);
      if (signal.aborted) stopped();
      else signal.addEventListener('abort', stopped, { once: true });
    });
  }

  /** 回应线程在等的审批；对不上时 409，内容不符时 400。Line 代处理的记录留在 Line 的收件箱。 */
  respond(threadId: string, id: string, value: unknown): void {
    const entry = this.waits.get(threadId);
    if (entry?.waiting.id !== id || entry.waiting.kind !== 'approval') throw new WaitingConflict(entry?.waiting ?? null);
    entry.settle(decisionOf(value, entry.waiting.mustAsk));
  }

  /** 用户没回应审批、直接发了一条新消息（新消息已先排进输入）：按拒绝交回。对不上当前审批时什么也不做。 */
  skip(threadId: string, id: string): void {
    const entry = this.waits.get(threadId);
    if (entry?.waiting.id === id) entry.settle('deny' satisfies ApprovalDecision);
  }
}

/** 提问与密钥请求：存在库里，按发出的先后排；变了就把线程的整份请求交给 changed。 */
export class Asks {
  constructor(private store: Store, private changed: (threadId: string, asks: Ask[]) => void) {}

  list(threadId: string): Ask[] { return this.store.asks(threadId); }
  get(threadId: string, id: string): Ask | undefined { return this.list(threadId).find((ask) => ask.id === id); }

  add(threadId: string, request: AskRequest): Ask {
    const ask: Ask = { id: randomUUID(), since: Date.now(), ...request };
    this.store.addAsk(threadId, ask);
    this.changed(threadId, this.list(threadId));
    return ask;
  }

  /** 撤下一项；已经不在时返回 false。 */
  remove(threadId: string, id: string): boolean {
    const removed = this.store.removeAsk(threadId, id);
    if (removed) this.changed(threadId, this.list(threadId));
    return removed;
  }

  clear(threadId: string): void {
    if (this.store.clearAsks(threadId)) this.changed(threadId, []);
  }

  /** 线程自己的 question 工具：提问或收回。 */
  question(threadId: string): Tool {
    return {
      name: 'question', description, parameters: z.toJSONSchema(questionArguments) as JsonObject,
      validate(value) {
        const parsed = questionArguments.safeParse(value);
        if (!parsed.success) throw new Error(`参数无效：${issues(parsed.error)}`);
      },
      execute: async (value): Promise<ToolResult> => {
        const args = questionArguments.parse(value);
        if (args.withdraw !== undefined) return { status: 'success', output: this.withdraw(threadId, args.withdraw, 'question') };
        const ask = this.add(threadId, { kind: 'question', questions: args.questions! });
        return { status: 'success', output: `已向用户提问，请求 ID 是 ${ask.id}。` };
      },
    };
  }

  /** 代理收回自己的请求，返回交给模型的说明。 */
  withdraw(threadId: string, id: string, kind: Ask['kind']): string {
    const ask = this.get(threadId, id);
    if (!ask || ask.kind !== kind) return `没有在等用户回应的这个${kind === 'question' ? '提问' : '密钥请求'}：${id}，可能已经回应或收回了。`;
    this.remove(threadId, id);
    return '已收回。';
  }
}

/** 提问的回应：校验后按问题带上原文。 */
export function questionResponseOf(ask: Extract<Ask, { kind: 'question' }>, value: unknown): QuestionResponse {
  const parsed = questionResponse.safeParse(value);
  if (!parsed.success) throw new KiteError(`回答无效：${issues(parsed.error)}`);
  if ('decision' in parsed.data) return { denied: true, ...(parsed.data.reason ? { reason: parsed.data.reason } : {}) };
  const { answers, reason: why } = parsed.data;
  const { questions } = ask;
  if (answers.length !== questions.length) throw new KiteError(`要回答全部 ${questions.length} 个问题`);
  return { answers: questions.map((q, index) => {
    const { selected = [], other } = answers[index]!;
    const labels = new Set(q.options.map((o) => o.label));
    if (new Set(selected).size !== selected.length || selected.some((label) => !labels.has(label))) {
      throw new KiteError(`第 ${index + 1} 个问题选了不存在或重复的选项`);
    }
    const count = selected.length + (other ? 1 : 0);
    if (q.multiSelect ? count === 0 : count !== 1) throw new KiteError(`第 ${index + 1} 个问题${q.multiSelect ? '至少选一项' : '只能选一项或写「其他」'}`);
    return { question: q.question, ...(selected.length ? { selected } : {}), ...(other ? { other } : {}) };
  }), ...(why ? { reason: why } : {}) };
}

/** 密钥请求的回应：逐项的值与请求对上，文件里的项只能项目专用。一项都没填的也收下，交给模型时如实说明。 */
export function secretResponseOf(ask: Extract<Ask, { kind: 'secret' }>, value: unknown): SecretResponse {
  const parsed = secretResponse.safeParse(value);
  if (!parsed.success) throw new KiteError(`回应无效：${issues(parsed.error)}`);
  if ('decision' in parsed.data) return { denied: true, ...(parsed.data.reason ? { reason: parsed.data.reason } : {}) };
  const { values } = parsed.data.secret;
  const scope = parsed.data.secret.scope ?? 'project';
  if (values.length !== ask.secrets.length) throw new KiteError(`要按顺序给全部 ${ask.secrets.length} 项，没填的写 null`);
  if (scope === 'account' && ask.secrets.every((s) => s.file)) throw new KiteError('环境变量文件里的项只能存为项目专用');
  return { values, scope };
}

/** 提问的结果交给代理的那条输入：via 是代答的 Line。 */
export function questionResultText(ask: Extract<Ask, { kind: 'question' }>, response: QuestionResponse, via?: InputVia): string {
  const who = via ? 'Line 替用户' : '用户';
  if ('denied' in response) {
    return [`${who}没有回答你的提问（请求 ${ask.id}），关掉了：`, ...ask.questions.map((q) => `- ${q.question}`),
      ...(response.reason ? [`理由：${response.reason}`] : [])].join('\n');
  }
  return [`${who}回答了你的提问（请求 ${ask.id}）：`, ...response.answers.map((a) => {
    const parts = [...(a.selected ?? []).map((label) => `「${label}」`), ...(a.other ? [`其他：${a.other}`] : [])];
    return `- ${a.question}\n  回答：${parts.join('；')}`;
  }), ...(via && response.reason ? [`Line 的理由：${response.reason}`] : [])].join('\n');
}

/** 拒绝密钥请求时交给代理的那条输入。 */
export function secretDeniedText(ask: Extract<Ask, { kind: 'secret' }>, reasonText?: string): string {
  return `用户拒绝提供你请求的密钥（请求 ${ask.id}）：${ask.secrets.map(secretLabel).join('、')}${reasonText ? `。理由：${reasonText}` : ''}`;
}

function decisionOf(value: unknown, mustAsk: boolean): ApprovalDecision {
  const parsed = decisionRequest.safeParse(value);
  if (!parsed.success) throw new KiteError(`审批无效：${issues(parsed.error)}`);
  if (mustAsk && parsed.data.decision === 'remember') throw new KiteError('必问的动作每次都要问，只能批准这一次或拒绝');
  return parsed.data.decision;
}
