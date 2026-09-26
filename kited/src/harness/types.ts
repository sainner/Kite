/** 主循环的公开契约。模型传输、具体工具和工作树操作由宿主注入。 */
import type { ContextSnapshot, ContextSource } from './context/types.ts';
export type Json = null | boolean | number | string | Json[] | { [key: string]: Json };
export type JsonObject = { [key: string]: Json };

export interface Input {
  id: string;
  text: string;
  source: 'human' | 'kite';
}

export interface ToolCall {
  id: string;
  name: string;
  /** 适配器须在参数完整后才产出调用；参数是否合法由工具 validate 判断。 */
  arguments: Json;
}

export interface ModelItem {
  id: string;
  /** 原生完整条目，包括 reasoning 等不用于界面显示的字段。 */
  raw: JsonObject;
  call?: ToolCall;
}

export interface ToolResult {
  status: 'success' | 'error' | 'not_executed' | 'unknown';
  output: string;
}

export type ContextItem =
  | { type: 'input'; input: Input }
  | { type: 'output'; item: ModelItem }
  | { type: 'tool_result'; callId: string; result: ToolResult }
  | { type: 'feedback'; text: string };

export type ModelEvent =
  | { type: 'delta'; text: string; itemId?: string }
  | { type: 'item'; item: ModelItem }
  /** 必须显式给出成功完成；断流不能冒充完成。 */
  | { type: 'completed'; responseId: string; needsFollowUp?: boolean; usage?: JsonObject };

export interface ToolDefinition {
  name: string;
  description: string;
  parameters: JsonObject;
}

export interface ModelRequest {
  id: string;
  turnId: string;
  cwd: string;
  instructions: string;
  history: ContextItem[];
  tools: ToolDefinition[];
}

export interface Model {
  /** 必须响应 signal，并关闭底层请求；不要在适配器中执行工具或重放副作用。 */
  stream(request: ModelRequest, signal: AbortSignal): AsyncIterable<ModelEvent>;
}

export interface Tool extends ToolDefinition {
  /** 默认排他；只有宿主明确声明的工具才允许并发。 */
  parallel?: boolean;
  validate(arguments_: Json): void;
  /** 返回/抛错之前，必须确认该调用的受管执行已停止。无法确认时返回 unknown。 */
  execute(arguments_: Json, context: { cwd: string; signal: AbortSignal }): Promise<ToolResult>;
}

export type Outcome =
  | { kind: 'completed' }
  | { kind: 'interrupted' }
  | { kind: 'failed'; message: string }
  | { kind: 'needs_recovery'; message: string };

export type JournalEvent =
  | { type: 'input.received'; input: Input }
  | { type: 'input.cancelled'; inputId: string }
  | { type: 'turn.started'; turnId: string }
  | { type: 'context.prepared'; snapshot: ContextSnapshot }
  /** 旧记录没有 contextId，仍能恢复历史，但无法还原当时的指令。 */
  | { type: 'request.started'; turnId: string; requestId: string; inputIds: string[]; contextId?: string }
  | { type: 'model.item'; turnId: string; requestId: string; item: ModelItem }
  | { type: 'request.completed'; turnId: string; requestId: string; responseId: string; needsFollowUp: boolean; usage?: JsonObject }
  | { type: 'request.failed'; turnId: string; requestId: string; message: string }
  | { type: 'tool.started'; turnId: string; requestId: string; callId: string }
  | { type: 'tool.finished'; turnId: string; requestId: string; callId: string; result: ToolResult }
  | { type: 'turn.feedback'; turnId: string; text: string }
  | { type: 'turn.finished'; turnId: string; outcome: Outcome }
  | { type: 'recovery.confirmed' };

export type JournalRecord = JournalEvent & { version: 1; seq: number; at: number };

export interface Journal {
  readonly records: readonly JournalRecord[];
  /** 同步追加并 fsync 后才返回；失败后不得再追加。与控制状态变更处于同一个短同步段。 */
  append(event: JournalEvent): JournalRecord;
  close(): void;
}

export type Phase = 'idle' | 'running' | 'stopping' | 'finishing' | 'paused' | 'needs_recovery' | 'closed';
export interface SessionState {
  phase: Phase;
  busy: boolean;
  turnId?: string;
  lastOutcome?: Outcome;
}

export type SessionEvent =
  | { type: 'state'; state: SessionState }
  | { type: 'record'; record: JournalRecord }
  | { type: 'delta'; turnId: string; requestId: string; text: string; itemId?: string }
  | { type: 'error'; message: string };

export interface SessionOptions {
  cwd: string;
  /** 同步工厂在每次请求边界求值；组装后复制、保存，再发送给模型。 */
  instructions: string | ContextSource | (() => ContextSource);
  journal: Journal;
  model: Model;
  tools: Tool[];
  /** 显式预算；达到时暂停，不冒充完成。 */
  maxRequestsPerTurn?: number;
  /** 管理宿主打开旧会话时先暂停待处理输入，等 send 或 resume 明确启动。 */
  startPaused?: boolean;
  onEvent?(event: SessionEvent): void;
  afterTools?(turnId: string, callIds: string[]): Promise<void>;
  afterTurn?(turnId: string, outcome: Outcome): Promise<void>;
  /** 返回非空反馈表示继续；计入同一模型请求预算。 */
  beforeStop?(turnId: string): Promise<string | undefined>;
}

export interface SessionRunner {
  readonly state: SessionState;
  send(input: Input): Promise<void>;
  cancel(inputId: string): Promise<void>;
  interrupt(): Promise<void>;
  /** 显式继续错误或恢复后的会话；可以在没有新输入时继续已有上下文。 */
  resume(): Promise<void>;
  /** 宿主必须先确认残留进程已停止；只解除恢复阻塞，不自动执行。 */
  confirmRecovery(): Promise<void>;
  shutdown(): Promise<void>;
  /** 等到当前推进（含排队回合及收尾）停下；不触发新工作。 */
  settled(): Promise<void>;
}
