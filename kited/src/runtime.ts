/** kited 的执行入口：旧会话沿用 Claude，新会话由本地 harness 执行。 */
import { join } from 'node:path';
import { KiteError } from './errors.ts';
import type { RuntimeEvent } from './events.ts';
import { Runner, type RunnerState } from './runner.ts';
import type { PluginInstance, ThreadContext } from './model.ts';
import { kiteTools } from './tools.ts';
import { readSubscriptionCredentials } from './harness/auth.ts';
import { ChatGPTModel } from './harness/chatgpt.ts';
import { openThreadHost } from './harness/thread-host.ts';
import { harnessPolicy } from './harness/execution-policy.ts';
import { applyExecutionGrants, executionRevision, instanceExecutionGrants } from './execution-grants.ts';
import { projectContext } from './harness/context/project.ts';
import { agentRevision, instanceAgent } from './agent-definition.ts';
import { pluginDefinition } from './plugins.ts';
import type { OperationToolSelection } from './operations.ts';
import type { Input, Model, Phase, Recovery, StopRequest, ThreadNotification, Tool } from './harness/types.ts';

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
}

export interface RuntimeEvents {
  emit(event: RuntimeEvent): void;
  label(text: string): void;
  snapshot(callIds: string[]): Promise<void>;
  idle(completed: boolean): void;
}

export async function openRuntime(s: ThreadContext, home: string, main: string, on: RuntimeEvents, options: RuntimeOptions,
  currentThread: () => ThreadContext, notifications: (after: number) => ThreadNotification[],
  operations: { tools: Tool[]; prepare(instance: PluginInstance): OperationToolSelection }): Promise<Runtime> {
  const { id, nativeId, title, runtime, definitionId, workspace: { cwd, id: workspaceId } } = s;
  if (runtime === 'claude') {
    const runner = new Runner({
      cwd, nativeId, title,
      tools: () => kiteTools({ main, worktree: cwd, checkLogs: join(home, 'sessions', id, 'checks'),
        onCheck: (result) => on.emit({ type: 'check', result }) }),
    }, {
      message: (message) => on.emit({ type: 'sdk', message }),
      turnStart: (prompt, source) => on.label(source === 'system' ? '后台任务完成' : prompt),
      toolBatch: (input) => on.snapshot(input.tool_calls.map((call) => call.tool_use_id)),
      turnEnd: () => on.snapshot([]),
      idle: () => on.idle(true),
      state: (state, error) => on.emit({ type: 'runner', state, ...(error ? { error } : {}) }),
    });
    return {
      get state() { return runner.state; }, get busy() { return runner.busy; },
      async send(input) { runner.send({ text: input.text, human: input.source === 'human' }); },
      async interrupt() { await runner.interrupt(); return []; },
      async shutdown() {
        if (runner.busy) await runner.interrupt();
        await runner.shutdown();
      },
    };
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
