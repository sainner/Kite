/**
 * Line 的 monitor（docs/Line与工作区流转.md「monitor 的事件路由」、docs/Monitor.md）：Line 工作区里由宿主建的那个
 * kite.monitor 实例，来源是账号下各工作机的会话状态与关注设备，视图就是收件箱。不自己运行模型。
 * 定时读各工作机的状态汇总（本机变化后 2 秒补读），把事件路由成三种动作：进收件箱、发系统通知、唤醒 Line。
 * 收件箱默认不唤醒 Line；只有用户点代处理、托管、用户回来时的简报与 Line 自己发起的工作有了结果，才给 Line 的线程
 * 投一条 Kite 来源的输入（正文用 line.monitor 模板），自动唤醒每天有预算。Line 自约的时刻用通用 monitor 的定时来源。
 * 状态（收件箱、离开期间的时间线、托管、待投递项）存在这个实例上，随工作区流转。远程工作机的事件只提示重读，
 * 这一版用定时读取代替订阅各机事件流。
 */
import { randomUUID } from 'node:crypto';
import { z } from 'zod';
import { assembleContext, bindContext, sceneValues } from '../harness/context/assembler.ts';
import type { ContextDefinition, ContextValues } from '../harness/context/types.ts';
import type { InputNotice } from '../harness/types.ts';
import type { AccountMachine } from '../account-data/directory.ts';
import type { MachineSummary } from '../kite.ts';
import type { AgentInstance, PluginInstance } from '../model.ts';
import type { Store } from '../store.ts';
import type { Waiting } from '../waiting.ts';
import { KiteError } from '../errors.ts';
import { secretLabel } from '../secrets.ts';
import type { Peers } from './peers.ts';

const section = (id: string, title: string, variable: string, lead: string) => ({
  type: 'condition' as const, id, title, variable,
  cases: [{ id: `${id}-none`, title: '没有', equals: '', blocks: [] }],
  otherwise: { id: `${id}-some`, title: '有', blocks: [{ type: 'paragraph' as const, id: `${id}-list`, title, parts: [
    { type: 'text' as const, text: lead }, { type: 'variable' as const, name: variable },
  ] }] },
});

export const lineMonitorContextDefinition: ContextDefinition = {
  version: 2, id: 'kite.line-monitor', title: 'Line 的唤醒', scene: 'line.monitor',
  blocks: [
    section('delegated', '交给你处理的事项', 'monitor.delegated',
      '下面这些收件箱事项交给你代用户处理：\n'),
    section('results', '你发起的工作有了结果', 'monitor.results', '你之前发起的工作有了结果：\n'),
    section('briefing', '用户回来了', 'monitor.briefing', ''),
  ],
};

const id = z.string().min(1);
const itemKinds = ['approval', 'question', 'secret', 'turn', 'failed', 'preparation', 'unreachable'] as const;
export type InboxKind = (typeof itemKinds)[number];
const itemSchema = z.object({
  /** waiting:<等待>、turn:<线程>、failed:<线程>、preparation:<工作区>、machine:<工作机>。 */
  id,
  kind: z.enum(itemKinds),
  machine: z.object({ id, name: z.string() }).strict(),
  workspace: z.object({ id, name: z.string(), project: z.object({ id, name: z.string() }).strict() }).strict().optional(),
  thread: z.object({ id, title: z.string() }).strict().optional(),
  /** 审批、提问与密钥请求：原线程等待的那个对象，回应写回原线程所在工作机。 */
  waiting: z.custom<Waiting>((value) => typeof value === 'object' && value !== null).optional(),
  /** 一句话说明：提问摘要、审批目标、失败原因等。 */
  text: z.string(),
  /** 事情发生的时刻；addedAt 是进收件箱的时刻。 */
  at: z.number(),
  addedAt: z.number(),
  /** Line 自己线程上的请求：只能由用户处理。 */
  own: z.literal(true).optional(),
  /** 交给了 Line：用户点代处理、按时段托管或超时托管；sent 是投给 Line 的时刻。 */
  delegated: z.object({ by: z.enum(['user', 'period', 'timeout']), at: z.number(), sent: z.number().optional() }).strict().optional(),
  /** 已交回用户（Line 留给用户、没给出处理或超出预算），不再自动交给 Line。 */
  left: z.literal(true).optional(),
  notified: z.literal(true).optional(),
  /** Line 留给用户的说明，或宿主交回用户的原因。 */
  note: z.string().optional(),
}).strict();
export type InboxItem = z.infer<typeof itemSchema>;

/** 离开期间了结的事项：Line 代处理了（handled）、Line 留给用户（left）、在别处回应或自己解除（resolved）。 */
const recordSchema = z.object({ at: z.number(), item: itemSchema, outcome: z.enum(['handled', 'left', 'resolved']),
  decision: z.string().optional(), reason: z.string().optional() }).strict();
export type InboxRecord = z.infer<typeof recordSchema>;

const wakeSchema = z.discriminatedUnion('kind', [
  /** Line 发起的工作有了结果；超出预算时 fallback 进用户的收件箱。 */
  z.object({ kind: z.literal('result'), text: z.string(), at: z.number(), fallback: itemSchema }).strict(),
  z.object({ kind: z.literal('briefing'), since: z.number(), at: z.number() }).strict(),
]);

export const delegationSchema = z.object({
  /** 按时段托管到这个时刻（毫秒）。 */
  until: z.number().optional(),
  /** 超时托管：审批与提问等用户这么多分钟还没处理，再交给 Line。 */
  timeoutMinutes: z.number().int().min(1).max(24 * 60).optional(),
}).strict();
export type Delegation = z.infer<typeof delegationSchema>;


/** 旧版本留下的字段在解析时丢掉。 */
const stateSchema = z.object({
  items: z.record(z.string(), itemSchema).default({}),
  /** 当前或上一次离开的那一段：回来后作为简报留着，下次离开时换成新的一段。 */
  period: z.object({ since: z.number(), until: z.number().optional() }).strict().optional(),
  /** 这一段里了结的事项，按时间先后。 */
  records: z.array(recordSchema).default([]),
  /** 每个线程已路由过的回合收尾时间，键是「工作机:线程」。 */
  seen: z.record(z.string(), z.number()).default({}),
  /** 连不上的工作机从何时起连不上（毫秒）。 */
  unreachable: z.record(z.string(), z.number()).default({}),
  /** 离开时刻：关注设备变空的那一刻；有设备关注时没有。 */
  away: z.number().optional(),
  /** 上一条回合结束摘要通知的时刻。 */
  digestAt: z.number().optional(),
  delegation: delegationSchema.default({}),
  /** 还没投给 Line 的唤醒。 */
  queue: z.array(wakeSchema).default([]),
  /** 当天（本机时区）已投递的唤醒次数。 */
  wakes: z.object({ day: z.string(), count: z.number().int() }).strict().optional(),
  /** line_relay 已转达的用户消息，键由来源消息与目标决定，重试只去重。 */
  relays: z.record(z.string(), z.enum(['answered', 'sent'])).default({}),
  seq: z.number().int().nonnegative().default(0),
  /** 已决定投递、尚未确认送达的输入；重启后用同一 ID 补送。 */
  pending: z.object({ id: z.string(), text: z.string(), title: z.string().optional() }).strict().optional(),
});
export type MonitorState = z.infer<typeof stateSchema>;

export const monitorState = (instance: Pick<AgentInstance, 'state'>): MonitorState => stateSchema.parse(instance.state.monitor ?? {});

/** 系统通知：App 在 Mac 上发本地通知，点开是收件箱里的 item。 */
export interface LineNotification { id: string; title: string; body: string; item?: string }

/** 连不上超过这么久才进收件箱，短暂断线不打扰。 */
const UNREACHABLE_MS = 30 * 60_000;
/** 回合结束不逐条通知：离开后攒这么久发第一条摘要，之后每隔这么久最多一条。 */
const DIGEST_MS = 10 * 60_000;
/** 离开这么久、回来时收件箱有离开期间进来的事项，才唤醒 Line 写简报。 */
const BRIEFING_AWAY_MS = 30 * 60_000;
/** 按时段托管时攒一会儿再唤醒 Line，把一串事项合成一次。 */
const PERIOD_BATCH_MS: Partial<Record<InboxKind, number>> = { approval: 15_000, question: 15_000, secret: 15_000, failed: 15_000, turn: 60_000 };
/** 每天自动唤醒 Line 的次数上限；用户点的代处理不受限。 */
export const DAILY_WAKES = 40;
const RECORDS_KEEP = 200;
const RELAYS_KEEP = 200;
/** 没人关注时一进收件箱就单条通知的事项；回合结束走摘要。 */
const IMMEDIATE = new Set<InboxKind>(['approval', 'question', 'secret', 'failed', 'preparation', 'unreachable']);

const clip = (text: string, limit: number) => {
  const flat = text.replace(/\s+/g, ' ').trim();
  return flat.length > limit ? `${flat.slice(0, limit)}…` : flat;
};
const day = (now: number) => new Date(now).toDateString();

/** Line 能代处理的事项：别人线程上的审批、提问、回合结束与失败。密钥请求只能由用户填写。 */
export const delegable = (item: InboxItem) => !item.own && ['approval', 'question', 'turn', 'failed'].includes(item.kind);

export function where(item: Pick<InboxItem, 'machine' | 'workspace' | 'thread'>): string {
  return [`工作机「${item.machine.name}」(${item.machine.id})`,
    ...(item.workspace ? [`项目「${item.workspace.project.name}」`, `工作区「${item.workspace.name}」(${item.workspace.id})`] : []),
    ...(item.thread ? [`线程「${item.thread.title}」(${item.thread.id})`] : [])].join(' ');
}

const kindLabel: Record<InboxKind, string> = {
  approval: '等待批准', question: '等待回答', secret: '等待密钥', turn: '回合结束', failed: '失败', preparation: '准备失败',
  unreachable: '连不上',
};

function waitingText(waiting: Waiting): string {
  if (waiting.kind === 'question') return clip(waiting.questions.map((q) => q.question).join(' / '), 300);
  if (waiting.kind === 'secret') return clip(waiting.secrets.map((s) => `${secretLabel(s)}：${s.reason}`).join('；'), 300);
  return clip(waiting.target, 300);
}

/** 给 Line 的事项详情：审批与提问带上完整内容，Line 据此用 line_handle 回应。 */
function detail(item: InboxItem): string {
  const head = `- [${item.id}] ${kindLabel[item.kind]}：${where(item)}`;
  const waiting = item.waiting;
  if (waiting?.kind === 'approval') return `${head}\n  工具 ${waiting.tool}，目标：${waiting.target}；原因：${waiting.reason}`
    + (waiting.secretReferences?.length ? `；带着密钥 ${waiting.secretReferences.join('、')}` : '');
  if (waiting?.kind === 'question') return [head, ...waiting.questions.map((q, index) =>
    `  问题 ${index + 1}（${q.multiSelect ? '可多选' : '单选'}）：${q.question}\n    选项：${q.options.map((o) => `「${o.label}」${o.description}`).join('；')}`)].join('\n');
  return `${head}\n  ${item.text}`;
}

function notification(item: InboxItem): LineNotification {
  const title = item.thread ? `「${item.thread.title}」${kindLabel[item.kind]}` : `${item.workspace?.name ?? item.machine.name}${kindLabel[item.kind]}`;
  return { id: randomUUID(), title, body: `${item.text}（${item.workspace?.project.name ?? item.machine.name}）`, item: item.id };
}

/**
 * 关注设备变化：变空记下离开时刻，开始新的一段时间线（上一段的记录丢掉）；回来时这一段收尾，
 * 离开够久且收件箱有离开期间进来的事项，就排一次简报。
 */
export function attend(state: MonitorState, focused: boolean, now: number): void {
  if (!focused) {
    if (state.away !== undefined) return;
    state.away = now;
    state.period = { since: now };
    state.records = [];
    return;
  }
  const away = state.away;
  if (away === undefined) return;
  state.away = undefined;
  state.digestAt = undefined;
  state.period = { since: state.period?.since ?? away, until: now };
  if (now - away >= BRIEFING_AWAY_MS && Object.values(state.items).some((item) => item.addedAt >= away)) {
    state.queue = [...state.queue.filter((wake) => wake.kind !== 'briefing'), { kind: 'briefing', since: away, at: now }];
  }
}

export interface RouteInput {
  /** Line 的线程。 */
  line: string;
  machines: AccountMachine[];
  /** 读到了汇总的工作机。 */
  summaries: Map<string, MachineSummary>;
  focused: boolean;
  now: number;
}

/**
 * 一轮路由：按各工作机的汇总更新收件箱、排 Line 的唤醒、决定要发的系统通知。读不到汇总的工作机保留上次的事项。
 * 同一线程只看最新状态，同一事项只进一次收件箱；Line 自己的线程与冻结副本不唤醒 Line。
 */
export function route(state: MonitorState, input: RouteInput): LineNotification[] {
  const { now } = input;
  const notes: LineNotification[] = [];
  attend(state, input.focused, now);
  if (state.delegation.until !== undefined && state.delegation.until <= now) state.delegation = { ...state.delegation, until: undefined };
  const period = state.delegation.until !== undefined;
  const present = new Map<string, InboxItem>();
  const restarted = new Set<string>();
  const put = (item: Omit<InboxItem, 'addedAt'>) => present.set(item.id, { ...item, addedAt: now });

  const unreachable: Record<string, number> = {};
  for (const machine of input.machines) {
    if (input.summaries.has(machine.id)) continue;
    const since = state.unreachable[machine.id] ?? now;
    unreachable[machine.id] = since;
    if (now - since >= UNREACHABLE_MS) put({ id: `machine:${machine.id}`, kind: 'unreachable', machine: { id: machine.id, name: machine.name },
      text: `工作机「${machine.name}」已连不上超过 30 分钟`, at: since });
  }
  // 工作机目录暂时读不到时没列出的工作机，保留上次的连不上记录与事项，免得恢复后当成新事项。
  for (const [machine, since] of Object.entries(state.unreachable)) {
    if (!input.summaries.has(machine) && !input.machines.some((entry) => entry.id === machine)) unreachable[machine] = since;
  }
  state.unreachable = unreachable;

  let lineSettled: number | undefined;
  // 读到汇总的工作机按本轮重建，归档掉的线程随之清掉。
  const seen = Object.fromEntries(Object.entries(state.seen).filter(([key]) => !input.summaries.has(key.slice(0, key.indexOf(':')))));
  for (const [machineId, summary] of input.summaries) {
    // 名字以工作机目录为准，和 App 里看到的一致；目录读不到时用工作机自己报的。
    const machine = { id: summary.machine.id, name: input.machines.find((entry) => entry.id === machineId)?.name ?? summary.machine.name };
    for (const workspace of summary.workspaces) {
      // 已流转走的是冻结副本，它的线程状态以当前宿主为准。
      if (workspace.status === 'transferred') continue;
      const space = { id: workspace.id, name: workspace.name, project: workspace.project };
      if (workspace.status === 'failed') put({ id: `preparation:${workspace.id}`, kind: 'preparation', machine, workspace: space,
        text: '工作区准备失败，可以重跑准备', at: now });
      for (const thread of workspace.threads) {
        const own = thread.id === input.line;
        const base = { machine, workspace: space, thread: { id: thread.id, title: thread.title }, ...(own ? { own: true as const } : {}) };
        if (own && !thread.busy) lineSettled = thread.settledAt;
        if (thread.busy) restarted.add(thread.id);
        // 卡着回合的审批与没回应的提问、密钥请求，每项一个事项
        for (const waiting of [...(thread.waiting ? [thread.waiting] : []), ...(thread.asks ?? [])]) {
          put({ ...base, id: `waiting:${waiting.id}`, kind: waiting.kind, waiting, text: waitingText(waiting), at: waiting.since });
        }
        // Line 发起的工作失败交给 Line；超出预算时已经进了收件箱的照常保留到状态解除。
        if (thread.lastOutcome === 'failed' && thread.waitingForResume && (!thread.byLine || state.items[`failed:${thread.id}`])) {
          put({ ...base, id: `failed:${thread.id}`, kind: 'failed', text: clip(thread.failure ?? '上一回合失败，等待继续', 300), at: thread.settledAt ?? now });
        }
        // 回合结束：Line 发起的交给 Line，别人的只收离开期间正常结束的；用户或 Line 停下的不算。还有没回应的提问、密钥请求时
        // 线程是在等你回应，上面已经各有一项，不再另算回合结束（之后的回应会开新的回合）。
        const key = `${machineId}:${thread.id}`;
        const settled = thread.settledAt;
        if (settled === undefined) continue;
        if (!thread.busy && settled > (state.seen[key] ?? 0) && !own && thread.lastOutcome !== 'interrupted' && !thread.asks?.length) {
          const item: InboxItem = { ...base, id: `turn:${thread.id}`, kind: 'turn', text: thread.lastOutcome === 'failed' ? '回合失败' : '回合结束', at: settled, addedAt: now };
          if (thread.byLine) {
            state.queue.push({ kind: 'result', at: now, text: `${where(item)} ${thread.lastOutcome === 'failed' ? `失败：${clip(thread.failure ?? '', 300)}` : '回合结束'}`,
              fallback: thread.lastOutcome === 'failed' ? { ...item, id: `failed:${thread.id}`, kind: 'failed', text: clip(thread.failure ?? '回合失败', 300) } : item });
          } else if (thread.lastOutcome === 'completed' && state.away !== undefined && settled >= state.away) {
            present.set(item.id, item);
            delete state.items[item.id];
          }
        }
        seen[key] = settled;
      }
    }
  }
  state.seen = seen;

  // 收件箱：读到汇总的工作机按本轮状态增删，回合结束留到被处理或线程开始新一轮；读不到的保留。
  for (const [key, item] of Object.entries(state.items)) {
    if (present.has(key)) continue;
    if (item.kind === 'unreachable') {
      if (!(item.machine.id in unreachable)) remove(state, key, now);
      continue;
    }
    const summary = input.summaries.get(item.machine.id);
    if (!summary) continue;
    if (item.kind === 'turn' && item.thread && !restarted.has(item.thread.id)
      && summary.workspaces.some((w) => w.status !== 'transferred' && w.threads.some((t) => t.id === item.thread!.id))) continue;
    remove(state, key, now);
  }
  for (const [key, fresh] of present) {
    const existing = state.items[key];
    if (existing) { state.items[key] = { ...existing, text: fresh.text, ...(fresh.waiting ? { waiting: fresh.waiting } : {}) }; continue; }
    state.items[key] = admit(fresh, period, input.focused, notes);
  }

  // 超时托管：审批与提问等用户超过设定时间还没处理，交给 Line。
  const timeout = state.delegation.timeoutMinutes;
  for (const item of Object.values(state.items)) {
    if (timeout !== undefined && !item.delegated && !item.left && delegable(item) && item.waiting && now - item.addedAt >= timeout * 60_000) {
      item.delegated = { by: 'timeout', at: now };
    }
    // 投给 Line 之后它的回合结束了还没了结的，交回用户。
    if (item.delegated?.sent !== undefined && lineSettled !== undefined && lineSettled > item.delegated.sent) {
      returnToUser(item, 'Line 没有给出处理，留给你', input.focused, notes);
    }
  }

  // 离开期间结束的回合合成摘要通知。
  if (!input.focused && state.away !== undefined) {
    const fresh = Object.values(state.items).filter((item) => item.kind === 'turn' && !item.notified && !item.delegated);
    if (fresh.length && now - state.away >= DIGEST_MS && (state.digestAt === undefined || now - state.digestAt >= DIGEST_MS)) {
      for (const item of fresh) item.notified = true;
      state.digestAt = now;
      notes.push({ id: randomUUID(), title: `${fresh.length} 个线程结束了回合`,
        body: fresh.map((item) => `「${item.thread?.title ?? item.workspace?.name}」`).join('、') });
    }
  }
  return notes;
}

/** 事项了结、移出收件箱；离开期间的记进这一段的时间线。 */
function remove(state: MonitorState, key: string, now: number, record?: Omit<InboxRecord, 'at' | 'item'>): void {
  const item = state.items[key];
  if (!item) return;
  delete state.items[key];
  if (state.away !== undefined) state.records = [...state.records, { at: now, item, outcome: 'resolved' as const, ...record }].slice(-RECORDS_KEEP);
}

/** 新进收件箱：按时段托管中直接交给 Line（Line 交回时再通知），否则没人关注时立即通知。 */
function admit(item: InboxItem, period: boolean, focused: boolean, notes: LineNotification[]): InboxItem {
  if (period && delegable(item)) return { ...item, delegated: { by: 'period', at: item.addedAt } };
  if (!focused && IMMEDIATE.has(item.kind)) { notes.push(notification(item)); return { ...item, notified: true }; }
  return item;
}

function returnToUser(item: InboxItem, note: string, focused: boolean, notes: LineNotification[]): void {
  delete item.delegated;
  item.left = true;
  item.note = note;
  if (!focused && !item.notified && IMMEDIATE.has(item.kind)) { item.notified = true; notes.push(notification(item)); }
}

export interface Collected { delegated: InboxItem[]; results: string[]; briefing?: { since: number; items: InboxItem[] } }

/** 这次唤醒在 Line 窗口里显示的那一句。 */
function wakeTitle({ delegated, results, briefing }: Collected): string {
  return [...delegated.length ? [`${delegated.length} 件事交给 Line 处理`] : [], ...results.length ? [`${results.length} 个工作结果`] : [],
    ...briefing ? ['你回来了，要一段简报'] : []].join('，') || '收件箱有新动静';
}

/**
 * 取出该投给 Line 的唤醒：用户点的代处理随时投；托管、结果与简报计入每日预算，超了不再唤醒，
 * 事项交回用户的收件箱，Line 的工作结果也进收件箱，简报作罢。
 */
export function collect(state: MonitorState, now: number, focused: boolean, notes: LineNotification[]): Collected | undefined {
  const ready = Object.values(state.items).filter((item) => item.delegated && item.delegated.sent === undefined
    && now >= item.delegated.at + (item.delegated.by === 'period' ? PERIOD_BATCH_MS[item.kind] ?? 0 : 0));
  const asked = ready.filter((item) => item.delegated!.by === 'user');
  const automatic = ready.length > asked.length || state.queue.length > 0;
  if (!ready.length && !state.queue.length) return undefined;
  const count = state.wakes?.day === day(now) ? state.wakes.count : 0;
  let delegated = ready;
  let queue = state.queue;
  state.queue = [];
  if (automatic && count >= DAILY_WAKES) {
    const reason = '今天自动唤醒 Line 的次数已用完，留给你处理';
    for (const item of ready) if (item.delegated!.by !== 'user') returnToUser(item, reason, focused, notes);
    for (const wake of queue) {
      if (wake.kind !== 'briefing') state.items[wake.fallback.id] = admit({ ...wake.fallback, addedAt: now, left: true, note: reason }, false, focused, notes);
    }
    delegated = asked;
    queue = [];
    if (!asked.length) return undefined;
  }
  for (const item of delegated) item.delegated = { ...item.delegated!, sent: now };
  // 只有用户点的代处理时不计入预算
  if (automatic) state.wakes = { day: day(now), count: count + 1 };
  const briefing = queue.find((wake) => wake.kind === 'briefing');
  return {
    delegated,
    results: queue.flatMap((wake) => wake.kind === 'result' ? [wake.text] : []),
    ...(briefing ? { briefing: { since: briefing.since, items: Object.values(state.items).filter((item) => item.addedAt >= briefing.since) } } : {}),
  };
}

export interface MonitorHost {
  store: Store;
  peers: Peers;
  /** 本机上的 Line 实例。 */
  line(): AgentInstance | undefined;
  /** Line 的 monitor 实例（收件箱），状态存在它上面；没有时由宿主补建。 */
  inbox(): PluginInstance | undefined;
  /** 投给 Line 线程的 Kite 来源输入；同一 ID 重复送达只去重。 */
  deliver(threadId: string, text: string, inputId: string, notice: InputNotice): Promise<unknown>;
  template(): ContextDefinition;
  /** Line 线程的公共变量。 */
  variables(threadId: string): ContextValues;
  /** 此刻有没有设备在关注 Kite。 */
  focused(): boolean;
  notify(notification: LineNotification): void;
  /** 收件箱变了。 */
  changed(): void;
}

export class LineMonitor {
  private timer?: Timer;
  private soon?: Timer;
  private next?: Timer;
  private running?: Promise<void>;

  constructor(private host: MonitorHost, private intervalMs = 60_000) {}

  start(): void {
    this.timer = setInterval(() => void this.check(), this.intervalMs);
    this.timer.unref();
    void this.check();
  }

  /** 本机状态变化后稍等再读，合并一串连续的变化。 */
  nudge(): void {
    if (!this.timer || this.soon) return;
    this.soon = setTimeout(() => { this.soon = undefined; void this.check(); }, 2_000);
    this.soon.unref();
  }

  stop(): Promise<void> | undefined {
    clearInterval(this.timer);
    clearTimeout(this.soon);
    clearTimeout(this.next);
    this.timer = undefined;
    return this.running;
  }

  /** 读一轮状态、路由并投递；上一轮没完就并入它。 */
  check(): Promise<void> {
    this.running ??= this.round().catch((error) => console.error(`[monitor] ${(error as Error).message}`)).finally(() => { this.running = undefined; });
    return this.running;
  }

  /** 当前的 monitor 状态，只读。 */
  state(): MonitorState | undefined {
    const inbox = this.host.inbox();
    return inbox ? monitorState(inbox) : undefined;
  }

  /** 关注设备变了：立即记下离开或回来，回来时可能排一次简报。 */
  attention(focused: boolean): void {
    if (!this.host.line()) return;
    this.mutate((state) => attend(state, focused, Date.now()));
    if (focused && this.state()?.queue.length) void this.check();
  }

  /** 收件箱：等你的事项，以及当前或上一次离开那一段里了结的记录。 */
  inbox(): { items: InboxItem[]; period?: { since: number; until?: number }; records: InboxRecord[]; delegation: Delegation } {
    const state = this.required();
    return { items: Object.values(state.items).sort((a, b) => a.addedAt - b.addedAt), ...(state.period ? { period: state.period } : {}),
      records: state.records, delegation: state.delegation };
  }

  /** 用户把一项交给 Line 代处理，立即唤醒。 */
  delegate(itemId: string): InboxItem {
    const item = this.mutate((state) => {
      const item = this.item(state, itemId);
      if (!delegable(item)) throw new KiteError(item.own ? '这是 Line 自己发起的请求，只能由你处理' : '这一项 Line 处理不了', 409);
      if (item.delegated) throw new KiteError('这一项已经交给 Line 了', 409);
      item.delegated = { by: 'user', at: Date.now() };
      delete item.left;
      return { ...item };
    });
    void this.check();
    return item;
  }

  /** 用户在收件箱里点开或点「知道了」：只用于回合结束，其余随状态解除才移出。 */
  dismiss(itemId: string): void {
    this.mutate((state) => {
      const item = this.item(state, itemId);
      if (item.kind !== 'turn') throw new KiteError('这一项要等原线程的状态解除才会移出', 409);
      delete state.items[itemId];
    });
  }

  delegation(): Delegation { return this.required().delegation; }

  configureDelegation(delegation: Delegation): Delegation {
    if (delegation.until !== undefined && delegation.until <= Date.now()) throw new KiteError('托管结束时间要晚于现在');
    return this.mutate((state) => {
      state.delegation = delegation;
      return delegation;
    });
  }

  /** line_handle 核对：这一项确实交给了 Line，且不是 Line 自己发起的请求。 */
  claim(itemId: string): InboxItem {
    const state = this.required();
    const item = this.item(state, itemId);
    if (item.own) throw new KiteError('这是你自己发起的请求，只能由用户处理');
    if (!item.delegated) throw new KiteError('这一项没有交给你，留给用户处理');
    return item;
  }

  /** Line 处理完一项：移出收件箱；离开期间的记进时间线，带决定与理由。 */
  resolve(itemId: string, decision: string, reason: string): void {
    this.mutate((state) => remove(state, itemId, Date.now(), { outcome: 'handled', decision, reason }));
  }

  /** Line 拿不准，留给用户。 */
  leave(itemId: string, reason: string): void {
    const notes: LineNotification[] = [];
    this.mutate((state) => {
      const item = state.items[itemId];
      if (!item) return;
      returnToUser(item, reason, this.host.focused(), notes);
      if (state.away !== undefined) state.records = [...state.records, { at: Date.now(), item: { ...item }, outcome: 'left' as const, reason }].slice(-RECORDS_KEEP);
    });
    for (const note of notes) this.host.notify(note);
  }

  relayed(key: string): 'answered' | 'sent' | undefined { return this.required().relays[key]; }

  markRelayed(key: string, how: 'answered' | 'sent'): void {
    this.mutate((state) => { state.relays = Object.fromEntries([...Object.entries(state.relays), [key, how]].slice(-RELAYS_KEEP)); });
  }

  private required(): MonitorState {
    const state = this.state();
    if (!state) throw new KiteError('这台工作机没有 Line', 404);
    return state;
  }

  private item(state: MonitorState, itemId: string): InboxItem {
    const item = state.items[itemId];
    if (!item) throw new KiteError(`收件箱里没有这一项：${itemId}`, 404);
    return item;
  }

  /** 读改写 Line 实例上的状态；同步完成，几处并发的修改不会互相覆盖。 */
  private mutate<T>(change: (state: MonitorState) => T): T {
    const inbox = this.host.line() && this.host.inbox();
    const current = inbox && this.host.store.instance(inbox.id);
    if (!current) throw new KiteError('这台工作机没有 Line', 404);
    const state = monitorState(current);
    const before = JSON.stringify(state.items);
    const result = change(state);
    this.host.store.setInstanceState(current.id, { ...current.state, monitor: state });
    if (JSON.stringify(state.items) !== before) this.host.changed();
    return result;
  }

  private async round(): Promise<void> {
    const line = this.host.line();
    if (!line) return;
    const machines = await this.host.peers.machines();
    const summaries = new Map<string, MachineSummary>();
    await Promise.all(machines.filter((machine) => machine.online).map(async (machine) => {
      try { summaries.set(machine.id, await this.host.peers.call<MachineSummary>(machine, 'GET', '/summary')); } catch { /* 记为连不上。 */ }
    }));
    const notes: LineNotification[] = [];
    this.mutate((state) => {
      const now = Date.now();
      const focused = this.host.focused();
      notes.push(...route(state, { line: line.id, machines, summaries, focused, now }));
      if (state.pending) return;
      const collected = collect(state, now, focused, notes);
      if (!collected) return;
      state.seq += 1;
      state.pending = { id: `monitor:${line.id}:${state.seq}`, text: this.render(line.id, collected, now), title: wakeTitle(collected) };
    });
    for (const note of notes) this.host.notify(note);
    const pending = this.state()?.pending;
    if (pending) {
      // 先落盘再投递：投递失败（如 Line 的工作区正在交接）下一轮用同一 ID 补送。
      await this.host.deliver(line.id, pending.text, pending.id, { kind: 'line.monitor', title: pending.title ?? '收件箱有新动静' });
      this.mutate((state) => { if (state.pending?.id === pending.id) state.pending = undefined; });
    }
    this.arm();
  }

  /** 下一个到点的事（托管攒批、超时、自约时刻、摘要、托管结束）早于下一轮定时读取时，按它约一次。 */
  private arm(): void {
    clearTimeout(this.next);
    const state = this.state();
    if (!state || !this.timer) return;
    const now = Date.now();
    const due: number[] = [];
    if (state.delegation.until !== undefined) due.push(state.delegation.until);
    for (const item of Object.values(state.items)) {
      if (item.delegated && item.delegated.sent === undefined) due.push(item.delegated.at + (item.delegated.by === 'period' ? PERIOD_BATCH_MS[item.kind] ?? 0 : 0));
      if (state.delegation.timeoutMinutes !== undefined && !item.delegated && !item.left && delegable(item) && item.waiting) {
        due.push(item.addedAt + state.delegation.timeoutMinutes * 60_000);
      }
      // 同 route 的摘要：交给 Line 的不进摘要，不能拿它约时刻，否则到点后一直按最短间隔空转
      if (state.away !== undefined && item.kind === 'turn' && !item.notified && !item.delegated) due.push(Math.max(state.away, state.digestAt ?? 0) + DIGEST_MS);
    }
    const next = Math.min(...due);
    if (!Number.isFinite(next) || next - now >= this.intervalMs) return;
    this.next = setTimeout(() => void this.check(), Math.max(next - now, 200));
    this.next.unref();
  }

  private render(threadId: string, collected: Collected, now: number): string {
    const minutes = collected.briefing ? Math.round((now - collected.briefing.since) / 60_000) : 0;
    return assembleContext(bindContext(this.host.template(), { ...this.host.variables(threadId), ...sceneValues<'line.monitor'>({
      'monitor.delegated': collected.delegated.map(detail).join('\n'),
      'monitor.results': collected.results.map((text) => `- ${text}`).join('\n'),
      'monitor.briefing': collected.briefing ? [
        `用户离开了约 ${minutes} 分钟，刚回到 Kite。给用户一段简报：离开期间发生了什么、哪几件需要用户、建议先处理哪个。收件箱里离开期间进来的事项：`,
        ...(collected.briefing.items.length ? collected.briefing.items.map(detail) : ['（都已处理完）']),
      ].join('\n') : '',
    }) })).instructions;
  }
}
