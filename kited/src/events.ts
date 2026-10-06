/** 原生运行事件只在宿主内部流转；业务事件按实际归属标识工作区或线程。 */
import type { SDKMessage } from '@anthropic-ai/claude-agent-sdk';
import type { CheckResult } from './check.ts';
import type { RunnerState } from './claude/runner.ts';
import type { PluginInstance, WorkspaceStatus } from './model.ts';
import type { HarnessEvent } from './harness/types.ts';
import type { ClaudeState } from './claude/control.ts';

export type RuntimeEvent =
  | { type: 'claude.control'; state: ClaudeState }
  | { type: 'claude.tool'; callId: string; stage: 'running' | 'finished'; at: number }
  | { type: 'claude.output'; callId: string; text: string; limit: number }
  | { type: 'sdk'; message: SDKMessage }
  | { type: 'harness'; event: HarnessEvent }
  | { type: 'runner'; state: RunnerState; error?: string }
  | { type: 'idle' }
  | { type: 'check'; result: CheckResult }
  | { type: 'error'; message: string };
export type ThreadEvent = RuntimeEvent & { threadId: string };
export type DomainEvent =
  | { type: 'checkout.changed'; projectId: string; checkoutId: string }
  | { type: 'workspace.changed'; workspaceId: string; status: WorkspaceStatus }
  | { type: 'thread.changed'; workspaceId: string; threadId: string; status: PluginInstance['status'] }
  | ({ workspaceId: string; originThreadId?: string } & (
    | { type: 'workspace.setup'; exit: number | null; log: string }
    | { type: 'workspace.snapshot'; commit: string; label: string; changedFiles: number }
    | { type: 'workspace.adopt'; result: AdoptResult }
    | { type: 'workspace.error'; message: string }
  ));
export type KiteEvent = ThreadEvent | DomainEvent;
/** 集成在本地完成后推送到远程；推送失败不撤销本地主线，下次集成或现场推送时一并推上去。 */
export type PushOutcome = { status: 'pushed' } | { status: 'failed'; message: string };
export type AdoptResult =
  | { status: 'adopted'; commit: string; push: PushOutcome }
  /** 有开放线程时交给 agent 解决冲突，回合结束后自动重试。 */
  | { status: 'conflict'; files: string[] };

export type EventScope = 'catalog' | { workspaceId: string } | { threadId: string };
export type Stamped<Event> = Event & { at: number };
export type Envelope = Stamped<KiteEvent>;

export class Bus<Event = KiteEvent> {
  private subs = new Set<{ filter?: (e: Stamped<Event>) => boolean; fn: (e: Stamped<Event>) => void }>();
  emit(event: Event): void {
    const env = { ...event, at: Date.now() };
    for (const { filter, fn } of this.subs) if (!filter || filter(env)) fn(env);
  }
  /** 不传过滤条件时订阅全部事件；调用方负责选择范围。 */
  subscribe(filter: ((e: Stamped<Event>) => boolean) | undefined, fn: (e: Stamped<Event>) => void): () => void {
    const sub = { filter, fn };
    this.subs.add(sub);
    return () => this.subs.delete(sub);
  }
}
