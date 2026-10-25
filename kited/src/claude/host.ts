/** Claude 的宿主只管理输入交接和 Kite 工具；模型循环、上下文历史及续接由 SDK 负责。 */
import { randomUUID } from 'node:crypto';
import { join } from 'node:path';
import type { Options } from '@anthropic-ai/claude-agent-sdk';
import { Runner } from './runner.ts';
import { readClaudeMessages } from './history.ts';
import { claudeToolServer } from './tools.ts';
import { claudeState, readClaudeControl, saveClaudeControl } from './control.ts';
import { claudeInputTokens } from './usage.ts';
import type { SecretProvider } from '../secrets.ts';
import type { CheckHost } from '../check.ts';
import { KiteError } from '../errors.ts';
import { localTools, type ShellBackground, type ShellOutside } from '../execution/local-tools.ts';
import { commandEnvironment, type ExecutionPolicy } from '../execution/sandbox.ts';
import { stopProcessGroups, type NetworkAsk } from '../execution/command.ts';
import type { CompactionRequest, Input, Outcome, Phase, StopRequest, Tool, ToolImage } from '../harness/types.ts';
import { fromUser, modelText, returnedOnStop, sameInput, withSkillText } from '../harness/input.ts';
import type { SkillCatalog } from '../harness/context/project.ts';
import type { ContextDefinition, ContextValues } from '../harness/context/types.ts';
import { EXIT_LIMIT, exitOutcome, HarnessRunner, interruptionNotice } from '../harness/runner.ts';
import { lockDirectory, markRunning, withThreadJournal } from '../harness/thread-host.ts';
import { importClaude, syncToClaude } from '../handoff/handoff.ts';
import { ClaudeSummaryModel } from './summary.ts';
import { AUTO_COMPACT_RATIO } from '../harness/compaction.ts';
import type { AgentDefinition } from '../agents/definition.ts';
import type { Runtime, RuntimeEvents } from '../runtime.ts';

/** 宿主与跨后端翻译共用的会话锁；返回释放函数。 */
export function acquireClaudeLock(directory: string): () => void {
  return lockDirectory(join(directory, 'claude-lock'), () => new KiteError('Claude 会话仍被另一个宿主占用', 409));
}

export async function openClaudeHost(options: {
  cwd: string; directory: string; diffDir: string; nativeId: string; title: string;
  policy(): ExecutionPolicy;
  secrets?: SecretProvider;
  askNetwork?: NetworkAsk;
  /** 长命令转到后台终端，见 ShellBackground。 */
  background?: ShellBackground;
  /** 沙箱外运行的判断与申请，见 ShellOutside。 */
  outside?: ShellOutside;
  /** check 工具要的检出、日志目录与出沙箱的判断，见 CheckHost。 */
  check?: CheckHost;
  prepare(afterNotification: number): { agent: AgentDefinition; instructions: string; contextUpdate: string; tools: Tool[]; allowed: Set<string>;
    notificationText: string; through: number };
  events: RuntimeEvents;
  /** 人发的消息带的附件里的图片交给模型的样子，交给进程时现取；见 workspace/attachments.ts。 */
  images?(input: Input): ToolImage[];
  /** 工具用的 skill 清单，回合开始与每个请求边界刷新，与同时取的基础上下文对得上；见 SkillCatalog。 */
  skills: SkillCatalog;
  /** 压缩所需的模板与净文件变化；不提供时不开放压缩。 */
  compaction?: {
    templates(): { compact: ContextDefinition; fileChanges: ContextDefinition };
    files(range: { from: number; to: number }): Promise<string | undefined>;
    /** 线程的公共变量，压缩时取一份。 */
    variables(): ContextValues;
  };
}): Promise<Runtime> {
  const data = readClaudeControl(options.directory);
  const releaseLock = acquireClaudeLock(options.directory);
  let phase: Phase = 'idle';
  let driver: Runner | undefined;
  /** 当前进程启动时的配置，及换配置重启期间等待旧进程退出的过程。 */
  let driverKey = '';
  let restarting: Promise<void> | undefined;
  /** 当前回合首条输入的原生 ID，作为工具调用的回合标识。 */
  let turnId = '';
  let controller = new AbortController();
  let closing = false;
  let settling: Promise<void> = Promise.resolve();
  let stopping: Promise<Input[]> | undefined;
  let terminal: Outcome | undefined;
  let storageFailed = false;
  /** 打开时发现上次被 kited 退出打断，还没由上层决定接着做（见 continueInterrupted）；新输入、继续和停止也算处理了。 */
  let interrupted = false;
  /** 上层接着做时附在继续说明里的话，下一个回合放说明时用掉。 */
  let interruptionNote: string | undefined;
  const activeTools = new Set<string>();
  const drainWaiters = new Set<() => void>();
  /** 进行中的压缩或撤销，期间不启动新回合；停止会取消其中的摘要请求。 */
  let compacting: Promise<void> | undefined;
  let compactionAbort: AbortController | undefined;
  /** 本回合最近一次主循环模型请求的实测输入，收尾时与运行窗口配对；压缩后清除。 */
  let measured: { requestId: string; tokens: number } | undefined;
  let currentModel = '';
  let windowQuery: AbortController | undefined;
  const publish = () => options.events.emit({ type: 'claude.control', state: claudeState(data, phase, !!compacting) });
  const requireStorage = () => { if (storageFailed) throw new KiteError('会话记录写入失败，须重新打开', 409); };
  /** 会话目录里「正在运行」标记的现状；标记只在 save 里按状态推导，见 markRunning。 */
  let marked: boolean | undefined;
  const save = () => {
    requireStorage();
    try {
      saveClaudeControl(options.directory, data);
      // 回合在跑（含收尾与停止中），或被 kited 退出打断后还没接着做；连续崩溃到上限的不再接着做。
      const running = phase !== 'idle' || (data.exited && data.exits < EXIT_LIMIT);
      if (running !== marked) { markRunning(options.directory, running); marked = running; }
    }
    catch (error) {
      storageFailed = true; data.outcome = { kind: 'failed', message: `Claude 宿主记录写入失败：${String(error)}` }; data.paused = true;
      controller.abort();
      const running = driver;
      if (running) void running.interrupt().then(() => running.shutdown()).catch(() => {});
      publish(); throw error;
    }
    publish();
  };
  /** 收尾或启动进程时出了意料之外的错：回合记为失败，停下等人。 */
  const fail = (failure: unknown) => {
    data.outcome = { kind: 'failed', message: String(failure) }; data.paused = true; phase = 'idle';
    try { save(); } catch { publish(); }
    options.events.emit({ type: 'error', message: String(failure) });
  };
  /** 登记着的命令进程组到这时还在的（kited 退出时没跟着退出，或命令留下的后台进程）停掉；停不掉的留在登记里下次再停。 */
  const stopLeftovers = async () => { data.processes = await stopProcessGroups(data.processes); };
  /** 进程已经退出时，交给 Claude 还没收尾的输入按原生记录核对：进了记录的算交过，没进的重新排队，下次交接时再交。 */
  const settleInputs = async () => {
    const pending = data.inputs.filter((entry) => entry.status === 'active' || entry.status === 'submitted');
    // 开始处理（active）的一定交过，只有交出去还没开始的要查原生记录。
    const history = pending.some((entry) => !entry.delivered)
      ? new Set((await readClaudeMessages(options.nativeId, options.cwd)).map((message) => message.uuid)) : undefined;
    for (const entry of pending) {
      entry.delivered ||= !!history?.has(entry.sdkId);
      entry.status = entry.delivered ? 'done' : 'queued';
    }
  };
  const tools = localTools({ cwd: options.cwd, diffDir: options.diffDir, logDir: join(options.directory, 'commands'),
    env: commandEnvironment(process.env), policy: options.policy, secrets: options.secrets, skills: options.skills,
    ...(options.askNetwork ? { askNetwork: options.askNetwork } : {}),
    ...(options.background ? { background: options.background } : {}),
    ...(options.outside ? { outside: options.outside } : {}),
    ...(options.check ? { check: options.check } : {}),
    onProcess(pid, active, started) {
      data.processes = [...data.processes.filter((group) => group.pid !== pid), ...(active ? [{ pid, started }] : [])];
      save();
    },
  });
  const waitTools = () => activeTools.size ? new Promise<void>((resolve) => { drainWaiters.add(resolve); }) : Promise.resolve();
  const boundaryContext = () => {
    options.skills.refresh();
    const prepared = options.prepare(data.through);
    const update = (data.context ?? data.initialContext) !== prepared.instructions ? prepared.contextUpdate : '';
    const text = [update, prepared.through > data.through ? prepared.notificationText : ''].filter(Boolean).join('\n\n');
    // hook 返回即交接给上游的下一次请求；失败后不自动重投已交接通知。
    data.context = prepared.instructions; data.through = prepared.through; save();
    return text;
  };
  /** 进程中途退出（异常或停止）时收尾这一回合；回合之间退出没有回合可收，下一条消息到来时 resume。 */
  const finish = async (error?: string) => {
    if (phase === 'idle') {
      driver = undefined;
      options.events.emit({ type: 'runner', state: 'closed', ...(error ? { error } : {}) });
      return;
    }
    controller.abort();
    await waitTools();
    await stopLeftovers();
    const wasStopping = phase === 'stopping';
    await settleInputs();
    // exited 是 kited 关闭时停下的回合（见 shutdown），记为被退出打断，kited 下次启动时接着做。
    data.outcome = data.exited ? exitOutcome() : error ? { kind: 'failed', message: error } : wasStopping ? { kind: 'interrupted' }
      : terminal ?? { kind: 'failed', message: 'Claude 进程退出但未返回回合结果' };
    data.paused = data.outcome.kind === 'failed';
    if (data.outcome.kind === 'completed') data.exits = 0;
    // 收尾期间到来的消息看到进程尚未清掉，不会抢先启动新进程。
    phase = wasStopping ? 'stopping' : 'idle'; driver = undefined;
    save();
    options.events.emit({ type: 'runner', state: 'closed', ...(error ? { error } : {}) });
    if (!wasStopping && !closing && !data.paused && data.inputs.some((entry) => entry.status === 'queued')) pump();
    // 被 kited 关闭停下的回合下次启动接着做，不算回合结束，不回报。
    else if (!data.exited) options.events.idle(data.outcome);
  };
  /** 常驻进程上的回合正常收口：进程留着，结果与队列照常处理。 */
  const completeTurn = async (running: Runner) => {
    if (phase !== 'running') return;
    // 查询期间仍占用线程；新输入排队，不能抢先启动下一回合或修改模型配置。
    phase = 'finishing'; publish();
    const query = new AbortController();
    windowQuery = query;
    controller.abort();
    let usage: Awaited<ReturnType<Runner['contextUsage']>>;
    try {
      await waitTools();
      if (query.signal.aborted || closing || driver !== running) return;
      usage = await running.contextUsage(query.signal);
    } finally { if (windowQuery === query) windowQuery = undefined; }
    if (query.signal.aborted || closing || driver !== running) return;
    const window = usage?.window ?? (data.contextWindow?.model === currentModel ? data.contextWindow.tokens : undefined);
    if (measured && window !== undefined) data.contextWindow = { model: currentModel, tokens: window, requestId: measured.requestId };
    // 进程还在：交给它、还没开始的留在它自己的队列里，由它接着处理，不重新排队。
    for (const entry of data.inputs) if (entry.status === 'active') entry.status = 'done';
    data.outcome = terminal ?? { kind: 'failed', message: 'Claude 回合结束但未返回结果' };
    data.paused = data.outcome.kind === 'failed';
    if (data.outcome.kind === 'completed') data.exits = 0;
    phase = 'idle';
    save();
    // 回合之间才能改写会话：用量达到窗口的 85% 时先压缩，之后再处理排队的输入。
    if (!closing && !data.paused && options.compaction && window !== undefined && measured && measured.tokens >= Math.floor(window * AUTO_COMPACT_RATIO)) {
      void compaction({ compact: { id: randomUUID(), automatic: true } }).catch(() => {});
    }
    if (!closing && !data.paused && data.inputs.some((entry) => entry.status === 'queued')) pump();
    else options.events.idle(data.outcome);
  };
  /**
   * Claude 线程的压缩与撤销：停下空闲的常驻进程，把 Claude 内容导入 journal，在 journal 上按 harness 的规则压缩或撤销，
   * 再按结果重组 Claude 会话，下一回合启动进程时从重组后的会话恢复。范围校验在返回前完成，摘要与重组在后台进行；
   * 自动压缩失败时暂停会话，等待显式继续。
   */
  const compaction = (action: { compact: CompactionRequest } | { revert: string }): Promise<void> => {
    requireStorage();
    const settings = options.compaction;
    if (!settings) return Promise.reject(new KiteError('这台工作机未开放 Claude 线程的压缩', 409));
    if (closing || compacting || stopping || phase !== 'idle') return Promise.reject(new KiteError('会话正在执行，空闲后才能压缩', 409));
    const automatic = 'compact' in action && 'automatic' in action.compact;
    const abort = new AbortController();
    let checked = false;
    let recorded = false;
    let validated!: (error?: unknown) => void;
    const accepted = new Promise<void>((resolve, reject) => { validated = (error) => { checked = true; if (error) reject(error); else resolve(); }; });
    compactionAbort = abort;
    const job = (async () => {
      await restarting;
      if (driver) { const retired = driver; driver = undefined; await retired.shutdown(); }
      for (const record of importClaude(options.directory, options.cwd, options.nativeId)) {
        options.events.emit({ type: 'harness', event: { type: 'record', record } });
      }
      const prepared = options.prepare(data.through);
      const available = [...tools, ...prepared.tools].filter((tool) => prepared.allowed.has(tool.name));
      const effort = prepared.agent.model.reasoning === 'default' ? undefined : prepared.agent.model.reasoning as Options['effort'];
      const model = new ClaudeSummaryModel({ cwd: options.cwd, nativeId: options.nativeId, signal: abort.signal,
        configuration: { model: prepared.agent.model.model, effort,
          systemPrompt: { type: 'custom', snapshot: false, prompt: data.initialContext ?? prepared.instructions } },
        // 与主会话相同的工具声明才能命中同一前缀缓存；摘要不放行调用。
        mcpServers: { kite: claudeToolServer({ tools: available, allowed: () => false,
          context: () => { throw new Error('压缩摘要不能调用工具'); }, finished: () => {} }) } });
      const errors: string[] = [];
      await withThreadJournal(options.directory, async (journal) => {
        const runner = new HarnessRunner({ cwd: options.cwd, journal,
          prepareRequest: () => ({ model, tools: [], instructions: prepared.instructions, settings: { model: prepared.agent.model },
            compactionTemplates: settings.templates(), variables: settings.variables() }),
          compactionFiles: (range) => settings.files(range),
          onEvent(event) {
            if (event.type === 'record') {
              if (event.record.type === 'context.compacted' || event.record.type === 'context.compaction.reverted') recorded = true;
              options.events.emit({ type: 'harness', event });
            }
            if (event.type === 'error') errors.push(event.message);
          } });
        try {
          if ('revert' in action) await runner.revertCompaction(action.revert);
          else await runner.compact(action.compact);
        } catch (error) { throw new KiteError((error as Error).message, 409); }
        validated();
        await runner.settled();
        if (errors.length) throw new Error(errors.join('\n'));
      });
      await syncToClaude(options.directory, options.cwd, options.nativeId, prepared.agent.model.model);
      measured = undefined;
    })();
    compacting = job.catch((error: unknown) => {
      if (!checked) { validated(error); return; }
      if (abort.signal.aborted) return;
      const message = error instanceof Error ? error.message : String(error);
      // 记录已写入而会话未重组时，继续之前须先补做重组，暂停等待显式继续。
      if (automatic || recorded) { data.outcome = { kind: 'failed', message: `上下文压缩未完成：${message}` }; data.paused = true; save(); }
      options.events.emit({ type: 'error', message });
    }).finally(() => {
      compacting = undefined; compactionAbort = undefined; publish();
      if (!closing && !data.paused && data.inputs.some((entry) => entry.status === 'queued')) pump();
    });
    publish();
    return accepted;
  };
  /**
   * 进程随实例常驻，在实例归档、切换后端、手动停止或 kited 退出时结束。模型、思考强度和工具集合只在启动时
   * 交给 SDK，变化后在下一回合开始前重启进程，与「下次启动进程时生效」的约定一致。
   */
  const configKey = (prepared: ReturnType<typeof options.prepare>, available: Tool[]) => JSON.stringify({
    model: prepared.agent.model,
    tools: available.map(({ name, description, parameters }) => [name, description, parameters]),
  });
  const pump = () => {
    if (closing || compacting || phase === 'finishing' || phase === 'stopping' || data.paused || restarting || (driver && driver.state !== 'running')) return;
    if (!data.exited && !data.inputs.some((item) => item.status === 'queued')) return;
    // 回合进行中的新消息沿原生输入流插话。
    if (driver && phase === 'running') { submitQueued(driver); return; }
    let prepared: ReturnType<typeof options.prepare>;
    try { options.skills.refresh(); prepared = options.prepare(data.through); } catch (error) {
      data.outcome = { kind: 'failed', message: String(error) }; data.paused = true; save(); return;
    }
    // 被 kited 退出打断后的第一个回合：在排队的输入前面放一条继续说明，接着做。
    if (data.exited) {
      const first = data.inputs.findIndex((item) => item.status === 'queued');
      data.inputs.splice(first < 0 ? data.inputs.length : first, 0, queue(interruptionNotice(interruptionNote)));
      data.exited = false; interruptionNote = undefined;
    }
    const entry = data.inputs.find((item) => item.status === 'queued')!;
    data.initialContext ??= prepared.instructions;
    currentModel = prepared.agent.model.model;
    if (data.contextWindow?.model !== currentModel) data.contextWindow = undefined;
    measured = undefined;
    controller = new AbortController(); terminal = undefined; turnId = entry.sdkId;
    phase = 'running'; data.outcome = undefined; save();
    const available = [...tools, ...prepared.tools].filter((tool) => prepared.allowed.has(tool.name));
    const key = configKey(prepared, available);
    if (driver && driverKey === key) { submitQueued(driver); return; }
    // 换配置时先等旧进程退出；进程退出时没能按原生记录核对完的输入（记录读不了），启动新进程前再核对一次，核对不了就停下等人。
    const retired = driver;
    const unsettled = data.inputs.some((item) => item.status === 'active' || item.status === 'submitted');
    if (!retired && !unsettled) { start(prepared, available, key); return; }
    driver = undefined;
    const ready = (async () => {
      if (retired) await retired.shutdown();
      if (unsettled) await settleInputs();
    })();
    restarting = ready.then(() => {
      restarting = undefined;
      if (!closing && phase === 'running') start(prepared, available, key);
    }, (failure: unknown) => {
      restarting = undefined;
      fail(`没能按 Claude 的会话记录核对上次交出去的输入：${String(failure)}`);
    }).catch(fail);
  };
  const start = (prepared: ReturnType<typeof options.prepare>, available: Tool[], key: string) => {
    driverKey = key;
    const runner: Runner = new Runner({ cwd: options.cwd, nativeId: options.nativeId, title: options.title, resident: true,
      configuration: () => ({ model: prepared.agent.model.model, effort: prepared.agent.model.reasoning === 'default' ? undefined : prepared.agent.model.reasoning as Options['effort'],
        systemPrompt: { type: 'custom', snapshot: false, prompt: data.initialContext! } }),
      mcpServers: () => ({ kite: claudeToolServer({ tools: available,
        allowed: (name) => options.prepare(data.through).allowed.has(name),
        context: (callId) => {
          if (controller.signal.aborted) throw new Error('本次执行已停止');
          activeTools.add(callId);
          options.events.emit({ type: 'claude.tool', callId, stage: 'running', at: Date.now() });
          return { cwd: options.cwd, signal: controller.signal, callId, turnId,
            output: (text, limit) => options.events.emit({ type: 'claude.output', callId, text, limit }) };
        },
        finished: (callId) => {
          activeTools.delete(callId);
          if (!activeTools.size) { for (const resolve of drainWaiters) resolve(); drainWaiters.clear(); }
          options.events.emit({ type: 'claude.tool', callId, stage: 'finished', at: Date.now() });
        },
      }) }),
    }, {
      message(message) {
        if (message.type === 'assistant' && message.parent_tool_use_id === null) {
          const tokens = claudeInputTokens(message.message.usage);
          measured = tokens === undefined ? undefined : { requestId: message.message.id, tokens };
        }
        if (message.type === 'result') terminal = message.is_error
          ? { kind: 'failed', message: 'errors' in message ? message.errors.join('\n') : 'Claude 执行失败' } : { kind: 'completed' };
        options.events.emit({ type: 'sdk', message });
      },
      input(id, state) {
        const current = data.inputs.find((item) => item.sdkId === id);
        if (!current || current.status === 'cancelled') return;
        if (state === 'started') {
          current.status = 'active'; current.delivered = true;
          options.events.label(current.input.text);
        } else if (state === 'completed' || (state === 'cancelled' && current.delivered)) current.status = 'done';
        save();
      },
      turnStart: boundaryContext,
      toolBatch: async (input) => {
        await options.events.snapshot(input.tool_calls.map((call) => call.tool_use_id));
        return boundaryContext();
      },
      turnEnd: () => options.events.snapshot([]),
      idle() {
        if (driver !== runner) return;
        settling = completeTurn(runner).catch(fail);
      },
      state(state, error) {
        // 换配置重启时退下的旧进程不再影响当前状态。
        if (driver !== runner) return;
        if (state === 'closed') {
          windowQuery?.abort();
          settling = finish(error).catch((failure) => {
            // 进程已经退出，不能还指着它，否则之后的消息一直排着；没核对完的输入在启动下一个进程前再核对。
            if (driver === runner) driver = undefined;
            fail(failure);
          });
        } else options.events.emit({ type: 'runner', state, ...(error ? { error } : {}) });
      },
    });
    driver = runner;
    submitQueued(runner);
  };
  /** Kite 替人放进队列的继续说明。 */
  const queue = (input: Input) => ({ input, sdkId: randomUUID(), at: Date.now(), status: 'queued' as const, delivered: false, midTurn: false });
  const submitQueued = (running: Runner) => {
    for (const entry of data.inputs.filter((item) => item.status === 'queued')) {
      entry.status = 'submitted'; save();
      running.send({ id: entry.sdkId, text: withSkillText(modelText(entry.input), entry.skill), human: entry.input.source === 'human',
        images: options.images?.(entry.input) });
    }
  };
  /**
   * 打开时核对上次的执行：停掉残留的命令进程，按原生记录核对输入、补完停止收据。停止没收尾就被 kited 退出打断的按停止补完，
   * 结果是被停下，不接着做；回合在跑时崩溃的记为被退出打断、连续崩溃加一次（关闭时停下的已在关闭时记下）。被退出打断的
   * 打开本身不开始执行：被退出打断的、退出前排着队还没开始的都停在等待继续，由上层决定接着做（见 continueInterrupted），
   * 接着做时由 pump 放一条继续说明；连续崩溃到上限的不接着做，exited 留着，等人继续。
   */
  const reopen = async () => {
    const stopped = data.stops.some((entry) => !entry.completed);
    // 已经记了 exited 的（关闭时停下，或上次打开时记下崩溃却没核对完输入）不再算一次崩溃。
    if (!stopped && !data.exited && data.inputs.some((entry) => entry.status === 'active' || entry.status === 'submitted')) {
      data.exited = true; data.exits += 1; data.outcome = exitOutcome(data.exits);
    }
    await stopLeftovers();
    await settleInputs();
    for (const receipt of data.stops) if (!receipt.completed) {
      for (const entry of data.inputs) if (entry.status === 'queued' && returnedOnStop(entry.input, receipt.by)) {
        if (!receipt.returned.some((input) => input.id === entry.input.id)) receipt.returned.push(entry.input);
        entry.status = 'cancelled';
      }
      const order = new Map(data.inputs.map((entry, index) => [entry.input.id, index]));
      receipt.returned.sort((a, b) => (order.get(a.id) ?? Infinity) - (order.get(b.id) ?? Infinity));
      receipt.completed = true;
    }
    const queued = data.inputs.some((entry) => entry.status === 'queued');
    // 同停止正常收尾：留下的等新输入或继续。
    if (stopped) { data.outcome = { kind: 'interrupted' }; data.paused = data.exits >= EXIT_LIMIT || queued; }
    interrupted = data.exited || (queued && !data.paused);
    if (interrupted) data.paused = true;
    save();
  };
  try { await reopen(); } catch (error) {
    data.outcome = { kind: 'failed', message: `打开会话时没能核对上次的执行：${String(error)}` }; data.paused = true;
    try { save(); } catch { /* 写不进记录时 broken 已经为真。 */ }
  }
  publish();
  return {
    get state() { return phase; }, get busy() { return phase !== 'idle' || !!compacting; }, get broken() { return storageFailed; },
    async send(input, skill) {
      requireStorage();
      const existing = data.inputs.find((entry) => entry.input.id === input.id);
      if (existing) { if (!sameInput(existing.input, input)) throw new KiteError('消息 ID 已用于其他内容', 409); return false; }
      if (data.importedInputs.includes(input.id)) return false;
      if (closing || phase === 'stopping') throw new KiteError('会话正在停止，请稍后发送', 409);
      data.inputs.push({ input, ...(skill ? { skill } : {}), sdkId: randomUUID(), at: Date.now(), status: 'queued', delivered: false, midTurn: phase === 'running' });
      interrupted = false;
      // 用户本人的消息或回应即继续，连续崩溃重新计数；自动送来的照常排队，解除不了连续崩溃到上限的暂停。
      if (fromUser(input)) data.exits = 0;
      if (data.exits < EXIT_LIMIT) data.paused = false;
      save(); pump();
      return true;
    },
    async cancel(id) {
      requireStorage();
      const entry = data.inputs.find((item) => item.input.id === id);
      if (!entry) throw new KiteError('没有这条排队消息', 404);
      if (entry.status === 'cancelled') return;
      if (entry.status !== 'queued' && !(entry.status === 'submitted' && await driver?.cancel(entry.sdkId))) throw new KiteError('消息已经交给 Claude，不能撤回', 409);
      entry.status = 'cancelled'; save();
    },
    interrupt(request: StopRequest = { id: randomUUID() }) {
      requireStorage();
      const encoded = JSON.stringify(request.inputs ?? []);
      const saved = data.stops.find((entry) => entry.id === request.id);
      if (saved) {
        if (saved.request !== encoded) return Promise.reject(new KiteError('停止 ID 已用于其他输入', 409));
        if (stopping) return stopping;
        return saved.completed ? Promise.resolve(saved.returned)
          : Promise.reject(new KiteError('这次停止没有完成，换一个停止 ID 再停', 409));
      }
      if (phase === 'stopping') return Promise.reject(new KiteError('正在停止，请重试原停止请求', 409));
      const incoming = new Map<string, Input>();
      for (const input of request.inputs ?? []) {
        const known = data.inputs.find((entry) => entry.input.id === input.id)?.input ?? incoming.get(input.id);
        if (known && !sameInput(known, input)) return Promise.reject(new KiteError('消息 ID 已用于其他内容', 409));
        incoming.set(input.id, input);
      }
      // 还没收到的照登记、一律退回（同 harness），迟到的发送只去重；不按来源留在队列里，否则停止反而把它们送进了被停的线程。
      const unknown = new Set<string>();
      for (const input of incoming.values()) {
        const known = data.inputs.find((entry) => entry.input.id === input.id);
        if (!known) {
          data.inputs.push({ input, sdkId: randomUUID(), at: Date.now(), status: 'queued', delivered: false, midTurn: false });
          unknown.add(input.id);
        }
      }
      const receipt = { id: request.id, request: encoded, returned: [] as Input[], completed: false, ...(request.by ? { by: request.by } : {}) };
      data.stops.push(receipt);
      windowQuery?.abort();
      // 人停下的不再接着做被 kited 退出打断的回合。
      data.paused = false; data.exited = false; interrupted = false; phase = 'stopping'; save(); controller.abort();
      stopping = (async () => {
        compactionAbort?.abort();
        await compacting;
        const running = driver;
        const cancelled = new Set(await running?.stop() ?? []);
        for (const entry of data.inputs) if (entry.status === 'queued' || (cancelled.has(entry.sdkId) && !entry.delivered)) {
          // 不退回的留在队列里，Claude 撤下的改回排队，下次重新交接。
          if (unknown.has(entry.input.id) || returnedOnStop(entry.input, request.by)) { entry.status = 'cancelled'; receipt.returned.push(entry.input); }
          else entry.status = 'queued';
        }
        save();
        if (running) await running.shutdown();
        await waitTools(); await settling; await stopLeftovers();
        // 留下的等新输入或继续，不自动推进，连续崩溃到上限的暂停也留着；进程退出时的收尾会改掉 paused，在这里定。
        data.paused = data.exits >= EXIT_LIMIT || data.inputs.some((entry) => entry.status === 'queued');
        phase = 'idle'; data.outcome = { kind: 'interrupted' }; receipt.completed = true; save();
        return receipt.returned;
      })().catch((error) => {
        phase = 'idle'; data.outcome = { kind: 'failed', message: `停止没有完成：${String(error)}` }; data.paused = true;
        save(); throw error;
      }).finally(() => { stopping = undefined; });
      return stopping;
    },
    compact: (request) => compaction({ compact: request }),
    revertCompaction: (id) => compaction({ revert: id }),
    async resume() {
      requireStorage();
      if (phase !== 'idle' || compacting) throw new KiteError('请先停止执行', 409);
      // 压缩已记录而重组失败时在这里补做；没有待交接的内容时不改动会话。
      if (options.compaction && !driver) {
        try { await syncToClaude(options.directory, options.cwd, options.nativeId, options.prepare(data.through).agent.model.model); }
        catch (error) { throw new KiteError(`重组 Claude 会话失败：${(error as Error).message}`, 409); }
      }
      // 被 kited 退出打断的由 pump 放上那条继续说明。
      if (!data.exited && !data.inputs.some((entry) => entry.status === 'queued') && data.paused) {
        data.inputs.push(queue({ id: randomUUID(), text: '继续上次任务。', source: 'kite', notice: { kind: 'resumed', title: '接着上次的任务' } }));
      }
      interrupted = false; data.exits = 0; data.paused = false; save(); pump();
    },
    async continueInterrupted(note) {
      requireStorage();
      if (!interrupted || data.exits >= EXIT_LIMIT) return;
      // 登记里还留着的是打开时没能停下的命令进程，一并告诉代理。
      interruptionNote = [note, data.processes.length ? '有命令的进程没能停下，可能还在运行' : ''].filter(Boolean).join('；') || undefined;
      interrupted = false; data.paused = false; save(); pump();
    },
    async shutdown() {
      closing = true; controller.abort();
      windowQuery?.abort();
      compactionAbort?.abort();
      // 中途出错（写不进记录、Claude 没确认清空队列）也等进程与收尾结束、释放锁，否则线程在 kited 重启前一直打不开。
      try {
        await compacting;
        await restarting;
        // 进行中的停止先停完，免得它在锁释放后还写记录。
        await stopping?.catch(() => {});
        const running = driver;
        // 空闲的常驻进程直接关闭，不当作停止，上一回合的结果保持不变。
        if (running && phase === 'idle') await running.shutdown();
        else if (running) {
          // 关闭时停下的回合记为被 kited 关闭打断，kited 下次启动时接着做。
          if (phase === 'running') { data.exited = true; data.outcome = exitOutcome(); }
          phase = 'stopping'; publish();
          try {
            const cancelled = new Set(await running.stop());
            for (const entry of data.inputs) if (cancelled.has(entry.sdkId) && !entry.delivered) entry.status = 'queued';
            save();
          } finally { await running.shutdown(); }
        }
      } finally {
        try {
          await waitTools(); await settling;
          if (data.processes.length) {
            await stopLeftovers();
            try { save(); } catch { /* 写不进记录时下次打开照样停一遍。 */ }
          }
        } finally { releaseLock(); }
      }
    },
  };
}
