/** 面向客户端的会话协议。原生 journal 负责恢复，显示投影只负责历史和实时事件。 */
import type { DiffReference } from '../workspace/file-diffs.ts';
import type { DomainEvent, Stamped } from '../events.ts';
import type { CheckResult } from '../check.ts';
import type { Input, Json, Phase, Outcome, Recovery } from '../harness/types.ts';
import type { WorkspaceStatus } from '../model.ts';

export type DisplayBlock =
  | { type: 'human'; id: string; text: string; midTurn: boolean }
  | { type: 'kite' | 'error' | 'compacted'; text: string }
  | { type: 'text' | 'thinking'; text: string; parts?: string[] }
  | { type: 'tool_use'; id: string; name: string; input: Json; batch?: string; arguments?: string;
      stage?: 'generating' | 'queued' | 'running' | 'finished' | 'not_executed' | 'unfinished';
      output?: string; outputTruncated?: boolean; outputLimit?: number; startedAt?: number; finishedAt?: number }
  | { type: 'tool_result'; call: string; output: string; diff?: DiffReference; status: 'success' | 'error' | 'not_executed' | 'unknown' }
  | { type: 'interrupted' };
export interface DisplayRecord { id: string; at: number; parent?: string; generation?: 'streaming' | 'complete' | 'interrupted'; block: DisplayBlock }
export interface DisplayDelta { id: string; field: 'text' | 'arguments' | 'output'; text: string; part?: number; replace?: boolean; limit?: number; input?: Json }
export interface PendingInput extends Input { midTurn: boolean }
export interface DisplayState {
  phase: Phase;
  busy: boolean;
  waitingForResume: boolean;
  lastOutcome?: Outcome;
  recovery?: Recovery;
  status: WorkspaceStatus;
  error?: string;
  /** 最近一次完成请求的输入用量；窗口上限缺失时不能计算百分比。 */
  context?: { requestId: string; inputTokens: number; windowTokens?: number; measuredAt: number };
  capabilities: { send: boolean; interrupt: boolean; resume: boolean; cancel: boolean };
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
export type DisplayEvent = DomainEvent | (ThreadDisplayEvent & { threadId: string });
export type DisplayEnvelope = Stamped<DisplayEvent & { cursor: string }>;
