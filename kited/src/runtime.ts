/** kited 的执行入口：Claude 与自研 harness 各自负责完整 agent 循环，共用 Kite 的能力。 */
import { join } from 'node:path';
import type { AccountClient } from './account-client.ts';
import { KiteError } from './errors.ts';
import type { RuntimeEvent } from './events.ts';
import type { RunnerState } from './claude/runner.ts';
import { openClaudeHost } from './claude/host.ts';
import { assembleContext, restoreContext } from './harness/context/assembler.ts';
import { contextUpdateContext } from './harness/context/notifications.ts';
import type { PluginInstance, ThreadContext } from './model.ts';
import { readSubscriptionCredentials } from './harness/auth.ts';
import { CHATGPT_CONTEXT_WINDOW, ChatGPTModel } from './harness/chatgpt.ts';
import { openThreadHost } from './harness/thread-host.ts';
import { harnessPolicy } from './execution/policy.ts';
import { applyExecutionGrants, executionRevision, instanceExecutionGrants } from './execution/grants.ts';
import { projectContext } from './harness/context/project.ts';
import type { ContextDefinition } from './harness/context/types.ts';
import { agentRevision, instanceAgent } from './agents/definition.ts';
import { pluginDefinition } from './plugins/definitions.ts';
import type { OperationToolSelection } from './operations/operations.ts';
import type { CompactionRequest, Input, Model, Phase, Recovery, StopRequest, ThreadNotification, Tool } from './harness/types.ts';
import type { LightTaskOptions } from './light-tasks.ts';

export interface Runtime {
  readonly state: RunnerState | Phase;
  readonly busy: boolean;
  readonly recovery?: Recovery;
  send(input: Input): Promise<void>;
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
}

export interface RuntimeEvents {
  emit(event: RuntimeEvent): void;
  label(text: string): void;
  snapshot(callIds: string[]): Promise<void>;
  idle(completed: boolean): void;
}

export interface RuntimeHost {
  home: string;
  account?: AccountClient;
  /** 检出主目录，用来解析 Git 元数据。 */
  repository: string;
  events: RuntimeEvents;
  options: RuntimeOptions;
  /** ChatGPT 订阅响应带回的额度。 */
  chatgptLimits?(headers: Headers): void;
  /** 每次请求重新读取，配置和授权变化在下一次请求生效。 */
  current(): ThreadContext;
  notifications(after: number): ThreadNotification[];
  operations: { tools: Tool[]; prepare(instance: PluginInstance): OperationToolSelection };
  contextUpdateTemplate(): ContextDefinition;
  compactionTemplates(): { compact: ContextDefinition; fileChanges: ContextDefinition };
  /** 两个时刻之间工作区的净文件变化。 */
  compactionFiles(range: { from: number; to: number }): Promise<string | undefined>;
}

/** 两个后端共用的工具筛选：agent 配置声明的工具中，操作工具还须获得授权；插件工具只看授权。 */
function selectTools(current: ThreadContext, operations: RuntimeHost['operations']) {
  const agent = instanceAgent(current);
  const selection = operations.prepare(current);
  const operationNames = new Set(operations.tools.map((tool) => tool.name));
  const configured = new Set<string>(agent.tools);
  const permitted = (name: string) => configured.has(name) && (!operationNames.has(name) || selection.allowed.has(name));
  const plugins = selection.plugins.filter((tool) => selection.allowed.has(tool.name));
  return { agent, selection, permitted, plugins };
}

export async function openRuntime(s: ThreadContext, host: RuntimeHost): Promise<Runtime> {
  const { home, events: on, options, operations } = host;
  const { id, nativeId, title, runtime, definitionId, project: { id: projectId }, workspace: { cwd, id: workspaceId } } = s;
  if (runtime !== 'claude' && runtime !== 'harness') throw new KiteError(`不支持的会话后端：${runtime}`, 409);
  const basePolicy = await harnessPolicy({ cwd, env: process.env, home, repository: host.repository });
  const policy = () => applyExecutionGrants(basePolicy, cwd, instanceExecutionGrants(host.current()));
  const account = host.account;
  const secrets = account ? {
    list: (signal: AbortSignal) => account.listSecrets(projectId, signal),
    resolve: (references: string[], signal: AbortSignal) => account.resolveSecrets(references, projectId, signal),
  } : undefined;
  const diffDir = join(home, 'diffs', workspaceId);
  if (runtime === 'claude') {
    return openClaudeHost({ cwd, nativeId, title, directory: join(home, 'sessions', id), diffDir, policy, secrets,
      prepare(afterNotification) {
        const { agent, permitted, plugins } = selectTools(host.current(), operations);
        const allowed = new Set([...agent.tools.filter(permitted), ...plugins.map((tool) => tool.name)]);
        const updates = host.notifications(afterNotification);
        const instructions = assembleContext(projectContext(cwd, agent.context)).instructions;
        return { agent, instructions, contextUpdate: assembleContext(contextUpdateContext(instructions, host.contextUpdateTemplate())).instructions,
          tools: [...operations.tools, ...plugins], allowed,
          notificationText: updates.map((notification) => restoreContext(notification.context).instructions).join('\n\n'),
          through: updates.at(-1)?.sequence ?? afterNotification };
      }, events: on,
      compaction: { templates: () => host.compactionTemplates(), files: (range) => host.compactionFiles(range) },
    });
  }
  const declaredTools = new Set<string>(pluginDefinition(definitionId).agent!.tools);
  const inputs = new Map<string, string>();
  const thread = await openThreadHost({
    cwd, threadDir: join(home, 'sessions', id), diffDir, env: { ...process.env }, startPaused: true, policy, secrets,
    prepareRequest(tools, { afterNotification }) {
      const current = host.current();
      const execution = instanceExecutionGrants(current);
      const { agent, selection, permitted, plugins } = selectTools(current, operations);
      const declared = [...tools, ...operations.tools].filter((tool) => declaredTools.has(tool.name));
      return {
        model: options.model?.(current) ?? new ChatGPTModel({ ...agent.model, threadId: current.nativeId,
          credentials: () => readSubscriptionCredentials(join(home, 'auth', 'chatgpt', 'auth.json')),
          observeLimits: host.chatgptLimits }),
        tools: [...declared.filter((tool) => permitted(tool.name)), ...plugins],
        toolDefinitions: [...declared, ...selection.plugins].map(({ name, description, parameters }) => ({ name, description, parameters })),
        instructions: projectContext(current.workspace.cwd, agent.context),
        contextUpdateTemplate: host.contextUpdateTemplate(),
        compactionTemplates: host.compactionTemplates(),
        settings: { model: agent.model, contextWindow: CHATGPT_CONTEXT_WINDOW, maxRequestsPerTurn: agent.maxRequestsPerTurn,
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
      if (event.type === 'state' && event.state.phase === 'idle') on.idle(event.state.lastOutcome?.kind === 'completed');
    },
  });
  return {
    get state() { return thread.runner.state.phase; }, get busy() { return thread.runner.state.busy; },
    get recovery() { return thread.runner.state.recovery; },
    send: (input) => thread.runner.send(input),
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
