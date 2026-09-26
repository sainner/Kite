/** 宿主内部事件：原生消息交给 transcript 投影，HTTP 只暴露统一后的 Kite 显示协议。 */
import type { SDKMessage } from '@anthropic-ai/claude-agent-sdk';
import type { CheckResult } from './check.ts';
import type { RunnerState } from './runner.ts';
import type { SessionStatus } from './store.ts';
import type { SessionEvent } from './harness/types.ts';

export type KiteEvent =
  | { type: 'sdk'; message: SDKMessage }
  /** 自研 harness 的原生事件，仅供宿主和显示投影使用。 */
  | { type: 'harness'; event: SessionEvent }
  | { type: 'status'; status: SessionStatus }
  | { type: 'runner'; state: RunnerState; error?: string }
  /** 回合结束，之后没有新消息。 */
  | { type: 'idle' }
  | { type: 'setup'; exit: number | null; log: string }
  | { type: 'snapshot'; commit: string; label: string; changedFiles: number }
  | { type: 'adopt'; result: AdoptResult }
  /** agent 调了 check 工具。 */
  | { type: 'check'; result: CheckResult }
  | { type: 'error'; message: string };

export type AdoptResult =
  | { status: 'adopted'; commit: string }
  /** 主线合进会话分支时冲突，已交给 agent 解决；它这一轮结束后自动重试。 */
  | { status: 'conflict'; files: string[] };

type Stamped<Event> = Event & { session: string; at: number };
export type Envelope = Stamped<KiteEvent>;
type Listener<Event> = (e: Stamped<Event>) => void;

export class Bus<Event = KiteEvent> {
  private subs = new Set<{ session?: string; fn: Listener<Event> }>();
  emit(session: string, e: Event): void {
    const env = { ...e, session, at: Date.now() };
    for (const s of this.subs) if (!s.session || s.session === session) s.fn(env);
  }
  /** session 为空时订阅全部会话。返回取消函数。 */
  subscribe(session: string | undefined, fn: Listener<Event>): () => void {
    const sub = { session, fn };
    this.subs.add(sub);
    return () => this.subs.delete(sub);
  }
}
