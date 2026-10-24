/** 原生运行事件只在宿主内部流转；业务事件按实际归属标识工作区或线程。 */
import type { SDKMessage } from '@anthropic-ai/claude-agent-sdk';
import type { CheckResult } from './check.ts';
import type { RunnerState } from './claude/runner.ts';
import type { PluginInstance, WorkspaceStatus } from './model.ts';
import type { HarnessEvent } from './harness/types.ts';
import type { ClaudeState } from './claude/control.ts';
import type { ModelAccountsSnapshot } from './model-accounts.ts';
import type { Ask, Waiting } from './waiting.ts';
import type { LineNotification } from './line/monitor.ts';
import type { LibraryList } from './library-sync.ts';

export type RuntimeEvent =
  | { type: 'claude.control'; state: ClaudeState }
  | { type: 'claude.tool'; callId: string; stage: 'running' | 'finished'; at: number }
  | { type: 'claude.output'; callId: string; text: string; limit: number }
  | { type: 'sdk'; message: SDKMessage }
  | { type: 'harness'; event: HarnessEvent }
  | { type: 'runner'; state: RunnerState; error?: string }
  /** completed：回合正常完成；停止、失败时为 false。 */
  | { type: 'idle'; completed: boolean }
  /** 等你批准的审批出现或解除（waiting 缺省）；对象由宿主的 Waits 持有，两个后端共用。 */
  | { type: 'waiting'; waiting?: Waiting }
  /** 线程没回应的提问与密钥请求变了，带上整份；由宿主的 Asks 持有。 */
  | { type: 'asks'; asks: Ask[] }
  | { type: 'check'; result: CheckResult }
  | { type: 'error'; message: string };
export type ThreadEvent = RuntimeEvent & { threadId: string };
export type DomainEvent =
  | { type: 'checkout.changed'; projectId: string; checkoutId: string }
  | { type: 'workspace.changed'; workspaceId: string; status: WorkspaceStatus }
  | { type: 'thread.changed'; workspaceId: string; threadId: string; status: PluginInstance['status'] }
  | { type: 'model-accounts.changed'; modelAccounts: ModelAccountsSnapshot }
  /**
   * 资源库里的一类目录变了（本机改的或同步来的），读过的客户端重新读取：role 是角色列表（签名状态与点阵签名的变化也算），
   * template 是上下文模板，skill 是 skill 列表。
   */
  | { type: 'library.changed'; kind: LibraryList }
  /** 这台工作机的 MCP 服务连接状态或工具目录变了，客户端重新读 /mcp；catalog 为真是清单本身（服务名、说明）变了。 */
  | { type: 'mcp.changed'; catalog?: boolean }
  /** Line 的收件箱变了：客户端更新标志旁的数目，打开着的收件箱重新读取。 */
  | { type: 'line.inbox' }
  /** Line 找用户：App 发系统通知，点开是收件箱里的那一项。 */
  | { type: 'line.notification'; notification: LineNotification }
  /** monitor 的时间线或来源状态变了，打开着的窗口重新读取。 */
  | { type: 'monitor.changed'; workspaceId: string; instanceId: string }
  /** 自动更新的状态变了：客户端重新读 /update。 */
  | { type: 'update.changed' }
  | ({ workspaceId: string; originThreadId?: string } & (
    | { type: 'workspace.setup'; exit: number | null; log: string }
    | { type: 'workspace.snapshot'; commit: string; label: string; changedFiles: number }
    | { type: 'workspace.adopt'; result: AdoptResult }
    | { type: 'workspace.sync'; result: SyncResult }
    | { type: 'workspace.error'; message: string }
  ));
export type KiteEvent = ThreadEvent | DomainEvent;
/** 直接合入在本地完成后推送到远程；推送失败不撤销本地主线，下次集成时一并推上去。 */
/** local：项目没有远程，只合回本机主线，其他工作机同步时快进过来。 */
/** failed 的 gitLogin：远程要求登录或拒绝了令牌时的主机，App 据此就地绑定令牌后再集成一次。 */
export type PushOutcome = { status: 'pushed' } | { status: 'local' } | { status: 'failed'; message: string; gitLogin?: string };
export type AdoptResult =
  | { status: 'adopted'; commit: string; push: PushOutcome }
  /** 提交 PR：工作区分支推到了远程的 branch；url 是 PR 页面，不能自动开 PR 的平台是去开 PR 的网页，没有 number。 */
  | { status: 'proposed'; branch: string; url: string; number?: number }
  /** 有开放线程时交给 agent 解决冲突，回合结束后自动重试。 */
  | { status: 'conflict'; files: string[] };
/** 同步：主线的新改动合进了工作区分支（synced），或已是最新（current）；冲突同采纳。 */
export type SyncResult = { status: 'synced'; commit: string } | { status: 'current' } | { status: 'conflict'; files: string[] };

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
