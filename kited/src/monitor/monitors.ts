/**
 * 通用 monitor（docs/Monitor.md）：工作区里的常驻插件实例 kite.monitor，观察命令或定时来源，把事件记进时间线，
 * 合成一条 Kite 来源的输入唤醒它的对象代理。代理用 monitor_start 建的来源单一；Line 的 monitor 由宿主建，
 * 规则在 line/monitor.ts，这里只跳过它。monitor 自己不运行模型，也不发系统通知。
 * 命令在对象代理的沙箱里、按它的执行授权运行；它不挂在任何工具调用上，越界没有可等的人，一律按白名单拒绝。
 */
import { randomUUID } from 'node:crypto';
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { z } from 'zod';
import { KiteError } from '../errors.ts';
import { processGroupAlive, runCommand } from '../execution/command.ts';
import type { ExecutionPolicy } from '../execution/sandbox.ts';
import { assembleContext, bindContext, sceneValues } from '../harness/context/assembler.ts';
import type { ContextDefinition, ContextValues } from '../harness/context/types.ts';
import type { PluginInstance } from '../model.ts';
import type { Store } from '../store.ts';

export const monitorDefinitionId = 'kite.monitor';

export const monitorEventsContextDefinition: ContextDefinition = {
  version: 2, id: 'kite.monitor-events', title: 'monitor 的事件', scene: 'monitor.events',
  blocks: [
    { type: 'paragraph', id: 'events', title: '新事件', parts: [
      { type: 'text', text: '你用 monitor_start 开的监视「' }, { type: 'variable', name: 'monitor.title' },
      { type: 'text', text: '」（' }, { type: 'variable', name: 'monitor.id' }, { type: 'text', text: '）有新事件：\n' },
      { type: 'variable', name: 'monitor.events' },
    ] },
    { type: 'paragraph', id: 'guidance', title: '处理方式', parts: [{ type: 'text',
      text: '按事件决定要不要接着做。来源都结束后监视不再有事件；不再需要时用 monitor_stop 停掉。' }] },
  ],
};

const id = z.string().min(1);
const sourceSchema = z.discriminatedUnion('kind', [
  z.object({ id, kind: z.literal('command'), command: z.string().min(1).max(20_000) }).strict(),
  z.object({ id, kind: z.literal('timer'), at: z.number(), repeat: z.enum(['daily', 'weekly']).optional() }).strict(),
]);
export type MonitorSource = z.infer<typeof sourceSchema>;
/** 实例配置 config.monitor：代理建的有来源；Line 的由宿主建，只标明 system。 */
const configSchema = z.union([
  z.object({ target: id, sources: z.array(sourceSchema).min(1).max(4) }).strict(),
  z.object({ target: id, system: z.literal('line') }).strict(),
]);
export type MonitorConfig = z.infer<typeof configSchema>;
export const monitorConfig = (instance: Pick<PluginInstance, 'config'>): MonitorConfig => configSchema.parse(instance.config.monitor);

const eventSchema = z.object({
  seq: z.number().int(), at: z.number(), source: z.string(),
  /** event 是来源的事件，end 是来源结束，这两种唤醒对象代理；note 只是记录（如重启后重新开始）。 */
  kind: z.enum(['event', 'end', 'note']),
  text: z.string(),
}).strict();
export type MonitorEvent = z.infer<typeof eventSchema>;
const stateSchema = z.object({
  events: z.array(eventSchema).default([]),
  /** 已结束的来源与原因。 */
  ended: z.record(z.string(), z.object({ at: z.number(), reason: z.string() }).strict()).default({}),
  /** 起过的来源：再起时在时间线上记一条重新开始。 */
  started: z.array(z.string()).default([]),
  /** 定时来源下一次触发的时刻。 */
  next: z.record(z.string(), z.number()).default({}),
  seq: z.number().int().nonnegative().default(0),
  /** 已交给对象代理的事件，到这个序号为止。 */
  delivered: z.number().int().nonnegative().default(0),
  deliveries: z.number().int().nonnegative().default(0),
  /** 当天（本机时区）唤醒的次数；capped 表示已记下用完预算。 */
  wakes: z.object({ day: z.string(), count: z.number().int(), capped: z.literal(true).optional() }).strict().optional(),
  /** 已决定投递、尚未确认送达的唤醒；补送用同一 ID。 */
  pending: z.object({ id: z.string(), text: z.string(), through: z.number().int() }).strict().optional(),
}).strict();
export type MonitorRuntimeState = z.infer<typeof stateSchema>;
export const monitorRuntimeState = (instance: Pick<PluginInstance, 'state'>) => stateSchema.parse(instance.state.monitor ?? {});

/** 每个 monitor 每天最多唤醒对象代理的次数。 */
export const MONITOR_DAILY_WAKES = 40;
/** 一分钟里超过这么多事件就停掉这个来源。 */
const BURST_LIMIT = 60;
/** 同一来源 200 毫秒内的几行合成一个事件。 */
const LINE_BATCH_MS = 200;
/** 事件之后稍等再唤醒，把一串事件合成一次。 */
const WAKE_DELAY_MS = 1_000;
const RETRY_MS = 30_000;
const EVENTS_KEEP = 500;
const EVENT_TEXT_LIMIT = 4_000;
/** 每个代理同时开着的 monitor 上限。 */
const PER_TARGET = 10;
const MAX_TIMER = 2_147_483_647;
const day = (now: number) => new Date(now).toDateString();
const clip = (text: string) => text.length > EVENT_TEXT_LIMIT ? `${text.slice(0, EVENT_TEXT_LIMIT)}…` : text;
const time = (at: number) => new Date(at).toLocaleString('zh-CN', { hour12: false });

export interface MonitorStart {
  title: string;
  /** 每输出一行是一个事件，退出即结束。 */
  command?: string;
  /** 定时：at 是毫秒时刻。 */
  at?: number;
  repeat?: 'daily' | 'weekly';
}

export interface MonitorsHost {
  store: Store;
  home: string;
  env: NodeJS.ProcessEnv;
  /** 对象代理此刻的执行策略。 */
  policy(target: PluginInstance): Promise<ExecutionPolicy>;
  /** 投给对象代理的 Kite 来源输入；同一 ID 重复送达只去重。 */
  deliver(threadId: string, text: string, inputId: string): Promise<unknown>;
  template(): ContextDefinition;
  /** 对象代理线程的公共变量。 */
  variables(threadId: string): ContextValues;
  /** 在工作区的控制队列里执行。 */
  run<T>(workspaceId: string, action: () => Promise<T>): Promise<T>;
  /** 实例增删或归档：工作区聚合变了。 */
  changed(workspaceId: string): void;
  /** 时间线或来源状态变了，打开着的窗口重新读取。 */
  updated(workspaceId: string, instanceId: string): void;
  /** 事件到唤醒之间的合批等待，测试里缩短；默认 1 秒。 */
  wakeDelayMs?: number;
}

interface Running { stop(reason?: string): Promise<void> }

export class Monitors {
  /** 实例 → 来源 → 正在运行的命令或计时器。 */
  private running = new Map<string, Map<string, Running>>();
  private wakeTimers = new Map<string, Timer>();
  private bursts = new Map<string, number[]>();
  private closed = false;
  private reconciling = false;

  constructor(private host: MonitorsHost) {}

  /** 工作区、线程状态变化后在下一个微任务里核对一次；变化在核对中途发出时不重入。 */
  soon(): void {
    if (this.reconciling) return;
    this.reconciling = true;
    queueMicrotask(() => { this.reconciling = false; this.reconcile(); });
  }

  /** 代理开一个 monitor：放在代理所在的工作区，来源与对象都是这个代理，默认不开窗口。 */
  create(workspaceId: string, origin: NonNullable<PluginInstance['origin']>, input: MonitorStart): Promise<{ instanceId: string }> {
    return this.host.run(workspaceId, async () => {
      const target = this.host.store.instance(origin.instanceId);
      if (!target || target.status !== 'open' || target.workspaceId !== workspaceId) throw new KiteError('只有工作区里打开着的代理能开 monitor', 409);
      if (this.monitors().filter((instance) => instance.status === 'open' && monitorConfig(instance).target === target.id).length >= PER_TARGET) {
        throw new KiteError(`同时开着的 monitor 最多 ${PER_TARGET} 个，先用 monitor_stop 停掉不需要的`, 409);
      }
      const source: MonitorSource = input.command !== undefined ? { id: 'command', kind: 'command', command: input.command }
        : { id: 'timer', kind: 'timer', at: input.at!, ...(input.repeat ? { repeat: input.repeat } : {}) };
      const instance: PluginInstance = { id: randomUUID(), workspaceId, definitionId: monitorDefinitionId, title: input.title,
        config: { monitor: { target: target.id, sources: [source] } }, state: {}, presentation: 'background', status: 'open',
        createdAt: Date.now(), origin };
      this.host.store.addPluginInstance(instance);
      this.host.changed(workspaceId);
      this.reconcile();
      return { instanceId: instance.id };
    });
  }

  /** 工作区里代理开的 monitor 与来源状态。 */
  list(workspaceId: string) {
    return this.monitors().filter((instance) => instance.workspaceId === workspaceId && instance.status === 'open')
      .map((instance) => this.summary(instance));
  }

  read(instance: PluginInstance) {
    return { ...this.summary(instance), events: monitorRuntimeState(instance).events };
  }

  private summary(instance: PluginInstance) {
    const config = monitorConfig(instance);
    if (!('sources' in config)) throw new KiteError('这是 Line 的 monitor', 409);
    const state = monitorRuntimeState(instance);
    return { instanceId: instance.id, title: instance.title, target: config.target,
      sources: config.sources.map((source) => ({ ...source, ...(state.next[source.id] ? { next: state.next[source.id] } : {}),
        ...(state.ended[source.id] ? { ended: state.ended[source.id] } : {}) })),
      status: config.sources.every((source) => state.ended[source.id]) ? 'ended' as const : 'running' as const,
      wakesToday: state.wakes?.day === day(Date.now()) ? state.wakes.count : 0, dailyWakes: MONITOR_DAILY_WAKES };
  }

  /**
   * 让运行中的来源与实例、工作区、对象代理的状态一致：都打开着才运行；工作区交接、冻结或归档时停下进程但不算结束，
   * 回到打开时再起，时间线上记一条重新开始。对象代理归档时 monitor 随之归档。
   */
  reconcile(): void {
    if (this.closed) return;
    for (const instance of this.monitors()) {
      try { this.reconcileOne(instance); }
      catch (error) { console.error(`[monitor] 核对 ${instance.id} 失败：${(error as Error).message}`); }
    }
  }

  private reconcileOne(instance: PluginInstance): void {
    const config = monitorConfig(instance);
    const target = this.host.store.instance(config.target);
    if (instance.status === 'open' && target?.status !== 'open') {
      this.host.store.archiveInstance(instance.id);
      this.host.changed(instance.workspaceId);
      instance.status = 'archived';
    }
    if (!('sources' in config)) return;
    const live = instance.status === 'open' && this.host.store.workspace(instance.workspaceId)?.status === 'open';
    const state = monitorRuntimeState(instance);
    const running = this.running.get(instance.id) ?? new Map<string, Running>();
    for (const source of config.sources) {
      const current = running.get(source.id);
      if (live && !current && !state.ended[source.id]) running.set(source.id, this.launch(instance, source));
      if (!live && current) { running.delete(source.id); void current.stop(); }
    }
    if (running.size) this.running.set(instance.id, running);
    else this.running.delete(instance.id);
    if (live && (state.pending || state.events.some((event) => event.seq > state.delivered && event.kind !== 'note'))) this.scheduleWake(instance.id);
  }

  /** 停下工作区里 monitor 的来源，不算结束；工作区再开放时由 reconcile 重新开始。 */
  async closeWorkspace(workspaceId: string): Promise<void> {
    const stopping: Promise<void>[] = [];
    for (const [instanceId, sources] of this.running) {
      if (this.host.store.instance(instanceId)?.workspaceId !== workspaceId) continue;
      this.running.delete(instanceId);
      stopping.push(...[...sources.values()].map((entry) => entry.stop()));
    }
    await Promise.all(stopping);
  }

  /** 停下全部进程，来源不算结束，下次启动时再起。 */
  async close(): Promise<void> {
    this.closed = true;
    for (const timer of this.wakeTimers.values()) clearTimeout(timer);
    const all = [...this.running.values()].flatMap((sources) => [...sources.values()]);
    this.running.clear();
    await Promise.all(all.map((entry) => entry.stop()));
  }

  private monitors(): PluginInstance[] {
    return this.host.store.workspaces().flatMap((workspace) => this.host.store.instances(workspace.id))
      .filter((instance) => instance.definitionId === monitorDefinitionId);
  }

  private launch(instance: PluginInstance, source: MonitorSource): Running {
    this.mutate(instance.id, (state) => {
      if (state.started.includes(source.id)) this.append(state, source.id, 'note', '重新开始监视（工作机重启或工作区重新打开），期间的事件可能重复或遗漏');
      else state.started.push(source.id);
    });
    return source.kind === 'command' ? this.command(instance, source) : this.timer(instance, source);
  }

  private command(instance: PluginInstance, source: Extract<MonitorSource, { kind: 'command' }>): Running {
    const controller = new AbortController();
    let reason: string | undefined;
    let buffer = '';
    let lines: string[] = [];
    let batch: Timer | undefined;
    const flush = () => {
      clearTimeout(batch);
      batch = undefined;
      if (!lines.length) return;
      const text = lines.join('\n');
      lines = [];
      this.event(instance.id, source.id, text, () => { reason = `事件太密（一分钟超过 ${BURST_LIMIT} 个），已停掉这个来源`; controller.abort(); });
    };
    const onStdout = (part: string) => {
      buffer += part;
      for (let end = buffer.indexOf('\n'); end >= 0; end = buffer.indexOf('\n')) {
        const line = buffer.slice(0, end).replace(/\r$/, '');
        buffer = buffer.slice(end + 1);
        if (line.trim()) lines.push(line);
      }
      if (buffer.length > EVENT_TEXT_LIMIT) { lines.push(buffer); buffer = ''; }
      if (lines.length && !batch) batch = setTimeout(flush, LINE_BATCH_MS);
    };
    const directory = join(this.host.home, 'sessions', instance.id);
    const done = (async () => {
      const config = monitorConfig(instance);
      const target = this.host.store.instance(config.target);
      const workspace = this.host.store.workspace(instance.workspaceId);
      if (!target || !workspace) throw new KiteError('monitor 的对象代理或工作区不在了');
      this.killLeftovers(directory);
      const result = await runCommand(source.command, MAX_TIMER, controller.signal, {
        cwd: workspace.cwd, logDir: join(directory, 'commands'), env: this.host.env, policy: await this.host.policy(target), outputLimit: 2_000,
        onStdout, onProcess: (pid, active) => this.registerProcess(directory, pid, active),
      });
      if (buffer.trim()) lines.push(buffer);
      flush();
      // 关停或工作区不再打开时停下的不算结束；事件太密停下的算。
      if (controller.signal.aborted && !reason) return;
      this.end(instance.id, source.id, reason ?? `命令结束：${result.output.split('\n')[0]}`);
    })().catch((error) => {
      if (!controller.signal.aborted || reason) this.end(instance.id, source.id, reason ?? `命令没能运行：${(error as Error).message}`);
    });
    return { stop: async () => { controller.abort(); await done; } };
  }

  private timer(instance: PluginInstance, source: Extract<MonitorSource, { kind: 'timer' }>): Running {
    let handle: Timer | undefined;
    let stopped = false;
    const arm = () => {
      if (stopped) return;
      const next = monitorRuntimeState(this.host.store.instance(instance.id)!).next[source.id] ?? source.at;
      handle = setTimeout(fire, Math.min(Math.max(next - Date.now(), 0), MAX_TIMER));
    };
    const fire = () => {
      if (stopped) return;
      const now = Date.now();
      const next = monitorRuntimeState(this.host.store.instance(instance.id)!).next[source.id] ?? source.at;
      // 超过 setTimeout 上限的远期时刻分几段等。
      if (next > now) { arm(); return; }
      this.event(instance.id, source.id, `到点：${time(next)}`);
      if (!source.repeat) { this.end(instance.id, source.id, '定时已触发'); return; }
      const step = (source.repeat === 'daily' ? 1 : 7) * 24 * 3_600_000;
      let following = next;
      while (following <= now) following += step;
      this.mutate(instance.id, (state) => { state.next[source.id] = following; });
      arm();
    };
    arm();
    return { stop: async () => { stopped = true; clearTimeout(handle); } };
  }

  /** 记下一个来源事件；同一来源一分钟里超过上限就叫停。 */
  private event(instanceId: string, sourceId: string, text: string, burst?: () => void): void {
    const key = `${instanceId}:${sourceId}`;
    const now = Date.now();
    const recent = [...(this.bursts.get(key) ?? []).filter((at) => now - at < 60_000), now];
    this.bursts.set(key, recent);
    this.mutate(instanceId, (state) => this.append(state, sourceId, 'event', clip(text)));
    if (burst && recent.length > BURST_LIMIT) burst();
    this.scheduleWake(instanceId);
  }

  private end(instanceId: string, sourceId: string, reason: string): void {
    this.running.get(instanceId)?.delete(sourceId);
    this.bursts.delete(`${instanceId}:${sourceId}`);
    if (!this.host.store.instance(instanceId)) return;
    this.mutate(instanceId, (state) => {
      state.ended[sourceId] = { at: Date.now(), reason };
      this.append(state, sourceId, 'end', reason);
    });
    this.scheduleWake(instanceId);
  }

  private append(state: MonitorRuntimeState, source: string, kind: MonitorEvent['kind'], text: string): void {
    state.seq += 1;
    state.events = [...state.events, { seq: state.seq, at: Date.now(), source, kind, text }].slice(-EVENTS_KEEP);
  }

  private scheduleWake(instanceId: string, delay = this.host.wakeDelayMs ?? WAKE_DELAY_MS): void {
    if (this.closed || this.wakeTimers.has(instanceId)) return;
    const timer = setTimeout(() => { this.wakeTimers.delete(instanceId); void this.wake(instanceId); }, delay);
    timer.unref();
    this.wakeTimers.set(instanceId, timer);
  }

  /** 把还没交给对象代理的事件合成一条输入投过去；先落盘再投递，失败稍后用同一 ID 补送。每天有预算，超了只记时间线。 */
  private async wake(instanceId: string): Promise<void> {
    const instance = this.host.store.instance(instanceId);
    if (!instance || instance.status !== 'open' || this.host.store.workspace(instance.workspaceId)?.status !== 'open') return;
    const config = monitorConfig(instance);
    const pending = this.mutate(instanceId, (state) => {
      if (state.pending) return state.pending;
      const fresh = state.events.filter((event) => event.seq > state.delivered && event.kind !== 'note');
      if (!fresh.length) return undefined;
      const now = Date.now();
      const count = state.wakes?.day === day(now) ? state.wakes.count : 0;
      const through = fresh.at(-1)!.seq;
      if (count >= MONITOR_DAILY_WAKES) {
        if (!(state.wakes?.day === day(now) && state.wakes.capped)) {
          this.append(state, 'monitor', 'note', `今天唤醒对象代理的次数（${MONITOR_DAILY_WAKES}）已用完，之后的事件只记在这里`);
          state.wakes = { day: day(now), count, capped: true };
        }
        state.delivered = through;
        return undefined;
      }
      state.wakes = { day: day(now), count: count + 1 };
      state.deliveries += 1;
      state.pending = { id: `monitor:${instanceId}:${state.deliveries}`, text: this.render(instance, config.target, fresh), through };
      return state.pending;
    });
    if (!pending) return;
    try {
      await this.host.deliver(config.target, pending.text, pending.id);
      this.mutate(instanceId, (state) => {
        if (state.pending?.id !== pending.id) return;
        state.delivered = Math.max(state.delivered, pending.through);
        state.pending = undefined;
      });
      // 投递期间又来的事件接着送。
      if (monitorRuntimeState(this.host.store.instance(instanceId)!).events.some((event) => event.seq > pending.through && event.kind !== 'note')) this.scheduleWake(instanceId);
    } catch (error) {
      console.error(`[monitor] 唤醒 ${config.target} 失败，稍后补送：${(error as Error).message}`);
      this.scheduleWake(instanceId, RETRY_MS);
    }
  }

  private render(instance: PluginInstance, target: string, events: MonitorEvent[]): string {
    return assembleContext(bindContext(this.host.template(), { ...this.host.variables(target), ...sceneValues<'monitor.events'>({
      'monitor.title': instance.title,
      'monitor.id': instance.id,
      'monitor.events': events.map((event) => `- [${time(event.at)}] ${event.kind === 'end' ? `（来源结束）${event.text}` : event.text}`).join('\n'),
    }) })).instructions;
  }

  private mutate<T>(instanceId: string, change: (state: MonitorRuntimeState) => T): T {
    const instance = this.host.store.instance(instanceId);
    if (!instance) throw new KiteError(`没有这个 monitor：${instanceId}`, 404);
    const state = monitorRuntimeState(instance);
    const result = change(state);
    this.host.store.setInstanceState(instanceId, { ...instance.state, monitor: state });
    this.host.updated(instance.workspaceId, instanceId);
    return result;
  }

  /** 上次运行留下的进程组（进程异常退出时没来得及停）先停掉，再起新的。 */
  private killLeftovers(directory: string): void {
    const file = join(directory, 'processes.json');
    if (!existsSync(file)) return;
    const pids: unknown = JSON.parse(readFileSync(file, 'utf8'));
    if (Array.isArray(pids)) for (const pid of pids) {
      if (Number.isSafeInteger(pid) && pid > 1 && processGroupAlive(pid)) { try { process.kill(-pid, 'SIGKILL'); } catch { /* 已经退出。 */ } }
    }
    writeFileSync(file, '[]');
  }

  private registerProcess(directory: string, pid: number, active: boolean): void {
    mkdirSync(directory, { recursive: true });
    writeFileSync(join(directory, 'processes.json'), JSON.stringify(active ? [pid] : []));
  }
}
