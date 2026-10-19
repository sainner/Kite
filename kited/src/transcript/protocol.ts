/** 面向客户端的会话协议。原生 journal 负责恢复，显示投影只负责历史和实时事件。 */
import type { DiffReference } from '../workspace/file-diffs.ts';
import type { DomainEvent, Stamped } from '../events.ts';
import type { CheckResult } from '../check.ts';
import type { Input, InputNotice, Json, Phase, Outcome, Recovery } from '../harness/types.ts';
import { senderName } from '../harness/input.ts';
import type { WorkspaceStatus } from '../model.ts';
import type { Ask, Waiting } from '../waiting.ts';

export type DisplayBlock =
  | { type: 'human'; id: string; text: string; midTurn: boolean }
  /** 别的代理发来的：sender 的名称在收下时固定，instance 是发信方的实例 ID（Line 是 Line 的），画头像用。 */
  | { type: 'agent'; id: string; text: string; sender: { name: string; instance: string } }
  /** Kite 自动发的：notice 说是哪种通知，没有的（Claude 原生行等）按正文显示；response 是转交的用户回应。 */
  | { type: 'kite'; text: string; notice?: InputNotice; response?: true }
  /** from、through 是被压缩范围首尾记录的 id；Claude 原生压缩没有范围。 */
  | { type: 'compacted'; text: string; id?: string; from?: string; through?: string; automatic?: boolean; reverted?: boolean }
  | { type: 'text' | 'thinking'; text: string; parts?: string[] }
  | { type: 'tool_use'; id: string; name: string; input: Json; batch?: string; arguments?: string;
      stage?: 'generating' | 'queued' | 'running' | 'finished' | 'not_executed' | 'unfinished';
      output?: string; outputTruncated?: boolean; outputLimit?: number; startedAt?: number; finishedAt?: number }
  | { type: 'tool_result'; call: string; output: string; diff?: DiffReference; status: 'success' | 'error' | 'not_executed' | 'unknown' };
/** 输入在记录里的样子：按来源分三种块，正文都是原文。 */
export function inputBlock(input: Input, midTurn: boolean): DisplayBlock {
  switch (input.source) {
    case 'human': return { type: 'human', id: input.id, text: input.text, midTurn };
    case 'agent': return { type: 'agent', id: input.id, text: input.text, sender: { name: senderName(input.from), instance: input.from.instance } };
    case 'kite': return { type: 'kite', text: input.text, ...(input.notice ? { notice: input.notice } : {}), ...(input.response ? { response: true } : {}) };
  }
}
export interface DisplayRecord { id: string; at: number; parent?: string; generation?: 'streaming' | 'complete' | 'interrupted'; block: DisplayBlock }
export interface DisplayDelta { id: string; field: 'text' | 'arguments' | 'output'; text: string; part?: number; replace?: boolean; limit?: number; input?: Json }
export type PendingInput = Input & { midTurn: boolean };
export interface DisplayState {
  phase: Phase;
  busy: boolean;
  /** 正在生成压缩摘要。 */
  compacting?: boolean;
  waitingForResume: boolean;
  /** 回合卡在一项审批上等人批准；phase 仍为 running。 */
  waiting?: Waiting;
  /** 没回应的提问与密钥请求，按发出的先后；不阻塞回合。 */
  asks?: Ask[];
  lastOutcome?: Outcome;
  recovery?: Recovery;
  status: WorkspaceStatus;
  error?: string;
  /** 最近一次完成请求的输入用量与当时生效的运行窗口；窗口未知时不能用模型最大能力计算百分比。 */
  context?: { requestId: string; inputTokens: number; windowTokens?: number; measuredAt: number };
  capabilities: { send: boolean; interrupt: boolean; resume: boolean; cancel: boolean; switchRuntime?: boolean; compact?: boolean };
}
export interface History {
  version: 1;
  threadId: string;
  cursor: string;
  records: DisplayRecord[];
  pending: PendingInput[];
  state: DisplayState;
}
export type ThreadDisplayEvent =
  | { type: 'thread.record'; record: DisplayRecord }
  | { type: 'thread.record.delta'; delta: DisplayDelta }
  | { type: 'thread.pending'; pending: PendingInput[] }
  | { type: 'thread.state'; state: DisplayState }
  | { type: 'thread.idle' }
  | { type: 'thread.check'; result: CheckResult }
  | { type: 'thread.error'; message: string };
/**
 * 代理活动摘要，供停靠栏这类概览使用；完整状态以线程流的 thread.state 为准。只有载入过显示投影的线程才有摘要。
 * settledAt 是工作机实时看到的最近一回合收尾时间，客户端用它判断结果是否已看过，重启后不保留。
 */
export interface ThreadActivity {
  phase: Phase;
  waitingForResume: boolean;
  /** 在等人回应的：回合卡着的审批；没有时，空闲的线程最早一项没回应的请求。 */
  waiting?: Waiting['kind'];
  outcome?: Outcome['kind'];
  error?: true;
  changedAt?: number;
  settledAt?: number;
}
export type DisplayEvent = DomainEvent | (ThreadDisplayEvent & { threadId: string })
  | { type: 'thread.activity'; workspaceId: string; threadId: string; activity: ThreadActivity };
export type DisplayEnvelope = Stamped<DisplayEvent & { cursor: string }>;
