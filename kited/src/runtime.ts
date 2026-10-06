/** kited 的执行入口：Claude 与自研 harness 各自负责完整 agent 循环，共用 Kite 的能力。 */
import { join } from 'node:path';
import { KiteError } from './errors.ts';
import type { RuntimeEvent } from './events.ts';
import type { RunnerState } from './claude/runner.ts';
import { openClaudeHost } from './claude/host.ts';
import { assembleContext, restoreContext } from './harness/context/assembler.ts';
import { contextUpdateContext } from './harness/context/notifications.ts';
import type { PluginInstance, ThreadContext } from './model.ts';
import { readSubscriptionCredentials } from './harness/auth.ts';
import { ChatGPTModel } from './harness/chatgpt.ts';
import { openThreadHost } from './harness/thread-host.ts';
import { harnessPolicy } from './execution/policy.ts';
import { applyExecutionGrants, executionRevision, instanceExecutionGrants } from './execution/grants.ts';
import { projectContext } from './harness/context/project.ts';
import type { ContextDefinition } from './harness/context/types.ts';
import { agentRevision, instanceAgent } from './agents/definition.ts';
import { pluginDefinition } from './plugins/definitions.ts';
import type { OperationToolSelection } from './operations/operations.ts';
import type { Input, Model, Phase, Recovery, StopRequest, ThreadNotification, Tool } from './harness/types.ts';
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

export async function openRuntime(s: ThreadContext, home: string, main: string, on: RuntimeEvents, options: RuntimeOptions,
  currentThread: () => ThreadContext, notifications: (after: number) => ThreadNotification[],
  operations: { tools: Tool[]; prepare(instance: PluginInstance): OperationToolSelection },
  contextUpdateTemplate: () => ContextDefinition): Promise<Runtime> {
  const { id, nativeId, title, runtime, definitionId, workspace: { cwd, id: workspaceId } } = s;
  if (runtime === 'claude') {
    const basePolicy = await harnessPolicy({ cwd, env: process.env, home, repository: main });
    return openClaudeHost({ cwd, nativeId, title, directory: join(home, 'sessions', id), diffDir: join(home, 'diffs', workspaceId),
      policy: () => applyExecutionGrants(basePolicy, cwd, instanceExecutionGrants(currentThread())),
      prepare(afterNotification) {
        const current = currentThread();
        const agent = instanceAgent(current);
        const selected = operations.prepare(current);
        const operationNames = new Set(operations.tools.map((tool) => tool.name));
        const allowed = new Set([...agent.tools.filter((name) => !operationNames.has(name) || selected.allowed.has(name)),
          ...selected.plugins.filter((tool) => selected.allowed.has(tool.name)).map((tool) => tool.name)]);
        const updates = notifications(afterNotification);
        const instructions = assembleContext(projectContext(cwd, agent.context)).instructions;
        return { agent, instructions, contextUpdate: assembleContext(contextUpdateContext(instructions, contextUpdateTemplate())).instructions,
          tools: [...operations.tools, ...selected.plugins], allowed,
          notificationText: updates.map((notification) => restoreContext(notification.context).instructions).join('\n\n'),
          through: updates.at(-1)?.sequence ?? afterNotification };
      }, events: on,
    });
  }
  if (runtime !== 'harness') throw new KiteError(`不支持的会话后端：${runtime}`, 409);
  const threadDir = join(home, 'sessions', id);
  const declaredTools = new Set<string>(pluginDefinition(definitionId).agent!.tools);
  const inputs = new Map<string, string>();
  const operationNames = new Set(operations.tools.map((tool) => tool.name));
  const basePolicy = await harnessPolicy({ cwd, env: process.env, home, repository: main });
  const host = await openThreadHost({
    cwd, threadDir, diffDir: join(home, 'diffs', workspaceId), env: { ...process.env }, startPaused: true,
    policy: () => applyExecutionGrants(basePolicy, cwd, instanceExecutionGrants(currentThread())),
    prepareRequest(tools, { afterNotification }) {
      const current = currentThread();
      const execution = instanceExecutionGrants(current);
      const agent = instanceAgent(current);
      const allowed = new Set<string>(agent.tools);
      const { plugins, allowed: granted, sources } = operations.prepare(current);
      const declared = [...tools, ...operations.tools].filter((tool) => declaredTools.has(tool.name));
      return {
        model: options.model?.(current) ?? new ChatGPTModel({ ...agent.model, threadId: current.nativeId,
          credentials: () => readSubscriptionCredentials(join(home, 'auth', 'chatgpt', 'auth.json')) }),
        tools: [...declared.filter((tool) => allowed.has(tool.name) && (!operationNames.has(tool.name) || granted.has(tool.name))),
          ...plugins.filter((tool) => granted.has(tool.name))],
        toolDefinitions: [...declared, ...plugins].map(({ name, description, parameters }) => ({ name, description, parameters })),
        instructions: projectContext(current.workspace.cwd, agent.context),
        contextUpdateTemplate: contextUpdateTemplate(),
        settings: { model: agent.model, maxRequestsPerTurn: agent.maxRequestsPerTurn,
          execution: { grants: execution, revision: executionRevision(execution) },
          agent: { definitionId: current.definitionId, revision: agentRevision(agent) },
          pluginTools: sources },
        notifications: notifications(afterNotification),
      };
    },
    afterTools: (_turnId, ids) => on.snapshot(ids),
    afterTurn: () => on.snapshot([]),
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
    get state() { return host.runner.state.phase; }, get busy() { return host.runner.state.busy; },
    get recovery() { return host.runner.state.recovery; },
    send: (input) => host.runner.send(input),
    interrupt: (request) => host.runner.interrupt(request), shutdown: () => host.close(),
    resume: async () => {
      if (host.runner.state.recovery) throw new KiteError('请先确认旧执行已停止，再恢复会话', 409);
      await host.runner.resume();
    },
    recover: () => host.confirmRecovery(),
    cancel: (inputId) => host.runner.cancel(inputId),
  };
}
