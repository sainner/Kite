/** kited 的执行入口：旧会话沿用 Claude，新会话由本地 harness 执行。 */
import { join } from 'node:path';
import { KiteError } from './errors.ts';
import type { KiteEvent } from './events.ts';
import { Runner, type RunnerState } from './runner.ts';
import type { Session } from './store.ts';
import { kiteTools } from './tools.ts';
import { readSubscriptionCredentials } from './harness/auth.ts';
import { ChatGPTModel } from './harness/chatgpt.ts';
import { openSessionHost, readSessionMetadata } from './harness/session-host.ts';
import { defaultContextDefinition } from './harness/context/project.ts';
import type { ContextDefinition } from './harness/context/types.ts';
import type { Input, Model, Phase } from './harness/types.ts';

export interface Runtime {
  readonly state: RunnerState | Phase;
  readonly busy: boolean;
  send(input: Input): Promise<void>;
  interrupt(): Promise<void>;
  shutdown(): Promise<void>;
  resume?(): Promise<void>;
  recover?(): Promise<void>;
}

export interface RuntimeOptions {
  /** 本地模型入口，可在集成测试中替换为可控模型流。 */
  model?(session: Session): Model;
}

export interface RuntimeEvents {
  emit(event: KiteEvent): void;
  label(text: string): void;
  snapshot(callIds: string[]): Promise<void>;
  idle(completed: boolean): void;
}

const worktreeContext: ContextDefinition = {
  ...defaultContextDefinition, id: 'kite.worktree', title: '工作树会话',
  blocks: [...defaultContextDefinition.blocks, {
    type: 'paragraph', id: 'worktree', title: '工作树边界', parts: [{
      type: 'text', text: '当前目录是 Kite 为这个会话创建的独立工作树，请在这里完成工作，不要切回主文件夹修改。Kite 在工具批次和回合结束后保存快照，由用户决定采纳或回退。不要自行删除工作树或会话分支。项目有 .kite/check 时通过 shell 执行检查。',
    }],
  }],
};

export async function openRuntime(s: Session, home: string, main: string, on: RuntimeEvents, options: RuntimeOptions): Promise<Runtime> {
  if (s.runtime === 'claude') {
    const runner = new Runner({
      cwd: s.worktree, nativeId: s.nativeId, title: s.title,
      tools: () => kiteTools({ main, worktree: s.worktree, checkLogs: join(home, 'sessions', s.id, 'checks'),
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
      interrupt: () => runner.interrupt(),
      async shutdown() {
        if (runner.busy) await runner.interrupt();
        await runner.shutdown();
      },
    };
  }
  if (s.runtime !== 'harness') throw new KiteError(`不支持的会话后端：${s.runtime}`, 409);
  const sessionDir = join(home, 'sessions', s.id);
  const saved = readSessionMetadata(sessionDir);
  const modelConfig = { model: saved?.modelConfig?.model ?? process.env.KITE_MODEL ?? 'gpt-6-sol', reasoning: saved?.modelConfig?.reasoning ?? 'medium' };
  const inputs = new Map<string, string>();
  const host = await openSessionHost({
    cwd: s.worktree, sessionDir, env: { ...process.env }, modelConfig, maxRequestsPerTurn: 50, startPaused: true,
    contextDefinition: worktreeContext,
    model: options.model?.(s) ?? new ChatGPTModel({
      ...modelConfig, sessionId: s.nativeId,
      credentials: () => readSubscriptionCredentials(join(home, 'auth', 'chatgpt', 'auth.json')),
    }),
    afterTools: (_turnId, ids) => on.snapshot(ids),
    afterTurn: () => on.snapshot([]),
    onEvent(event) {
      if (event.type === 'record') {
        const row = event.record;
        if (row.type === 'input.received') inputs.set(row.input.id, row.input.text);
        if (row.type === 'input.cancelled') inputs.delete(row.inputId);
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
    async send(input) {
      await host.runner.send(input);
      if (host.runner.state.phase === 'needs_recovery') on.emit({ type: 'harness', event: { type: 'state', state: host.runner.state } });
    },
    interrupt: () => host.runner.interrupt(), shutdown: () => host.close(),
    resume: async () => {
      if (host.runner.state.phase === 'needs_recovery') throw new KiteError('请先确认旧执行已停止，再恢复会话', 409);
      await host.runner.resume();
    },
    recover: () => host.confirmRecovery(),
  };
}
