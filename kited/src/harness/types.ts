/** 主循环的公开契约。模型传输、具体工具和工作树操作由宿主注入。 */
import type { DiffReference } from '../workspace/file-diffs.ts';
import type { ContextDefinition, ContextSnapshot, ContextSource } from './context/types.ts';
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
  diff?: DiffReference;
  status: 'success' | 'error' | 'not_executed' | 'unknown';
  output: string;
}

export type ContextItem =
  | { type: 'input'; input: Input }
  | { type: 'output'; item: ModelItem }
  | { type: 'tool_result'; callId: string; result: ToolResult }
  | { type: 'feedback'; text: string }
  | { type: 'notification'; notification: Omit<ThreadNotification, 'context'>; text: string };

/** 宿主按线程归属投递；sequence 来自持久来源，内核生成的上下文更新不占用来源游标。 */
export interface ThreadNotification {
  id: string;
  sequence?: number;
  kind: string;
  source: string;
  authority: 'instruction' | 'observation';
  /** 保存正文的定义与变量；请求正文和历史预览均从这份快照还原。 */
  context: ContextSnapshot;
}

export interface RequestSettings {
  execution?: { revision: string; grants: import('../execution/grants.ts').ExecutionGrants };
  model?: { model: string; reasoning: string };
  maxRequestsPerTurn?: number;
  agent?: { definitionId: string; revision: string };
  allowedTools?: string[];
  pluginTools?: import('../plugins/tools.ts').PluginToolSource[];
}

export interface RequestSnapshot {
  id: string;
  settings: RequestSettings;
  tools: ToolDefinition[];
}

export interface HarnessRequest {
  model: Model;
  tools: Tool[];
  /** 声明目录在首次请求固定；tools 是本次实际可执行的子集。 */
  toolDefinitions?: ToolDefinition[];
  instructions: string | ContextSource;
  /** 本次基础上下文变化时使用的通知模板；独立宿主未指定时使用内置定义。 */
  contextUpdateTemplate?: ContextDefinition;
  settings: RequestSettings;
  notifications?: ThreadNotification[];
}

/** 只用于展示的生成事件，不可据此执行工具或续接模型。 */
export type ModelStreamEvent =
  | { type: 'item.started'; itemId: string; kind: 'text' | 'thinking' | 'tool_use'; callId?: string; name?: string }
  | { type: 'delta'; text: string; itemId?: string; field?: 'text' | 'thinking' | 'arguments'; part?: number; replace?: boolean };

export type ModelEvent = ModelStreamEvent
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
  allowedTools?: string[];
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
  execute(arguments_: Json, context: { cwd: string; signal: AbortSignal; callId?: string; turnId?: string; output?: (text: string, limit: number) => void }): Promise<ToolResult>;
}

export type Outcome =
  | { kind: 'completed' }
  | { kind: 'interrupted' }
  | { kind: 'failed'; message: string };

export interface Recovery { message: string }
export interface StopRequest { id: string; inputs?: Input[] }

export type JournalEvent =
  | { type: 'input.received'; input: Input }
  | { type: 'input.cancelled'; inputId: string }
  /** 停止收据同时撤回队列、登记未确认输入，迟到重试不得重新入队。 */
  | { type: 'thread.stopped'; id: string; returned: Input[] }
  | { type: 'turn.started'; turnId: string }
  | { type: 'context.prepared'; snapshot: ContextSnapshot }
  | { type: 'request.configured'; snapshot: RequestSnapshot }
  | { type: 'request.started'; turnId: string; requestId: string; inputIds: string[]; contextId: string;
      configurationId: string; notifications?: ThreadNotification[] }
  | { type: 'model.item'; turnId: string; requestId: string; item: ModelItem }
  | { type: 'request.completed'; turnId: string; requestId: string; responseId: string; needsFollowUp: boolean; usage?: JsonObject }
  | { type: 'request.failed'; turnId: string; requestId: string; message: string }
  | { type: 'tool.started'; turnId: string; requestId: string; callId: string }
  | { type: 'tool.finished'; turnId: string; requestId: string; callId: string; result: ToolResult }
  | { type: 'turn.feedback'; turnId: string; text: string }
  | { type: 'turn.finished'; turnId: string; outcome: Outcome; recovery?: Recovery }
  | { type: 'recovery.confirmed' };

export type JournalRecord = JournalEvent & { version: 1; seq: number; at: number };

export interface Journal {
  readonly records: readonly JournalRecord[];
  /** 同步追加并 fsync 后才返回；失败后不得再追加。与控制状态变更处于同一个短同步段。 */
  append(event: JournalEvent): JournalRecord;
  close(): void;
}

export type Phase = 'idle' | 'running' | 'stopping' | 'finishing';
/** 一个 Thread 当前的执行状态；归档等持久生命周期由产品模型保存。 */
export interface ThreadState {
  phase: Phase;
  busy: boolean;
  waitingForResume: boolean;
  recovery?: Recovery;
  turnId?: string;
  lastOutcome?: Outcome;
}

export type HarnessEvent =
  | { type: 'state'; state: ThreadState }
  | { type: 'record'; record: JournalRecord }
  | (ModelStreamEvent & { turnId: string; requestId: string })
  | { type: 'tool.output'; turnId: string; requestId: string; callId: string; text: string; limit: number }
  | { type: 'error'; message: string };

export interface HarnessOptions {
  cwd: string;
  journal: Journal;
  /** 同步取得本次配置与尚未投递的通知；读取不得启动模型或产生工具副作用。 */
  prepareRequest(cursor: { afterNotification: number }): HarnessRequest;
  /** 管理宿主打开旧会话时先暂停待处理输入，等 send 或 resume 明确启动。 */
  startPaused?: boolean;
  onEvent?(event: HarnessEvent): void;
  afterTools?(turnId: string, callIds: string[]): Promise<void>;
  afterTurn?(turnId: string, outcome: Outcome): Promise<void>;
  /** 返回非空反馈表示继续；计入同一模型请求预算。 */
  beforeStop?(turnId: string): Promise<string | undefined>;
}

/** 驱动一个 Thread 的执行实例；实例关闭后，同一 Thread 仍可从原记录恢复。 */
export interface ThreadRunner {
  readonly state: ThreadState;
  readonly lifecycle: 'open' | 'closing' | 'closed';
  send(input: Input): Promise<void>;
  cancel(inputId: string): Promise<void>;
  interrupt(request?: StopRequest): Promise<Input[]>;
  /** 显式继续错误或恢复后的会话；可以在没有新输入时继续已有上下文。 */
  resume(): Promise<void>;
  /** 宿主必须先确认残留进程已停止；只解除恢复阻塞，不自动执行。 */
  confirmRecovery(): Promise<void>;
  shutdown(): Promise<void>;
  /** 等到当前推进（含排队回合及收尾）停下；不触发新工作。 */
  settled(): Promise<void>;
}
