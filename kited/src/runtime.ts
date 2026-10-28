/** kited 的执行入口：Claude 与自研 harness 各自负责完整 agent 循环，共用 Kite 的能力。 */
import { join } from 'node:path';
import type { AccountMachine } from './account-data/directory.ts';
import type { Credentials } from './account-data/credentials.ts';
import type { SecretRequest } from './secrets.ts';
import type { Candidate } from './account-data/directory.ts';
import { KiteError } from './errors.ts';
import type { RuntimeEvent } from './events.ts';
import type { RunnerState } from './claude/runner.ts';
import { idleCompactionPending, openClaudeHost } from './claude/host.ts';
import { assembleContext, restoreContext } from './harness/context/assembler.ts';
import { contextUpdateContext, instancesChangedContext, rosterOf } from './harness/context/notifications.ts';
import type { PluginInstance, ThreadContext } from './model.ts';
import type { ShellBackground, ShellOutside } from './execution/local-tools.ts';
import { deepseekKey, harnessModel } from './harness/adapters.ts';
import { openThreadHost } from './harness/thread-host.ts';
import { agentPolicy, harnessPolicy } from './execution/policy.ts';
import { effectiveExecution, executionRevision, instanceExecutionChanges } from './execution/grants.ts';
import { projectContext, SkillCatalog } from './harness/context/project.ts';
import { skillsBinding, type SkillSources } from './harness/context/skills.ts';
import { effectiveTools, threadVariables, type InstancesView, type McpView } from './context-variables.ts';
import type { ProjectConstraints } from './account-data/registry.ts';
import type { McpServers } from './mcp/servers.ts';
import { instanceMcp, MCP_TOOL_PREFIX } from './mcp/tools.ts';
import type { ContextDefinition } from './harness/context/types.ts';
import { agentRevision, instanceAgent } from './agents/definition.ts';
import { supportsFast } from './agents/models.ts';
import { agentTools } from './plugins/definitions.ts';
import type { OperationToolSelection } from './operations/operations.ts';
import { lineToolNames, operationToolNames } from './operations/contract.ts';
import type { CompactionRequest, Input, Model, Outcome, Phase, StopRequest, ThreadNotification, Tool } from './harness/types.ts';
import type { UpdatesOptions } from './update/updates.ts';
import type { LightTaskOptions } from './light-tasks.ts';
import type { ProjectToolRule } from './roles.ts';
import { permittedTools } from './agents/tool-policy.ts';
import { searchTool } from './harness/tool-search.ts';
import { Attachments } from './workspace/attachments.ts';
import { checkLogs, type CheckHost } from './check.ts';
import type { NetworkAsk } from './execution/command.ts';
import { webTools } from './web/tools.ts';

export interface Runtime {
  readonly state: RunnerState | Phase;
  readonly busy: boolean;
  /** 会话记录写入失败（如磁盘满）：执行已停下，要关掉从记录重新打开。 */
  readonly broken: boolean;
  /** skill 是 /名字 点选的 skill 收下时固定的正文（名字在 input.skill），见 InputMaterial。 */
  send(input: Input, skill?: string): Promise<boolean>;
  interrupt(request?: StopRequest): Promise<Input[]>;
  shutdown(): Promise<void>;
  resume?(): Promise<void>;
  /** 见 ThreadRunner.continueInterrupted：打开不开始执行，被 kited 退出打断的由上层决定接着做。 */
  continueInterrupted(note?: string): Promise<void>;
  cancel?(inputId: string): Promise<void>;
  compact?(request: CompactionRequest): Promise<void>;
  revertCompaction?(id: string): Promise<void>;
  /** 见 ThreadRunner.rewind。 */
  rewind?(inputId: string, dryRun?: boolean): Promise<{ calls: string[] }>;
}



export interface RuntimeOptions {
  /** 本地模型入口，可在集成测试中替换为可控模型流。 */
  model?(thread: ThreadContext): Model;
  /** 后台轻任务独立选模型；false 关闭，测试可注入受控模型。 */
  lightTasks?: false | Partial<LightTaskOptions>;
  /** 测试里替换 Line 看到的工作机目录：同一进程里的几台 kited 按给出的地址直接互访，不经组网。 */
  peers?: { directory(): Promise<AccountMachine[]> };
  /** 测试里替换组网里的对端：同一进程里的几台 kited 按给出的地址直接互访，发现与同步都不经组网。 */
  directory?: { candidates(): Candidate[] };
  /** 凭据的封装密钥放登录钥匙串（安装版 macOS 服务）；否则放数据目录里的文件。 */
  keychain?: boolean;
  /** 安装版服务的安装目录（KITE_INSTALL_ROOT）；有它且运行目录带构建号时才发布与自动更新。 */
  install?: UpdatesOptions;
  /** 测试里缩短 monitor 事件到唤醒之间的合批等待（毫秒），默认 1 秒。 */
  monitorWakeDelayMs?: number;
  /** 测试里缩短本机目录变化到写进目录摘要之间的合批等待（毫秒），默认 1 秒。 */
  catalogDelayMs?: number;
  /** 测试里换掉终端起的 shell（默认是用户的登录 shell）。 */
  terminalShell?: string[];
  /** 测试里缩短终端探测监听端口的间隔（毫秒），默认 2 秒。 */
  terminalPortScanMs?: number;
  /** 测试里缩短预览等画面稳定的节奏，默认连续 300 毫秒不变、每 100 毫秒截一帧、最多 3 秒。 */
  previewSettle?: import('./preview/screen.ts').SettleTiming;
}

export interface RuntimeEvents {
  emit(event: RuntimeEvent): void;
  label(text: string): void;
  snapshot(callIds: string[]): Promise<void>;
  /** 回合收尾、线程转为空闲时调用一次，带这一回合的结果。 */
  idle(outcome: Outcome | undefined): void;
}

export interface RuntimeHost {
  home: string;
  /** Kite 的 skill 来源（用户层与机器层的位置），见 SkillSources。 */
  skills: SkillSources;
  credentials?: Credentials;
  /** 检出主目录，用来解析 Git 元数据。 */
  repository: string;
  events: RuntimeEvents;
  options: RuntimeOptions;
  /** ChatGPT 订阅响应带回的额度。 */
  chatgptLimits?(headers: Headers): void;
  /** 每次请求重新读取，配置和授权变化在下一次请求生效。 */
  current(): ThreadContext;
  notifications(after: number): ThreadNotification[];
  /** 宿主提供的 Kite 工具：协作操作（另须授权）与线程自己的提问。 */
  operations: { tools: Tool[]; prepare(instance: PluginInstance): OperationToolSelection };
  contextUpdateTemplate(): ContextDefinition;
  instancesTemplate(): ContextDefinition;
  compactionTemplates(): { compact: ContextDefinition; fileChanges: ContextDefinition };
  /** 两个时刻之间工作区的净文件变化。 */
  compactionFiles(range: { from: number; to: number }): Promise<string | undefined>;
  /**
   * 所在项目的约束：工具规则、执行授权的基础与边界、禁用的 MCP 服务。每次请求和每次调用工具时读取，
   * 工具与 MCP 的收紧即时生效，执行授权的收紧对之后的命令生效。
   */
  constraints(): ProjectConstraints | undefined;
  /** 这台工作机的外部 MCP 服务；生效的服务的工具按需加载，每次请求和调用前按此刻的开关与约束取。 */
  mcp?: McpView & Pick<McpServers, 'tools'>;
  /** 公共变量 workspace.instances 的取值，见 workspace-instances.ts。 */
  instances?: InstancesView;
  /** 命令连接名单外的主机时交给它决定：按问的那一刻实例的审批模式放行、拒绝或问人，中途改模式对运行中的命令也生效。 */
  askNetwork: NetworkAsk;
  /** shell 的长命令转到后台终端：超时、用户插话或模型要求时接管，见 terminal/terminals.ts。 */
  background?: ShellBackground;
  /** 命令能不能出沙箱：生效的沙箱外命令直接放行，其余按审批模式申请。 */
  outside?: ShellOutside;
  /** 宿主按项目密钥写进工作区的文件（相对路径），对代理只读；每次调用工具时读取。 */
  secretFiles(): string[];
  /** credentials 的请求动作：向用户要密钥，发出请求后返回交给模型的说明；收回见 withdrawSecret。 */
  requestSecret(request: SecretRequest, signal: AbortSignal): Promise<string>;
  withdrawSecret(id: string): string;
  /** check 要在沙箱外跑与主线不一致的 .kite/check 时问：按审批模式放行、拒绝或问人；不给时这样的检查在沙箱里跑。 */
  approveCheck?(script: string, reason: string, signal: AbortSignal): Promise<boolean>;
}

/** 两个后端共用的工具筛选：agent 配置声明、经项目约束过滤后的有效工具，协作与 Line 的工具还须获得授权；插件工具只看授权。 */
function selectTools(current: ThreadContext, operations: RuntimeHost['operations'], constraint: ProjectToolRule | undefined) {
  const agent = instanceAgent(current);
  const selection = operations.prepare(current);
  const operationNames = new Set<string>([...operationToolNames, ...lineToolNames]);
  const effective = new Set(effectiveTools(agent, constraint, current.workspace.cwd));
  const permitted = (name: string) => effective.has(name) && (!operationNames.has(name) || selection.allowed.has(name));
  return { agent, selection, permitted, plugins: selection.plugins };
}

/** 空闲着也要打开的会话：Claude 会话定着还没到时的空闲压缩，kited 启动后打开它才接着计时。 */
export const pendingWhileIdle = (home: string, thread: Pick<ThreadContext, 'id' | 'runtime'>) =>
  thread.runtime === 'claude' && idleCompactionPending(join(home, 'sessions', thread.id));

export async function openRuntime(s: ThreadContext, host: RuntimeHost): Promise<Runtime> {
  const { home, events: on, options, operations } = host;
  const { id, nativeId, title, runtime, project: { id: projectId }, workspace: { cwd, id: workspaceId } } = s;
  if (runtime !== 'claude' && runtime !== 'harness') throw new KiteError(`不支持的会话后端：${runtime}`, 409);
  const basePolicy = await harnessPolicy({ cwd, env: process.env, home, repository: host.repository });
  // 两个宿主在请求边界刷新它；工具、沙箱放行和这里给代理的清单用同一份。
  const skills = new SkillCatalog(cwd, host.skills);
  const variables = (current: ThreadContext) => ({ ...threadVariables(current, host.constraints(), { skills: host.skills, mcp: host.mcp, instances: host.instances }),
    'project.skills': () => skillsBinding(skills.skills) });
  const policy = () => agentPolicy(basePolicy, cwd, instanceExecutionChanges(host.current()), host.constraints()?.execution, host.secretFiles());
  const mcpTools = (current: ThreadContext) => host.mcp?.tools(host.mcp.effective(instanceMcp(current), host.constraints()?.mcp?.deny)) ?? [];
  const credentials = host.credentials;
  const secrets = credentials ? {
    list: async () => credentials.available(projectId),
    resolve: (references: string[]) => credentials.resolve(references, projectId),
    request: (request: SecretRequest, signal: AbortSignal) => host.requestSecret(request, signal),
    withdraw: (id: string) => host.withdrawSecret(id),
  } : undefined;
  // 两个后端共用；Key 每次调用时从账号凭据取，DeepSeek 用模型 API 里的那把。
  const web = webTools({ policy, askNetwork: host.askNetwork, keys: async () => {
    const deepseek = await deepseekKey(credentials && (() => credentials.apiKeys()));
    return [...(deepseek ? [{ provider: 'deepseek' as const, key: deepseek }] : []), ...credentials ? await credentials.searchKeys() : []];
  } });
  const diffDir = join(home, 'diffs', workspaceId);
  const check: CheckHost = { main: host.repository, logs: checkLogs(home, workspaceId), outside: {
    readOnly: () => effectiveExecution(instanceExecutionChanges(host.current()), host.constraints()?.execution).grants.workspace === 'read',
    approve: (script, reason, signal) => host.approveCheck?.(script, reason, signal) ?? Promise.resolve(false),
  } };
  const attachments = new Attachments(home);
  const images = (input: Input) => input.source === 'human' && input.attachments ? attachments.images(workspaceId, input.attachments) : [];
  if (runtime === 'claude') {
    return openClaudeHost({ cwd, nativeId, title, directory: join(home, 'sessions', id), diffDir, policy, secrets, askNetwork: host.askNetwork, images, skills, check,
      ...(host.background ? { background: host.background } : {}),
      ...(host.outside ? { outside: host.outside } : {}),
      prepare(afterNotification) {
        const current = host.current();
        const { agent, permitted, plugins } = selectTools(current, operations, host.constraints()?.tools);
        const external = mcpTools(current);
        const allowed = new Set([...agent.tools.filter(permitted), ...plugins.map((tool) => tool.name), ...external.map((tool) => tool.name)]);
        const updates = host.notifications(afterNotification);
        const values = variables(current);
        const assembled = assembleContext(projectContext(agent.context, values));
        const { instructions, stable } = assembled;
        const roster = rosterOf(assembled);
        return { agent, instructions, stable, ...(roster !== undefined ? { roster } : {}),
          contextUpdate: assembleContext(contextUpdateContext(instructions, values, host.contextUpdateTemplate())).instructions,
          instancesChanged: (previous: string) => {
            const changed = instancesChangedContext(previous, roster!, values, host.instancesTemplate());
            return changed ? assembleContext(changed).instructions : '';
          },
          tools: [...web, ...operations.tools, ...plugins, ...external], allowed,
          notificationText: updates.map((notification) => restoreContext(notification.context).instructions).join('\n\n'),
          through: updates.at(-1)?.sequence ?? afterNotification };
      }, events: on,
      compaction: { templates: () => host.compactionTemplates(), files: (range) => host.compactionFiles(range),
        variables: () => variables(host.current()) },
    });
  }
  const inputs = new Map<string, string>();
  let busy = false;
  /** 刚结束的回合被 kited 关闭停下：下次启动接着做，不算回合结束，不回报。 */
  let cut = false;
  const thread = await openThreadHost({
    cwd, threadDir: join(home, 'sessions', id), diffDir, env: { ...process.env }, policy, secrets, askNetwork: host.askNetwork, skills, check,
    ...(host.background ? { background: host.background } : {}),
    ...(host.outside ? { outside: host.outside } : {}),
    prepareRequest(tools, { afterNotification }) {
      const current = host.current();
      const constraints = host.constraints();
      const execution = effectiveExecution(instanceExecutionChanges(current), constraints?.execution).grants;
      const { agent, selection, permitted, plugins } = selectTools(current, operations, constraints?.tools);
      const values = variables(current);
      // 声明顺序取代理插件的工具目录，与实例配置一致。
      const available = [...tools, ...web, ...operations.tools];
      const declared = agentTools.flatMap((name) => available.find((tool) => tool.name === name) ?? []);
      // 快速模式是实例配置里的开关，当前型号支持才生效；请求配置记下这次是否生效，用量按它折算。
      const choice = current.config.fast === true && supportsFast(agent.model.model) ? { ...agent.model, fast: true } : agent.model;
      const { model, contextWindow } = harnessModel(choice, { threadId: current.nativeId, chatgptAuth: join(home, 'auth', 'chatgpt', 'auth.json'),
        ...(credentials ? { apiKeys: () => credentials.apiKeys() } : {}), ...(host.chatgptLimits ? { observeLimits: host.chatgptLimits } : {}) });
      // 插件与 MCP 工具不进声明，经 tool_search 按插件实例或服务名加载；搜得到的是此刻获准的。
      const external = mcpTools(current);
      const search = searchTool([...plugins, ...external]);
      return {
        model: options.model?.(current) ?? model,
        tools: [...declared.filter((tool) => permitted(tool.name)), search, ...plugins, ...external],
        // 请求发出后项目约束收紧、MCP 服务关掉或被禁时，这次请求里的调用也在执行前拦下；依赖的工具被禁，它也拦下。
        blocked: (name) => {
          const constraint = host.constraints()?.tools;
          if ((agentTools as readonly string[]).includes(name) && !permittedTools(agentTools, constraint ? [constraint] : []).includes(name)) return `项目约束已禁用 ${name}`;
          return name.startsWith(MCP_TOOL_PREFIX) && !mcpTools(host.current()).some((tool) => tool.name === name) ? `MCP 服务已关掉或被禁用：${name}` : undefined;
        },
        instructions: projectContext(agent.context, values), variables: values,
        contextUpdateTemplate: host.contextUpdateTemplate(),
        instancesTemplate: host.instancesTemplate(),
        compactionTemplates: host.compactionTemplates(),
        settings: { model: choice, contextWindow,
          execution: { grants: execution, revision: executionRevision(execution) },
          agent: { definitionId: current.definitionId, revision: agentRevision(agent) },
          pluginTools: selection.sources },
        notifications: host.notifications(afterNotification),
      };
    },
    afterTools: (_turnId, ids) => on.snapshot(ids),
    afterTurn: () => on.snapshot([]),
    compactionFiles: (range) => host.compactionFiles(range),
    onEvent(event) {
      if (event.type === 'record') {
        const row = event.record;
        if (row.type === 'input.received') inputs.set(row.input.id, row.input.text);
        if (row.type === 'input.cancelled') inputs.delete(row.inputId);
        if (row.type === 'turn.finished') cut = !!row.exited;
        if (row.type === 'thread.stopped') for (const input of row.returned) inputs.delete(input.id);
        if (row.type === 'request.started') for (const id of row.inputIds) {
          const text = inputs.get(id);
          if (text) on.label(text);
          inputs.delete(id);
        }
      }
      on.emit({ type: 'harness', event });
      // 空闲中的状态变化（撤回排队输入等）不算回合收尾。
      if (event.type === 'state') {
        const was = busy;
        // 手动压缩也把阶段置为运行、busy 为真，但不在回合里（没有 turnId）；回合中途的自动压缩照旧算在回合里。
        busy = event.state.phase !== 'idle' && !(event.state.compacting && !event.state.turnId);
        if (was && !busy && !cut) on.idle(event.state.lastOutcome);
      }
    },
  });
  return {
    get state() { return thread.runner.state.phase; }, get busy() { return thread.runner.state.busy; },
    get broken() { return thread.runner.broken; },
    send: (input, skill) => thread.runner.send(input, { images: images(input), ...(skill ? { skill } : {}) }),
    interrupt: (request) => thread.runner.interrupt(request), shutdown: () => thread.close(),
    resume: () => thread.runner.resume(),
    continueInterrupted: (note) => thread.continueInterrupted(note),
    cancel: (inputId) => thread.runner.cancel(inputId),
    compact: (request) => thread.runner.compact(request),
    revertCompaction: (id) => thread.runner.revertCompaction(id),
    rewind: (inputId, dryRun) => thread.runner.rewind(inputId, dryRun),
  };
}
