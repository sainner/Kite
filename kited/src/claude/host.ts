/** Claude 的宿主只管理输入交接和 Kite 工具；模型循环、上下文历史及续接由 SDK 负责。 */
import { randomUUID } from 'node:crypto';
import { existsSync, mkdirSync, rmSync, readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import type { Options } from '@anthropic-ai/claude-agent-sdk';
import { Runner } from './runner.ts';
import { readClaudeMessages } from './history.ts';
import { claudeToolServer } from './tools.ts';
import { claudeState, readClaudeControl, sameInput, saveClaudeControl } from './control.ts';
import { KiteError } from '../errors.ts';
import { localTools } from '../execution/local-tools.ts';
import { commandEnvironment, type ExecutionPolicy } from '../execution/sandbox.ts';
import { processGroupAlive } from '../execution/command.ts';
import type { Input, Outcome, Phase, StopRequest, Tool } from '../harness/types.ts';
import type { AgentDefinition } from '../agents/definition.ts';
import type { Runtime, RuntimeEvents } from '../runtime.ts';

export function openClaudeHost(options: {
  cwd: string; directory: string; diffDir: string; nativeId: string; title: string;
  policy(): ExecutionPolicy;
  prepare(afterNotification: number): { agent: AgentDefinition; instructions: string; contextUpdate: string; tools: Tool[]; allowed: Set<string>; notificationText: string; through: number };
  events: RuntimeEvents;
}): Runtime {
  const data = readClaudeControl(options.directory);
  const lock = join(options.directory, 'claude-lock');
  mkdirSync(options.directory, { recursive: true, mode: 0o700 });
  if (existsSync(lock)) {
    const pid = Number(readFileSync(join(lock, 'owner'), 'utf8'));
    let alive = true;
    try { process.kill(pid, 0); } catch (error) { alive = (error as NodeJS.ErrnoException).code !== 'ESRCH'; }
    if (alive) throw new KiteError('Claude 会话仍被另一个宿主占用', 409);
    rmSync(lock, { recursive: true });
  }
  mkdirSync(lock, { mode: 0o700 });
  writeFileSync(join(lock, 'owner'), String(process.pid));
  let phase: Phase = 'idle';
  let driver: Runner | undefined;
  let controller = new AbortController();
  let closing = false;
  let settling: Promise<void> = Promise.resolve();
  let stopping: Promise<Input[]> | undefined;
  let terminal: Outcome | undefined;
  let storageFailed = false;
  const activeTools = new Set<string>();
  const drainWaiters = new Set<() => void>();
  const publish = () => options.events.emit({ type: 'claude.control', state: claudeState(data, phase) });
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
    env: commandEnvironment(process.env), policy: options.policy,
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
  const finish = async (error?: string) => {
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
    phase = wasStopping ? 'stopping' : 'idle'; driver = undefined;
    save();
    options.events.emit({ type: 'runner', state: 'closed', ...(error ? { error } : {}) });
    if (!wasStopping && !closing && !data.paused && data.inputs.some((entry) => entry.status === 'queued')) pump();
    else options.events.idle(data.outcome.kind === 'completed');
  };
  const pump = () => {
    if (closing || phase === 'stopping' || data.recovery || data.paused || (driver && driver.state !== 'running')) return;
    const entry = data.inputs.find((item) => item.status === 'queued');
    if (!entry) return;
    let prepared: ReturnType<typeof options.prepare>;
    try { prepared = options.prepare(data.through); } catch (error) {
      data.outcome = { kind: 'failed', message: String(error) }; data.paused = true; save(); return;
    }
    data.initialContext ??= prepared.instructions;
    if (driver) { submitQueued(driver); return; }
    controller = new AbortController(); terminal = undefined;
    phase = 'running'; data.outcome = undefined; save();
    const available = [...tools, ...prepared.tools].filter((tool) => prepared.allowed.has(tool.name));
    driver = new Runner({ cwd: options.cwd, nativeId: options.nativeId, title: options.title, closeWhenIdle: true,
      configuration: () => ({ model: prepared.agent.model.model, effort: prepared.agent.model.reasoning === 'default' ? undefined : prepared.agent.model.reasoning as Options['effort'],
        maxTurns: prepared.agent.maxRequestsPerTurn, systemPrompt: { type: 'custom', snapshot: false, prompt: data.initialContext! } }),
      mcpServers: () => ({ kite: claudeToolServer({ tools: available,
        allowed: (name) => options.prepare(data.through).allowed.has(name),
        context: (callId) => {
          if (controller.signal.aborted) throw new Error('本次执行已停止');
          activeTools.add(callId);
          options.events.emit({ type: 'claude.tool', callId, stage: 'running', at: Date.now() });
          return { cwd: options.cwd, signal: controller.signal, callId, turnId: entry.sdkId,
            output: (text, limit) => options.events.emit({ type: 'claude.output', callId, text, limit }) };
        },
        finished: (callId, result) => {
          activeTools.delete(callId);
          if (!activeTools.size) { for (const resolve of drainWaiters) resolve(); drainWaiters.clear(); }
          options.events.emit({ type: 'claude.tool', callId, stage: 'finished', at: Date.now() });
          if (result.status === 'unknown') {
            data.recovery = { message: result.output }; controller.abort(); save();
            void driver?.stop().then(() => driver?.shutdown()).catch((error) => options.events.emit({ type: 'error', message: String(error) }));
          }
        },
      }) }),
    }, {
      message(message) {
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
      idle() {},
      state(state, error) {
        if (state === 'closed') settling = finish(error).catch((failure) => {
          data.recovery = { message: String(failure) }; phase = 'idle'; publish();
          options.events.emit({ type: 'error', message: String(failure) });
        });
        else options.events.emit({ type: 'runner', state, ...(error ? { error } : {}) });
      },
    });
    submitQueued(driver);
  };
  const submitQueued = (running: Runner) => {
    for (const entry of data.inputs.filter((item) => item.status === 'queued')) {
      entry.status = 'submitted'; save();
      running.send({ id: entry.sdkId, text: entry.input.text, human: entry.input.source === 'human' });
    }
  };
  publish();
  return {
    get state() { return phase; }, get busy() { return phase !== 'idle'; }, get recovery() { return data.recovery; },
    async send(input) {
      requireStorage();
      const existing = data.inputs.find((entry) => entry.input.id === input.id);
      if (existing) { if (!sameInput(existing.input, input)) throw new KiteError('消息 ID 已用于其他内容', 409); return; }
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
    async resume() {
      requireStorage();
      if (data.recovery || phase !== 'idle') throw new KiteError('请先停止执行并确认恢复', 409);
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
      const running = driver;
      if (running) {
        phase = 'stopping'; publish();
        const cancelled = new Set(await running.stop());
        for (const entry of data.inputs) if (cancelled.has(entry.sdkId) && !entry.delivered) entry.status = 'queued';
        save(); await running.shutdown();
      }
      await waitTools(); await settling; processesStopped();
      rmSync(lock, { recursive: true, force: true });
    },
  };
}
