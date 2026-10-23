/** kited 的执行入口：Claude 与自研 harness 各自负责完整 agent 循环，共用 Kite 的能力。 */
import { join } from 'node:path';
import type { AccountMachine } from './account-data/directory.ts';
import type { Credentials } from './account-data/credentials.ts';
import type { SecretRequest } from './secrets.ts';
import type { Candidate } from './account-data/directory.ts';
import { KiteError } from './errors.ts';
import type { RuntimeEvent } from './events.ts';
import type { RunnerState } from './claude/runner.ts';
import { openClaudeHost } from './claude/host.ts';
import { assembleContext, restoreContext } from './harness/context/assembler.ts';
import { contextUpdateContext } from './harness/context/notifications.ts';
import type { PluginInstance, ThreadContext } from './model.ts';
import type { ShellBackground, ShellOutside } from './execution/local-tools.ts';
import { harnessModel } from './harness/adapters.ts';
import { openThreadHost } from './harness/thread-host.ts';
import { agentPolicy, harnessPolicy } from './execution/policy.ts';
import { effectiveExecution, executionRevision, instanceExecutionChanges, type ProjectExecution } from './execution/grants.ts';
import { projectContext, SkillCatalog } from './harness/context/project.ts';
import { skillsBinding, type SkillSources } from './harness/context/skills.ts';
import { effectiveTools, threadVariables } from './context-variables.ts';
import type { ContextDefinition } from './harness/context/types.ts';
import { agentRevision, instanceAgent } from './agents/definition.ts';
import { agentTools } from './plugins/definitions.ts';
import type { OperationToolSelection } from './operations/operations.ts';
import { lineToolNames, operationToolNames } from './operations/contract.ts';
import type { CompactionRequest, Input, Model, Outcome, Phase, Recovery, StopRequest, ThreadNotification, Tool } from './harness/types.ts';
import type { UpdatesOptions } from './update/updates.ts';
import type { LightTaskOptions } from './light-tasks.ts';
import type { ProjectToolRule } from './roles.ts';
import { permittedTools } from './agents/tool-policy.ts';
import { searchTool } from './harness/tool-search.ts';
import { Attachments } from './workspace/attachments.ts';
import type { NetworkAsk } from './execution/command.ts';

export interface Runtime {
  readonly state: RunnerState | Phase;
  readonly busy: boolean;
  readonly recovery?: Recovery;
  /** skill 是 /名字 点选的 skill 收下时固定的正文（名字在 input.skill），见 InputMaterial。 */
  send(input: Input, skill?: string): Promise<boolean>;
  interrupt(request?: StopRequest): Promise<Input[]>;
  shutdown(): Promise<void>;
  resume?(): Promise<void>;
  recover?(): Promise<void>;
  cancel?(inputId: string): Promise<void>;
  compact?(request: CompactionRequest): Promise<void>;
  revertCompaction?(id: string): Promise<void>;
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
  compactionTemplates(): { compact: ContextDefinition; fileChanges: ContextDefinition };
  /** 两个时刻之间工作区的净文件变化。 */
  compactionFiles(range: { from: number; to: number }): Promise<string | undefined>;
  /** 所在项目的工具约束；每次请求和每次调用工具时读取，收紧即时生效。 */
  toolConstraint(): ProjectToolRule | undefined;
  /** 所在项目的执行授权基础与边界；每次请求和每次调用工具时读取，收紧对之后的命令生效。 */
  executionConstraint(): ProjectExecution | undefined;
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
}

/** 两个后端共用的工具筛选：agent 配置声明、经项目约束过滤后的有效工具，协作与 Line 的工具还须获得授权；插件工具只看授权。 */
function selectTools(current: ThreadContext, operations: RuntimeHost['operations'], constraint: ProjectToolRule | undefined) {
  const agent = instanceAgent(current);
  const selection = operations.prepare(current);
  const operationNames = new Set<string>([...operationToolNames, ...lineToolNames]);
  const effective = new Set(effectiveTools(agent, constraint));
  const permitted = (name: string) => effective.has(name) && (!operationNames.has(name) || selection.allowed.has(name));
  return { agent, selection, permitted, plugins: selection.plugins };
}

export async function openRuntime(s: ThreadContext, host: RuntimeHost): Promise<Runtime> {
  const { home, events: on, options, operations } = host;
  const { id, nativeId, title, runtime, project: { id: projectId }, workspace: { cwd, id: workspaceId } } = s;
  if (runtime !== 'claude' && runtime !== 'harness') throw new KiteError(`不支持的会话后端：${runtime}`, 409);
  const basePolicy = await harnessPolicy({ cwd, env: process.env, home, repository: host.repository });
  // 两个宿主在请求边界刷新它；工具、沙箱放行和这里给代理的清单用同一份。
  const skills = new SkillCatalog(cwd, host.skills);
  const variables = (current: ThreadContext) => ({ ...threadVariables(current, host.toolConstraint(), host.executionConstraint(), host.skills),
    'project.skills': () => skillsBinding(skills.skills) });
  const policy = () => agentPolicy(basePolicy, cwd, instanceExecutionChanges(host.current()), host.executionConstraint(), host.secretFiles());
  const credentials = host.credentials;
  const secrets = credentials ? {
    list: async () => credentials.available(projectId),
    resolve: (references: string[]) => credentials.resolve(references, projectId),
    request: (request: SecretRequest, signal: AbortSignal) => host.requestSecret(request, signal),
    withdraw: (id: string) => host.withdrawSecret(id),
  } : undefined;
  const diffDir = join(home, 'diffs', workspaceId);
  const attachments = new Attachments(home);
  const images = (input: Input) => input.source === 'human' && input.attachments ? attachments.images(workspaceId, input.attachments) : [];
  if (runtime === 'claude') {
    return openClaudeHost({ cwd, nativeId, title, directory: join(home, 'sessions', id), diffDir, policy, secrets, askNetwork: host.askNetwork, images, skills,
      ...(host.background ? { background: host.background } : {}),
      ...(host.outside ? { outside: host.outside } : {}),
      prepare(afterNotification) {
        const current = host.current();
        const { agent, permitted, plugins } = selectTools(current, operations, host.toolConstraint());
        const allowed = new Set([...agent.tools.filter(permitted), ...plugins.map((tool) => tool.name)]);
        const updates = host.notifications(afterNotification);
        const values = variables(current);
        const instructions = assembleContext(projectContext(agent.context, values)).instructions;
        return { agent, instructions, contextUpdate: assembleContext(contextUpdateContext(instructions, values, host.contextUpdateTemplate())).instructions,
          tools: [...operations.tools, ...plugins], allowed,
          notificationText: updates.map((notification) => restoreContext(notification.context).instructions).join('\n\n'),
          through: updates.at(-1)?.sequence ?? afterNotification };
      }, events: on,
      compaction: { templates: () => host.compactionTemplates(), files: (range) => host.compactionFiles(range),
        variables: () => variables(host.current()) },
    });
  }
  const inputs = new Map<string, string>();
  let busy = false;
  const thread = await openThreadHost({
    cwd, threadDir: join(home, 'sessions', id), diffDir, env: { ...process.env }, startPaused: true, policy, secrets, askNetwork: host.askNetwork, skills,
    ...(host.background ? { background: host.background } : {}),
    ...(host.outside ? { outside: host.outside } : {}),
    prepareRequest(tools, { afterNotification }) {
      const current = host.current();
      const execution = effectiveExecution(instanceExecutionChanges(current), host.executionConstraint()).grants;
      const { agent, selection, permitted, plugins } = selectTools(current, operations, host.toolConstraint());
      const values = variables(current);
      // 声明顺序取代理插件的工具目录，与实例配置一致。
      const available = [...tools, ...operations.tools];
      const declared = agentTools.flatMap((name) => available.find((tool) => tool.name === name) ?? []);
      const { model, contextWindow } = harnessModel(agent.model, { threadId: current.nativeId, chatgptAuth: join(home, 'auth', 'chatgpt', 'auth.json'),
        ...(credentials ? { apiKeys: () => credentials.apiKeys() } : {}), ...(host.chatgptLimits ? { observeLimits: host.chatgptLimits } : {}) });
      // 插件工具不进声明，经 tool_search 按实例加载；搜得到的是此刻获准的。
      const search = searchTool(plugins);
      return {
        model: options.model?.(current) ?? model,
        tools: [...declared.filter((tool) => permitted(tool.name)), search, ...plugins],
        // 请求发出后项目约束收紧时，这次请求里的调用也在执行前拦下；依赖的工具被禁，它也拦下。
        blocked: (name) => {
          const constraint = host.toolConstraint();
          return (agentTools as readonly string[]).includes(name) && !permittedTools(agentTools, constraint ? [constraint] : []).includes(name)
            ? `项目约束已禁用 ${name}` : undefined;
        },
        toolDefinitions: [...declared, search].map(({ name, description, parameters }) => ({ name, description, parameters })),
        instructions: projectContext(agent.context, values), variables: values,
        contextUpdateTemplate: host.contextUpdateTemplate(),
        compactionTemplates: host.compactionTemplates(),
        settings: { model: agent.model, contextWindow,
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
        if (was && !busy) on.idle(event.state.lastOutcome);
      }
    },
  });
  return {
    get state() { return thread.runner.state.phase; }, get busy() { return thread.runner.state.busy; },
    get recovery() { return thread.runner.state.recovery; },
    send: (input, skill) => thread.runner.send(input, { images: images(input), ...(skill ? { skill } : {}) }),
    interrupt: (request) => thread.runner.interrupt(request), shutdown: () => thread.close(),
    resume: async () => {
      if (thread.runner.state.recovery) throw new KiteError('请先确认旧执行已停止，再恢复会话', 409);
      await thread.runner.resume();
    },
    recover: () => thread.confirmRecovery(),
    cancel: (inputId) => thread.runner.cancel(inputId),
    compact: (request) => thread.runner.compact(request),
    revertCompaction: (id) => thread.runner.revertCompaction(id),
  };
}
