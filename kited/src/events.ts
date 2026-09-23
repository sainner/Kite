/** 实时事件：SDK 原始消息原样转发，另加 Kite 自己的状态变化。事件不落库，历史以会话记录和 git 为准。 */
import type { SDKMessage } from '@anthropic-ai/claude-agent-sdk';
import type { RunnerState } from './runner.ts';
import type { SessionStatus } from './store.ts';

export type KiteEvent =
  | { type: 'sdk'; message: SDKMessage }
  | { type: 'status'; status: SessionStatus }
  | { type: 'runner'; state: RunnerState; error?: string }
  /** 回合结束，之后没有新消息。 */
  | { type: 'idle' }
  | { type: 'setup'; exit: number | null; log: string }
  | { type: 'snapshot'; commit: string; label: string; changedFiles: number }
  | { type: 'adopt'; result: AdoptResult }
  | { type: 'error'; message: string };

export type AdoptResult =
  | { status: 'adopted'; commit: string }
  /** 主线合进会话分支时冲突，已交给 agent 解决；它这一轮结束后自动重试。 */
  | { status: 'conflict'; files: string[] };

export type Envelope = KiteEvent & { session: string; at: number };

type Listener = (e: Envelope) => void;

export class Bus {
  private subs = new Set<{ session?: string; fn: Listener }>();
  emit(session: string, e: KiteEvent): void {
    const env = { ...e, session, at: Date.now() } as Envelope;
    for (const s of this.subs) if (!s.session || s.session === session) s.fn(env);
  }
  /** session 为空时订阅全部会话。返回取消函数。 */
  subscribe(session: string | undefined, fn: Listener): () => void {
    const sub = { session, fn };
    this.subs.add(sub);
    return () => this.subs.delete(sub);
  }
}
