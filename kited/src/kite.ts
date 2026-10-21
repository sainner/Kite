/** 工作区负责文件、快照和采纳；线程负责模型执行及独立的对话记录。 */
import type { CompactionRequest, Input, InputNotice, InputOrigin, InputVia, StopRequest } from './harness/types.ts';
import { AgentReports, agentReportContextDefinition, agentWorkspaceContextDefinition } from './agent-reports.ts';
import { randomUUID } from 'node:crypto';
import { existsSync, readdirSync, rmSync } from 'node:fs';
import { FileDiffStore } from './workspace/file-diffs.ts';
import { join, relative } from 'node:path';
import { ChildrenPending, GitLoginRequired, KiteError } from './errors.ts';
import { type AdoptResult, Bus, type PushOutcome, type SyncResult } from './events.ts';
import { advanceMainline, behindCount, fetchMainline, hasUnmerged, mainline, mainRefs, mergeMainline, type Mainline } from './workspace/mainline.ts';
import { CheckoutManagement, type EnvFile, type ProjectSource } from './workspace/checkout-management.ts';
import { AccountData } from './account-data/store.ts';
import { Credentials } from './account-data/credentials.ts';
import { ProjectRegistry } from './account-data/registry.ts';
import { Directory, type Candidate } from './account-data/directory.ts';
import { Replication } from './account-data/replication.ts';
import { Updates } from './update/updates.ts';
import { GitHubBinding, gitHubRepo } from './account-data/github.ts';
import { fileKey, keychainKey } from './account-data/key.ts';
import type { GitCredentials } from './git-credential.ts';
import type { Peer } from './peer-fetch.ts';
import { fetchPeerRefs, serveCheckout, type PeerRoute } from './workspace/peer-git.ts';
import { replicaDigest, replicaFiles, replicaManifest, replicaSources, ReplicaStore, Replicas, type FileState, type ReplicaEntry, type ReplicaPage } from './transfer/replica.ts';
import { normalizeRemote, remoteHost } from './remote-url.ts';
import { gitTry, isDirty, revParse } from './workspace/git.ts';
import { fetchBranch, lsRemote, pushBranch, tracking } from './workspace/remote.ts';
import { openRuntime, type Runtime, type RuntimeOptions } from './runtime.ts';
import { capture, changesBetween, findSnapshot, list, restore, snapshotRef, type Snapshot } from './workspace/snapshots.ts';
import { childChanged, commitParent, mergeChild, mergeParent } from './workspace/children.ts';
import { compactTemplate } from './harness/compaction.ts';
import type { Store } from './store.ts';
import { holds, type AgentInstance, type Checkout, type Machine, type OpenWindowRequest, type PluginInstance, type Project, type ThreadContext, type Workspace, type WorkspaceModel, type WorkspaceStatus, type WorkspaceWindow } from './model.ts';
import { PluginCatalog } from './plugins/catalog.ts';
import { PluginHost } from './plugins/host.ts';
import { InstanceConfiguration } from './instance-configuration.ts';
import { handOff } from './handoff/handoff.ts';
import { instanceAgent, type AgentDefinition } from './agents/definition.ts';
import { InstanceLifecycle, type AgentChoice } from './instance-lifecycle.ts';
import { ContextTemplates } from './context-templates.ts';
import { defaultRoleId, instanceRole, lineRoleId, Roles, type RoleSelection, type RoleSnapshot } from './roles.ts';
import { environmentVariables, previewVariable, storedThreadVariables, writeVariableFile, type VariableScope } from './context-variables.ts';
import { LibrarySync, type LibraryChanges } from './library-sync.ts';
import { agentDefinitionId, agentToolCatalog, agentTools } from './plugins/definitions.ts';
import { addWorktree, excludeSecretFiles, removeSecretFile, removeWorktree, runSetup, writeSecretFiles } from './workspace/worktrees.ts';
import {
  agentConfigurationContextDefinition, contextUpdateContextDefinition, executionPermissionsContextDefinition, fileChangesContextDefinition,
  pluginToolsContextDefinition,
} from './harness/context/notifications.ts';
import { defaultApprovalMode, effectiveExecution, instanceExecutionChanges, unsandboxedVerdict } from './execution/grants.ts';
import { agentPolicy, harnessPolicy } from './execution/policy.ts';
import { commandEnvironment } from './execution/sandbox.ts';
import { monitorConfig, monitorDefinitionId, monitorEventsContextDefinition, Monitors } from './monitor/monitors.ts';
import { InstanceOperations } from './operations/operations.ts';
import { OperationReceipts } from './operations/receipts.ts';
import { lineGrant, type OperationGrant, type OperationInput } from './operations/contract.ts';
import { Peers } from './line/peers.ts';
import { LineMonitor, lineMonitorContextDefinition } from './line/monitor.ts';
import { lineTools } from './line/tools.ts';
import { LINE_AGENTS } from './line/project.ts';
import { Attention } from './line/attention.ts';
import { setupLogPath, worktreePath } from './paths.ts';
import type { Network } from './network.ts';
import { WorkspaceFiles, fileSelection } from './workspace/files.ts';
import { TranscriptFeed } from './transcript/feed.ts';
import { TranscriptHistory } from './transcript/history.ts';
import type { DisplayState, History, ThreadActivity } from './transcript/protocol.ts';
import { readRaw, type RawPage } from './transcript/raw.ts';
import { claudeRecordPath } from './handoff/claude-records.ts';
import { LightTasks } from './light-tasks.ts';
import { ThreadTitles, titleTemplate } from './thread-titles.ts';
import { WorkspaceNames, workspaceNameTemplate } from './workspace-names.ts';
import { draftPullRequest, pullRequestTemplate } from './pull-requests.ts';
import { commitMessageTemplate, draftCommit } from './commit-messages.ts';
import { emblemTemplate, TemplateEmblems } from './template-emblems.ts';
import { ChatGPTModel } from './harness/chatgpt.ts';
import { readSubscriptionCredentials } from './harness/auth.ts';
import { SubscriptionLogins } from './subscription-logins.ts';
import { ModelAccounts, readModelAccounts } from './model-accounts.ts';
import { agentModelCatalog } from './agents/capabilities.ts';
import { TokenCounter } from './token-counts.ts';
import { VoiceSessions, voiceTemplate } from './voice/sessions.ts';
import { Terminals, terminalExitContextDefinition } from './terminal/terminals.ts';
import { type ApprovalRequest, type Ask, Asks, questionResponseOf, questionResultText, secretDeniedText, secretResponseOf, type SecretWaitingItem, type Waiting, WaitingConflict, Waits } from './waiting.ts';
import { hasEnvKey, secretLabel, setEnvLine, type SecretRequest } from './secrets.ts';
import type { Integration } from './account-data/registry.ts';
import { WorkspaceTransfers } from './transfer/transfers.ts';
import { readManifest } from './transfer/records.ts';
import { diskEnough, modelLogin, readEnvironment, type Environment, type HandoverNeed } from './environment.ts';

export interface ThreadView extends ThreadContext { runner: Runtime['state']; busy: boolean }

export interface MachineSummary {
  machine: { id: string; name: string };
  workspaces: Array<{
    id: string; epoch: number; status: WorkspaceStatus; name: string; project: { id: string; name: string };
    threads: Array<{ id: string; title: string; role: string | null; phase: string; busy: boolean; waitingForResume: boolean;
      lastOutcome?: string; failure?: string; recovery?: string; waiting?: Waiting; asks?: Ask[];
      /** 这台工作机实时看到的最近一次回合结束时间；重启后要等下一次回合结束才有。 */
      settledAt?: number;
      /** 最近一条输入是 Line 自己的说明：这一回合是 Line 发起的工作，结果交给 Line。 */
      byLine?: true }>;
  }>;
}
const firstLine = (text: string) => text.trim().split('\n')[0]!.trim() || '（空消息）';
const titleOf = (prompt: string) => firstLine(prompt).slice(0, 80);
/** 手动起的标题与名称：去掉首尾空白后须为 1～80 字符的单行文本。 */
function singleLine(text: string, what: string): string {
  const value = text.trim();
  if (!value || value.length > 80 || /[\r\n]/.test(value)) throw new KiteError(`${what}须为 1～80 字符的单行文本`);
  return value;
}
/** 不带首条消息建的空工作区先叫这个，之后跟着代理的标题起名，见 WorkspaceNames。 */
const UNNAMED_WORKSPACE = '新工作区';

/** 新建工作区时 App 定的几个 ID，见 Kite.createWorkspace。 */
export interface NewWorkspaceIds { id?: string; windowId?: string; messageId?: string }

const PUSH_ATTEMPTS = 3;
/** 有预告的离开时被打断、换到另一台工作机后补的说明。 */
const CONTINUE_AFTER_MOVE = '原来那台工作机将要睡眠或关机，这个工作区换到了这里，刚才的回合被打断了。接着刚才的工作继续。';

/** 冲突交给线程处理的那次工作区操作：集成、同步或子工作区合回，回合正常结束后宿主接着做。 */
type Merging = 'adopt' | 'sync' | 'merge';
/** 子工作区合回的结果：merged 合进了父工作区，unchanged 没有改动，两种都已归档；conflict 冲突交给了子工作区里的线程。 */
export type MergeResult = { status: 'merged' | 'unchanged' } | { status: 'conflict'; files: string[] };
/** 合回第二步因父工作区又改了同一处而撤回后，从第一步重来的次数上限。 */
const MERGE_ATTEMPTS = 3;
/** initiator 是发起合回的代理；threadId 与 afterResolution 是处理冲突的回合正常结束后宿主接着合；check 是操作层的授权复核。 */
type MergeOptions = { initiator?: string; threadId?: string; afterResolution?: boolean; check?: () => void };
/** continue 见 Kite.restoreWorkspace。 */
type TransferOptions = { operationId?: string; timeoutMs?: number; continue?: Array<{ threadId: string; inputs: Input[] }> };
/** 提交 PR 时已推上去的分支（分支与提交记在工作区的 pullRequest 上）：base 是 PR 的目标分支，target 是合进来的远程主线引用。 */
type Proposal = { status: 'pushed'; base: string; target: string };

const mergingTitle: Record<Merging, string> = { adopt: '集成', sync: '同步', merge: '合回' };

function conflictPrompt(action: Merging, branch: string, files: string[]): string {
  const head = action === 'merge' ? `Kite 正在把这个子工作区合回父工作区。把父工作区的最新状态合进 ${branch} 时这些文件冲突了：`
    : `Kite 正在${action === 'adopt' ? '把工作区的改动集成进主线' : '把主线的新改动同步进工作区'}。把主线（本机或远程）合进 ${branch} 时这些文件冲突了：`;
  return [head, ...files.map((f) => `- ${f}`), '',
    '请直接编辑这些文件解决冲突，保留双方意图，并删除全部冲突标记；需要删除的文件直接删除。',
    `本回合正常结束后，Kite 会提交合并并继续${mergingTitle[action]}。`].join('\n');
}

/** 提交 PR 时的远程分支名：按工作区名称取英文字母与数字，取不出来时用工作区 ID 的前 8 位。 */
function proposalBranch(name: string, id: string): string {
  const slug = name.normalize('NFKD').toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 48).replace(/-+$/, '');
  return `kite/${slug || id.slice(0, 8)}`;
}

/** 不能自动开 PR 的平台：去网页上开 PR 的地址。 */
function proposalPage(remote: string, base: string, branch: string): string {
  const site = `https://${remote}`;
  if (remote.startsWith('gitlab.')) return `${site}/-/merge_requests/new?merge_request[source_branch]=${encodeURIComponent(branch)}&merge_request[target_branch]=${encodeURIComponent(base)}`;
  const path = (ref: string) => ref.split('/').map(encodeURIComponent).join('/');
  return `${site}/compare/${path(base)}...${path(branch)}?expand=1`;
}

/** 确认恢复：后端核对交接后把阻塞解开。 */
async function recoverRuntime(r: Runtime): Promise<void> {
  if (!r.recover) throw new KiteError('这个后端不支持恢复确认', 409);
  await r.recover();
}

export class Kite {
  readonly events = new TranscriptFeed();
  readonly subscriptionLogins: SubscriptionLogins;
  readonly modelAccounts: ModelAccounts;
  readonly operations: InstanceOperations;
  readonly receipts: OperationReceipts;
  readonly catalog: PluginCatalog;
  readonly contextTemplates: ContextTemplates;
  readonly roles: Roles;
  /** 账号级数据（资源库、项目登记与约束、凭据、各工作机的目录摘要），在工作机之间同步，见 docs/分布式架构.md。 */
  readonly accountData: AccountData;
  readonly registry: ProjectRegistry;
  readonly credentials: Credentials;
  readonly directory: Directory;
  readonly replication: Replication;
  /** 自动更新：发布本机手动装上的版本，跟进别处发布的版本，见 docs/macOS安装与打包.md「自动更新」。 */
  readonly updates: Updates;
  /** 其他工作机持有的工作区，在本机跟进的副本。 */
  readonly replicas: Replicas;
  readonly github: GitHubBinding;
  /** Git 访问凭据：按远程所在的主机用绑定的凭据。 */
  readonly git: GitCredentials;
  readonly library: LibrarySync;
  readonly plugins: PluginHost;
  readonly lightTasks?: LightTasks;
  readonly titles?: ThreadTitles;
  readonly workspaceNames: WorkspaceNames;
  readonly emblems: TemplateEmblems;
  readonly tokenCounts: TokenCounter;
  readonly voice: VoiceSessions;
  readonly waits: Waits;
  readonly asks: Asks;
  /** 正在处理回应的请求（存密钥途中），同一项的第二次回应按对不上拒绝。 */
  private answering = new Set<string>();
  readonly transfers: WorkspaceTransfers;
  /** Line 调用同账号的工作机。 */
  readonly peers: Peers;
  /** Line 的 monitor；daemon 服务起来后启动。 */
  readonly monitor: LineMonitor;
  readonly reports: AgentReports;
  /** 正在关注 Kite 的设备；Line 所在的工作机据此决定通知与收件箱。 */
  readonly attention: Attention;
  /** 代理用 monitor_start 开的 monitor；Line 的那个由 monitor（LineMonitor）负责。 */
  readonly monitors: Monitors;
  readonly terminals: Terminals;
  /** 最近一条输入是 Line 自己说明的线程；只在内存里，重启后按用户的工作对待。 */
  private lineWork = new Set<string>();
  /** 服务起来后才知道本机监听地址与组网，Line 调本机和别的工作机时用。 */
  private serving?: { url: string; network?: Network };
  private readonly transcripts: TranscriptHistory;
  private readonly configuration: InstanceConfiguration;
  private readonly instances: InstanceLifecycle;
  private readonly checkoutManagement: CheckoutManagement;
  private runners = new Map<string, Runtime>();
  private openingRunners = new Map<string, Promise<Runtime>>();
  private queues = new Map<string, Promise<unknown>>();
  private preparations = new Map<string, AbortController>();
  private stopping = false;
  /** 正在跑 shell 命令的线程：用户发来消息时通知它们，命令转到后台，好让消息送到模型。 */
  private interjections = new Map<string, Set<() => void>>();
  private turnLabels = new Map<string, string>();
  /**
   * 采纳冲突转交的线程，按工作区。处理回合期间工作区停在合并中途，同一工作区的其他线程不能开始工作；
   * 回合正常结束后宿主接着采纳，见 docs/工作区并行.md。initiator 是发起子工作区合回的代理，接着合完把结果交给它。
   */
  private resolving = new Map<string, { threadId: string; action: Merging; initiator?: string }>();
  /** 设了路径的项目密钥（凭据 ID → 项目与路径）：哪些文件要写进哪个项目的工作区，变化时据此删掉旧路径上的文件。 */
  private secretPaths = new Map<string, { projectId: string; path: string }>();
  /** 攒着还没处理的凭据变化，见 secretsChanged。 */
  private changedSecrets = new Set<string>();
  private leaseSync?: Promise<void>;
  /** 含锁外网络操作的项目任务，关闭时仍需等待它们完成登记。 */
  private projectOperations = new Set<Promise<unknown>>();
  private projectSync?: Timer;
  /** 正在启用的 Line：两次启用请求不建出两个。 */
  private enablingLine?: Promise<WorkspaceModel>;
  /** 有预告的离开时交出、还没确认交出去的工作区；醒来或登出被取消时还在本机的撤回交接。 */
  private leavingIds = new Set<string>();

  constructor(readonly store: Store, readonly home: string, readonly bus: Bus, private options: RuntimeOptions = {}) {
    this.accountData = new AccountData(join(home, 'account.db'), store.machine.id,
      options.keychain ? keychainKey(store.machine.id) : fileKey(join(home, 'credentials.key')));
    this.registry = new ProjectRegistry(this.accountData);
    this.credentials = new Credentials(this.accountData, { projectExists: (id) => !!this.registry.get(id),
      canonicalProject: (id) => this.registry.canonical(id) });
    this.git = {
      credential: async (url) => {
        const remote = normalizeRemote(url);
        return remote ? this.credentials.git(remoteHost(remote)) : null;
      },
    };
    this.github = new GitHubBinding((login, token) => this.credentials.saveGit('github.com', login, token),
      async () => (await this.credentials.git('github.com'))?.password);
    this.directory = new Directory({
      data: this.accountData, self: () => store.machine, build: () => this.updates.version.build, address: () => this.serving?.network?.status().address,
      snapshot: () => {
        const line = this.lineInstance()?.workspaceId;
        return { machine: store.machine, projects: store.projects(), checkouts: store.checkouts(), workspaces: store.workspaces(), ...(line ? { line } : {}) };
      },
      candidates: () => options.directory?.candidates() ?? this.tailnetPeers(),
      fetch: (address, path, init) => this.peerFetch(address, path, init),
      changed: () => { this.replication.sync(); this.updates.evaluate(); },
      ...(options.catalogDelayMs !== undefined ? { publishDelayMs: options.catalogDelayMs } : {}),
    });
    this.replication = new Replication({ data: this.accountData, directory: this.directory, fetch: (address, path, init) => this.peerFetch(address, path, init) });
    this.updates = new Updates({ data: this.accountData, machineId: store.machine.id, peers: () => this.directory.reachable(),
      fetch: (address, path, init) => this.peerFetch(address, path, init), busy: () => this.busy(),
      changed: () => bus.emit({ type: 'update.changed' }) }, options.install);
    // 回合结束、终端退出、工作区准备好或流转完、项目操作结束都会经这几种事件：新版在等空闲时据此马上再看。
    bus.subscribe((event) => ['idle', 'workspace.changed', 'thread.changed', 'checkout.changed'].includes(event.type), () => this.updates.nudge());
    // 摘要标着 Line 在哪个工作区，Line 的线程建好或归档时也要重写。
    const lineThread = (id: string) => { const t = store.instance(id); return !!t && instanceRole(t)?.id === lineRoleId; };
    bus.subscribe((event) => event.type === 'checkout.changed' || event.type === 'workspace.changed'
      || event.type === 'thread.changed' && lineThread(event.threadId), () => this.directory.schedule());
    this.accountData.subscribe((changed) => {
      if (!changed.some((entry) => entry.kind === 'project')) return;
      this.registry.reconcile();
      // 登记表变了只对一遍本机记录，不拉取主线：拉取留给定时的项目同步。
      this.projectSync ??= setTimeout(() => { this.projectSync = undefined; void this.syncProjects({ fetch: false }); }, 500);
    });
    this.checkoutManagement = new CheckoutManagement(store, home, { registry: this.registry, git: this.git, github: this.github,
      peers: (projectId) => this.projectPeers(projectId),
      saveEnvFiles: async (projectId, files) => { for (const file of files) await this.credentials.saveFileSecret(projectId, file.path, file.value); },
      discard: (projectId) => this.forgetProject(projectId),
    }, bus, (key, action) => this.serial(key, action));
    this.secretPaths = this.credentials.secretPaths();
    this.accountData.subscribe((changed) => {
      const ids = changed.filter((entry) => entry.kind === 'credential').map((entry) => entry.id);
      if (!ids.length) return;
      // 一次操作常连着写好几条凭据（删除项目、导入几个环境变量文件），攒到这一轮事件循环结束再一起处理。
      if (!this.changedSecrets.size) setTimeout(() => void this.secretsChanged(), 0);
      for (const id of ids) this.changedSecrets.add(id);
    });
    this.subscriptionLogins = new SubscriptionLogins(home);
    this.modelAccounts = new ModelAccounts(home, (modelAccounts) => bus.emit({ type: 'model-accounts.changed', modelAccounts }),
      (home) => readModelAccounts(home, { usage: store, apiKeys: () => this.credentials.apiKeys() }));
    this.catalog = new PluginCatalog(join(home, 'plugins'));
    this.roles = new Roles(store);
    this.contextTemplates = new ContextTemplates(store, [
      titleTemplate, workspaceNameTemplate, compactTemplate, emblemTemplate, pullRequestTemplate, commitMessageTemplate,
      agentConfigurationContextDefinition, contextUpdateContextDefinition, executionPermissionsContextDefinition, fileChangesContextDefinition,
      pluginToolsContextDefinition, voiceTemplate, lineMonitorContextDefinition, monitorEventsContextDefinition, terminalExitContextDefinition,
      agentReportContextDefinition, agentWorkspaceContextDefinition,
    ]);
    this.library = new LibrarySync({ data: this.accountData, registry: this.registry, store, roles: this.roles, templates: this.contextTemplates,
      catalog: this.catalog, changed: (changes) => this.libraryChanged(changes) });
    this.receipts = new OperationReceipts(store);
    this.operations = new InstanceOperations(this);
    this.waits = new Waits((threadId, waiting) => bus.emit({ type: 'waiting', threadId, ...(waiting ? { waiting } : {}) }));
    this.asks = new Asks(store, (threadId, asks) => bus.emit({ type: 'asks', threadId, asks }));
    this.plugins = new PluginHost(this);
    this.peers = new Peers({ self: () => ({ id: store.machine.id, name: store.machine.name, url: this.serving?.url }),
      machines: options.peers?.directory ?? (async () => this.directory.list()),
      fetch: (address, path, init) => this.peerFetch(address, path, init) });
    this.reports = new AgentReports({
      template: (scene) => this.contextTemplates.get({ 'agent.report': agentReportContextDefinition, 'agent.workspace': agentWorkspaceContextDefinition }[scene].id,
        scene).definition,
      variables: (threadId) => storedThreadVariables(store, threadId),
      open: (instanceId) => store.instance(instanceId)?.status === 'open',
      title: (instanceId) => store.instance(instanceId)?.title ?? instanceId,
      reply: async (threadId) => (await this.reply(threadId)).reply?.text,
      asking: (threadId) => store.asks(threadId).length > 0,
      deliver: (threadId, text, inputId, notice) => this.send(threadId, text, inputId, { source: 'kite', notice }),
      notify: (threadId, notification) => store.addInstanceNotification(threadId, notification),
    });
    this.monitor = new LineMonitor({ store, peers: this.peers,
      line: () => this.lineInstance(), inbox: () => this.lineInbox(true), deliver: (threadId, text, inputId, notice) => this.send(threadId, text, inputId, { source: 'kite', notice }),
      template: () => this.contextTemplates.get(lineMonitorContextDefinition.id, 'line.monitor').definition,
      variables: (threadId) => storedThreadVariables(store, threadId),
      focused: () => this.attention.devices().length > 0,
      notify: (notification) => bus.emit({ type: 'line.notification', notification }),
      changed: () => bus.emit({ type: 'line.inbox' }) });
    this.attention = new Attention((devices) => this.monitor.attention(devices.length > 0));
    // 本机的等待与回合变化很快读一轮，远程工作机靠定时读取。
    bus.subscribe((event) => event.type === 'waiting' || event.type === 'asks' || event.type === 'idle', () => this.monitor.nudge());
    this.monitors = new Monitors({ store, home, env: commandEnvironment(process.env),
      policy: async (target) => {
        const { workspace, checkout } = this.workspace(target.workspaceId);
        return agentPolicy(await harnessPolicy({ cwd: workspace.cwd, env: process.env, home, repository: checkout.path }), workspace.cwd,
          instanceExecutionChanges(target), store.workspaceConstraints(target.workspaceId)?.execution, this.secretFiles(checkout.projectId));
      },
      deliver: (threadId, text, inputId, notice) => this.send(threadId, text, inputId, { source: 'kite', notice }),
      template: () => this.contextTemplates.get(monitorEventsContextDefinition.id, 'monitor.events').definition,
      variables: (threadId) => storedThreadVariables(store, threadId),
      run: (workspaceId, action) => this.control(workspaceId, action),
      changed: (workspaceId) => this.changed(workspaceId),
      updated: (workspaceId, instanceId) => bus.emit({ type: 'monitor.changed', workspaceId, instanceId }),
      ...(options.monitorWakeDelayMs !== undefined ? { wakeDelayMs: options.monitorWakeDelayMs } : {}) });
    // 工作区开放、交接、冻结、归档与代理归档都会改变 monitor 能不能运行。
    bus.subscribe((event) => event.type === 'workspace.changed' || event.type === 'thread.changed', () => this.monitors.soon());
    this.replicas = new Replicas(new ReplicaStore(join(home, 'replicas')), {
      holders: () => this.directory.online(),
      held: (id) => { const w = store.workspace(id); return w && holds(w) ? w.epoch : undefined; },
      checkout: (projectId) => store.checkouts(projectId)[0]?.path,
      fetch: (address, path, init) => this.peerFetch(address, path, init),
      fetchRefs: (cwd, holder, projectId, specs) => fetchPeerRefs(cwd, holder, projectId, this.peerRoute(), specs),
    });
    this.transfers = new WorkspaceTransfers({
      store, home, git: this.git, replicas: this.replicas,
      online: (machine) => this.directory.online().find((entry) => entry.id === machine),
      elsewhere: (workspaceId) => this.directory.copies(workspaceId),
      call: (machine, method, path, body) => this.peers.call(machine, method, path, { body, timeoutMs: 60_000 }),
      control: (id, action) => this.control(id, action),
      workspace: (id) => this.workspace(id),
      threadState: (id) => this.threadState(id),
      stopThread: (thread) => this.stopThread(thread),
      closePlugins: (id) => this.closeExtensions(id),
      snapshot: (workspace, label) => this.snapshot(workspace, [], label),
      setStatus: (id, status) => this.setWorkspaceStatus(id, status),
      changed: (id) => this.changed(id),
      removed: (id) => bus.emit({ type: 'workspace.changed', workspaceId: id, status: 'archived' }),
      recordsReplaced: (ids) => this.transcripts.forget(ids),
      environment: (projectId) => this.environment(projectId),
      ensureCheckout: async (projectId) => (await this.ensureCheckout(projectId)).checkout,
      setUpWorktree: (id, checkout, cwd) => this.setUpWorktree(id, checkout, cwd),
      freeze: (id, handingOff) => this.freeze(id, handingOff),
    });
    this.configuration = new InstanceConfiguration(this, {
      run: (workspaceId, action) => this.control(workspaceId, action),
      context: (id) => this.context(id), openThread: (id) => this.openThread(id),
      runtime: (thread) => this.runnerForManagement(thread),
      switchRuntime: (id, agent, commit) => this.switchRuntime(id, agent, commit),
      changed: (workspaceId) => this.changed(workspaceId),
    });
    this.instances = new InstanceLifecycle(this, {
      run: (workspaceId, action) => this.control(workspaceId, action),
      changed: (workspaceId) => this.changed(workspaceId),
      revokeGrants: (instance) => this.configuration.revokeInstanceGrants(instance),
    });
    this.terminals = new Terminals({ store, home, env: process.env,
      run: (workspaceId, action) => this.control(workspaceId, action),
      changed: (workspaceId) => this.changed(workspaceId),
      collect: (instance) => this.instances.collect(instance),
      deliver: (threadId, text, inputId, notice) => this.send(threadId, text, inputId, { source: 'kite', notice }),
      template: () => this.contextTemplates.get(terminalExitContextDefinition.id, 'terminal.exit').definition,
      variables: (threadId) => storedThreadVariables(store, threadId),
      forward: (ports) => this.serving?.network?.forward(ports),
      ...(options.terminalShell ? { shell: options.terminalShell } : {}),
      ...(options.terminalPortScanMs !== undefined ? { portScanMs: options.terminalPortScanMs } : {}) });
    this.tokenCounts = new TokenCounter({ apiKeys: () => this.credentials.apiKeys() });
    this.voice = new VoiceSessions({
      keys: () => this.credentials.speechKeys(),
      template: () => this.contextTemplates.get(voiceTemplate.id, voiceTemplate.scene),
      history: (id) => this.history(id),
      variables: () => environmentVariables(store.machine),
    });
    if (options.lightTasks !== false && process.env.KITE_LIGHT_TASKS !== '0') {
      const light = options.lightTasks;
      this.lightTasks = new LightTasks({
        model: light?.model ?? (({ id, model }) => new ChatGPTModel({
          model: model.model, reasoning: model.reasoning, threadId: id,
          credentials: () => readSubscriptionCredentials(join(home, 'auth', 'chatgpt', 'auth.json')),
          observeLimits: (headers) => this.modelAccounts.observeChatGPT(headers),
        })),
        timeoutMs: light?.timeoutMs,
        onResult: light?.onResult ?? (({ usage, ...result }) => console.info('[轻任务]', JSON.stringify({
          ...result, ...(usage ? { usage: { inputTokens: usage.input_tokens, outputTokens: usage.output_tokens,
            totalTokens: usage.total_tokens } } : {}),
        }))),
      });
      this.titles = new ThreadTitles(store, this.lightTasks, this.contextTemplates, {
        history: (id) => this.history(id), changed: (thread) => this.threadChanged(thread),
        renamed: (id) => this.workspaceNames.follow(id),
      });
    }
    this.workspaceNames = new WorkspaceNames(store, this.lightTasks, this.contextTemplates, (id) => this.changed(id));
    this.emblems = new TemplateEmblems(store, this.roles, this.contextTemplates, this.lightTasks,
      () => bus.emit({ type: 'roles.changed' }), (id, emblem) => this.library.write('emblem', id, emblem));
    for (const w of store.workspaces()) if (w.status === 'preparing') store.setWorkspaceStatus(w.id, 'failed');
    this.transcripts = new TranscriptHistory(store, home, bus, this.events);
    this.terminals.recover();
  }

  machine(): Machine { return this.store.machine; }
  /**
   * 资源库的写入先进账号级数据（见 LibrarySync.save），再存本机缓存。期望的版本按本机缓存给出，缓存里没有就是账号级数据里也没有。
   */
  async updateContextTemplate(id: string, expectedRevision: string, template: unknown) {
    const valid = this.contextTemplates.validate(id, expectedRevision, template);
    this.library.save('template', id, valid, this.contextTemplates.accountRevision(id), this.contextTemplates.isDefault(valid));
    const saved = this.contextTemplates.update(expectedRevision, valid);
    this.bus.emit({ type: 'context-templates.changed' });
    return saved;
  }
  /** 恢复默认就是保存默认内容。 */
  resetContextTemplate(id: string, expectedRevision: string) {
    return this.updateContextTemplate(id, expectedRevision, this.contextTemplates.builtin(id));
  }
  /**
   * 角色列表带上点阵签名状态，以及角色编辑器要用的代理插件全部工具（连同界面名称与分组）、提示词变量和模型目录；
   * defaultApproval 是角色没给审批模式时新建代理用的，App 的角色编辑器与新代理草稿据此显示。
   */
  roleCatalog() {
    return { roles: this.roles.list().map((role) => this.emblems.decorate(role)), tools: agentTools, toolCatalog: agentToolCatalog,
      variables: this.contextTemplates.sceneVariables('thread.create'), ...agentModelCatalog(), defaultApproval: defaultApprovalMode };
  }
  async createRole(value: unknown) {
    const role = this.roles.validateNew(value);
    this.library.write('role', role.id, role, null);
    return this.roleSaved(this.roles.create(role));
  }
  async updateRole(id: string, expectedRevision: string, value: unknown) {
    const role = this.roles.validate(id, expectedRevision, value);
    this.library.save('role', id, role, this.roles.accountRevision(id), this.roles.isDefault(role));
    return this.roleSaved(this.roles.update(expectedRevision, role));
  }
  /** 只有内置角色能恢复默认；签名照常随提示词更新，手改过的保留。 */
  resetRole(id: string, expectedRevision: string) {
    return this.updateRole(id, expectedRevision, this.roles.builtin(id));
  }
  /** 插件包先存进账号资源库，再装到本机；其他工作机同步到后用到时再装。 */
  async installPlugin(raw: unknown) {
    const value = this.catalog.validate(raw);
    this.library.write('plugin', value.id, value, null);
    return this.catalog.install(value);
  }
  private libraryChanged(changes: LibraryChanges) {
    if (changes.roles) this.bus.emit({ type: 'roles.changed' });
    if (changes.templates) this.bus.emit({ type: 'context-templates.changed' });
    for (const { projectId, before } of changes.constraints) this.configuration.constraintsChanged(projectId, before);
  }
  /** 角色保存后通知各端刷新，并随提示词更新点阵签名。 */
  private roleSaved(saved: RoleSnapshot) {
    this.bus.emit({ type: 'roles.changed' });
    this.emblems.roleSaved(saved);
    return this.emblems.decorate(saved);
  }
  projects(): Project[] { return this.store.projects(); }
  checkouts(projectId?: string): Checkout[] { return this.store.checkouts(projectId); }
  /** 添加项目前的检查，不写任何东西：远程能不能访问、集成方式的默认值、文件夹里被忽略的环境变量文件。 */
  checkProject(source: ProjectSource) {
    return this.projectOperation(() => this.checkoutManagement.check(source));
  }
  /** 添加项目。没有远程的文件夹在本机导入成检出，导入在登记锁外，停机时仍要等它完成登记。 */
  addProject(source: ProjectSource, options: { integration?: Integration; envFiles?: EnvFile[] } = {}) {
    return this.projectOperation(() => this.checkoutManagement.add(source, options));
  }
  /** fetch 为 false 时只按登记表对齐本机记录，不拉取主线、不刷新工作区（登记表一变就做的那种）。 */
  syncProjects(options: { fetch?: boolean } = {}): Promise<void> {
    if (this.stopping) return Promise.resolve();
    const fetch = options.fetch ?? true;
    // 并入别的项目后本机的约束缓存挂到保留的项目上，按登记表重对一遍，有变化时通知正在运行的实例。
    return this.projectOperation(async () => {
      if (await this.checkoutManagement.syncProjects(fetch ? (checkout, main) => this.refreshWorkspaces(checkout, main) : undefined)) this.library.refresh();
      for (const project of this.store.projects()) if (this.registry.deleted(project.id)) await this.removeLocalProject(project.id);
    });
  }
  /** 检出拉取了主线之后：更新它的工作区落后主线（main）的提交数，查询提交 PR 的工作区的 PR 状态。 */
  private async refreshWorkspaces(checkout: Checkout, main: Mainline): Promise<void> {
    const remote = this.store.project(checkout.projectId)?.remote;
    const repo = remote ? gitHubRepo(remote) : undefined;
    const open = this.store.workspaces().filter((w) => w.checkoutId === checkout.id && (w.status === 'open' || w.status === 'failed'));
    await Promise.all(open.map(async (w) => {
      try {
        let changed = this.store.setWorkspaceBehind(w.id, await behindCount(w.cwd, main));
        if (repo && w.pullRequest?.state === 'open' && w.pullRequest.number !== undefined) {
          const state = await this.github.pullRequestState(repo.owner, repo.repo, w.pullRequest.number);
          // 查询期间工作区可能又集成过一次：只在记录还是查的那一份时改状态。
          const now = this.store.workspace(w.id)?.pullRequest;
          if (state && now && state !== now.state && now.number === w.pullRequest.number && now.commit === w.pullRequest.commit) {
            this.store.setWorkspacePullRequest(w.id, { ...now, state });
            changed = true;
          }
        }
        if (changed) this.changed(w.id);
      } catch (error) { console.warn(`[项目同步] 工作区 ${w.name}：${(error as Error).message}`); }
    }));
  }
  /**
   * 删除项目：从登记表删掉，项目专用的密钥一起删；本机先移除这个项目的工作区与 Kite 的检出再返回，其他工作机同步到删除后各自移除。
   * 用户自己的文件夹不受影响。Line 所在的项目不能删。
   */
  async deleteProject(id: string): Promise<void> {
    this.assertRunning();
    const line = this.lineInstance();
    if (line && this.workspace(line.workspaceId).project.id === id) throw new KiteError('Line 所在的项目不能删除', 409);
    this.registry.require(id);
    this.forgetProject(id);
    // 只移除本机这一个项目，不等别的项目拉取主线。
    await this.projectOperation(() => this.removeLocalProject(id));
  }
  /** 从登记表删掉项目（已经删了的不管），连同它专用的密钥。 */
  private forgetProject(id: string): void {
    this.credentials.deleteProject(id);
    if (this.registry.get(id)) this.registry.remove(id);
  }
  /**
   * 登记表删掉了项目：停下本机这个项目的线程与插件，回收工作树，工作区的记录与会话文件删掉，
   * 最后删掉 Kite 的检出（裸仓库）与项目记录。
   */
  private removeLocalProject(projectId: string): Promise<void> {
    return this.serial('register', async () => {
      if (!this.store.project(projectId)) return;
      for (const w of this.store.workspaces(projectId)) {
        this.preparations.get(w.id)?.abort();
        await this.control(w.id, async () => {
          const checkout = this.store.checkout(w.checkoutId)!;
          const threads = this.store.threads(w.id);
          for (const t of threads) if (t.status !== 'archived') await this.stopThread(t);
          const release = await this.closeExtensions(w.id);
          try {
            if (existsSync(w.cwd)) await removeWorktree(checkout.path, w.cwd, w.branch);
            this.store.deleteWorkspaceRows(w.id);
          } finally { release(); }
          for (const path of [...threads.map((t) => join(this.home, 'sessions', t.id)), join(this.home, 'diffs', w.id), join(this.home, 'workspaces', w.id)]) {
            rmSync(path, { recursive: true, force: true });
          }
          this.transcripts.forget(threads.map((t) => t.id));
          this.bus.emit({ type: 'workspace.changed', workspaceId: w.id, status: 'archived' });
        });
      }
      const checkouts = this.store.checkouts(projectId);
      this.store.removeProject(projectId);
      rmSync(join(this.home, 'worktrees', projectId), { recursive: true, force: true });
      for (const c of checkouts) {
        rmSync(c.path, { recursive: true, force: true });
        this.bus.emit({ type: 'checkout.changed', projectId, checkoutId: c.id });
      }
    });
  }
  /** 给没有远程的项目设远程：用本机检出把全部分支和标签推上去，再写进登记表；各工作机的检出随项目同步改用它。 */
  setProjectRemote(projectId: string, remote: string) {
    return this.projectOperation(() => this.checkoutManagement.setRemote(projectId, remote));
  }

  /** 并发修改时被覆盖的版本，按发生先后，最近的在前；凭据只给公开信息。 */
  conflicts() {
    return this.accountData.list('conflict').map(({ body }) => {
      const { kind, id, at, by, body: value } = body as { kind: string; id: string; at: number; by: string; body: Record<string, unknown> };
      const { sealed: _, ...shown } = value;
      return { kind, id, at, by, body: shown };
    }).sort((a, b) => b.at - a.at);
  }
  /** 别的工作机拉取本机检出（没有远程的项目）。 */
  serveCheckout(request: Request, projectId: string, rest: string): Promise<Response> {
    const checkout = this.store.checkouts(projectId)[0];
    if (!checkout) throw new KiteError('这台工作机没有这个项目的检出', 404);
    return serveCheckout(request, checkout.path, rest);
  }

  /**
   * 还原流转来的工作区（见 WorkspaceTransfers.restore）。continue 是源机有预告地离开时打断的线程及收回的排队输入：
   * 接管后先补一条说明让它接着做被打断的回合，再把排队的输入按原来的正文、来源与经由重发。
   */
  async restoreWorkspace(projectId: string | undefined, workspaceId: string, options: { from?: string; force?: boolean;
    continue?: Array<{ threadId: string; inputs: Input[] }> } = {}): Promise<WorkspaceModel> {
    // 没给项目时从本机手上的副本里取（强制接管时源机已不在线）。
    const project = projectId ?? this.replicas.store.state(workspaceId)?.projectId;
    if (!project) throw new KiteError('这台工作机上没有这个工作区的副本，要写 project', 404);
    const model = await this.transfers.restore(project, workspaceId, options);
    for (const item of options.continue ?? []) await this.continueThread(item);
    // 强制接管整组接管：本机手上有副本的子工作区跟着接管（正常流转由源机逐个交）。没接成的报给父工作区，不算这次失败。
    if (options.force) {
      for (const child of this.replicaChildren(workspaceId)) {
        await this.restoreWorkspace(project, child.id, { force: true }).catch((error: Error) => this.bus.emit({ type: 'workspace.error', workspaceId,
          message: `子工作区「${child.name}」没接管过来：${error.message}` }));
      }
    }
    return model;
  }
  /** 本机手上完整的副本里，挂在这个工作区下面的子工作区。 */
  private replicaChildren(id: string): Array<{ id: string; name: string }> {
    const store = this.replicas.store;
    return store.ids().flatMap((other) => {
      if (!store.state(other)?.complete) return [];
      try {
        const manifest = readManifest(store.dir(other));
        return manifest.parentId === id ? [{ id: other, name: manifest.name }] : [];
      } catch { return []; }
    });
  }
  private async continueThread({ threadId, inputs }: { threadId: string; inputs: Input[] }): Promise<void> {
    try {
      await this.send(threadId, CONTINUE_AFTER_MOVE, randomUUID(), { source: 'kite', notice: { kind: 'moved', title: '换到了这台工作机，接着刚才的工作' } });
      // 收回的输入已记在线程里（收到后又被打断收回），原 id 会被当成重复；正文与来源照旧，换新 id 重发。
      for (const { id: _, text, ...origin } of inputs) await this.send(threadId, text, randomUUID(), origin);
    } catch (error) { console.error(`[换机] 线程 ${threadId} 没能接着做：${(error as Error).message}`); }
  }

  /**
   * 把本机持有的工作区流转到 target（App 与 Line 的手动流转、有预告的离开都走这里）：进入可交接状态，目标补齐副本、装好后接过执行权，
   * 本机随即核对、冻结。没成就撤回交接，留在本机；目标其实已接管时撤回会冻结本地记录，照成功算。continue 见 restoreWorkspace。
   * 子工作区随父工作区整组流转，先交出整组，再从父工作区起逐个交给目标；见 docs/Line与工作区流转.md「工作区流转」。
   * 父工作区已不在本机的子工作区（整组流转中途没交出去的）可以单独再流转。
   */
  async transferWorkspace(id: string, target: string, options: TransferOptions = {}): Promise<{ workspaceId: string; machine: string; epoch: number }> {
    if (target === this.store.machine.id) throw new KiteError('工作区已经在这台工作机上', 409);
    const { workspace: root } = this.workspace(id);
    if (this.heldParent(root)) throw new KiteError('子工作区随父工作区一起流转，不能单独流转', 409);
    const group = [root, ...this.store.descendantWorkspaces(id)];
    let epoch = root.epoch;
    const handed: Workspace[] = [];
    for (const member of group) {
      try {
        const r = await this.transfers.handover(member.id);
        if (member === root) epoch = r.epoch;
        handed.push(member);
      } catch (error) {
        for (const done of handed) await this.transfers.cancel(done.id).catch(() => {});
        throw member === root ? error : new KiteError(`子工作区「${member.name}」：${(error as Error).message}`, 409);
      }
    }
    // 整组共用一个时限，后面的成员只用剩下的时间（有预告的离开要在睡眠或关机前交完）。
    const until = Date.now() + (options.timeoutMs ?? 30 * 60_000);
    for (const [index, member] of group.entries()) {
      try {
        await this.handTo(member, target, { ...options, timeoutMs: Math.max(1_000, until - Date.now()), operationId: index ? randomUUID() : options.operationId });
      }
      catch (error) {
        for (const rest of group.slice(index + 1)) await this.transfers.cancel(rest.id).catch(() => {});
        if (!index) throw error;
        throw new KiteError(`「${root.name}」已经流转，子工作区「${member.name}」没交出去，和后面的一起留在本机：${(error as Error).message}；可以再单独流转它们`, 409);
      }
    }
    return { workspaceId: id, machine: target, epoch: epoch + 1 };
  }
  /** 把已交出的一个工作区交给目标；没成就撤回，目标其实已接管时照成功算。 */
  private async handTo(w: Workspace, target: string, options: TransferOptions): Promise<void> {
    const { project } = this.workspace(w.id);
    const resumes = options.continue?.filter((item) => this.store.instance(item.threadId)?.workspaceId === w.id) ?? [];
    try {
      await this.peers.call(target, 'POST', '/workspaces/restore', {
        body: { project: project.id, workspaceId: w.id, operationId: options.operationId ?? randomUUID(), from: this.store.machine.id,
          ...(resumes.length ? { continue: resumes } : {}) },
        timeoutMs: options.timeoutMs ?? 30 * 60_000 });
    } catch (error) {
      try { if (this.store.workspace(w.id)?.status === 'handing_off') await this.transfers.cancel(w.id); }
      catch { /* 撤回不了的留在可交接状态，可以重试或再撤回。 */ }
      if (this.store.workspace(w.id)?.status !== 'transferred') throw error;
    }
    // 有远程的项目目标在 lease 上接管，本机下次核对才冻结；这里立即核对，失败不影响已完成的流转。
    await this.transfers.check(w.id).catch(() => {});
  }
  /** 父工作区也在本机（没流转走、没归档）的子工作区，随父工作区流转。 */
  private heldParent(w: Workspace): boolean {
    const parent = w.parentId ? this.store.workspace(w.parentId) : null;
    return !!parent && holds(parent);
  }

  /**
   * 有预告的离开（系统将要睡眠、登出、重启或关机）：把属于自动换机范围的工作区交给合适的目标——Line 的总是换；项目打开了自动换机的，只换正在工作的。
   * 正在工作的线程先打断、收回排队的输入，到了目标机接着做被打断的回合。在时限里能交多少交多少，交不出去的撤回，留在本机。
   * 见 docs/分布式架构.md「执行权」。
   */
  async leaving(deadline: number): Promise<void> {
    // 先按 Line 与项目设置挑，再看线程；没起过运行器的线程不可能正在工作，不为判断它去载入历史。子工作区随父工作区整组判断、整组换。
    const plans = this.store.workspaces().filter((w) => w.status === 'open' && !this.heldParent(w)).flatMap((w) => {
      const projectId = this.store.checkout(w.checkoutId)!.projectId;
      const line = this.isLineWorkspace(w.id);
      if (!line && this.registry.get(projectId)?.autoHandover !== true) return [];
      const threads = [w, ...this.store.descendantWorkspaces(w.id)].flatMap((member) => this.store.threads(member.id)).filter((t) => t.status !== 'archived');
      const busy = threads.filter((t) => this.runners.get(t.id)?.busy);
      return line || busy.length ? [{ workspace: w, projectId, busy, models: new Set(threads.map((t) => instanceAgent(t).model.model)) }] : [];
    });
    await Promise.all(plans.map((plan) => this.leave(plan, deadline)));
  }
  private async leave(plan: { workspace: Workspace; projectId: string; busy: AgentInstance[]; models: Set<string> }, deadline: number): Promise<void> {
    const { workspace: w, projectId } = plan;
    const target = await this.handoverTarget(projectId, plan.models, deadline);
    if (!target) { console.warn(`[换机] 工作区 ${w.name} 没有合适的工作机可交，留在本机`); return; }
    const resumes: Array<{ threadId: string; inputs: Input[] }> = [];
    for (const t of plan.busy) {
      try { resumes.push({ threadId: t.id, inputs: (await this.interrupt(t.id)).returned }); }
      catch (error) { console.warn(`[换机] 打断线程 ${t.id} 失败：${(error as Error).message}`); }
    }
    const group = [w.id, ...this.store.descendantWorkspaces(w.id).map((member) => member.id)];
    for (const id of group) this.leavingIds.add(id);
    try {
      await this.transferWorkspace(w.id, target, { continue: resumes, timeoutMs: Math.max(1_000, deadline - Date.now()) });
    } catch (error) {
      console.warn(`[换机] 工作区 ${w.name} 没交出去，留在本机：${(error as Error).message}`);
      for (const item of resumes) {
        const at = this.store.instance(item.threadId)?.workspaceId;
        if (at && this.store.workspace(at)?.status === 'open') await this.continueThread(item);
      }
    }
    // 还停在可交接状态的留给醒来时再核对。
    for (const id of group) if (this.store.workspace(id)?.status !== 'handing_off') this.leavingIds.delete(id);
  }
  /**
   * 合适的目标：在线、工作区所用的模型厂商已登录、满足项目声明的环境、磁盘够用。各台一起问，连不上或读不到的跳过；
   * 几台都合适时优先不带电池的，再优先已有这个项目检出的。
   */
  private async handoverTarget(projectId: string, models: Set<string>, deadline: number): Promise<string | undefined> {
    const needs: HandoverNeed[] = this.registry.get(projectId)?.handoverNeeds ?? [];
    const holders = this.directory.holders(projectId);
    const timeoutMs = Math.min(5_000, deadline - Date.now() - 2_000);
    if (timeoutMs <= 0) return undefined;
    const query = `/environment?project=${encodeURIComponent(projectId)}${needs.length ? `&needs=${needs.join(',')}` : ''}`;
    const fits = await Promise.all(this.directory.online().map(async (machine) => {
      try {
        const environment = await this.peers.call<Environment>(machine.id, 'GET', query, { timeoutMs });
        const fit = [...models].every((model) => modelLogin(environment, model).status === 'ready') && diskEnough(environment)
          && needs.every((need) => environment.needs?.[need] === true);
        return fit ? [{ id: machine.id, battery: environment.battery === true, holder: holders.has(machine.id) }] : [];
      } catch { return []; }
    }));
    return fits.flat().sort((a, b) => Number(a.battery) - Number(b.battery) || Number(b.holder) - Number(a.holder))[0]?.id;
  }
  /** 醒来或登出被取消：离开前没交出去、还停在可交接状态的，核对后撤回，在本机接着做。 */
  async returned(): Promise<void> {
    for (const id of [...this.leavingIds]) {
      this.leavingIds.delete(id);
      try {
        await this.transfers.check(id);
        if (this.store.workspace(id)?.status === 'handing_off') await this.transfers.cancel(id);
      } catch (error) { console.warn(`[换机] 醒来后核对工作区 ${id} 失败：${(error as Error).message}`); }
    }
  }

  /** 服务起来后开始发现其他工作机、同步账号级数据。 */
  startAccountData(): void {
    this.directory.start();
    this.library.start();
    this.replicas.start();
    this.updates.start();
  }
  /** 这台工作机还在忙的事项；自动更新等它们都结束才换版。 */
  private busy(): string[] {
    const turns = [...this.runners.values()].filter((runner) => runner.busy).length;
    const terminals = this.terminals.active();
    const handing = this.store.workspaces().filter((w) => w.status === 'handing_off').length;
    return [
      ...(turns ? [`${turns} 个回合正在进行`] : []),
      ...(terminals ? [`${terminals} 个终端或后台命令在运行`] : []),
      ...(this.preparations.size ? [`${this.preparations.size} 个工作区正在准备`] : []),
      ...(handing ? [`${handing} 个工作区正在流转`] : []),
      // 接收流转的还原、采纳、快照与文件写入都在工作区与检出的队列里。
      ...(this.queues.size ? [`${this.queues.size} 项工作区操作正在进行`] : []),
      ...(this.projectOperations.size ? ['项目操作正在进行'] : []),
    ];
  }
  /** 测试里替换了对端时，几台 kited 按本机地址直接互访，不经组网。 */
  private get direct(): boolean { return !!(this.options.peers || this.options.directory); }
  /** 别的工作机里在线、有这个项目检出的那几台，按目录里最近的摘要找；没有远程的项目从它们那里拉取。 */
  private projectPeers(projectId: string): { route: PeerRoute; peers: Peer[] } {
    const holders = this.directory.holders(projectId);
    return { route: this.peerRoute(), peers: this.directory.online().filter((machine) => holders.has(machine.id)) };
  }
  /** kite-net 的本机 HTTP 代理；组网没开或测试里直接访问时没有。 */
  private proxyAddress(): string | undefined {
    const port = this.direct ? undefined : this.serving?.network?.status().httpProxyPort;
    return port ? `http://127.0.0.1:${port}` : undefined;
  }
  /** git 访问别的工作机的方式。 */
  private peerRoute(): PeerRoute {
    const proxy = this.proxyAddress();
    return proxy ? { proxy } : {};
  }

  /** 各工作区副本摘要的短暂缓存：几台跟进方同一轮来问时只算一次。 */
  private replicaDigests = new Map<string, { at: number; digest: string }>();
  /** 本机持有的工作区（未流转走、未归档）与各自副本的摘要，供其他工作机跟进。 */
  replicaEntries(): ReplicaEntry[] {
    const now = Date.now();
    return this.store.workspaces().filter(holds).map((w) => {
      const checkout = this.store.checkout(w.checkoutId)!;
      let cached = this.replicaDigests.get(w.id);
      if (!cached || now - cached.at > 3_000) {
        cached = { at: now, digest: replicaDigest(w, this.store.exportWorkspaceRows(w.id), replicaSources(this.home, w, this.store.threads(w.id))) };
        this.replicaDigests.set(w.id, cached);
      }
      return { workspaceId: w.id, projectId: checkout.projectId, epoch: w.epoch, status: w.status, digest: cached.digest };
    });
  }
  /** 一页工作区副本：known 是跟进方手上的文件情况；数据库行、清单与 Git 的位置只在最后一页给。 */
  async replicaPage(id: string, known: Record<string, FileState>): Promise<ReplicaPage> {
    const { workspace: w, checkout } = this.workspace(id);
    if (!holds(w)) throw new KiteError('这台工作机不再持有这个工作区', 404);
    const threads = this.store.threads(id);
    const sources = replicaSources(this.home, w, threads);
    const files = replicaFiles(sources, known);
    if (files.more) return { epoch: w.epoch, ...files };
    const rows = this.store.exportWorkspaceRows(id);
    const [snapshots, branch] = await Promise.all([revParse(checkout.path, snapshotRef(id)), revParse(checkout.path, `refs/heads/${w.branch}`)]);
    return { epoch: w.epoch, ...files, digest: replicaDigest(w, rows, sources), rows, git: { snapshots, branch },
      manifest: replicaManifest({ home: this.home, machine: this.store.machine.id, projectId: checkout.projectId, workspace: w, threads }) };
  }
  /** 组网里同一用户的对端设备；组网没开时为 undefined。 */
  private tailnetPeers(): Candidate[] | undefined {
    const network = this.serving?.network;
    const status = network?.status();
    if (!network || status?.state !== 'Running') return undefined;
    return (status.peers ?? []).flatMap((peer) => peer.ip
      ? [{ address: `http://${peer.ip.includes(':') ? `[${peer.ip}]` : peer.ip}:${network.port}`, online: peer.online === true }] : []);
  }
  /** 访问别的工作机：经 kite-net 的本机代理；测试替换了对端时直接访问。 */
  private peerFetch(address: string, path: string, init: RequestInit = {}): Promise<Response> {
    const proxy = this.proxyAddress();
    if (!this.direct && !proxy) return Promise.reject(new KiteError('这台工作机没有开启组网', 409));
    return fetch(new URL(path, address), { ...init, ...(proxy ? { proxy } : {}) });
  }
  /** 客户端读取的工作区列表；载入过的代理附活动摘要，打开的工作区附顶层名字（见 rootNames）。 */
  workspaces(projectId?: string): Array<WorkspaceModel & { workspace: { rootNames?: string[] };
    threads: Array<WorkspaceModel['threads'][number] & { activity?: ThreadActivity }> }> {
    return this.store.workspaceModels(projectId).map((model) => {
      const rootNames = this.rootNames(model.workspace);
      return { ...model, workspace: rootNames ? { ...model.workspace, rootNames } : model.workspace,
        threads: model.threads.map((thread) => {
          const activity = this.transcripts.activity(thread.instanceId);
          return activity ? { ...thread, activity } : thread;
        }) };
    });
  }
  /** 客户端上次拿到的各工作区顶层名字，快照后据此判断要不要让它重读。 */
  private readonly sentRootNames = new Map<string, string>();
  /**
   * 工作区目录顶层的文件和目录名：App 据此认出消息里的路径从哪里开始（docs/资源引用.md）。
   * 只给打开的工作区，读不了时没有。
   */
  private rootNames(w: Workspace): string[] | undefined {
    if (w.status !== 'open') return undefined;
    let names: string[];
    try { names = readdirSync(w.cwd).sort(); }
    catch { return undefined; }
    this.sentRootNames.set(w.id, names.join('/'));
    return names;
  }
  /**
   * 这台工作机的状态汇总，供 Line 查询与 monitor 核对：未归档的工作区、其中线程的执行状态与等你回应的对象。
   * 线程状态从显示投影读，首次读取会载入历史，不启动执行。
   */
  async summary(): Promise<MachineSummary> {
    const workspaces = await Promise.all(this.store.workspaceModels().filter((model) => model.workspace.status !== 'archived').map(async (model) => {
      const threads = new Set(model.threads.map((thread) => thread.instanceId));
      return {
        id: model.workspace.id, epoch: model.workspace.epoch, status: model.workspace.status, name: model.workspace.name,
        project: { id: model.project.id, name: model.project.name },
        threads: await Promise.all(model.instances.filter((instance) => instance.status === 'open' && threads.has(instance.id)).map(async (instance) => {
          const state = await this.threadState(instance.id);
          const settledAt = this.transcripts.activity(instance.id)?.settledAt;
          return { id: instance.id, title: instance.title, role: (instanceRole(instance)?.id ?? null), phase: state.phase, busy: state.busy,
            waitingForResume: state.waitingForResume, ...(state.lastOutcome ? { lastOutcome: state.lastOutcome.kind } : {}),
            ...(state.lastOutcome?.kind === 'failed' ? { failure: state.lastOutcome.message } : {}),
            ...(state.recovery ? { recovery: state.recovery.message } : {}), ...(state.waiting ? { waiting: state.waiting } : {}),
            ...(state.asks?.length ? { asks: state.asks } : {}),
            ...(settledAt !== undefined ? { settledAt } : {}), ...(this.lineWork.has(instance.id) ? { byLine: true as const } : {}) };
        })),
      };
    }));
    return { machine: { id: this.store.machine.id, name: this.store.machine.name }, workspaces };
  }
  workspace(id: string): WorkspaceModel {
    const model = this.store.workspaceModel(id);
    if (!model) throw new KiteError(`没有这个工作区：${id}`, 404);
    return model;
  }
  private context(id: string): ThreadContext {
    const thread = this.store.threadContext(id);
    if (!thread) throw new KiteError(`没有这个线程：${id}`, 404);
    return thread;
  }
  thread(id: string): ThreadView {
    const r = this.runners.get(id);
    return { ...this.context(id), runner: r?.state ?? 'closed', busy: r?.busy ?? false };
  }
  private assertRunning(): void { if (this.stopping) throw new KiteError('kited 正在关闭', 503); }
  private openThread(id: string): ThreadContext {
    const t = this.context(id);
    if (t.status !== 'open' || t.workspace.status !== 'open') throw new KiteError('线程或工作区尚未打开，不能执行', 409);
    return t;
  }
  private changed(workspaceId: string): void {
    this.bus.emit({ type: 'workspace.changed', workspaceId, status: this.store.workspace(workspaceId)!.status });
  }
  private threadChanged(t: AgentInstance): void {
    this.bus.emit({ type: 'thread.changed', workspaceId: t.workspaceId, threadId: t.id, status: t.status });
  }
  private setWorkspaceStatus(id: string, status: WorkspaceStatus): void {
    this.store.setWorkspaceStatus(id, status);
    this.changed(id);
  }
  private serial<T>(key: string, fn: () => Promise<T>): Promise<T> {
    const next = (this.queues.get(key) ?? Promise.resolve()).then(fn, fn);
    const tail = next.catch(() => {}).finally(() => {
      // 后续任务可能已经接上队列，只移除仍由本任务占据的尾项。
      if (this.queues.get(key) === tail) this.queues.delete(key);
      this.updates.nudge();
    });
    this.queues.set(key, tail);
    return next;
  }
  private projectOperation<T>(fn: () => Promise<T>): Promise<T> {
    this.assertRunning();
    const pending = Promise.resolve().then(fn).finally(() => { this.projectOperations.delete(pending); this.updates.nudge(); });
    this.projectOperations.add(pending);
    return pending;
  }
  /** 文件操作和线程控制共用工作区锁；模型回合不持锁，忙闲由 runtime 明确报告。 */
  private control<T>(workspace: string, fn: () => Promise<T>): Promise<T> {
    this.assertRunning();
    return this.serial(`workspace:${workspace}`, async () => { this.assertRunning(); return fn(); });
  }
  private controlThread<T>(id: string, fn: () => Promise<T>): Promise<T> {
    return this.control(this.context(id).workspaceId, fn);
  }
  private newThread(workspaceId: string, prompt: string, choice: AgentChoice, projectId?: string): AgentInstance {
    const instance = this.instances.newInstance(workspaceId, agentDefinitionId, titleOf(prompt), choice, projectId);
    return { ...instance, instanceId: instance.id, runtime: instanceAgent(instance).runtime, nativeId: randomUUID() };
  }

  /** 在这台工作机为项目建工作区前的环境。needs 是要查的换机环境需求。 */
  async environment(projectId: string, needs: HandoverNeed[] = []): Promise<Environment> {
    const checkout = this.store.checkouts(projectId)[0];
    if (!checkout) this.registry.require(projectId);
    return readEnvironment(this.home, this.store.machine, checkout, needs, () => this.credentials.apiKeys());
  }

  /**
   * 在这台工作机上为项目建工作区：先检查环境，不满足就不建；本机没有检出时先 clone，检出保留。先拉取主线，从最新的主线开出工作树。
   * 可以先建空工作区；带首条消息时，准备完成才启动首个线程。via 是经 Line 创建：首条消息是 Line 的说明。
   * ids 由 App 生成：App 先按工作区、首个代理窗口和首条消息的 ID 在本机建好，目录和线程事件到了认得出是同一个。
   */
  async createWorkspace(projectId: string, prompt?: string, role?: RoleSelection, via?: InputVia,
    ids: NewWorkspaceIds = {}): Promise<WorkspaceModel> {
    this.assertRunning();
    if (prompt !== undefined && !prompt.trim()) throw new KiteError('第一条消息不能为空');
    if (ids.id && this.store.workspace(ids.id)) throw new KiteError('工作区 ID 已使用', 409);
    if (ids.windowId && this.store.window(ids.windowId)) throw new KiteError('窗口 ID 已使用', 409);
    this.assertCanRun(await this.environment(projectId), role);
    // 刚 clone 的检出已是最新的主线，不再拉一次。
    const { checkout: c, cloned } = await this.ensureCheckout(projectId);
    const base = await this.serial(`checkout:${c.id}`, async () => {
      if (!cloned) await this.checkoutManagement.refresh(c);
      return mainline(c);
    });
    this.assertRunning();
    const id = ids.id ?? randomUUID();
    const w = this.newWorkspace(c, id, prompt ? titleOf(prompt) : UNNAMED_WORKSPACE, base, null);
    const t = prompt === undefined ? undefined : this.newThread(id, prompt, { role }, c.projectId);
    this.store.addWorkspace(w, t ? { agent: t, window: this.instances.newWindow(t, ids.windowId) } : undefined);
    this.prepare(w, c, t && { thread: t, input: { id: ids.messageId ?? randomUUID(), text: prompt!,
      ...(via ? { source: 'agent' as const, from: via } : { source: 'human' as const }) } });
    this.changed(id);
    if (t) this.threadChanged(t);
    return this.workspace(id);
  }

  /** 新工作区的记录：工作树在 Kite 数据目录里，分支是 kite/<ID>，准备好之前是 preparing。 */
  private newWorkspace(c: Checkout, id: string, name: string, base: string, parentId: string | null): Workspace {
    return { id, epoch: 1, checkoutId: c.id, name, nameMode: 'auto', cwd: worktreePath(this.home, c.projectId, id), branch: `kite/${id}`, base,
      status: 'preparing', createdAt: Date.now(), behind: 0, pullRequest: null, parentId };
  }

  /** 建工作区前的环境检查：所选角色默认模型的厂商在这台工作机已登录，磁盘够用；不满足就不建。 */
  private assertCanRun(environment: Environment, role?: { id: string; revision?: string }): void {
    const model = this.roles.get(role?.id ?? defaultRoleId, role?.revision).role.model.model;
    const login = modelLogin(environment, model);
    if (login.status !== 'ready') throw new KiteError(`这台工作机不能运行所选模型：${login.message}`, 409);
    if (!diskEnough(environment)) throw new KiteError('这台工作机的磁盘剩余空间不足 1 GB', 409);
  }

  /** 本机该项目的检出；没有时 clone 到数据目录并登记，检出保留。cloned 表示这次刚 clone。 */
  private ensureCheckout(projectId: string): Promise<{ checkout: Checkout; cloned: boolean }> {
    return this.projectOperation(() => this.checkoutManagement.ensure(projectId));
  }

  /** 项目设了路径的密钥文件（相对路径），对代理只读。 */
  private secretFiles(projectId: string): string[] {
    return [...this.secretPaths.values()].filter((entry) => entry.projectId === projectId).map((entry) => entry.path);
  }

  /**
   * 把项目设了路径的密钥路径记进检出的 info/exclude；原来记着、现在没有的路径（密钥删了或换了路径）从本机这个项目的各工作树里删掉。
   * exclude 本身就是写过哪些文件的记录，上次没删完的（例如 kited 中途退出）这次照样删。
   */
  private excludeSecrets(projectId: string): void {
    const checkout = this.store.checkouts(projectId)[0];
    if (!checkout) return;
    const dropped = excludeSecretFiles(checkout.path, this.secretFiles(projectId));
    for (const w of dropped.length ? this.store.workspaces(projectId).filter(holds) : []) for (const path of dropped) removeSecretFile(w.cwd, path);
  }

  /** 工作树建好、开放之前（新建、重跑准备、流转来还原）：先写入项目设了路径的密钥，再跑 setup。 */
  private async setUpWorktree(workspaceId: string, c: Checkout, cwd: string, signal?: AbortSignal) {
    await this.serial(`secrets:${workspaceId}`, async () => {
      this.excludeSecrets(c.projectId);
      await writeSecretFiles(cwd, await this.credentials.pathSecrets(c.projectId));
    });
    return runSetup(c.path, cwd, setupLogPath(this.home, workspaceId), this.home, signal);
  }

  /**
   * 凭据变了（本机改或同步过来，攒成一批）：把相关项目的密钥文件整体重写进本机这些项目的所有工作区，已删的项目不管。写不进去的报给工作区。
   */
  private async secretsChanged(): Promise<void> {
    const ids = [...this.changedSecrets];
    this.changedSecrets.clear();
    const projects = new Set(ids.flatMap((id) => this.secretPaths.get(id)?.projectId ?? []));
    this.secretPaths = this.credentials.secretPaths();
    for (const id of ids) { const now = this.secretPaths.get(id); if (now) projects.add(now.projectId); }
    await Promise.all([...projects].filter((projectId) => this.registry.get(projectId) && this.store.project(projectId)).map(async (projectId) => {
      this.excludeSecrets(projectId);
      const workspaces = this.store.workspaces(projectId).filter((w) => holds(w) && existsSync(w.cwd));
      if (!workspaces.length) return;
      const files = await this.credentials.pathSecrets(projectId).catch(() => []);
      await Promise.all(workspaces.map((w) => this.serial(`secrets:${w.id}`, () => writeSecretFiles(w.cwd, files))
        .catch((error: Error) => this.bus.emit({ type: 'workspace.error', workspaceId: w.id, message: `项目密钥没有写进工作区：${error.message}` }))));
    }));
  }

  /**
   * credentials 的请求动作：代理给了值、不用问用户的项直接存好，其余的发出请求、立即返回，用户回应后由 respondWaiting 交给代理。
   * 不用问的是环境变量文件里还没有或值本来就是代理给的项，全放行时是代理给了值的每一项。交给模型的说明不含用户填的值。
   */
  private async requestSecret(threadId: string, request: SecretRequest): Promise<string> {
    const { project, workspace } = this.context(threadId);
    const files = [...new Set(request.flatMap((item) => 'file' in item ? [item.file] : []))];
    for (const file of files) {
      if ((await gitTry(workspace.cwd, ['ls-files', '--error-unmatch', '--', file])).code === 0) {
        throw new Error(`${file} 是项目跟踪的文件，宿主不会把密钥写进去；先把它从 Git 里移除并忽略，再请求`);
      }
    }
    const contents = new Map(await Promise.all(files.map(async (file) =>
      [file, await this.credentials.fileSecret(project.id, file) ?? { value: '', agentKeys: [] }] as const)));
    const secrets: SecretWaitingItem[] = request.map((item) => ({ reason: item.reason,
      exists: 'file' in item ? hasEnvKey(contents.get(item.file)!.value, item.key) : this.credentials.hasSecret(project.id, item.name),
      ...('file' in item ? { file: item.file, key: item.key } : { name: item.name, secretKind: item.kind ?? 'text' }),
      ...(item.value !== undefined ? { value: item.value } : {}) }));
    const allowAll = this.configuration.approvalMode(threadId).effective === 'allow_all';
    // 用户给的项不让代理悄悄换掉
    const direct = (item: SecretWaitingItem) => item.value !== undefined && (allowAll
      || (item.file !== undefined && (!item.exists || contents.get(item.file)!.agentKeys.includes(item.key!))));
    const now = secrets.filter(direct), rest = secrets.filter((item) => !direct(item));
    const saved = now.length ? await this.saveSecrets(project.id, now, { values: now.map((item) => item.value!), scope: 'project' }, true) : '';
    if (!rest.length) return saved;
    const ask = this.asks.add(threadId, { kind: 'secret', secrets: rest });
    return `${saved ? `${saved}\n另外` : ''}已向用户要 ${rest.length} 项密钥，请求 ID 是 ${ask.id}。`;
  }

  /**
   * 存下填了的几项，返回逐项的说明：存好的给出引用或文件与变量名，没填的如实写明，不含填的值。
   * byAgent 表示存的是代理给的值、用户没看过：环境变量文件里这几项记成代理给的，之后代理可以直接改；用户在卡片上存的记成用户的。
   */
  private async saveSecrets(projectId: string, secrets: SecretWaitingItem[], response: { values: Array<string | null>; scope: 'project' | 'account' },
    byAgent = false): Promise<string> {
    const scope = response.scope === 'account' ? null : projectId;
    const lines: string[] = [];
    const written = new Map<string, { value: string; agentKeys: Set<string> }>();
    for (const [index, item] of secrets.entries()) {
      const value = response.values[index];
      if (value == null) { lines.push(`- ${secretLabel(item)}：用户没有填，没有存`); continue; }
      if (item.file && item.key) {
        // 等用户的时候文件可能被改过，按存之前的最新内容替换这一行
        let file = written.get(item.file);
        if (!file) {
          const stored = await this.credentials.fileSecret(projectId, item.file);
          file = { value: stored?.value ?? '', agentKeys: new Set(stored?.agentKeys) };
          written.set(item.file, file);
        }
        file.value = setEnvLine(file.value, item.key, value);
        if (byAgent) file.agentKeys.add(item.key);
        else file.agentKeys.delete(item.key);
        lines.push(`- ${secretLabel(item)}：已存好，宿主正把这个文件重写进项目的所有工作区`);
      } else {
        // 环境变量文件里的项总是项目专用，账号共享只对独立的密钥
        await this.credentials.saveSecret(scope, item.name!, item.secretKind ?? 'text', value);
        lines.push(`- ${secretLabel(item)}：已存好，引用是 {${scope ? 'project' : 'account'}.${item.name}}，在 shell 的 secrets 参数里使用`);
      }
    }
    for (const [path, file] of written) {
      await this.credentials.saveFileSecret(projectId, path, file.value, [...file.agentKeys].filter((key) => hasEnvKey(file.value, key)));
    }
    const missing = response.values.filter((value) => value == null).length;
    return [`存好 ${secrets.length - missing} 项${missing ? `，${missing} 项用户没有填` : ''}：`, ...lines].join('\n');
  }

  /**
   * 回应线程在等的一项：阻塞的审批交回那次调用；提问与密钥请求由宿主处理（存密钥），把结果作为一条输入交给代理，交上了才撤下请求。
   * 代理在跑就在下一次请求时纳入，空闲的就此开始新的回合；交不上（会话正在停止、在等确认恢复）时请求留着，报错给回应的一方，
   * 再回应一次即可（密钥已存的再存一遍是替换）。via 是代用户处理的 Line：提问写明由 Line 代答，密钥请求不接受。
   */
  async respondWaiting(threadId: string, id: string, value: unknown, via?: InputVia): Promise<void> {
    if (this.waits.current(threadId)?.id === id) return this.waits.respond(threadId, id, value);
    const ask = this.asks.get(threadId, id);
    if (!ask || this.answering.has(id)) throw new WaitingConflict(this.waits.current(threadId) ?? null);
    if (ask.kind === 'secret' && via) throw new KiteError('密钥请求只能由用户填写，不能交给 Line', 403);
    this.answering.add(id);
    try {
      let text: string;
      let notice: InputNotice;
      if (ask.kind === 'question') {
        const response = questionResponseOf(ask, value);
        text = questionResultText(ask, response, via);
        notice = { kind: 'question', title: `${via ? 'Line 替你' : '你'}${'denied' in response ? '关掉了提问' : '回答了提问'}`,
          ...(via ? { instance: via.instance } : {}) };
      } else {
        const response = secretResponseOf(ask, value);
        text = 'denied' in response ? secretDeniedText(ask, response.reason)
          : `用户回应了你的密钥请求（请求 ${ask.id}），${await this.saveSecrets(this.context(threadId).project.id, ask.secrets, response)}`;
        notice = { kind: 'secret', title: 'denied' in response ? '你拒绝提供密钥' : '你回应了密钥请求' };
      }
      // 用户自己回答的是用户在界面上做的，交给模型时不说成「不是用户说的话」；Line 代答的照常说明。
      await this.send(threadId, text, randomUUID(), { source: 'kite', notice, ...(via ? {} : { response: true as const }) }).catch((error: Error) => {
        throw error instanceof KiteError ? error : new KiteError(`结果没能交给代理：${error.message}`, 409);
      });
      this.asks.remove(threadId, id);
    } finally { this.answering.delete(id); }
  }

  /** 准备失败的工作区重跑准备：工作树还在就重写项目密钥、重跑 setup；不自动重跑。 */
  retrySetup(id: string): Promise<WorkspaceModel> {
    return this.control(id, async () => {
      const { workspace: w, checkout } = this.workspace(id);
      if (w.status !== 'failed') throw new KiteError('只有准备失败的工作区可以重跑准备', 409);
      this.setWorkspaceStatus(id, 'preparing');
      this.prepare(w, checkout, undefined, true);
      return this.workspace(id);
    });
  }

  /**
   * 建工作树、写入项目密钥、跑 setup、存初始快照后开放；带首条消息的线程在开放后才收到它。失败或被打断时工作区为 failed。
   * 重跑时工作树若没建成，先清掉残留的登记与分支：准备失败的工作区从未开放，分支上没有用户的改动。
   * opener 是用 isolation 开出这个子工作区的代理：没准备好时告诉它。
   */
  private prepare(w: Workspace, c: Checkout, first?: { thread: AgentInstance; input?: Input; opener?: string }, retry = false): void {
    const { id } = w;
    const t = first?.thread;
    const controller = new AbortController();
    this.preparations.set(id, controller);
    void this.serial(`workspace:${id}`, async () => {
      try {
        if (retry && !existsSync(w.cwd)) await removeWorktree(c.path, w.cwd, w.branch);
        if (!existsSync(w.cwd)) await addWorktree(c.path, w.cwd, w.branch, w.base);
        controller.signal.throwIfAborted();
        const setup = await this.setUpWorktree(id, c, w.cwd, controller.signal);
        this.bus.emit({ type: 'workspace.setup', workspaceId: id, originThreadId: t?.id, exit: setup?.exit ?? null, log: setup?.tail ?? '' });
        if (setup && setup.exit !== 0) throw new KiteError(`初始化脚本退出码 ${setup.exit}`);
        await this.snapshot(w, [], '工作区开始', t?.id);
        controller.signal.throwIfAborted();
        this.setWorkspaceStatus(id, 'open');
        if (first?.input) await this.sendInput(this.context(first.thread.id), first.input, () => controller.signal.throwIfAborted());
      } catch (e) {
        this.bus.emit({ type: 'workspace.error', workspaceId: id, originThreadId: t?.id, message: (e as Error).message });
        this.setWorkspaceStatus(id, 'failed');
        if (first?.opener && !this.stopping) {
          void this.reports.workspace(first.opener, { name: this.store.workspace(id)?.name ?? w.name, agent: first.thread.id }, '没有准备好',
            `没有准备好：${(e as Error).message}。里面的代理没有开始，用户可以在界面上重跑准备或放弃它。`).catch(() => {});
        }
      }
    }).finally(() => this.preparations.delete(id));
  }

  /** 新会话的草稿只在 App 本地；第一条消息连同草稿里选好的参数一次创建实例、会话和窗口。
   * windowId 与 messageId 由 App 生成：窗口经事件先到时 App 认得出是草稿变成的那个，第一条消息也和草稿里显示的是同一条。 */
  createThread(workspaceId: string, prompt: string, choice: AgentChoice = {}, windowId?: string, messageId?: string): Promise<ThreadView> {
    return this.control(workspaceId, async () => {
      const { workspace } = this.workspace(workspaceId);
      if (workspace.status !== 'open') throw new KiteError('工作区尚未打开', 409);
      if (!prompt.trim()) throw new KiteError('第一条消息不能为空');
      if (windowId && this.store.window(windowId)) throw new KiteError('窗口 ID 已使用', 409);
      this.assertNotResolving(workspaceId);
      await this.snapshot(workspace, [], '线程开始');
      const t = this.newThread(workspaceId, prompt, choice);
      this.store.addAgent(t, this.instances.newWindow(t, windowId));
      this.threadChanged(t);
      await this.sendInput(this.context(t.id), { id: messageId ?? randomUUID(), text: prompt, source: 'human' });
      return this.thread(t.id);
    });
  }

  /** 操作层只登记实例；有首条消息时才打开执行资源，窗口由 presentation 决定。 */
  /** sender 是首条消息的来源，与 agent.send 的规则相同，由操作层按调用方给出。 */
  startAgent(workspaceId: string, input: OperationInput<'agent.start'>, origin?: PluginInstance['origin'],
    sender: InputOrigin = { source: 'human' }, check: () => void = () => {}): Promise<{ instanceId: string; windowId?: string; workspaceId?: string }> {
    if (input.isolation === 'workspace') return this.startIsolated(workspaceId, input, origin, sender, check);
    return this.control(workspaceId, async () => {
      check();
      const { workspace } = this.workspace(workspaceId);
      if (workspace.status !== 'open') throw new KiteError('工作区尚未打开', 409);
      if (input.prompt !== undefined) {
        this.assertNotResolving(workspaceId);
        await this.snapshot(workspace, [], '线程开始');
      }
      check();
      const agent = this.delegatedAgent(workspaceId, workspaceId, input, origin);
      const window = agent.presentation === 'window' ? this.instances.newWindow(agent) : undefined;
      this.store.addAgent(agent, window);
      this.titled(agent, input);
      this.changed(workspaceId);
      if (input.prompt !== undefined) {
        await this.sendInput(this.context(agent.id), { id: input.operationId, text: input.prompt, ...sender });
      }
      return { instanceId: agent.id, ...(window ? { windowId: window.id } : {}) };
    });
  }

  /**
   * agent_start 的 isolation：在本机从调用方工作区最近的快照开出子工作区，新代理是其中第一个线程，带 prompt 时准备好才收到。
   * 环境检查与准备同新建工作区，不要用户批准，见 docs/项目与远程仓库.md「子工作区」。
   */
  private async startIsolated(parentId: string, input: OperationInput<'agent.start'>, origin: PluginInstance['origin'], sender: InputOrigin,
    check: () => void): Promise<{ instanceId: string; windowId?: string; workspaceId: string }> {
    const { checkout: c } = this.workspace(parentId);
    this.assertCanRun(await this.environment(c.projectId), { id: input.role ?? defaultRoleId });
    return this.control(parentId, async () => {
      check();
      const { workspace: parent } = this.workspace(parentId);
      if (parent.status !== 'open') throw new KiteError('工作区尚未打开', 409);
      this.assertNotResolving(parentId);
      const base = await commitParent(parent);
      check();
      const id = randomUUID();
      const agent = this.delegatedAgent(id, parentId, input, origin, c.projectId);
      const w = this.newWorkspace(c, id, input.title ?? (input.prompt ? titleOf(input.prompt) : UNNAMED_WORKSPACE), base, parentId);
      const window = agent.presentation === 'window' ? this.instances.newWindow(agent) : undefined;
      this.store.addWorkspace(w, { agent, window });
      this.titled(agent, input);
      this.prepare(w, c, { thread: agent, opener: origin?.instanceId,
        ...(input.prompt === undefined ? {} : { input: { id: input.operationId, text: input.prompt, ...sender } }) });
      this.changed(id);
      return { instanceId: agent.id, ...(window ? { windowId: window.id } : {}), workspaceId: id };
    });
  }

  /**
   * agent_start 建的代理，放在 workspaceId 里：角色、展示方式与创建来源照参数；调用方只能读工作区时它也只能读。
   * 执行约束按 constraintsOf 那个工作区的项目取（子工作区这时还没入库，取父工作区的）。
   */
  private delegatedAgent(workspaceId: string, constraintsOf: string, input: OperationInput<'agent.start'>, origin: PluginInstance['origin'],
    projectId?: string): AgentInstance {
    const instance = this.instances.newInstance(workspaceId, agentDefinitionId, input.title ?? (input.prompt ? titleOf(input.prompt) : '新代理'),
      { role: { id: input.role ?? defaultRoleId } }, projectId);
    instance.presentation = input.presentation;
    instance.origin = origin;
    const project = this.store.workspaceConstraints(constraintsOf)?.execution;
    if (origin && effectiveExecution(instanceExecutionChanges(this.store.instance(origin.instanceId)!), project).grants.workspace === 'read') {
      instance.config.execution = { ...instanceExecutionChanges(instance), workspace: 'read' };
    }
    return { ...instance, instanceId: instance.id, runtime: instanceAgent(instance).runtime, nativeId: randomUUID() };
  }

  /** agent_start 写了标题时记成手动起的，工作区跟着它起名。 */
  private titled(agent: AgentInstance, input: OperationInput<'agent.start'>): void {
    if (input.title !== undefined) this.store.saveThreadTitle(agent.id, 'initial', {
      title: agent.title, mode: 'manual', generatedAt: null, through: null,
    });
    this.threadChanged(agent);
    if (input.title !== undefined) this.workspaceNames.follow(agent.id);
  }

  selectFile(input: OperationInput<'files.select'>, check: () => void) {
    const instance = this.store.instance(input.instanceId)!;
    return this.control(instance.workspaceId, async () => {
      check();
      const current = this.store.instance(instance.id)!;
      const { workspace } = this.workspace(current.workspaceId);
      if (workspace.status !== 'open') throw new KiteError('工作区尚未打开', 409);
      if (fileSelection(current.state).revision !== input.expectedRevision) throw new KiteError('所选文件已变化，请刷新后重试', 409);
      let path: string | null = null;
      if (input.path !== null) {
        try {
          const files = new WorkspaceFiles(workspace.cwd);
          const target = files.resolve(input.path);
          path = relative(files.root, target);
          if (input.diffId) {
            const diff = new FileDiffStore(join(this.home, 'diffs', workspace.id)).read(input.diffId);
            if (!diff.files.some((file) => file.path === path)) throw new KiteError('这份差异中没有指定文件', 404);
          } else files.regular(target);
        }
        catch (error) {
          if (error instanceof KiteError) throw error;
          throw new KiteError(`无法选择文件：${error instanceof Error ? error.message : String(error)}`);
        }
      }
      const state = { path, revision: randomUUID(), ...(path && input.diffId ? { diffId: input.diffId } : {}) };
      this.store.setInstanceState(current.id, state);
      this.changed(current.workspaceId);
      return state;
    });
  }

  configureOperationGrants(id: string, expectedRevision: string, value: unknown) {
    return this.configuration.configureOperationGrants(id, expectedRevision, value);
  }
  executionGrants(id: string) { return this.configuration.executionGrants(id); }
  approvalMode(id: string) { return this.configuration.approvalMode(id); }
  configureApprovalMode(id: string, value: unknown) { return this.configuration.configureApprovalMode(id, value); }
  configureExecutionGrants(id: string, expectedRevision: string, value: unknown) {
    return this.configuration.configureExecutionGrants(id, expectedRevision, value);
  }

  async openWindow(workspaceId: string, request: OpenWindowRequest): Promise<WorkspaceWindow> {
    if (request.content.kind === 'create') this.library.ensurePlugin(request.content.definitionId);
    return this.instances.openWindow(workspaceId, request);
  }

  async createPluginInstance(workspaceId: string, id: string, definitionId: string, title?: string) {
    this.library.ensurePlugin(definitionId);
    return this.instances.createPluginInstance(workspaceId, id, definitionId, title);
  }

  closeWindow(workspaceId: string, id: string): Promise<void> {
    return this.instances.closeWindow(workspaceId, id);
  }

  agentConfig(id: string) { return this.configuration.agentConfig(id); }
  agentCapabilities(id: string) { return this.configuration.agentCapabilities(id); }
  contextVariable(scope: VariableScope, name: string) { return previewVariable(this.store, scope, name); }
  writeContextVariableFile(workspaceId: string, name: string, input: { path: string; content: string; expectedSha256: string | null }) {
    return writeVariableFile(this.store, workspaceId, name, input);
  }
  agentOptions(workspaceId: string) { return this.configuration.agentOptions(workspaceId); }
  configureAgent(id: string, expectedRevision: string, value: unknown) {
    return this.configuration.configureAgent(id, expectedRevision, value);
  }
  configureRole(id: string, expectedRevision: string, role: RoleSelection) {
    return this.configuration.configureRole(id, expectedRevision, role);
  }

  threadTitle(id: string) {
    this.context(id);
    return this.store.threadTitle(id)!;
  }
  async regenerateThreadTitle(id: string, expectedRevision: string) {
    const { completion } = await this.controlThread(id, async () => {
      const thread = this.openThread(id);
      if (!this.titles) throw new KiteError('这台工作机未启用轻任务', 503);
      const current = this.store.threadTitle(id)!;
      // 推进版本使更早的在途结果失效；失败时仍保留原题、模式和生成进度。
      if (!this.store.saveThreadTitle(id, expectedRevision, current)) throw new KiteError('标题已变化，请刷新后重试', 409);
      this.threadChanged(thread);
      return { completion: this.titles.regenerate(id) };
    });
    // 模型请求不占用工作区控制锁，用户仍可继续主会话。
    await completion;
    return this.threadTitle(id);
  }
  configureThreadTitle(id: string, expectedRevision: string, input: { mode: 'auto' } | { mode: 'manual'; title: string }) {
    return this.controlThread(id, async () => {
      const thread = this.openThread(id);
      const current = this.store.threadTitle(id)!;
      const title = singleLine(input.mode === 'manual' ? input.title : current.title, '标题');
      if (!this.store.saveThreadTitle(id, expectedRevision, { title, mode: input.mode, generatedAt: null, through: null })) {
        throw new KiteError('标题已变化，请刷新后重试', 409);
      }
      this.threadChanged(thread);
      if (title !== current.title) this.workspaceNames.follow(id);
      if (input.mode === 'auto') void this.titles?.refresh(id);
      return this.store.threadTitle(id)!;
    });
  }
  async history(id: string): Promise<History> { return (await this.transcripts.load(this.context(id))).snapshot(); }
  async threadState(id: string): Promise<DisplayState> { return (await this.transcripts.load(this.context(id))).state(); }
  historyNow(id: string): History { return this.transcripts.snapshot(id); }
  /** 线程的原生记录，调试查看用；from 是上次读到的各文件条数。 */
  rawTranscript(id: string, from: { journal: number; claude: number }): RawPage {
    const t = this.context(id);
    return readRaw(join(this.home, 'sessions', id), claudeRecordPath(t.workspace.cwd, t.nativeId), from);
  }
  /** 线程最后一回合的回复：最后一条输入之后的正文，供 Line 读取；太长时保留结尾。 */
  async reply(id: string) {
    const state = await this.threadState(id);
    const records = this.transcripts.snapshot(id).records;
    const texts: string[] = [];
    let at: number | undefined;
    for (let index = records.length - 1; index >= 0; index--) {
      const record = records[index]!;
      if (record.id.startsWith('input:')) break;
      if (record.block.type === 'text' && record.block.text.trim()) { texts.unshift(record.block.text); at ??= record.at; }
    }
    const text = texts.join('\n\n');
    return { threadId: id, phase: state.phase, busy: state.busy, ...(state.lastOutcome ? { lastOutcome: state.lastOutcome } : {}),
      ...(state.waiting ? { waiting: state.waiting } : {}), ...(state.asks?.length ? { asks: state.asks } : {}),
      ...(text ? { reply: { text: text.length > 20_000 ? `…${text.slice(-20_000)}` : text, at } } : {}) };
  }
  /** Line 线程里用户的一条消息：给了输入 ID 就取那条，否则取最近的一条；不是用户的消息时没有。 */
  private async userMessage(lineId: string, inputId?: string): Promise<{ id: string; text: string } | undefined> {
    const records = (await this.history(lineId)).records;
    const record = inputId === undefined ? records.findLast((entry) => entry.block.type === 'human')
      : records.find((entry) => entry.id === `input:${inputId}`);
    return record?.block.type === 'human' ? { id: record.block.id, text: record.block.text } : undefined;
  }
  /**
   * 调用方持有工作区控制锁，发送与切换不能同时通过状态检查。先把上下文追加到目标后端的原生记录再保存后端；
   * 保存失败后重试只会导入尚未导入的部分。
   */
  private async switchRuntime(id: string, agent: AgentDefinition, commit: () => void): Promise<void> {
    if (!(await this.threadState(id)).capabilities.switchRuntime) {
      throw new KiteError('请先停止会话、处理排队消息，再切换后端', 409);
    }
    const runner = await this.runnerForManagement(this.context(id));
    if (runner?.busy) throw new KiteError('请先停止会话，再切换后端', 409);
    // 用户在 App 里换后端连带确认恢复：旧后端先核对交接，再把会话交出去。
    if (runner?.recovery) {
      await recoverRuntime(runner);
      // 换过去只带走原生记录里已有的内容，交接结果未知的输入会丢，先由用户继续或撤回。
      if (!(await this.threadState(id)).capabilities.switchRuntime) throw new KiteError('有交接结果未知的消息，请先继续或撤回，再切换后端', 409);
    }
    await runner?.shutdown();
    this.runners.delete(id);
    try { await handOff({ home: this.home, thread: this.context(id), to: agent.runtime, model: agent.model.model }); }
    catch (error) { throw new KiteError(`上下文翻译失败，后端未切换：${(error as Error).message}`, 409); }
    commit();
    await this.transcripts.reset(this.context(id));
  }
  private runner(t: ThreadContext): Promise<Runtime> {
    const existing = this.runners.get(t.id);
    if (existing) return Promise.resolve(existing);
    // 同一线程只打开一个 runtime；并发的打开请求共用同一次初始化，不依赖调用方持有工作区锁。
    let opening = this.openingRunners.get(t.id);
    if (!opening) {
      opening = this.openRunner(t).finally(() => this.openingRunners.delete(t.id));
      this.openingRunners.set(t.id, opening);
    }
    return opening;
  }
  private async openRunner(t: ThreadContext): Promise<Runtime> {
    const { id, workspaceId, workspace, title } = t;
    await this.transcripts.load(t);
    const r = await openRuntime(t, {
      home: this.home, credentials: this.credentials, repository: t.checkout.path, options: this.options,
      chatgptLimits: (headers) => this.modelAccounts.observeChatGPT(headers),
      events: {
        emit: (event) => {
          if (event.type === 'sdk' && event.message.type === 'rate_limit_event') this.modelAccounts.observeClaude(event.message.rate_limit_info);
          this.bus.emit({ ...event, threadId: id });
        },
        label: (text) => this.turnLabels.set(id, firstLine(text)),
        snapshot: (ids) => this.snapshot(workspace, ids, this.turnLabels.get(id) ?? title, id),
        idle: (outcome) => {
          const completed = outcome?.kind === 'completed';
          this.bus.emit({ type: 'idle', threadId: id, completed });
          this.reports.settled(id, outcome).catch((error) => console.error(`[回报] ${id} 的回合收尾没能处理：${(error as Error).message}`));
          const resolving = this.resolving.get(workspaceId);
          if (outcome?.kind === 'failed' && resolving?.threadId === id && resolving.action === 'merge') {
            this.reportMerge(resolving.initiator, workspaceId, '没能合回',
              `没能合回：处理冲突的回合失败了（${outcome.message}）。子工作区停在合并中途，让它接着处理，回合正常结束后会接着合回。`);
          }
          if (completed && !this.stopping && resolving?.threadId === id) {
            const next = {
              adopt: () => this.adopt(workspaceId, id, true), sync: () => this.syncWorkspace(workspaceId, id, true),
              merge: () => this.mergeWorkspace(workspaceId, { threadId: id, afterResolution: true, initiator: resolving.initiator }),
            }[resolving.action]();
            next.catch((e) => this.bus.emit({ type: 'workspace.error', workspaceId, originThreadId: id,
              message: `自动${mergingTitle[resolving.action]}失败：${(e as Error).message}` }));
          }
        },
      },
      current: () => this.context(id),
      notifications: (after) => this.store.instanceNotifications(id, after),
      // Line 的管理工具只声明给 Line 角色的实例，免得每个代理的请求都带着它们的说明。
      operations: { tools: [...this.operations.tools(id), this.asks.question(id),
        ...(instanceRole(t)?.id === lineRoleId ? lineTools({ store: this.store, peers: this.peers, machine: this.store.machine.id, instanceId: id,
          monitor: this.monitor, message: (inputId) => this.userMessage(id, inputId),
          approve: (request, signal) => this.waits.approve(id, request, signal) }) : [])],
      prepare: (instance) => this.operations.prepareTools(instance) },
      contextUpdateTemplate: () => this.contextTemplates.get(contextUpdateContextDefinition.id, contextUpdateContextDefinition.scene).definition,
      compactionTemplates: () => ({
        compact: this.contextTemplates.get(compactTemplate.id, compactTemplate.scene).definition,
        fileChanges: this.contextTemplates.get(fileChangesContextDefinition.id, fileChangesContextDefinition.scene).definition,
      }),
      compactionFiles: ({ from, to }) => changesBetween(workspace.cwd, workspaceId, from, to),
      secretFiles: () => this.secretFiles(t.project.id),
      requestSecret: (request) => this.requestSecret(id, request),
      withdrawSecret: (ask) => this.asks.withdraw(id, ask, 'secret'),
      toolConstraint: () => this.store.projectConstraints(t.project.id)?.tools,
      executionConstraint: () => this.store.projectConstraints(t.project.id)?.execution,
      askNetwork: ({ host, port }, signal) => {
        const target = host.includes(':') ? `[${host}]` : host;
        return this.askApproval(id, { tool: 'shell', target: port === undefined ? target : `${target}:${port}`,
          reason: '命令要连接网络许可之外的主机', mustAsk: false }, signal);
      },
      background: {
        interjected: (listener) => {
          const listeners = this.interjections.get(id) ?? new Set();
          listeners.add(listener);
          this.interjections.set(id, listeners);
          return () => { listeners.delete(listener); if (!listeners.size) this.interjections.delete(id); };
        },
        adopt: (command, info) => this.terminals.adopt(id, command, info),
      },
      outside: {
        verdict: (command) => {
          const { grants, denied } = effectiveExecution(instanceExecutionChanges(this.context(id)), this.store.projectConstraints(t.project.id)?.execution);
          return unsandboxedVerdict(command, grants.unsandboxed, denied.unsandboxed);
        },
        // 以「 *」结尾的命令记下来就成了带任意参数的模式，只能批准这一次。
        ask: (command, description, signal, secrets) => this.askApproval(id, { tool: 'shell', target: command.trim(), reason: description,
          mustAsk: command.trim().endsWith(' *'), outside: true, ...(secrets?.length ? { secretReferences: secrets } : {}) }, signal),
      },
    });
    this.runners.set(id, r);
    return r;
  }
  /**
   * 命令要连接执行授权之外的主机，或代理申请在沙箱外运行一条命令：按实例此刻的审批模式放行、拒绝或在线程上问人。
   * 「允许并记住」把主机加进网络许可、把整条命令原样记成实例的沙箱外命令；记不住（如线程已归档）也放行这一次。
   */
  private async askApproval(id: string, request: ApprovalRequest, signal: AbortSignal): Promise<boolean> {
    const mode = this.configuration.approvalMode(id).effective;
    if (mode !== 'ask') return mode === 'allow_all';
    const decision = await this.waits.approve(id, request, signal);
    if (decision === 'remember') {
      await this.configuration.remember(id, request.outside ? 'unsandboxed' : 'network', request.target)
        .catch((error: Error) => console.error(`[审批] 记住${request.outside ? '沙箱外命令' : '网络许可'}失败：${error.message}`));
    }
    return decision === 'once' || decision === 'remember';
  }
  /** 恢复检查只打开 journal，不执行旧输入。 */
  private async runnerForManagement(t: AgentInstance): Promise<Runtime | undefined> {
    return this.runners.get(t.id) ?? (t.status === 'open' && existsSync(join(this.home, 'sessions', t.id))
      ? await this.runner(this.context(t.id)) : undefined);
  }
  /** 线程不再处理集成或同步的冲突：停下、归档，或宿主已接着做。 */
  /** quiet 是宿主自己接着做（或交不出去）；否则是被停下或归档，子工作区合回停在了半路，告诉发起合回的代理。 */
  private endResolving(t: { id: string; workspaceId: string }, quiet = false): void {
    const resolving = this.resolving.get(t.workspaceId);
    if (resolving?.threadId !== t.id) return;
    this.resolving.delete(t.workspaceId);
    if (!quiet && resolving.action === 'merge') this.reportMerge(resolving.initiator, t.workspaceId, '没能合回', '没能合回：处理冲突的代理被停下了，合回没有接着做。');
  }
  /** 冲突的处理回合期间，只有处理冲突的那个线程能开始工作。 */
  private assertNotResolving(workspaceId: string, threadId?: string): void {
    const resolver = this.resolving.get(workspaceId);
    if (resolver && resolver.threadId !== threadId) throw new KiteError('工作区停在合并主线的冲突里，等处理冲突的线程结束或停下它再开始', 409);
  }
  /** 动整个工作区的操作（回退、采纳）要求全员空闲；线程之间的启动、发送与继续默认并行，见 docs/工作区并行.md。 */
  private async assertIdle(workspaceId: string): Promise<void> {
    if (await this.working(workspaceId)) throw new KiteError('工作区有线程正在工作或等待恢复确认', 409);
  }
  /** 工作区有线程正在工作或等待恢复确认。 */
  private async working(workspaceId: string): Promise<boolean> {
    for (const t of this.store.threads(workspaceId)) {
      if (t.status === 'archived') continue;
      const r = await this.runnerForManagement(t);
      if (r?.busy || r?.recovery) return true;
    }
    return false;
  }
  /** origin 是来源与发信方，由调用方按调用身份给出，见 InputOrigin。 */
  send(id: string, text: string, inputId: string = randomUUID(), origin: InputOrigin = { source: 'human' },
    check: () => void = () => {}): Promise<{ id: string }> {
    if (!text.trim()) throw new KiteError('消息不能为空');
    if (!inputId) throw new KiteError('消息 id 不能为空');
    return this.controlThread(id, async () => {
      check();
      const t = this.openThread(id);
      await this.sendInput(t, { id: inputId, text, ...origin }, check);
      return { id: inputId };
    });
  }
  private async sendInput(thread: ThreadContext, input: Input, check: () => void = () => {}): Promise<void> {
    this.assertNotResolving(thread.workspaceId, thread.id);
    const runner = await this.runner(thread);
    check();
    // 先登记交代方再交给线程：回合可能在 send 返回之前就收尾。
    const undo = this.reports.received(thread.id, input);
    let accepted: boolean;
    try { accepted = await runner.send(input); }
    catch (error) { undo(); throw error; }
    // 同一 ID 重发（操作重试）不是新的交代，收下时该做的第一次已经做过。
    if (!accepted) { undo(); return; }
    if (input.source === 'human') for (const listener of [...this.interjections.get(thread.id) ?? []]) listener();
    // Line 自己的说明让这一回合成为 Line 的工作；用户的消息（含经 Line 转达的原文）收回给用户。
    if (input.source === 'agent' && input.from.kind === 'line') this.lineWork.add(thread.id);
    else if (input.source === 'human') this.lineWork.delete(thread.id);
    // 还没有标题记录（没起过名、没手动改过）时，用第一条消息作标题
    if (this.store.threadTitle(thread.id)?.revision === 'initial') {
      this.store.renameInstance(thread.id, titleOf(input.text));
      this.threadChanged(thread);
      this.workspaceNames.follow(thread.id, true);
    }
    // 输入受理后即与主会话并行，标题材料包含尚未交给主模型的排队消息。
    void this.titles?.refresh(thread.id);
  }
  cancel(id: string, inputId: string): Promise<void> {
    return this.controlThread(id, async () => {
      const r = await this.runner(this.openThread(id));
      if (!r.cancel) throw new KiteError('这个后端不支持撤回排队消息', 409);
      await r.cancel(inputId);
    });
  }
  async interrupt(id: string, request?: StopRequest, check: () => void = () => {}): Promise<{ returned: Input[] }> {
    // 只在锁内冻结队列；停止工具与收尾期间仍允许其他控制请求得到明确拒绝。
    const { completion } = await this.controlThread(id, async () => {
      check();
      this.preparations.get(this.context(id).workspaceId)?.abort();
      const r = await this.runner(this.context(id));
      check();
      this.endResolving(this.context(id));
      return { completion: r.interrupt(request) };
    });
    return { returned: await completion };
  }
  resume(id: string, check: () => void = () => {}): Promise<void> {
    return this.controlThread(id, async () => {
      check();
      const t = this.openThread(id);
      this.assertNotResolving(t.workspaceId, t.id);
      const r = await this.runner(t);
      check();
      if (!r.resume) throw new KiteError('这个后端通过发消息继续', 409);
      await r.resume();
    });
  }
  /** 压缩不改文件，不要求同一工作区的其他线程空闲；模型请求在锁外进行，结果经显示事件送达。 */
  compact(id: string, request: CompactionRequest): Promise<void> {
    return this.controlThread(id, async () => {
      const r = await this.runner(this.openThread(id));
      if (!r.compact) throw new KiteError('这个后端暂不支持压缩上下文', 409);
      try { await r.compact(request); }
      catch (error) { throw new KiteError((error as Error).message, 409); }
    });
  }
  revertCompaction(id: string, compactionId: string): Promise<void> {
    return this.controlThread(id, async () => {
      const r = await this.runner(this.openThread(id));
      if (!r.revertCompaction) throw new KiteError('这个后端暂不支持压缩上下文', 409);
      try { await r.revertCompaction(compactionId); }
      catch (error) { throw new KiteError((error as Error).message, 409); }
    });
  }
  /** 只确认恢复，`kite` 命令行用；App 在发送、继续和停止时连带确认，见 confirmRecovery。 */
  recover(id: string): Promise<void> {
    return this.controlThread(id, async () => recoverRuntime(await this.runner(this.openThread(id))));
  }
  /**
   * 用户在 App 里发送、继续或停止时连带确认恢复。没有阻塞或还在收尾时不动，由随后的操作按当时状态处理：
   * 重试不会把已经继续的会话再停住，重试中的停止也照旧等原来那次。
   */
  confirmRecovery(id: string): Promise<void> {
    return this.controlThread(id, async () => {
      const r = await this.runner(this.openThread(id));
      if (r.recovery && !r.busy) await recoverRuntime(r);
    });
  }
  /** 用户在 App 里合回主线或手动流转时，连带确认工作区里待恢复的线程；自动换机和冲突处理后的自动合回不经过这里。 */
  async confirmWorkspaceRecovery(workspaceId: string): Promise<void> {
    for (const t of this.store.threads(workspaceId)) {
      if (t.status !== 'archived' && (await this.threadState(t.id)).recovery) await this.confirmRecovery(t.id);
    }
  }

  private snapshot(w: Workspace, toolUseIds: string[], label: string, threadId?: string): Promise<void> {
    return this.serial(`snap:${w.id}`, async () => {
      const r = await capture(w.cwd, w.id, label, toolUseIds, threadId);
      if (!r.created) return;
      this.bus.emit({ type: 'workspace.snapshot', workspaceId: w.id, originThreadId: threadId, commit: r.commit, changedFiles: r.changedFiles, label });
      // 顶层多了或少了名字：让客户端重读工作区列表，消息里新目录下的路径才认得出
      const sent = this.sentRootNames.get(w.id);
      if (sent !== undefined && sent !== this.rootNames(w)?.join('/')) this.changed(w.id);
    });
  }
  snapshots(id: string): Promise<Snapshot[]> { const m = this.workspace(id); return list(m.checkout.path, id); }
  restore(id: string, commit: string): Promise<void> {
    return this.control(id, async () => {
      const { workspace: w, checkout } = this.workspace(id);
      if (w.status !== 'open') throw new KiteError('工作区尚未打开', 409);
      await this.assertIdle(id);
      const full = await findSnapshot(checkout.path, id, commit);
      if (!full) throw new KiteError('找不到这个工作区的快照', 404);
      await this.serial(`snap:${id}`, async () => {
        const { safety, current, label } = await restore(w.cwd, id, full);
        for (const [snapshot, title] of [[safety, '回退前自动保存'], [current, label]] as const) {
          if (snapshot.created) this.bus.emit({ type: 'workspace.snapshot', workspaceId: id,
            commit: snapshot.commit, label: title, changedFiles: snapshot.changedFiles });
        }
      });
      this.changed(id);
    });
  }
  /**
   * 按项目的集成方式集成：直接合入或提交 PR，见 docs/项目与远程仓库.md「工作区与集成」。冲突交给工作区里的一个打开线程。
   * afterResolution：线程处理冲突的回合已正常结束，由宿主提交其结果；这次仍失败不再转交，避免往复。
   */
  async adopt(id: string, originThreadId?: string, afterResolution = false): Promise<AdoptResult> {
    const { workspace: current } = this.workspace(id);
    if (current.parentId) throw new KiteError('子工作区不能直接集成，只能合回父工作区或放弃', 409);
    // 先确认能集成再清子工作区，集成不了时不动它们；处理冲突后的自动集成不再清，期间新开的由下面的检查报出来。
    if (!afterResolution) {
      if (current.status !== 'open') throw new KiteError('只能集成已打开的工作区', 409);
      await this.assertIdle(id);
      await this.clearChildren(id);
    }
    return this.control(id, async () => {
      // 集成全程持有工作区锁，此时放开不会让其他线程插进来。
      if (afterResolution && originThreadId) this.endResolving({ id: originThreadId, workspaceId: id }, true);
      const model = this.workspace(id);
      const { workspace: w, checkout, project } = model;
      if (w.status !== 'open') throw new KiteError('只能集成已打开的工作区', 409);
      await this.assertIdle(id);
      // 下层的排在前面：先合回它们，上层才合得回。
      const pending = this.store.descendantWorkspaces(id).reverse();
      if (pending.length) throw new ChildrenPending(pending.map((child) => ({ id: child.id, name: child.name })));
      const proposing = !!project.remote && this.registry.get(project.id)?.integration === 'pullRequest';
      // 提交说明要等辅助模型，在检出锁外起草，不挡同一项目的其他工作区。
      const message = await draftCommit({ tasks: this.lightTasks, templates: this.contextTemplates, model });
      const merged = await this.serial(`checkout:${checkout.id}`, (): Promise<AdoptResult | Proposal> => proposing
        ? this.pushProposal(model, message, afterResolution) : this.mergeIntoMainline(w, checkout, message, afterResolution));
      // PR 的起草与开 PR 要等辅助模型与 GitHub，放在检出锁外，不挡同一项目的其他工作区。
      const result = merged.status === 'pushed' ? await this.openProposal(model, merged) : merged;
      if (result.status === 'conflict') await this.handConflict(id, 'adopt', w, result.files, afterResolution);
      // 合好了主线就不再落后
      else if (this.store.setWorkspaceBehind(id, 0)) this.changed(id);
      this.bus.emit({ type: 'workspace.adopt', workspaceId: id, originThreadId, result });
      return result;
    });
  }
  /**
   * 直接合入：把本机主线与远程主线合进工作区分支，本机主线快进后推送。拿不到远程时照常合进本机主线，结果里报告推送失败，
   * 远程要求登录时另带主机；推送被拒说明远程刚有新提交，重新拉取、合并后再推，冲突同样留在工作区。
   * 没有远程的项目合进本机主线就结束，其他工作机同步时快进过来。
   */
  private async mergeIntoMainline(w: Workspace, checkout: Checkout, message: string, afterResolution: boolean): Promise<AdoptResult> {
    let { main, access, offline } = await this.checkoutManagement.refresh(checkout);
    const local = !this.store.project(checkout.projectId)?.remote;
    for (let attempt = 1; ; attempt++) {
      const r = await mergeMainline(w.cwd, message, mainRefs(main), { stageResolved: afterResolution });
      if (r.status === 'conflict') return r;
      await advanceMainline(checkout, main.branch, r.commit);
      const adopted = (push: PushOutcome): AdoptResult => ({ status: 'adopted', commit: r.commit, push });
      const failed = (error: Error) => adopted({ status: 'failed', message: error.message,
        ...(error instanceof GitLoginRequired ? { gitLogin: error.host } : {}) });
      if (local) return adopted({ status: 'local' });
      if (!access) return failed(offline ?? new KiteError('无法访问远程'));
      let pushed: Awaited<ReturnType<typeof pushBranch>>;
      try { pushed = await pushBranch(checkout.path, main.branch, access); }
      catch (error) { return failed(error as Error); }
      if (pushed === 'pushed') return adopted({ status: 'pushed' });
      if (pushed === 'protected') return failed(new KiteError('主线受保护，不能直接推送；在项目设置里把集成方式改为提交 PR'));
      if (attempt === PUSH_ATTEMPTS) return failed(new KiteError('远程持续有新的提交，推送多次被拒，请稍后再集成'));
      try { main = await fetchMainline(checkout, main.branch, access); }
      catch (error) { return failed(error as Error); }
    }
  }
  /**
   * 提交 PR 的前一半，调用方持有检出锁：把远程主线（和远程上这个 PR 分支里别人推的提交）合进工作区分支，推到远程的 PR 分支，不动本机主线。
   * 第一次提交时按工作区名称起分支名，远程或本机别的工作区已占用的名字后面加序号；推上去就记下，之后开 PR 失败了重试也推到同一个分支。
   */
  private async pushProposal(model: WorkspaceModel, message: string, afterResolution: boolean): Promise<Proposal | { status: 'conflict'; files: string[] }> {
    const { workspace: w, checkout, project } = model;
    const { main, access, offline } = await this.checkoutManagement.refresh(checkout);
    // 拉不到远程就提交不了：照原样报出，远程要求登录时是 GitLoginRequired，错误体带上主机。
    if (!access) throw offline instanceof KiteError ? offline : new KiteError(`无法访问远程：${offline?.message ?? '没有 origin'}`, 409);
    const base = main.branch;
    let branch = w.pullRequest?.branch;
    if (!branch) {
      const taken = new Set([...(await lsRemote(checkout.path, access, 'refs/heads/kite/*', '查看远程分支')).keys()].map((ref) => ref.slice('refs/heads/'.length)));
      for (const other of this.store.workspaces(checkout.projectId)) if (other.pullRequest) taken.add(other.pullRequest.branch);
      const name = proposalBranch(w.name, w.id);
      branch = name;
      for (let n = 2; taken.has(branch); n++) branch = `${name}-${n}`;
    }
    const theirs = w.pullRequest && await fetchBranch(checkout.path, branch, access) ? tracking(branch) : null;
    // 远程主线；远程还没有这个分支时是本机主线
    const target = main.upstream ?? main.local;
    const r = await mergeMainline(w.cwd, message, [target, theirs], { stageResolved: afterResolution });
    if (r.status === 'conflict') return r;
    const pushed = await pushBranch(checkout.path, w.branch, access, branch);
    if (pushed === 'rejected') throw new KiteError(`远程的 ${branch} 刚有新的提交，请重试`, 409);
    if (pushed === 'protected') throw new KiteError(`远程不接受推送到 ${branch}`, 409);
    // 开着的 PR 沿用；没开过或已合并、关闭的先记成网页地址，开出新 PR 后再换（不带旧编号，免得按旧 PR 的状态算已采纳）。
    const open = w.pullRequest?.state === 'open' && w.pullRequest.number !== undefined ? w.pullRequest : undefined;
    this.store.setWorkspacePullRequest(w.id, open ? { ...open, branch, commit: r.commit }
      : { branch, url: proposalPage(project.remote!, base, branch), state: 'open', commit: r.commit });
    return { status: 'pushed', base, target };
  }
  /**
   * 提交 PR 的后一半，不持检出锁：GitHub 上自动开 PR（标题与说明由辅助生成起草），已有开着的就沿用；其他平台只推分支，
   * 给出去网页上开 PR 的地址。开着的 PR 随推送更新，合并或关闭了的再集成时开一个新的。
   */
  private async openProposal(model: WorkspaceModel, pushed: Proposal): Promise<AdoptResult> {
    const { workspace: { id }, project } = model;
    const { base, target } = pushed;
    let pull = this.store.workspace(id)!.pullRequest!;
    const repo = gitHubRepo(project.remote!);
    if (repo && pull.number === undefined) {
      // 起草要等辅助模型：没绑定 GitHub 时 openPullRequest 不会调用它
      const opened = await this.github.openPullRequest(repo.owner, repo.repo, { head: pull.branch, base },
        () => draftPullRequest({ tasks: this.lightTasks, templates: this.contextTemplates, base: target, model }));
      if (opened) this.store.setWorkspacePullRequest(id, pull = { ...pull, ...opened });
    }
    this.changed(id);
    return { status: 'proposed', branch: pull.branch, url: pull.url, ...(pull.number !== undefined ? { number: pull.number } : {}) };
  }
  /**
   * 集成父工作区之前：没有改动、也没在工作的子工作区（连同它下面的）直接归档。各个子工作区分别加锁，不在父工作区的锁里，
   * 免得和先拿子工作区锁、再拿父工作区锁的合回互等。剩下的由集成报给用户，见 docs/项目与远程仓库.md「子工作区」。
   */
  private async clearChildren(id: string): Promise<void> {
    for (const child of this.store.childWorkspaces(id)) {
      const group = [child, ...this.store.descendantWorkspaces(child.id)];
      // 不带 force：停下线程之后再查一遍改动，查到了就留着，由集成报出来。
      if ((await Promise.all(group.map((w) => this.settled(w)))).every(Boolean)) await this.archiveWorkspace(child.id).catch(() => {});
    }
  }
  /** 子工作区可以随手清掉：不在准备中，没有线程正在工作（没起过运行器的不可能在工作），也没有改动。 */
  private async settled(w: Workspace): Promise<boolean> {
    return w.status !== 'preparing' && !this.store.threads(w.id).some((t) => this.runners.get(t.id)?.busy) && !(await childChanged(w));
  }

  /** 把集成、同步或合回的冲突交给工作区里最近的打开线程；手动重试遗留冲突同样转交，处理回合被打断后仍能继续。 */
  private async handConflict(id: string, action: Merging, w: Workspace, files: string[], afterResolution: boolean, initiator?: string): Promise<void> {
    const t = this.store.threads(id).findLast((thread) => thread.status === 'open');
    if (afterResolution || !t) return;
    this.resolving.set(id, { threadId: t.id, action, ...(initiator ? { initiator } : {}) });
    try {
      await this.sendInput(this.context(t.id), { id: randomUUID(), text: conflictPrompt(action, w.branch, files), source: 'kite',
        notice: { kind: 'conflict', title: `${mergingTitle[action]}时 ${files.length} 个文件冲突，交给代理解决` } });
    }
    catch (error) { this.endResolving(t, true); throw error; }
  }
  /**
   * 同步：拉取主线，合进工作区分支，不推送；要求线程全部空闲，冲突交给其中的线程，合完保存快照。
   * 拉不到远程时照用本机主线和上次拉取的远程主线；远程要求登录不算拉不到，报出来让用户绑定令牌后再同步。afterResolution 同 adopt。
   */
  syncWorkspace(id: string, originThreadId?: string, afterResolution = false): Promise<SyncResult> {
    return this.control(id, async () => {
      if (afterResolution && originThreadId) this.endResolving({ id: originThreadId, workspaceId: id }, true);
      const { workspace: w, checkout } = this.workspace(id);
      if (w.parentId) throw new KiteError('子工作区不和主线同步，合回时会先带上父工作区的最新状态', 409);
      if (w.status !== 'open') throw new KiteError('只能同步已打开的工作区', 409);
      await this.assertIdle(id);
      const result = await this.serial(`checkout:${checkout.id}`, async (): Promise<SyncResult> => {
        const { main, offline } = await this.checkoutManagement.refresh(checkout);
        if (offline instanceof GitLoginRequired) throw offline;
        if (!(await revParse(w.cwd, 'MERGE_HEAD')) && (await behindCount(w.cwd, main)) === 0) return { status: 'current' };
        const r = await mergeMainline(w.cwd, w.name, mainRefs(main), { stageResolved: afterResolution });
        return r.status === 'conflict' ? r : { status: 'synced', commit: r.commit };
      });
      if (result.status === 'conflict') await this.handConflict(id, 'sync', w, result.files, afterResolution);
      else {
        if (result.status === 'synced') await this.snapshot(w, [], '同步主线', originThreadId);
        if (this.store.setWorkspaceBehind(id, 0)) this.changed(id);
      }
      this.bus.emit({ type: 'workspace.sync', workspaceId: id, originThreadId, result });
      return result;
    });
  }
  /**
   * 子工作区合回父工作区，见 docs/项目与远程仓库.md「子工作区」：只要求子工作区的线程空闲，父工作区照常工作。先把父工作区的现状合进子工作区分支，
   * 冲突交给子工作区里的一个线程，回合正常结束后宿主接着合（afterResolution）；再合进父工作区，这一步冲突就撤回、从头再来。
   * 合完保存父工作区的快照并归档子工作区，没有改动时直接归档。initiator 是发起合回的代理：冲突交出去以后的结果作为一条输入交给它。
   * 先拿子工作区的锁再拿父工作区的；归档、集成父工作区时各个子工作区分别加锁，不嵌套在父工作区的锁里，两边不会互等。
   */
  async mergeWorkspace(id: string, options: MergeOptions = {}): Promise<MergeResult> {
    const { workspace: child } = this.workspace(id);
    if (!child.parentId) throw new KiteError('只有子工作区能合回，顶层工作区用集成', 409);
    // 准备中的子工作区占着自己的锁跑 setup，先挡在外面，不在锁里等它。
    if (child.status !== 'open') throw new KiteError('只能合回已打开的子工作区', 409);
    const parentId = child.parentId;
    // 冲突交出去以后宿主接着合的结果；当场合完的由操作结果告诉调用方。
    const report = (title: string, result: string) => { if (options.afterResolution) this.reportMerge(options.initiator, id, title, result); };
    let result: MergeResult;
    try { result = await this.control(id, () => this.control(parentId, () => this.mergeHeld(id, parentId, options))); }
    catch (error) {
      report('没能合回', `没能合回：${(error as Error).message}。子工作区还在，处理之后可以再用 agent_merge 合回。`);
      throw error;
    }
    if (result.status === 'conflict') {
      if (!this.resolving.has(id)) report('没能合回', `没能合回：这些文件的冲突没解决完：${result.files.join('、')}。子工作区还在，处理之后可以再用 agent_merge 合回。`);
      return result;
    }
    // 它下面的子工作区没有改动、也没在工作（合回前查过），放开锁之后归档，各层随之归档。
    for (const rest of this.store.childWorkspaces(id)) await this.archiveWorkspace(rest.id, true).catch(() => {});
    if (result.status === 'merged') report('合回了', '已合回当前工作区并归档。');
    else report('没有改动，已归档', '没有改动，已归档。');
    return result;
  }
  /** 合回的结果交给发起合回的代理；界面上发起的没有。title 与 result 见 AgentReports.workspace。 */
  private reportMerge(initiator: string | undefined, id: string, title: string, result: string): void {
    if (!initiator) return;
    void this.reports.workspace(initiator, { name: this.store.workspace(id)?.name ?? id, agent: this.store.childLead(id) ?? id }, title, result).catch(() => {});
  }
  private async mergeHeld(id: string, parentId: string, options: MergeOptions): Promise<MergeResult> {
    options.check?.();
    if (options.afterResolution && options.threadId) this.endResolving({ id: options.threadId, workspaceId: id }, true);
    const { workspace: w } = this.workspace(id);
    const { workspace: parent } = this.workspace(parentId);
    if (w.status !== 'open') throw new KiteError('只能合回已打开的子工作区', 409);
    if (parent.status !== 'open') throw new KiteError('父工作区没有打开，等它打开再合回', 409);
    await this.assertIdle(id);
    for (const rest of this.store.descendantWorkspaces(id)) {
      if (!(await this.settled(rest))) throw new KiteError(`它下面的子工作区「${rest.name}」还有没合回的改动或正在工作，先把它合回或放弃`, 409);
    }
    if (!(await childChanged(w))) {
      await this.archiveHeld(id, true);
      return { status: 'unchanged' };
    }
    for (let attempt = 1; ; attempt++) {
      const resolved = options.afterResolution === true && attempt === 1;
      const first = await mergeParent(w, parent, resolved);
      if (first.status === 'conflict') {
        await this.handConflict(id, 'merge', w, first.files, resolved, options.initiator);
        return first;
      }
      if ((await mergeChild(parent, w.branch)).status === 'merged') break;
      if (attempt === MERGE_ATTEMPTS) throw new KiteError('父工作区一直在改同一处，没能合回，稍后再试', 409);
    }
    await this.snapshot(parent, [], `合回子工作区「${w.name}」`);
    await this.archiveHeld(id, true);
    this.changed(parentId);
    return { status: 'merged' };
  }
  private async stopThread(t: AgentInstance): Promise<void> {
    const r = await this.runnerForManagement(t);
    this.endResolving(t);
    if (r) { await r.shutdown(); this.runners.delete(t.id); }
    this.turnLabels.delete(t.id);
  }
  /** 归档保留会话与业务数据，停止执行并关闭它的窗口；随窗口回收的实例关闭窗口即可。 */
  archiveInstance(id: string): Promise<void> {
    const instance = this.store.instance(id);
    if (!instance) throw new KiteError(`没有这个实例：${id}`, 404);
    const definition = this.catalog.get(instance.definitionId);
    if (definition.agent) return this.archiveThread(id);
    if (definition.id === monitorDefinitionId && 'system' in monitorConfig(instance)) throw new KiteError('Line 的收件箱随 Line 存在，不能单独归档', 409);
    if (definition.lifetime === 'window') throw new KiteError('此实例随窗口回收，关闭窗口即可');
    if (definition.lifetime === 'process') throw new KiteError('此实例随进程结束回收，停止进程即可');
    return this.control(instance.workspaceId, async () => {
      if (this.store.instance(id)!.status === 'archived') return;
      const release = await this.plugins.closeInstance(id);
      try { this.store.archiveInstance(id); } finally { release(); }
      this.changed(instance.workspaceId);
    });
  }
  /** 代理连同同一工作区里它开出的各层子代理一起归档；父代理先归档，子代理停下时不再回报给它。 */
  private archiveThread(id: string): Promise<void> {
    const t = this.context(id);
    this.preparations.get(t.workspaceId)?.abort();
    return this.control(t.workspaceId, async () => {
      for (const member of [id, ...this.subagents(t.workspaceId, id)]) {
        const current = this.context(member);
        if (current.status === 'archived') continue;
        await this.stopThread(current);
        await this.terminals.stopOwned(member, '启动它的代理已归档');
        this.asks.clear(member);
        this.store.archiveInstance(member);
        this.threadChanged({ ...current, status: 'archived' });
      }
    });
  }
  /** 同一工作区里由这个代理开出、还开着的各层子代理；中间一层已归档的，它下面的不算。 */
  private subagents(workspaceId: string, id: string): string[] {
    const open = this.store.threads(workspaceId).filter((t) => t.status === 'open');
    const below = (parent: string): string[] =>
      open.filter((t) => t.origin?.instanceId === parent).flatMap((t) => [t.id, ...below(t.id)]);
    return below(id);
  }
  /** 手动起的名不再跟着代理的标题改；切回自动时当场按代理的标题重起，见 WorkspaceNames。 */
  nameWorkspace(id: string, input: { mode: 'auto' } | { mode: 'manual'; name: string }): WorkspaceModel {
    const { workspace: w } = this.workspace(id);
    if (!['preparing', 'open', 'failed'].includes(w.status)) throw new KiteError('工作区已归档或交给了别的工作机，不能改名', 409);
    if (input.mode === 'auto') this.workspaceNames.restore(id);
    else this.workspaceNames.manual(id, singleLine(input.name, '名称'));
    return this.workspace(id);
  }
  /**
   * 归档工作区，连同下面各层的子工作区，最深的先归档。没带 force 时任何一个有没合回的改动都先拒绝，不打断线程；
   * 用户放弃子工作区也走这里，带 force。
   */
  async archiveWorkspace(id: string, force = false): Promise<void> {
    const { workspace: self, checkout } = this.workspace(id);
    if (this.isLineWorkspace(id)) throw new KiteError('Line 所在的工作区不能归档', 409);
    const children = this.store.descendantWorkspaces(id);
    // 有子工作区时先把整组查一遍，免得归档到一半才被挡住；没有时由 archiveHeld 自己查。
    if (!force && children.length) {
      for (const w of [self, ...children]) if (w.status !== 'archived' && await this.unmerged(w, checkout)) throw new KiteError(this.unmergedMessage(w), 409);
    }
    for (const child of children.reverse()) {
      this.preparations.get(child.id)?.abort();
      await this.control(child.id, () => this.archiveHeld(child.id, force));
    }
    this.preparations.get(id)?.abort();
    return this.control(id, () => this.archiveHeld(id, force));
  }
  /** 工作区有没有没合回的改动：子工作区对着开出时的起点，顶层工作区对着主线；提交 PR 的工作区以 PR 合并为已采纳。 */
  private async unmerged(w: Workspace, checkout: Checkout): Promise<boolean> {
    if (!existsSync(w.cwd)) return false;
    if (w.parentId) return childChanged(w);
    // 提交 PR 的工作区合并之后没有新改动就算集成了。
    const pull = this.store.workspace(w.id)!.pullRequest;
    if (pull?.state === 'merged' && !(await isDirty(w.cwd)) && (await revParse(w.cwd, 'HEAD')) === pull.commit) return false;
    return hasUnmerged(checkout, w.cwd);
  }
  private unmergedMessage(w: Workspace): string {
    return w.parentId ? `子工作区「${w.name}」有没合回的改动；确定丢弃就加 force` : '工作区有没集成的改动；确定丢弃就加 force';
  }
  /** 调用方持有工作区锁。 */
  private async archiveHeld(id: string, force: boolean): Promise<void> {
    const { workspace: w, checkout } = this.workspace(id);
    const threads = this.store.threads(id);
    if (w.status === 'archived') return;
    // 先检查再停止，拒绝归档时不打断正在工作的线程；停止期间写入的改动再检查一次。
    const assertMerged = async () => {
      if (!force && await this.unmerged(w, checkout)) throw new KiteError(this.unmergedMessage(w), 409);
    };
    await assertMerged();
    for (const t of threads) if (t.status !== 'archived') await this.stopThread(t);
    await assertMerged();
    if (existsSync(w.cwd)) await this.snapshot(w, [], '归档前保存');
    const releasePlugins = await this.closeExtensions(id);
    try {
      await removeWorktree(checkout.path, w.cwd, w.branch);
      this.store.archiveWorkspace(id);
    } finally { releasePlugins(); }
    for (const t of threads) if (t.status !== 'archived') this.threadChanged({ ...t, status: 'archived' });
    this.changed(id);
  }
  /** 服务起来后由 daemon 告知本机监听地址与组网，Line 据此调用本机与别的工作机。 */
  listening(serving: { url: string; network?: Network }): void {
    this.serving = serving;
    this.terminals.forwardAll();
  }

  /** 本机上的 Line 实例（未归档、在打开的工作区里）。账号下只有一个 Line，多个 Line 不在当前范围。 */
  lineInstance(): AgentInstance | undefined {
    return this.store.threads().find((thread) => thread.status === 'open' && instanceRole(thread)?.id === lineRoleId
      && this.store.workspace(thread.workspaceId)?.status === 'open');
  }
  /** Line 的 monitor 实例（收件箱）；ensure 时没有就补建一个，带窗口。 */
  lineInbox(ensure = false): PluginInstance | undefined {
    const line = this.lineInstance();
    if (!line) return undefined;
    const found = this.store.instances(line.workspaceId).find((instance) => instance.definitionId === monitorDefinitionId
      && instance.status === 'open' && 'system' in monitorConfig(instance));
    if (found || !ensure) return found;
    const inbox = this.addLineInbox(line);
    this.changed(line.workspaceId);
    return inbox;
  }
  /** 给 Line 建收件箱，连同窗口入库。 */
  private addLineInbox(line: Pick<AgentInstance, 'id' | 'workspaceId'>): PluginInstance {
    const inbox: PluginInstance = { id: randomUUID(), workspaceId: line.workspaceId, definitionId: monitorDefinitionId, title: '收件箱',
      config: { monitor: { target: line.id, system: 'line' } }, state: {}, presentation: 'window', status: 'open', createdAt: Date.now() };
    this.store.addPluginInstance(inbox, this.instances.newWindow(inbox));
    return inbox;
  }
  /** 工作区交接、冻结或归档前停下终端、插件进程与 monitor 的来源；monitor 的来源不算结束，工作区再开放时重新开始，终端不再拉起。 */
  private async closeExtensions(workspaceId: string): Promise<() => void> {
    await this.terminals.closeWorkspace(workspaceId, '工作区已归档或交出，终端已停止');
    await this.monitors.closeWorkspace(workspaceId);
    return this.plugins.closeWorkspace(workspaceId);
  }
  private isLineWorkspace(workspaceId: string): boolean {
    return this.store.threads(workspaceId).some((thread) => thread.status === 'open' && instanceRole(thread)?.id === lineRoleId);
  }

  /**
   * 启用 Line：在这台工作机建一个没有远程的项目（检出里只有说明与空的记忆索引）和一个工作区，承载 Line 代理与它的收件箱，
   * 代理带上账号范围的 line 授权；其他工作机从这台的检出拉取。本机已有 Line 时返回它所在的工作区。
   */
  enableLine(): Promise<WorkspaceModel> {
    const existing = this.store.workspaces().find((w) => holds(w) && this.isLineWorkspace(w.id));
    if (existing) return Promise.resolve(this.workspace(existing.id));
    this.enablingLine ??= this.createLine().finally(() => { this.enablingLine = undefined; });
    return this.enablingLine;
  }
  private async createLine(): Promise<WorkspaceModel> {
    // 别的工作机已有 Line 就不再建第二个。摘要同步有延迟，几乎同时在两台启用仍可能各建一个，要等有见证方才能挡住。
    const elsewhere = this.directory.entries().find((entry) => entry.id !== this.store.machine.id && entry.snapshot?.line);
    if (elsewhere) throw new KiteError(`Line 已在工作机「${elsewhere.name}」上，账号下只有一个 Line；要换到这台，从 Line 的菜单把它流转过来`, 409);
    const role = { id: lineRoleId, revision: this.roles.get(lineRoleId).revision };
    // 先查环境再建项目，跑不了 Line 的工作机上不留下空的 Line 项目。
    this.assertCanRun(await readEnvironment(this.home, this.store.machine, undefined, [], () => this.credentials.apiKeys()), role);
    const project = await this.projectOperation(() => this.checkoutManagement.create('Line',
      { 'AGENTS.md': LINE_AGENTS, '.kite/memory/MEMORY.md': '' }));
    let model: WorkspaceModel;
    try { model = await this.createWorkspace(project.id, undefined, role); }
    catch (error) {
      this.forgetProject(project.id);
      await this.projectOperation(() => this.removeLocalProject(project.id)).catch(() => {});
      throw error;
    }
    return this.control(model.workspace.id, async () => {
      const agent = this.newThread(model.workspace.id, 'Line', { role: { id: lineRoleId } }, project.id);
      agent.config.grants = [...(agent.config.grants as OperationGrant[]), lineGrant];
      this.store.addAgent(agent, this.instances.newWindow(agent));
      this.addLineInbox(agent);
      this.store.saveThreadTitle(agent.id, 'initial', { title: 'Line', mode: 'manual', generatedAt: null, through: null });
      this.threadChanged(agent);
      // 工作区跟着 Line 的标题叫「Line」
      this.workspaceNames.follow(agent.id);
      this.changed(model.workspace.id);
      return this.workspace(model.workspace.id);
    });
  }

  /** 联网后核对本机持有的工作区，已被接管的冻结（见 WorkspaceTransfers.checkAll）。 */
  syncLeases(): Promise<void> {
    // 远程不通时一轮可能很久，上一轮没完就不叠加新的一轮。
    this.leaseSync ??= (this.stopping ? Promise.resolve() : this.transfers.checkAll()).finally(() => { this.leaseSync = undefined; });
    return this.leaseSync;
  }

  /** 执行权已在别的机器：停下本地线程与插件，本机多出的改动存成快照留给人合并，记录冻结。 */
  private freeze(id: string, handingOff?: { epoch: number; to: string }): Promise<void> {
    if (handingOff === undefined) this.preparations.get(id)?.abort();
    return this.control(id, async () => {
      const { workspace: w } = this.workspace(id);
      if (handingOff && !(w.epoch === handingOff.epoch && (w.status === 'handing_off'
        || (w.status === 'transferred' && this.store.workspaceReceiver(id, w.epoch) === handingOff.to)))) {
        throw new KiteError('源工作机没有在把这个工作区交给本机，可能已撤回或已交给别的工作机', 409);
      }
      if (w.status === 'transferred' || w.status === 'archived') return;
      for (const t of this.store.threads(id)) if (t.status !== 'archived') await this.stopThread(t);
      if (existsSync(w.cwd)) await this.snapshot(w, [], '流转后本机留下的改动');
      const release = await this.closeExtensions(id);
      try { this.store.freezeWorkspace(id, handingOff && { epoch: w.epoch, machine: handingOff.to }); } finally { release(); }
      this.changed(id);
    });
  }

  async shutdown(): Promise<void> {
    this.stopping = true;
    clearTimeout(this.projectSync);
    this.directory.close();
    this.library.close();
    await Promise.all([this.titles?.close(), this.workspaceNames.close(), this.emblems.close(), this.lightTasks?.close(), this.subscriptionLogins.close(), this.replication.close(), this.replicas.close(), this.updates.close()]);
    await this.monitor.stop();
    await this.monitors.close();
    await this.terminals.close();
    await this.plugins.close();
    await this.operations.close();
    for (const c of this.preparations.values()) c.abort();
    await Promise.allSettled(this.projectOperations);
    await Promise.allSettled([...this.queues.values(), ...this.openingRunners.values()]);
    await Promise.all([...this.runners.values()].map((r) => r.shutdown()));
    this.accountData.close();
  }
}
