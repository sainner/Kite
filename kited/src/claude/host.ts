/** Claude 的宿主只管理输入交接和 Kite 工具；模型循环、上下文历史及续接由 SDK 负责。 */
import { randomUUID } from 'node:crypto';
import { existsSync, mkdirSync, rmSync, readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import type { Options } from '@anthropic-ai/claude-agent-sdk';
import { Runner } from './runner.ts';
import { readClaudeMessages } from './history.ts';
import { claudeToolServer } from './tools.ts';
import { claudeState, readClaudeControl, sameInput, saveClaudeControl } from './control.ts';
import type { SecretProvider } from '../secrets.ts';
import { KiteError } from '../errors.ts';
import { localTools } from '../execution/local-tools.ts';
import { commandEnvironment, type ExecutionPolicy } from '../execution/sandbox.ts';
import { processGroupAlive } from '../execution/command.ts';
import type { CompactionRequest, Input, Outcome, Phase, StopRequest, Tool } from '../harness/types.ts';
import type { ContextDefinition } from '../harness/context/types.ts';
import { HarnessRunner } from '../harness/runner.ts';
import { withThreadJournal } from '../harness/thread-host.ts';
import { importClaude, syncToClaude } from '../handoff/handoff.ts';
import { ClaudeSummaryModel } from './summary.ts';
import { AUTO_COMPACT_RATIO } from '../harness/compaction.ts';
import type { AgentDefinition } from '../agents/definition.ts';
import type { Runtime, RuntimeEvents } from '../runtime.ts';

/** 宿主与跨后端翻译共用的会话锁；返回释放函数。 */
export function acquireClaudeLock(directory: string): () => void {
  const lock = join(directory, 'claude-lock');
  mkdirSync(directory, { recursive: true, mode: 0o700 });
  if (existsSync(lock)) {
    // 建锁与写 owner 之间退出会留下没有 owner 的锁；残留命令另由进程组登记阻止恢复。
    let pid = 0;
    try { pid = Number(readFileSync(join(lock, 'owner'), 'utf8')); } catch { /* 视为无主的旧锁。 */ }
    let alive = Number.isSafeInteger(pid) && pid > 0;
    if (alive) try { process.kill(pid, 0); } catch (error) { alive = (error as NodeJS.ErrnoException).code !== 'ESRCH'; }
    if (alive) throw new KiteError('Claude 会话仍被另一个宿主占用', 409);
    rmSync(lock, { recursive: true });
  }
  mkdirSync(lock, { mode: 0o700 });
  writeFileSync(join(lock, 'owner'), String(process.pid));
  return () => rmSync(lock, { recursive: true, force: true });
}

export function openClaudeHost(options: {
  cwd: string; directory: string; diffDir: string; nativeId: string; title: string;
  policy(): ExecutionPolicy;
  secrets?: SecretProvider;
  prepare(afterNotification: number): { agent: AgentDefinition; instructions: string; contextUpdate: string; tools: Tool[]; allowed: Set<string>; notificationText: string; through: number };
  events: RuntimeEvents;
  /** 压缩所需的模板、净文件变化和自动压缩阈值；不提供时不开放压缩。 */
  compaction?: {
    templates(): { compact: ContextDefinition; fileChanges: ContextDefinition };
    files(range: { from: number; to: number }): Promise<string | undefined>;
    /** 模型目录中的窗口；进程报告实际认定的窗口之前用它判断自动压缩。 */
    window(model: string): number | undefined;
  };
}): Runtime {
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
  const activeTools = new Set<string>();
  const drainWaiters = new Set<() => void>();
  /** 进行中的压缩或撤销，期间不启动新回合；停止会取消其中的摘要请求。 */
  let compacting: Promise<void> | undefined;
  let compactionAbort: AbortController | undefined;
  /** 最近一次主循环模型请求的实测输入，回合结束时据此判断是否自动压缩；压缩后清零。 */
  let measured = 0;
  let currentModel = '';
  /** 当前进程认定的窗口，因账号与型号而异，可能小于模型目录中的值（2026-10-09 假端点上 sonnet、opus 为 20 万）。 */
  let cliWindow: number | undefined;
  const publish = () => options.events.emit({ type: 'claude.control', state: claudeState(data, phase, !!compacting) });
  const requireStorage = () => { if (storageFailed) throw new KiteError('会话记录写入失败，请重新打开宿主并核查后恢复', 409); };
  const save = () => {
    requireStorage();
    try { saveClaudeControl(options.directory, data); }
    catch (error) {
      storageFailed = true; data.recovery = { message: 'Claude 宿主记录写入失败，请重新打开宿主并核查后恢复。' };
      controller.abort();
      const running = driver;
      if (running) void running.interrupt().then(() => running.shutdown()).catch(() => {});
      publish(); throw error;
    }
    publish();
  };
  const processesStopped = () => {
    if (data.processes.some(processGroupAlive)) throw new KiteError('Claude 的命令进程组仍在运行，请先停止旧进程', 409);
  };
  if (data.processes.some(processGroupAlive)) data.recovery = { message: 'Claude 的命令进程组仍可能运行，请先核查再恢复。' };
  const tools = localTools({ cwd: options.cwd, diffDir: options.diffDir, logDir: join(options.directory, 'commands'),
    env: commandEnvironment(process.env), policy: options.policy, secrets: options.secrets,
    onProcess(pid, active) {
      data.processes = active ? [...new Set([...data.processes, pid])] : data.processes.filter((value) => value !== pid);
      save();
    },
  });
  const waitTools = () => activeTools.size ? new Promise<void>((resolve) => { drainWaiters.add(resolve); }) : Promise.resolve();
  const boundaryContext = () => {
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
    try { processesStopped(); } catch (failure) { data.recovery = { message: String(failure) }; }
    const wasStopping = phase === 'stopping';
    for (const entry of data.inputs) if (entry.status === 'active') entry.status = 'done';
    if (data.inputs.some((entry) => entry.status === 'submitted')) data.recovery ??= { message: 'Claude 退出时仍有未确认交接的输入，请核查后恢复。' };
    data.outcome = error ? { kind: 'failed', message: error } : wasStopping ? { kind: 'interrupted' }
      : terminal ?? { kind: 'failed', message: 'Claude 进程退出但未返回回合结果' };
    data.paused = data.outcome.kind === 'failed' || !!data.recovery;
    if (error) data.recovery ??= { message: 'Claude 异常退出，请核查执行结果后恢复；不会重放工具。' };
    // 收尾期间到来的消息看到进程尚未清掉，不会抢先启动新进程。
    phase = wasStopping ? 'stopping' : 'idle'; driver = undefined;
    save();
    options.events.emit({ type: 'runner', state: 'closed', ...(error ? { error } : {}) });
    if (!wasStopping && !closing && !data.paused && data.inputs.some((entry) => entry.status === 'queued')) pump();
    else options.events.idle(data.outcome.kind === 'completed');
  };
  /** 常驻进程上的回合正常收口：进程留着，结果与队列照常处理。 */
  const completeTurn = async () => {
    if (phase !== 'running') return;
    controller.abort();
    await waitTools();
    try { processesStopped(); } catch (failure) { data.recovery = { message: String(failure) }; }
    for (const entry of data.inputs) if (entry.status === 'active') entry.status = 'done';
    if (data.inputs.some((entry) => entry.status === 'submitted')) data.recovery ??= { message: 'Claude 回合结束时仍有未确认交接的输入，请核查后恢复。' };
    data.outcome = terminal ?? { kind: 'failed', message: 'Claude 回合结束但未返回结果' };
    data.paused = data.outcome.kind === 'failed' || !!data.recovery;
    phase = 'idle';
    save();
    // 回合之间才能改写会话：用量达到窗口的 85% 时先压缩，之后再处理排队的输入。
    const window = cliWindow ?? options.compaction?.window(currentModel);
    if (!closing && !data.paused && window !== undefined && measured >= Math.floor(window * AUTO_COMPACT_RATIO)) {
      void compaction({ compact: { id: randomUUID(), automatic: true } }).catch(() => {});
    }
    if (!closing && !data.paused && data.inputs.some((entry) => entry.status === 'queued')) pump();
    else options.events.idle(data.outcome.kind === 'completed');
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
    if (data.recovery) return Promise.reject(new KiteError('会话需要先确认恢复', 409));
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
        const runner = new HarnessRunner({ cwd: options.cwd, journal, startPaused: true,
          prepareRequest: () => ({ model, tools: [], instructions: prepared.instructions, settings: { model: prepared.agent.model },
            compactionTemplates: settings.templates() }),
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
      measured = 0;
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
   * 进程随实例常驻，在实例归档、切换后端、手动停止或 kited 退出时结束。模型、思考强度、请求预算和工具集合只在启动时
   * 交给 SDK，变化后在下一回合开始前重启进程，与「下次启动进程时生效」的约定一致。
   */
  const configKey = (prepared: ReturnType<typeof options.prepare>, available: Tool[]) => JSON.stringify({
    model: prepared.agent.model, maxTurns: prepared.agent.maxRequestsPerTurn,
    tools: available.map(({ name, description, parameters }) => [name, description, parameters]),
  });
  const pump = () => {
    if (closing || compacting || phase === 'stopping' || data.recovery || data.paused || restarting || (driver && driver.state !== 'running')) return;
    const entry = data.inputs.find((item) => item.status === 'queued');
    if (!entry) return;
    // 回合进行中的新消息沿原生输入流插话。
    if (driver && phase === 'running') { submitQueued(driver); return; }
    let prepared: ReturnType<typeof options.prepare>;
    try { prepared = options.prepare(data.through); } catch (error) {
      data.outcome = { kind: 'failed', message: String(error) }; data.paused = true; save(); return;
    }
    data.initialContext ??= prepared.instructions;
    controller = new AbortController(); terminal = undefined; turnId = entry.sdkId;
    phase = 'running'; data.outcome = undefined; save();
    const available = [...tools, ...prepared.tools].filter((tool) => prepared.allowed.has(tool.name));
    const key = configKey(prepared, available);
    if (driver && driverKey === key) { submitQueued(driver); return; }
    if (driver) {
      const retired = driver;
      driver = undefined;
      restarting = retired.shutdown().finally(() => {
        restarting = undefined;
        if (!closing && phase === 'running') start(prepared, available, key);
      });
      return;
    }
    start(prepared, available, key);
  };
  const start = (prepared: ReturnType<typeof options.prepare>, available: Tool[], key: string) => {
    driverKey = key;
    currentModel = prepared.agent.model.model;
    cliWindow = undefined;
    const runner: Runner = new Runner({ cwd: options.cwd, nativeId: options.nativeId, title: options.title, resident: true,
      configuration: () => ({ model: prepared.agent.model.model, effort: prepared.agent.model.reasoning === 'default' ? undefined : prepared.agent.model.reasoning as Options['effort'],
        maxTurns: prepared.agent.maxRequestsPerTurn, systemPrompt: { type: 'custom', snapshot: false, prompt: data.initialContext! } }),
      mcpServers: () => ({ kite: claudeToolServer({ tools: available,
        allowed: (name) => options.prepare(data.through).allowed.has(name),
        context: (callId) => {
          if (controller.signal.aborted) throw new Error('本次执行已停止');
          activeTools.add(callId);
          options.events.emit({ type: 'claude.tool', callId, stage: 'running', at: Date.now() });
          return { cwd: options.cwd, signal: controller.signal, callId, turnId,
            output: (text, limit) => options.events.emit({ type: 'claude.output', callId, text, limit }) };
        },
        finished: (callId, result) => {
          activeTools.delete(callId);
          if (!activeTools.size) { for (const resolve of drainWaiters) resolve(); drainWaiters.clear(); }
          options.events.emit({ type: 'claude.tool', callId, stage: 'finished', at: Date.now() });
          if (result.status === 'unknown') {
            data.recovery = { message: result.output }; controller.abort(); save();
            void runner.stop().then(() => runner.shutdown()).catch((error) => options.events.emit({ type: 'error', message: String(error) }));
          }
        },
      }) }),
    }, {
      message(message) {
        if (message.type === 'assistant' && message.parent_tool_use_id === null) {
          const usage = message.message.usage;
          if (usage) measured = (usage.input_tokens ?? 0) + (usage.cache_creation_input_tokens ?? 0) + (usage.cache_read_input_tokens ?? 0);
        }
        // 回合结果到达后在后台问进程认定的窗口，不拖住回合收尾。
        if (message.type === 'result' && cliWindow === undefined) void runner.contextUsage().then((usage) => { if (usage && driver === runner) cliWindow = usage.window; });
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
        settling = completeTurn().catch((failure) => {
          data.recovery = { message: String(failure) }; phase = 'idle'; publish();
          options.events.emit({ type: 'error', message: String(failure) });
        });
      },
      state(state, error) {
        // 换配置重启时退下的旧进程不再影响当前状态。
        if (driver !== runner) return;
        if (state === 'closed') settling = finish(error).catch((failure) => {
          data.recovery = { message: String(failure) }; phase = 'idle'; publish();
          options.events.emit({ type: 'error', message: String(failure) });
        });
        else options.events.emit({ type: 'runner', state, ...(error ? { error } : {}) });
      },
    });
    driver = runner;
    submitQueued(runner);
  };
  const submitQueued = (running: Runner) => {
    for (const entry of data.inputs.filter((item) => item.status === 'queued')) {
      entry.status = 'submitted'; save();
      running.send({ id: entry.sdkId, text: entry.input.text, human: entry.input.source === 'human' });
    }
  };
  publish();
  return {
    get state() { return phase; }, get busy() { return phase !== 'idle' || !!compacting; }, get recovery() { return data.recovery; },
    async send(input) {
      requireStorage();
      const existing = data.inputs.find((entry) => entry.input.id === input.id);
      if (existing) { if (!sameInput(existing.input, input)) throw new KiteError('消息 ID 已用于其他内容', 409); return; }
      if (data.importedInputs.includes(input.id)) return;
      if (closing || phase === 'stopping' || data.recovery) throw new KiteError('请先完成停止或恢复确认', 409);
      if (data.inputs.some((entry) => entry.status === 'unconfirmed')) throw new KiteError('有交接结果未知的输入，请先核查并明确继续，或撤回编辑', 409);
      data.inputs.push({ input, sdkId: randomUUID(), at: Date.now(), status: 'queued', delivered: false, midTurn: phase === 'running' });
      data.paused = false; save(); pump();
    },
    async cancel(id) {
      requireStorage();
      const entry = data.inputs.find((item) => item.input.id === id);
      if (!entry) throw new KiteError('没有这条排队消息', 404);
      if (entry.status === 'cancelled') return;
      if (!['queued', 'unconfirmed'].includes(entry.status) && !(entry.status === 'submitted' && await driver?.cancel(entry.sdkId))) throw new KiteError('消息已经交给 Claude，不能撤回', 409);
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
          : Promise.reject(new KiteError('停止尚未确认完成，请先核查并恢复会话', 409));
      }
      if (phase === 'stopping') return Promise.reject(new KiteError('正在停止，请重试原停止请求', 409));
      const incoming = new Map<string, Input>();
      for (const input of request.inputs ?? []) {
        const known = data.inputs.find((entry) => entry.input.id === input.id)?.input ?? incoming.get(input.id);
        if (known && !sameInput(known, input)) return Promise.reject(new KiteError('消息 ID 已用于其他内容', 409));
        incoming.set(input.id, input);
      }
      for (const input of incoming.values()) {
        const known = data.inputs.find((entry) => entry.input.id === input.id);
        if (!known) {
          data.inputs.push({ input, sdkId: randomUUID(), at: Date.now(), status: 'queued', delivered: false, midTurn: false });
        }
      }
      const receipt = { id: request.id, request: encoded, returned: [] as Input[], completed: false };
      data.stops.push(receipt);
      data.paused = false; phase = 'stopping'; save(); controller.abort();
      stopping = (async () => {
        compactionAbort?.abort();
        await compacting;
        const running = driver;
        const cancelled = new Set(await running?.stop() ?? []);
        for (const entry of data.inputs) if (entry.status === 'queued' || entry.status === 'unconfirmed' || (cancelled.has(entry.sdkId) && !entry.delivered)) {
          entry.status = 'cancelled'; receipt.returned.push(entry.input);
        }
        save();
        if (running) await running.shutdown();
        await waitTools(); await settling; processesStopped();
        phase = 'idle'; data.outcome = { kind: 'interrupted' }; receipt.completed = true; save();
        return receipt.returned;
      })().catch((error) => {
        phase = 'idle'; data.recovery ??= { message: `停止尚未确认：${String(error)}` };
        save(); throw error;
      }).finally(() => { stopping = undefined; });
      return stopping;
    },
    compact: (request) => compaction({ compact: request }),
    revertCompaction: (id) => compaction({ revert: id }),
    async resume() {
      requireStorage();
      if (data.recovery || phase !== 'idle' || compacting) throw new KiteError('请先停止执行并确认恢复', 409);
      // 压缩已记录而重组失败时在这里补做；没有待交接的内容时不改动会话。
      if (options.compaction && !driver) {
        try { await syncToClaude(options.directory, options.cwd, options.nativeId, options.prepare(data.through).agent.model.model); }
        catch (error) { throw new KiteError(`重组 Claude 会话失败：${(error as Error).message}`, 409); }
      }
      for (const entry of data.inputs) if (entry.status === 'unconfirmed') entry.status = 'queued';
      if (!data.inputs.some((entry) => entry.status === 'queued') && data.paused) data.inputs.push({
        input: { id: randomUUID(), text: '继续上次任务。', source: 'kite' }, sdkId: randomUUID(), at: Date.now(), status: 'queued', delivered: false, midTurn: false,
      });
      data.paused = false; save(); pump();
    },
    async recover() {
      requireStorage();
      if (phase !== 'idle') throw new KiteError('请先停止执行', 409);
      processesStopped();
      const history = new Set((await readClaudeMessages(options.nativeId, options.cwd)).map((message) => message.uuid));
      for (const entry of data.inputs) if (entry.status === 'active' || entry.status === 'submitted') {
        entry.delivered ||= history.has(entry.sdkId);
        entry.status = entry.delivered ? 'done' : 'unconfirmed';
      }
      for (const receipt of data.stops) if (!receipt.completed) {
        for (const entry of data.inputs) if (entry.status === 'queued' || entry.status === 'unconfirmed') {
          if (!receipt.returned.some((input) => input.id === entry.input.id)) receipt.returned.push(entry.input);
          entry.status = 'cancelled';
        }
        const order = new Map(data.inputs.map((entry, index) => [entry.input.id, index]));
        receipt.returned.sort((a, b) => (order.get(a.id) ?? Infinity) - (order.get(b.id) ?? Infinity));
        receipt.completed = true;
      }
      if (data.inputs.some((entry) => entry.status === 'unconfirmed')) data.outcome = {
        kind: 'failed', message: '部分输入的交接结果未知，已保留在待发送区；请核查后继续，或撤回编辑。继续会重新发送这些输入。',
      };
      data.recovery = undefined; data.paused = true; save();
    },
    async shutdown() {
      closing = true; controller.abort();
      compactionAbort?.abort();
      await compacting;
      await restarting;
      const running = driver;
      // 空闲的常驻进程直接关闭，不当作停止，上一回合的结果保持不变。
      if (running && phase === 'idle') await running.shutdown();
      else if (running) {
        phase = 'stopping'; publish();
        const cancelled = new Set(await running.stop());
        for (const entry of data.inputs) if (cancelled.has(entry.sdkId) && !entry.delivered) entry.status = 'queued';
        save(); await running.shutdown();
      }
      await waitTools(); await settling; processesStopped();
      releaseLock();
    },
  };
}
