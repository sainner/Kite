/**
 * Line 的 monitor：属于 Line 工作区的宿主机制，不自己运行模型。定时读账号下各工作机的状态汇总，由状态派生待办集合；
 * 集合里出现新事项时，给 Line 的线程投一条 Kite 来源的输入（正文用 line.monitor 模板），Line 空闲时开始回合，
 * 运行中在下一次请求纳入。事项消失不唤醒，无事时不运行模型。状态（已告知的待办、离线时间、待投递项）存在 Line 实例上，
 * 随工作区流转。远程工作机的事件只用来提示重读，这一版用定时读取代替订阅各机事件流。
 */
import { z } from 'zod';
import { assembleContext } from '../harness/context/assembler.ts';
import type { ContextVariable } from '../harness/context/scenes.ts';
import type { ContextBinding, ContextDefinition } from '../harness/context/types.ts';
import type { MachineSummary } from '../kite.ts';
import type { AgentInstance } from '../model.ts';
import type { Store } from '../store.ts';
import type { Peers } from './peers.ts';

export const lineMonitorContextDefinition: ContextDefinition = {
  version: 2, id: 'kite.line-monitor', title: 'Line 的工作区变化', scene: 'line.monitor',
  blocks: [
    { type: 'paragraph', id: 'added', title: '新出现的待办', parts: [
      { type: 'text', text: '账号下的工作区有新的事项需要你核对：\n' },
      { type: 'variable', name: 'monitor.added' },
    ] },
    { type: 'condition', id: 'pending', title: '仍未处理的待办', variable: 'monitor.pending',
      cases: [{ id: 'pending-none', title: '没有', equals: '', blocks: [] }],
      otherwise: { id: 'pending-some', title: '有', blocks: [{ type: 'paragraph', id: 'pending-list', title: '仍未处理', parts: [
        { type: 'text', text: '之前告知过、仍未处理的：\n' },
        { type: 'variable', name: 'monitor.pending' },
      ] }] } },
    { type: 'paragraph', id: 'guidance', title: '处理方式', parts: [{ type: 'text',
      text: '先用 line_status 核对最新状态，需要用户回答、决定或验收的再用 report 告诉用户；不需要用户处理的不必上报。' }] },
  ],
};

const stateSchema = z.object({
  /** 已告知 Line 的待办：键是事项，值是所在工作机与说明。 */
  todo: z.record(z.string(), z.object({ machine: z.string(), text: z.string() }).strict()).default({}),
  /** 连不上的工作机从何时起连不上（毫秒）。 */
  unreachable: z.record(z.string(), z.number()).default({}),
  seq: z.number().int().nonnegative().default(0),
  /** 已决定投递、尚未确认送达的输入；重启后用同一 ID 补送。 */
  pending: z.object({ id: z.string(), text: z.string() }).optional(),
}).strict();
export type MonitorState = z.infer<typeof stateSchema>;

export const monitorState = (instance: Pick<AgentInstance, 'state'>): MonitorState => stateSchema.parse(instance.state.monitor ?? {});

/** 连不上超过这么久才算待办，短暂断线不打扰 Line。 */
const UNREACHABLE_MS = 30 * 60_000;
const clip = (text: string, limit: number) => text.replace(/\s+/g, ' ').length > limit ? `${text.replace(/\s+/g, ' ').slice(0, limit)}…` : text.replace(/\s+/g, ' ');

/** 由一台工作机的汇总派生待办：未答复的上报、恢复阻塞、失败后等待继续的线程、准备失败的工作区。Line 自己的线程与冻结副本不算。 */
export function deriveTodo(summary: MachineSummary, line: string): Map<string, string> {
  const items = new Map<string, string>();
  const where = (workspace: MachineSummary['workspaces'][number], title?: string) =>
    `工作机「${summary.machine.name}」(${summary.machine.id}) 项目「${workspace.project.name}」工作区「${workspace.name}」(${workspace.id})${title ? ` 线程「${title}」` : ''}`;
  for (const workspace of summary.workspaces) {
    // 已流转走的是冻结副本，它的上报与线程状态以当前宿主为准。
    if (workspace.status === 'transferred') continue;
    if (workspace.status === 'failed') items.set(`workspace:${workspace.id}:failed`, `${where(workspace)}准备失败`);
    for (const thread of workspace.threads) {
      if (thread.id === line) continue;
      const at = `${where(workspace, thread.title)}(${thread.id})`;
      if (thread.recovery) items.set(`thread:${thread.id}:recovery`, `${at}需要恢复确认：${clip(thread.recovery, 200)}`);
      else if (thread.lastOutcome === 'failed' && thread.waitingForResume) items.set(`thread:${thread.id}:failed`, `${at}上一回合失败，等待继续`);
    }
    for (const report of workspace.reports) {
      if (report.threadId === line || report.status !== 'open') continue;
      const thread = workspace.threads.find((entry) => entry.id === report.threadId);
      items.set(`report:${report.id}`, `${where(workspace, thread?.title)}(${report.threadId}) 提出 ${report.kind} 上报 ${report.id}：${clip(report.text, 300)}`);
    }
  }
  return items;
}

export interface MonitorHost {
  store: Store;
  peers: Peers;
  /** 本机上的 Line 实例。 */
  line(): AgentInstance | undefined;
  /** 投给 Line 线程的 Kite 来源输入；同一 ID 重复送达只去重。 */
  deliver(threadId: string, text: string, inputId: string): Promise<unknown>;
  template(): ContextDefinition;
}

export class LineMonitor {
  private timer?: Timer;
  private soon?: Timer;
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
    this.timer = undefined;
    return this.running;
  }

  /** 读一轮状态并在有新待办时投递；上一轮没完就并入它。 */
  check(): Promise<void> {
    this.running ??= this.round().catch((error) => console.error(`[monitor] ${(error as Error).message}`)).finally(() => { this.running = undefined; });
    return this.running;
  }

  /** 当前的 monitor 状态，只读。 */
  state(): MonitorState | undefined {
    const line = this.host.line();
    return line ? monitorState(line) : undefined;
  }

  private async round(): Promise<void> {
    const line = this.host.line();
    if (!line) return;
    let state = monitorState(line);
    if (!state.pending) {
      const now = Date.now();
      const todo = new Map<string, { machine: string; text: string }>();
      const unreachable: Record<string, number> = {};
      const keep = (machine: string) => { for (const [key, item] of Object.entries(state.todo)) if (item.machine === machine) todo.set(key, item); };
      const machines = await this.host.peers.machines();
      for (const machine of machines) {
        let summary: MachineSummary | undefined;
        if (machine.online) try { summary = await this.host.peers.call<MachineSummary>(machine.id, 'GET', '/summary'); } catch { /* 记为连不上。 */ }
        if (summary) { for (const [key, text] of deriveTodo(summary, line.id)) todo.set(key, { machine: machine.id, text }); continue; }
        // 离线的工作机保留上次的待办，超过阈值另记一条连不上。
        const since = state.unreachable[machine.id] ?? now;
        unreachable[machine.id] = since;
        keep(machine.id);
        if (now - since >= UNREACHABLE_MS) todo.set(`machine:${machine.id}:unreachable`, { machine: machine.id, text: `工作机「${machine.name}」(${machine.id}) 已连不上超过 30 分钟` });
      }
      // 账号目录暂时读不到时没列出的工作机，同样保留上次的待办，免得恢复后当成新事项再唤醒 Line。
      for (const item of Object.values(state.todo)) if (!machines.some((machine) => machine.id === item.machine)) keep(item.machine);
      const added = [...todo].filter(([key]) => !(key in state.todo));
      const pending = [...todo].filter(([key]) => key in state.todo);
      state = { todo: Object.fromEntries(todo), unreachable, seq: state.seq + (added.length ? 1 : 0),
        ...(added.length ? { pending: { id: `monitor:${line.id}:${state.seq + 1}`, text: this.render(added.map(([, item]) => item.text), pending.map(([, item]) => item.text)) } } : {}) };
      this.save(line, state);
    }
    if (!state.pending) return;
    // 先落盘再投递：投递失败（如 Line 的工作区正在交接）下一轮用同一 ID 补送。
    await this.host.deliver(line.id, state.pending.text, state.pending.id);
    const { pending: _, ...delivered } = state;
    this.save(line, delivered);
  }

  private render(added: string[], pending: string[]): string {
    const bindings: Record<ContextVariable<'line.monitor'>, ContextBinding> = {
      'monitor.added': { text: added.map((text) => `- ${text}`).join('\n') },
      'monitor.pending': { text: pending.map((text) => `- ${text}`).join('\n') },
    };
    return assembleContext({ definition: this.host.template(), bindings }).instructions;
  }

  private save(line: AgentInstance, state: MonitorState): void {
    const current = this.host.store.instance(line.id);
    if (current) this.host.store.setInstanceState(line.id, { ...current.state, monitor: state });
  }
}
