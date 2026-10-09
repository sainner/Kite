import { randomUUID } from 'node:crypto';
import { Bus, type EventScope } from '../events.ts';
import type { DisplayEvent } from './protocol.ts';

/** 显示协议按对象归属过滤；目录流只包含概要变更。 */
export function inScope(event: DisplayEvent, scope: EventScope): boolean {
  if (scope === 'catalog') return ['checkout.changed', 'workspace.changed', 'thread.changed', 'model-accounts.changed', 'context-templates.changed'].includes(event.type);
  if ('workspaceId' in scope) return 'workspaceId' in event && event.workspaceId === scope.workspaceId;
  return 'threadId' in event && event.threadId === scope.threadId;
}

/** cursor 只标识本次服务进程中的投影版本。重连总发完整快照。 */
export class TranscriptFeed extends Bus<DisplayEvent & { cursor: string }> {
  private epoch = randomUUID();
  private seq = 0;
  get cursor(): string { return `${this.epoch}:${this.seq}`; }
  override emit(event: DisplayEvent): void {
    this.seq++;
    super.emit({ ...event, cursor: this.cursor });
  }
}
