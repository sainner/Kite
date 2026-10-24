/**
 * 子代理回报，规则见 docs/实例操作.md「子代理回报」：一回合里发过消息的代理是交代方，回合收尾时把结果投给它们。
 * 交代关系与当天的唤醒次数只在内存里，kited 重启后进行中的回合不再回报，次数重新算。
 */
import { randomUUID } from 'node:crypto';
import { assembleContext, bindContext, sceneValues } from './harness/context/assembler.ts';
import type { ContextDefinition, ContextValues } from './harness/context/types.ts';
import type { Input, InputNotice, Outcome, ThreadNotification } from './harness/types.ts';
import { MONITOR_DAILY_WAKES } from './operations/contract.ts';

export const agentReportContextDefinition: ContextDefinition = {
  version: 2, id: 'kite.agent-report', title: '子代理回报', scene: 'agent.report',
  blocks: [
    { type: 'paragraph', id: 'result', title: '结果', parts: [
      { type: 'text', text: '你交代给代理「' }, { type: 'variable', name: 'report.title' },
      { type: 'text', text: '」（' }, { type: 'variable', name: 'report.id' }, { type: 'text', text: '）的这一回合结束了：' },
      { type: 'variable', name: 'report.result' }, { type: 'text', text: '。它最后的回复：\n' }, { type: 'variable', name: 'report.reply' },
    ] },
  ],
};

/** 子工作区的结果：合回完成或失败、没准备好，交给开出它的代理，见 docs/实例操作.md「子工作区」。 */
export const agentWorkspaceContextDefinition: ContextDefinition = {
  version: 2, id: 'kite.agent-workspace', title: '子工作区的结果', scene: 'agent.workspace',
  blocks: [
    { type: 'paragraph', id: 'result', title: '结果', parts: [
      { type: 'text', text: '你用 isolation 开出的子工作区「' }, { type: 'variable', name: 'child.workspace' },
      { type: 'text', text: '」（代理 ' }, { type: 'variable', name: 'child.id' }, { type: 'text', text: '）' }, { type: 'variable', name: 'child.result' },
    ] },
  ],
};

/** 每个代理每天被回报唤醒的次数上限，与 monitor 的唤醒预算相同；超了改成不唤醒的通知。 */
const DAILY_WAKES = MONITOR_DAILY_WAKES;
const REPLY_LIMIT = 3000;

export interface AgentReportHost {
  template(scene: 'agent.report' | 'agent.workspace'): ContextDefinition;
  variables(threadId: string): ContextValues;
  /** 实例还开着（没归档）。 */
  open(instanceId: string): boolean;
  title(instanceId: string): string;
  reply(threadId: string): Promise<string | undefined>;
  /** 线程还有没回应的提问或密钥请求。 */
  asking(threadId: string): boolean;
  deliver(threadId: string, text: string, inputId: string, notice: InputNotice): Promise<unknown>;
  notify(threadId: string, notification: Omit<ThreadNotification, 'sequence'>): void;
}

/** 停下线程的是谁；只有经停止操作停下的才回报，换机、关机等宿主打断的不报。 */
export type Stopper = { kind: 'user' | 'line' } | { kind: 'agent'; instance: string };

export class AgentReports {
  private delegators = new Map<string, Set<string>>();
  private stoppers = new Map<string, Stopper>();
  private wakes = new Map<string, { day: string; count: number }>();

  constructor(private host: AgentReportHost, private now = () => new Date()) {}

  /** 线程收下输入之前登记；返回撤销登记的函数，收不下时调用。 */
  received(threadId: string, input: Input): () => void {
    const before = this.delegators.get(threadId);
    if (input.source === 'human') this.delegators.delete(threadId);
    else if (input.source === 'agent' && input.from.kind === 'agent') this.delegators.set(threadId, new Set([...before ?? [], input.from.instance]));
    else return () => {};
    return () => { if (before) this.delegators.set(threadId, before); else this.delegators.delete(threadId); };
  }

  stopping(threadId: string, by: Stopper): void { this.stoppers.set(threadId, by); }

  /** 回合收尾时调用一次。 */
  async settled(threadId: string, outcome: Outcome | undefined): Promise<void> {
    // 提问与密钥请求不阻塞，回合会先结束；等用户回应不算结束，交代方留到回应之后的回合再报。
    if (outcome?.kind === 'completed' && this.host.asking(threadId)) return;
    const delegators = this.delegators.get(threadId);
    const stopper = this.stoppers.get(threadId);
    this.delegators.delete(threadId);
    this.stoppers.delete(threadId);
    if (!delegators?.size || !outcome) return;
    if (outcome.kind === 'interrupted' && !stopper) return;
    const result = outcome.kind === 'completed' ? '完成' : outcome.kind === 'failed' ? `失败：${outcome.message}`
      : stopper!.kind === 'agent' ? `被「${this.host.title(stopper!.instance)}」停下` : stopper!.kind === 'line' ? '被 Line 停下' : '被用户停下';
    const title = this.host.title(threadId);
    const notice: InputNotice = { kind: 'agent.report', instance: threadId, subject: title,
      title: `${title} ${outcome.kind === 'completed' ? '做完了' : outcome.kind === 'failed' ? '失败了' : '被停下了'}` };
    const reply = (await this.host.reply(threadId))?.trim();
    const values = sceneValues<'agent.report'>({
      'report.title': title, 'report.id': threadId, 'report.result': result,
      'report.reply': !reply ? '（没有回复）' : reply.length > REPLY_LIMIT ? `…${reply.slice(-REPLY_LIMIT)}` : reply,
    });
    for (const target of delegators) {
      if (stopper?.kind === 'agent' && stopper.instance === target) continue;
      if (!this.host.open(target)) continue;
      try { await this.report(target, 'agent.report', `instance:${threadId}`, values, notice); }
      catch (error) { console.error(`[回报] ${threadId} 的结果没能交给 ${target}：${(error as Error).message}`); }
    }
  }

  /**
   * 子工作区的结果交给开出它的代理；它已归档就不交。title 是给人看的那一句里接在名称后面的话，result 是交给模型的、接在名称后面的一句话。
   */
  async workspace(target: string, child: { name: string; agent: string }, title: string, result: string): Promise<void> {
    if (!this.host.open(target)) return;
    await this.report(target, 'agent.workspace', `instance:${child.agent}`, sceneValues<'agent.workspace'>({
      'child.workspace': child.name, 'child.id': child.agent, 'child.result': result,
    }), { kind: 'agent.workspace', instance: child.agent, subject: child.name, title: `子工作区「${child.name}」${title}` });
  }

  /** kind 是场景，也是通知的种类与输入 ID 的开头。 */
  private async report(target: string, kind: 'agent.report' | 'agent.workspace', source: string, values: ContextValues, notice: InputNotice): Promise<void> {
    const assembled = assembleContext(bindContext(this.host.template(kind), { ...this.host.variables(target), ...values }));
    const notification = () => this.host.notify(target, {
      id: randomUUID(), kind, source, authority: 'observation', context: assembled.snapshot });
    if (!this.spendWake(target)) return notification();
    // 交代方正在停止时收不下输入，改成通知，下一次自然请求时纳入。
    try { await this.host.deliver(target, assembled.instructions, `${kind}:${source}:${randomUUID()}`, notice); }
    catch { notification(); }
  }

  private spendWake(target: string): boolean {
    const day = this.now().toDateString();
    const used = this.wakes.get(target);
    const count = used?.day === day ? used.count : 0;
    if (count >= DAILY_WAKES) return false;
    this.wakes.set(target, { day, count: count + 1 });
    return true;
  }
}
