/** 操作入口绑定调用身份，校验授权，再复用现有实例与线程服务。 */
import { createHash } from 'node:crypto';
import { z } from 'zod';
import { join } from 'node:path';
import { FileDiffStore } from '../workspace/file-diffs.ts';
import { KiteError, OperationError, operationError } from '../errors.ts';
import type { Kite } from '../kite.ts';
import type { PluginInstance } from '../model.ts';
import { operationContracts, operationGrantsSchema, type OperationCaller, type OperationGrant, type OperationInput, type OperationName } from './contract.ts';
import type { JsonObject, Tool, ToolResult } from '../harness/types.ts';
import { WorkspaceFiles, fileSelection } from '../workspace/files.ts';
import { assertFileAccess, hostPrivatePaths } from '../execution/sandbox.ts';
import { pluginToolBindings, pluginToolGranted, pluginToolSource, type PluginToolBinding, type PluginToolSource } from '../plugins/tools.ts';

type OperationServices = Pick<Kite, 'store' | 'home' | 'catalog' | 'workspace' | 'plugins' | 'receipts' | 'threadState' | 'startAgent' | 'send' | 'interrupt' | 'resume' | 'selectFile'>;

export interface OperationToolSelection {
  plugins: Tool[];
  allowed: Set<string>;
  sources: PluginToolSource[];
}

const revision = (grants: OperationGrant[]) => createHash('sha256').update(JSON.stringify(grants)).digest('hex');
const parse = <T>(schema: z.ZodType<T>, value: unknown): T => {
  const result = schema.safeParse(value);
  if (!result.success) throw new OperationError(`操作参数无效：${result.error.issues.map((issue) => issue.message).join('；')}`, 'denied', 400);
  return result.data;
};
const callerKey = (caller: OperationCaller) => caller.kind === 'ui' ? 'ui' : `${caller.kind}:${caller.instanceId}`;
const inputId = (caller: OperationCaller, id: string) => caller.kind === 'ui' ? id : `${callerKey(caller)}:${id}`;
const pluginArguments = z.record(z.string(), z.unknown());

export class InstanceOperations {
  private active = new Set<Promise<unknown>>();
  private closing = false;
  constructor(private kite: OperationServices) {}

  grants(id: string) {
    const instance = this.kite.store.instance(id);
    if (!instance) throw new KiteError('没有这个实例', 404);
    const grants = parse(operationGrantsSchema, instance.config.grants ?? []);
    return { grants, revision: revision(grants) };
  }
  validateGrants(instance: PluginInstance, value: unknown): OperationGrant[] {
    const grants = parse(operationGrantsSchema, value);
    for (const grant of grants) {
      if (grant.operation === 'plugin.call') {
        const target = this.kite.store.instance(grant.instanceId);
        if (!target || target.status !== 'open' || target.workspaceId !== instance.workspaceId || this.kite.catalog.get(target.definitionId).runtime !== 'bun') {
          throw new KiteError('插件工具授权目标须是同一工作区内已打开的 Bun 插件实例');
        }
      }
      if ('definitionIds' in grant) for (const id of grant.definitionIds) {
        if (!this.kite.catalog.get(id).agent) throw new KiteError('只能授权创建 agent 定义');
      }
      if ('targets' in grant && grant.targets.kind === 'instances') for (const id of grant.targets.instanceIds) {
        const target = this.kite.store.instance(id);
        if (!target || target.workspaceId !== instance.workspaceId || (target.id === instance.id && grant.operation.startsWith('agent.'))
          || !this.kite.catalog.get(target.definitionId).operations.includes(grant.operation)) throw new KiteError('授权目标须在同一工作区内声明此操作；agent 不能通过协作操作控制自己');
      }
    }
    return grants;
  }

  /** 调用方由 HTTP 宿主或工具闭包提供，模型参数不能指定它。 */
  invoke(caller: OperationCaller, workspaceId: string, name: string, raw: unknown, signal?: AbortSignal): Promise<unknown> {
    const promise = this.dispatch(caller, workspaceId, name, raw, signal).catch((error) => { throw operationError(error); });
    this.active.add(promise);
    void promise.finally(() => this.active.delete(promise)).catch(() => {});
    return promise;
  }
  async close(): Promise<void> { this.closing = true; await Promise.allSettled([...this.active]); }

  private authorize(caller: OperationCaller, workspaceId: string, name: OperationName, args: Record<string, unknown>): void {
    if (this.closing) throw new OperationError('kited 正在关闭', 'denied', 503);
    if (caller.kind === 'model' && !operationContracts[name].tool && name !== 'plugin.call') throw new OperationError('此操作未向模型开放', 'denied', 403);
    this.kite.workspace(workspaceId);
    let target: PluginInstance | undefined;
    if (typeof args.instanceId === 'string') {
      target = this.kite.store.instance(args.instanceId) ?? undefined;
      if (!target || target.workspaceId !== workspaceId) throw new OperationError('工作区内没有这个目标实例', 'denied', 404);
      if (!this.kite.catalog.get(target.definitionId).operations.includes(name)) throw new OperationError('目标实例未声明此操作', 'denied', 403);
      if (target.status !== 'open') throw new OperationError('目标实例已归档', 'denied');
    }
    if (caller.kind === 'ui') return;
    const source = this.kite.store.instance(caller.instanceId);
    if (!source || source.status !== 'open' || source.workspaceId !== workspaceId) throw new OperationError('调用方不属于此工作区或已归档', 'denied', 403);
    if (name.startsWith('files.') && typeof args.path === 'string') {
      const files = new WorkspaceFiles(this.kite.workspace(workspaceId).workspace.cwd);
      try { assertFileAccess(files.resolve(args.path), 'read', { read: [files.root], write: [], network: [], denyRead: hostPrivatePaths(this.kite.home) }); }
      catch { throw new OperationError('插件不能读取宿主内部数据或工作区外文件', 'denied', 403); }
    }
    if (target?.id === source.id && name.startsWith('agent.')) throw new OperationError('实例不能通过协作操作控制自己', 'denied', 403);
    if (name === 'agent.stop' && args.inputs !== undefined) throw new OperationError('只有界面可以核定未确认的用户输入', 'denied', 403);
    const grants = this.grants(source.id).grants;
    const granted = name === 'plugin.call'
      ? pluginToolGranted({ instanceId: target!.id, toolName: args.tool as string }, grants)
      : grants.some((grant) => {
        if (grant.operation !== name) return false;
        if ('definitionIds' in grant) return grant.definitionIds.includes(args.definitionId as string);
        if ('targets' in grant) return target !== undefined && (grant.targets.kind === 'created'
          ? target.origin?.instanceId === source.id : grant.targets.instanceIds.includes(target.id));
        return true;
      });
    if (!granted) throw new OperationError('调用方未获准对该目标执行此操作', 'denied', 403);
  }

  private async dispatch(caller: OperationCaller, workspaceId: string, rawName: string, raw: unknown, signal?: AbortSignal): Promise<unknown> {
    if (!Object.hasOwn(operationContracts, rawName)) throw new OperationError('没有这个操作', 'denied', 404);
    const name = rawName as OperationName;
    const contract = operationContracts[name];
    const args = parse(contract.input as z.ZodType<Record<string, unknown>>, raw);
    const check = () => {
      if (signal?.aborted) throw new OperationError('操作提交前已取消', 'cancelled');
      this.authorize(caller, workspaceId, name, args);
    };
    check();
    const run = async () => contract.output.parse(await this.perform(caller, workspaceId, name, args, check, signal));
    // 消息和停止已有 journal 收据，直接复用，避免另记一份停止结果。
    if (contract.retry !== 'receipt') return run();
    return contract.output.parse(await this.kite.receipts.run({
      actor: callerKey(caller), id: args.operationId as string,
      request: JSON.stringify({ workspaceId, name, args }), execute: run,
    }));
  }

  private async perform(caller: OperationCaller, workspaceId: string, name: OperationName, args: Record<string, unknown>, check: () => void, signal?: AbortSignal): Promise<unknown> {
    switch (name) {
      case 'plugin.call': {
        const input = args as OperationInput<'plugin.call'>;
        const binding = caller.kind === 'ui' ? undefined : pluginToolBindings(this.kite.store.instance(caller.instanceId)!)
          .find((tool) => tool.instanceId === input.instanceId && tool.toolName === input.tool);
        if (caller.kind !== 'ui' && !binding) throw new OperationError('插件工具尚未登记', 'denied', 403);
        return this.kite.plugins.call(caller, input.instanceId, input.tool, input.operationId, input.arguments, signal, check, binding);
      }
      case 'agent.start': {
        const input = args as OperationInput<'agent.start'>;
        return this.kite.startAgent(workspaceId, input, caller.kind === 'ui' ? undefined : {
          instanceId: caller.instanceId, operationId: input.operationId, turnId: caller.turnId, callId: caller.callId,
        }, check);
      }
      case 'agent.list': {
        const agents = await Promise.all(this.kite.store.threads(workspaceId).map(async (instance) => {
          const state = await this.kite.threadState(instance.id);
          const operations = this.kite.catalog.get(instance.definitionId).operations.filter((operation) => {
            try { this.authorize(caller, workspaceId, operation, { instanceId: instance.id }); return true; } catch { return false; }
          });
          return { instanceId: instance.id, definitionId: instance.definitionId, title: instance.title,
            presentation: instance.presentation, status: instance.status, phase: state.phase, busy: state.busy,
            waitingForResume: state.waitingForResume, recovery: state.recovery?.message ?? null, operations };
        }));
        check();
        return { agents };
      }
      case 'agent.send': {
        const input = args as OperationInput<'agent.send'>;
        return this.kite.send(input.instanceId, input.text, inputId(caller, input.operationId), caller.kind === 'ui' ? 'human' : 'kite', check);
      }
      case 'agent.resume':
        await this.kite.resume(args.instanceId as string, check);
        return { ok: true };
      case 'agent.stop': {
        const input = args as OperationInput<'agent.stop'>;
        return this.kite.interrupt(input.instanceId, { id: inputId(caller, input.operationId), inputs: input.inputs }, check);
      }
      case 'files.diff': return new FileDiffStore(join(this.kite.home, 'diffs', workspaceId)).read(args.diffId as string);
      case 'files.state': return fileSelection(this.kite.store.instance(args.instanceId as string)!.state);
      case 'files.select': return this.kite.selectFile(args as OperationInput<'files.select'>, check);
      case 'files.list':
      case 'files.read': {
        try {
          const files = new WorkspaceFiles(this.kite.workspace(workspaceId).workspace.cwd);
          return name === 'files.list' ? files.list(args.path as string, args.offset as number, args.limit as number)
            : files.read(args as OperationInput<'files.read'>);
        } catch (error) {
          if (error instanceof KiteError) throw error;
          throw new KiteError(`读取文件失败：${error instanceof Error ? error.message : String(error)}`);
        }
      }
    }
  }

  private async invokeModel(instanceId: string, workspaceId: string, name: OperationName, args: Record<string, unknown>,
    context: Parameters<Tool['execute']>[1]): Promise<ToolResult> {
    if (!context.callId || !context.turnId) throw new Error('实例操作缺少宿主调用 ID');
    try {
      const result = await this.invoke({ kind: 'model', instanceId, turnId: context.turnId, callId: context.callId }, workspaceId, name,
        operationContracts[name].effect === 'read' ? args : { ...args, operationId: `${context.turnId}:${context.callId}` }, context.signal);
      const isError = name === 'plugin.call' && (result as { isError?: boolean }).isError;
      return { status: isError ? 'error' : 'success', output: JSON.stringify(result) };
    } catch (error) {
      const failure = operationError(error);
      const outcome = failure.outcome;
      return { status: outcome === 'unknown' ? 'unknown' : outcome === 'cancelled' ? 'not_executed' : 'error',
        output: JSON.stringify({ outcome, error: failure.message }) };
    }
  }

  /** 模型只看明确的工具名与 schema；operationId 取宿主的调用 ID。 */
  tools(instanceId: string): Tool[] {
    const workspaceId = this.kite.store.instance(instanceId)!.workspaceId;
    return Object.entries(operationContracts).flatMap(([name, contract]): Tool[] => {
      if (!contract.tool) return [];
      const schema = z.object(Object.fromEntries(Object.entries(contract.input.shape)
        .filter(([key]) => key !== 'operationId' && key !== 'inputs'))).strict();
      return [{
        name: contract.tool, description: contract.description, parameters: z.toJSONSchema(schema) as JsonObject,
        validate(value) { parse(schema, value); },
        execute: (value, context) => this.invokeModel(instanceId, workspaceId, name as OperationName, parse(schema, value), context),
      }];
    });
  }
  prepareTools(instance: PluginInstance): OperationToolSelection {
    const grants = parse(operationGrantsSchema, instance.config.grants ?? []);
    const bindings = pluginToolBindings(instance);
    const allowed = new Set([...grants.flatMap((grant) => {
      const tool = operationContracts[grant.operation].tool;
      return tool ? [tool] : [];
    }), ...bindings.filter((binding) => pluginToolGranted(binding, grants)).map((binding) => binding.modelName)]);
    return { plugins: this.pluginTools(instance.id, instance.workspaceId, bindings), allowed, sources: bindings.map(pluginToolSource) };
  }

  private pluginTools(instanceId: string, workspaceId: string, bindings: PluginToolBinding[]): Tool[] {
    return bindings.map(({ modelName, description, parameters, instanceId: targetId, toolName }) => ({
      name: modelName, description, parameters,
      validate(value) { parse(pluginArguments, value); },
      execute: (value, context) => this.invokeModel(instanceId, workspaceId, 'plugin.call', {
        instanceId: targetId, tool: toolName, arguments: value,
      }, context),
    }));
  }
}
