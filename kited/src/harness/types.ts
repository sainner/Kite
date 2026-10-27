/** 主循环的公开契约。模型传输、具体工具和工作树操作由宿主注入。 */
import type { DiffReference } from '../workspace/file-diffs.ts';
import type { ContextDefinition, ContextSnapshot, ContextSource, ContextValues } from './context/types.ts';
export type Json = null | boolean | number | string | Json[] | { [key: string]: Json };
export type JsonObject = { [key: string]: Json };

/**
 * 输入的来源，由宿主按调用身份填写，只用于显示、去重、回报和交给模型时的包装，不改变权限；校验与包装见 input.ts。
 * 人发的可带 via：经 Line 照原文转达的用户原话。Kite 发的可带 notice 说是哪种通知；可带 response：Kite 转交的用户回应
 * （用户自己回答的提问、密钥请求的结果），是用户在界面上做的，交给模型时不加「不是用户说的话」。代理来信必带发信方 from，名称在收下时固定。
 * 人发的开头用 /名字 点选了 skill 时带 skill：那个 skill 的名字，供显示；正文不在输入上，见 InputMaterial。
 */
export type InputOrigin =
  | { source: 'human'; via?: InputVia; attachments?: AttachmentRef[]; skill?: string }
  | { source: 'kite'; notice?: InputNotice; response?: true }
  | { source: 'agent'; from: InputSender };
export type Input = { id: string; text: string } & InputOrigin;

/** 宿主收下一条输入时固定、随收下的记录保存的材料，交给模型时用，不显示。 */
export interface InputMaterial {
  /** 附件里的图片交给模型的样子，附在这条输入上。 */
  images?: ToolImage[];
  /**
   * /名字 点选的 skill（名字在 input.skill）按收下那一刻的 SKILL.md 固定的正文（context/skills.ts 的 loadSkill），
   * 作为跟在这条输入后面的条目交给模型，见 history.ts 的 inputItems。
   */
  skill?: string;
}

/**
 * 交给模型的一段 skill 正文出自哪个 skill：skill 工具的结果、/名字 点选时跟在输入后面的正文、压缩后重附的正文都带着它，
 * 压缩只按它认出加载过哪些 skill（compaction.ts），不认工具名、不解析文本。正文就是这一条交给模型的文字，不另存一份。
 */
export interface SkillMark { name: string }

/**
 * 人发的消息带的附件，收下时按工作机上存好的那份固定：原件在附件存储里，工作区里另有一份给代理用（见 workspace/attachments.ts）。
 * 尺寸只有图片才有，是原图的。
 */
export interface AttachmentRef { id: string; name: string; mediaType: string; size: number; width?: number; height?: number }

/** Kite 自动发的是哪种通知，只用于界面显示，不交给模型。 */
export interface InputNotice {
  kind: 'agent.report' | 'agent.workspace' | 'monitor.events' | 'terminal.exit' | 'line.monitor' | 'conflict' | 'moved' | 'resumed' | 'question' | 'secret';
  /** 从用户的角度说发生了什么，比如「整理文档 做完了」「你回答了提问」。 */
  title: string;
  /** 说的是哪一个：子代理、子工作区、monitor、后台命令的名称，界面接在种类后面。 */
  subject?: string;
  /** 子代理回报的那个子代理，子工作区的结果里开子工作区时建的那个代理，或替用户回答提问的 Line 的实例 ID。 */
  instance?: string;
}

export interface InputVia { kind: 'line'; machine: string; instance: string }
/** Line 自己的话以它的经由为发信方。 */
export type InputSender = { kind: 'agent'; instance: string; title: string } | InputVia;

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
  /**
   * raw 的来源格式；缺省为 OpenAI Responses 条目。deepseek 也是 Responses 条目，推理是明文、不带加密内容；anthropic 是从 Claude 段导入的原生块。
   * 交给别的厂商时由适配器转换。
   */
  format?: 'anthropic' | 'deepseek';
  call?: ToolCall;
}

export interface ToolResult {
  diff?: DiffReference;
  status: 'success' | 'error' | 'not_executed' | 'unknown';
  output: string;
  /** 附给模型查看的图片，随记录持久保存，适配器按各自协议转换。 */
  images?: ToolImage[];
  /** tool_search 加载的工具定义，适配器把结果作为 tool_search_output 交回；见 tool-search.ts。 */
  tools?: ToolDefinition[];
  /** skill 工具加载的正文出自哪个 skill，output 就是正文。 */
  skill?: SkillMark;
}

/** 交给模型看的图片格式，各家适配器都收。 */
export const toolImageTypes = ['image/png', 'image/jpeg', 'image/webp'] as const;
export interface ToolImage {
  mediaType: typeof toolImageTypes[number];
  /** base64 正文。 */
  data: string;
}

export type ContextItem =
  /** images 是附件里的图片规整后交给模型的样子，收下输入时定下，随记录保存，适配器按各自协议附在这条输入上。 */
  | { type: 'input'; input: Input; images?: ToolImage[] }
  | { type: 'output'; item: ModelItem }
  | { type: 'tool_result'; callId: string; result: ToolResult }
  | { type: 'feedback'; text: string }
  /** skill 是这条通知的正文所出自的 skill（/名字 点选与压缩重附的），见 SkillMark。 */
  | { type: 'notification'; notification: Omit<ThreadNotification, 'context'>; text: string; skill?: SkillMark };

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
  model?: { model: string; reasoning: string; fast?: boolean };
  /** 宿主为这次请求采用的上下文窗口；显示与自动压缩共用，未知时省略。 */
  contextWindow?: number;
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
  /** 本次可执行的工具。内置的同时就是声明，关掉的仍留在声明里；按需加载的在当前上下文里加载过且定义未变才执行。 */
  tools: Tool[];
  /** 每次调用启动前再查一次；返回原因时不执行，结果为 not_executed。请求发出后才收紧的限制靠它拦下。 */
  blocked?(name: string): string | undefined;
  instructions: string | ContextSource;
  /** 宿主的公共变量，组装基础上下文更新、压缩与文件变化的模板时与场景专有变量一起使用；未提供时这些模板只能引用专有变量。 */
  variables?: ContextValues;
  /** 本次基础上下文变化时使用的通知模板；独立宿主未指定时使用内置定义。 */
  contextUpdateTemplate?: ContextDefinition;
  /** 工作区现况变化时使用的通知模板；未指定时使用内置定义。 */
  instancesTemplate?: ContextDefinition;
  /** 压缩指令与摘要包装（thread.compact）及净文件变化通知（thread.file_changes）；未指定时使用内置定义。 */
  compactionTemplates?: { compact?: ContextDefinition; fileChanges?: ContextDefinition };
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

/**
 * 模型请求没成功：retryable 的（连不上、中途断开、服务端出错、限流）由 runner 退避重试，
 * 其余（登录失效、余额不足、请求本身不对）直接让回合失败。适配器抛的其他错误都不重试。
 */
export class ModelRequestError extends Error {
  constructor(message: string, readonly retryable: boolean) { super(message); }
}

export interface Tool extends ToolDefinition {
  /** 默认排他；只有宿主明确声明的工具才允许并发。 */
  parallel?: boolean;
  /** 不常驻、按需加载的工具（插件工具）：不进声明，自研 harness 经 tool_search 按 group（插件实例 ID）加载，Claude 经 ToolSearch 搜到。 */
  deferred?: { group: string };
  validate(arguments_: Json): void;
  /** 返回/抛错之前，必须确认该调用的受管执行已停止。无法确认时返回 unknown。 */
  execute(arguments_: Json, context: { cwd: string; signal: AbortSignal; callId?: string; turnId?: string; output?: (text: string, limit: number) => void }): Promise<ToolResult>;
}

export type Outcome =
  | { kind: 'completed' }
  | { kind: 'interrupted' }
  | { kind: 'failed'; message: string };

/** by 是发起停止的代理或经界面入口的 Line，它发来、还没交给模型的消息退给它；用户在界面上停止时没有。 */
export interface StopRequest { id: string; inputs?: Input[]; by?: { kind: 'agent'; instance: string } | InputVia }

export type JournalEvent =
  | ({ type: 'input.received'; input: Input } & InputMaterial)
  | { type: 'input.cancelled'; inputId: string }
  /** 停止收据同时撤回队列、登记未确认输入，迟到重试不得重新入队。 */
  | { type: 'thread.stopped'; id: string; returned: Input[] }
  /** 显式继续（resume）：解除等待继续，连续崩溃的次数从头算。 */
  | { type: 'thread.resumed' }
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
  /**
   * exited：回合被 kited 退出打断（crashed 是崩溃后补记的，closed 是关闭时停下的），由上层决定接着做；连续崩溃几次就不再继续，见 HarnessRunner。
   * 已收到手动停止的回合不标，按停止收尾。
   */
  | { type: 'turn.finished'; turnId: string; outcome: Outcome; exited?: 'crashed' | 'closed' }
  /** 切换后端时导入另一后端在本段产生的上下文；through 指向来源原生记录中已导入的最后位置。 */
  | { type: 'context.imported'; id: string; source: { runtime: 'claude'; through: string }; items: ContextItem[];
      /** 来源后端已交接的通知游标与当前基础上下文，避免切换后重复投递。 */
      notificationCursor: number; instructions?: string }
  /**
   * 用 items 替换历史中 seq 位于 [from, until) 的段；until 缺省表示到这条记录为止的全部历史。
   * 段指请求、反馈与导入，以产生它的记录 seq 标识。summary 是模型给出的摘要正文，供界面显示。
   */
  | { type: 'context.compacted'; id: string; range: { from: number; until?: number }; automatic: boolean;
      items: ContextItem[]; summary: string; usage?: JsonObject }
  | { type: 'context.compaction.reverted'; id: string }
  /**
   * 回退到 inputId 那条输入之前：seq 不小于 from 的段（从那条输入所在的段起）此后都不进上下文，覆盖到这些段的压缩一并作废，
   * 完全在它之前的压缩照旧。之后的新段照常追加。
   */
  | { type: 'context.rewound'; id: string; inputId: string; from: number };

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
  /** 正在生成压缩摘要。 */
  compacting?: boolean;
  waitingForResume: boolean;
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
  onEvent?(event: HarnessEvent): void;
  afterTools?(turnId: string, callIds: string[]): Promise<void>;
  afterTurn?(turnId: string, outcome: Outcome): Promise<void>;
  /** 返回非空反馈表示继续。 */
  beforeStop?(turnId: string): Promise<string | undefined>;
  /** 压缩范围起止两个时刻（毫秒）之间工作区的净文件变化，作为通知正文的变量；没有变化或无从比较时返回 undefined。 */
  compactionFiles?(range: { from: number; to: number }, signal: AbortSignal): Promise<string | undefined>;
}

/** 手动压缩时 from、through 是范围首尾两条输入的 id；不给起止时覆盖全部已有历史，自动压缩也是这样。 */
export type CompactionRequest = { id: string } & ({ from: string; through: string } | { automatic?: true });

/** 驱动一个 Thread 的执行实例；实例关闭后，同一 Thread 仍可从原记录恢复。 */
export interface ThreadRunner {
  readonly state: ThreadState;
  readonly lifecycle: 'open' | 'closing' | 'closed';
  /** 会话记录写入失败（如磁盘满）：执行已停下，之后的操作都拒绝，要关掉从记录重新打开。 */
  readonly broken: boolean;
  /** 收下返回 true；同一 ID 已收下过（重试）时不再处理，返回 false。material 是宿主收下时固定、随输入记下交给模型的材料。 */
  send(input: Input, material?: InputMaterial): Promise<boolean>;
  cancel(inputId: string): Promise<void>;
  interrupt(request?: StopRequest): Promise<Input[]>;
  /** 显式继续失败或停下的会话；可以在没有新输入时继续已有上下文。 */
  resume(): Promise<void>;
  /**
   * 打开会话本身不开始执行：上次被 kited 退出打断的（回合被切断，或收下的输入还没开始处理）停在等待继续，由上层决定接着做。
   * 被切断的回合先放一条继续说明，note 附在说明里（如原工作机可能还在执行）；连续被崩溃打断到上限的不接着做。没被打断时什么也不做。
   */
  continueInterrupted(note?: string): Promise<void>;
  /** 校验范围并开始压缩后返回；结果以记录送达，失败以 error 事件报告。 */
  compact(request: CompactionRequest): Promise<void>;
  /** 撤销最外层的一次压缩。 */
  revertCompaction(id: string): Promise<void>;
  /** 回退到 inputId 那条输入之前，见 context.rewound；dryRun 只核对。calls 是回退后作废的工具调用。 */
  rewind(inputId: string, dryRun?: boolean): Promise<{ calls: string[] }>;
  shutdown(): Promise<void>;
  /** 等到当前推进（含排队回合及收尾）停下；不触发新工作。 */
  settled(): Promise<void>;
}
