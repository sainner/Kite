import { randomUUID } from 'node:crypto';
import { Bus, type EventScope } from '../events.ts';
import type { DisplayEvent } from './protocol.ts';

/** 显示协议按对象归属过滤；目录流只包含概要变更。 */
export function inScope(event: DisplayEvent, scope: EventScope): boolean {
  // workspace.snapshot 也给目录流：浏览窗口据此跟上 agent 改了的文件、刷新时间线
  if (scope === 'catalog') return ['checkout.changed', 'workspace.changed', 'workspace.snapshot', 'thread.changed', 'thread.activity', 'model-accounts.changed', 'library.changed',
    'mcp.changed', 'line.inbox', 'line.notification', 'monitor.changed', 'update.changed'].includes(event.type);
  if ('workspaceId' in scope) return 'workspaceId' in event && event.workspaceId === scope.workspaceId;
  // 活动摘要是目录概览，线程流已有完整的 thread.state。
  return 'threadId' in event && event.threadId === scope.threadId && event.type !== 'thread.activity';
}

/** cursor 只标识本次服务进程中的投影版本；线程流重连时据此只补变过的记录，见 TranscriptProjection.snapshot。 */
export class TranscriptFeed extends Bus<DisplayEvent & { cursor: string }> {
  private epoch = randomUUID();
  private count = 0;
  get cursor(): string { return `${this.epoch}:${this.count}`; }
  /** 最近一个事件的序号。 */
  get seq(): number { return this.count; }
  /** 本服务进程发出的 cursor 里的序号；别的进程的或认不出的为 undefined，不同进程的序号不可比较。 */
  seqOf(cursor: string): number | undefined {
    const split = cursor.lastIndexOf(':');
    const seq = Number(cursor.slice(split + 1));
    return split > 0 && cursor.slice(0, split) === this.epoch && Number.isSafeInteger(seq) && seq >= 0 && seq <= this.count ? seq : undefined;
  }
  override emit(event: DisplayEvent): void {
    this.count++;
    super.emit({ ...event, cursor: this.cursor });
  }
}
