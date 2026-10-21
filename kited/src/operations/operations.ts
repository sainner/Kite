/** 操作入口绑定调用身份，校验授权，再复用现有实例与线程服务。 */
import { createHash } from 'node:crypto';
import { z } from 'zod';
import { join } from 'node:path';
import { FileDiffStore } from '../workspace/file-diffs.ts';
import { KiteError, OperationError, operationError } from '../errors.ts';
import type { Kite } from '../kite.ts';
import { holds, type PluginInstance } from '../model.ts';
import { grantTools, operationContracts, operationGrantsSchema, scopedOperations, type GrantTargets, type OperationCaller, type OperationGrant, type OperationInput,
  type OperationName } from './contract.ts';
import { effectiveExecution, instanceExecutionChanges } from '../execution/grants.ts';
import { terminalDefinitionId } from '../terminal/terminals.ts';
import { findScript, mainlineScript } from '../terminal/scripts.ts';
import type { InputOrigin, JsonObject, Tool, ToolResult } from '../harness/types.ts';
import { WorkspaceFiles, fileSelection } from '../workspace/files.ts';
import { assertFileAccess, hostPrivatePaths } from '../execution/sandbox.ts';
import { instanceAgent } from '../agents/definition.ts';
import { defaultRoleId, instanceRole } from '../roles.ts';
import { pluginToolBindings, pluginToolGranted, pluginToolSource, type PluginToolBinding, type PluginToolSource } from '../plugins/tools.ts';

type OperationServices = Pick<Kite, 'store' | 'home' | 'catalog' | 'roles' | 'workspace' | 'plugins' | 'receipts' | 'threadState' | 'startAgent' | 'send' | 'reports' | 'waits' | 'interrupt' | 'resume' | 'mergeWorkspace' | 'selectFile'
  | 'monitors' | 'monitor' | 'archiveInstance' | 'lineInbox' | 'terminals' | 'approveScript'>;

export interface OperationToolSelection {
  plugins: Tool[];
  allowed: Set<string>;
  sources: PluginToolSource[];
}

const revision = (value: unknown) => createHash('sha256').update(JSON.stringify(value)).digest('hex');
const scoped = (name: OperationName) => (scopedOperations as readonly string[]).includes(name);
/** 超出后代范围时要用户批准的操作：协作范围里的写操作。 */
const confirmed = (name: OperationName) => scoped(name) && operationContracts[name].effect === 'write';
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

  grants(id: string): { grants: OperationGrant[]; revision: string } {
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
      if ('roleIds' in grant) for (const id of grant.roleIds) this.kite.roles.get(id);
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
    const workspace = this.kite.store.workspace(workspaceId);
    if (!workspace) throw new KiteError(`没有这个工作区：${workspaceId}`, 404);
    let target: PluginInstance | undefined;
    if (typeof args.instanceId === 'string') {
      target = this.kite.store.instance(args.instanceId) ?? undefined;
      // 协作操作还能对准子工作区里的实例，是否够得着再按授权的范围看，见 reaches。
      if (!target || (target.workspaceId !== workspaceId && !(scoped(name) && this.under(target.workspaceId, workspaceId)))) {
        throw new OperationError('工作区内没有这个目标实例', 'denied', 404);
      }
      if (!this.kite.catalog.get(target.definitionId).operations.includes(name)) throw new OperationError('目标实例未声明此操作', 'denied', 403);
      if (target.status !== 'open') throw new OperationError('目标实例已归档', 'denied');
      if (name === 'agent.merge' && this.kite.store.childLead(target.workspaceId) !== target.id) {
        throw new OperationError('只有用 isolation: workspace 开子工作区时建的那个代理可以合回；同一工作区的代理停下即可', 'denied', 409);
      }
    }
    if (caller.kind === 'ui') return;
    const source = this.kite.store.instance(caller.instanceId);
    if (!source || source.status !== 'open' || source.workspaceId !== workspaceId) throw new OperationError('调用方不属于此工作区或已归档', 'denied', 403);
    if (name.startsWith('files.') && typeof args.path === 'string') {
      const files = new WorkspaceFiles(workspace.cwd);
      try { assertFileAccess(files.resolve(args.path), 'read', { read: [files.root], write: [], network: [], denyRead: hostPrivatePaths(this.kite.home) }); }
      catch { throw new OperationError('插件不能读取宿主内部数据或工作区外文件', 'denied', 403); }
    }
    if (target?.id === source.id && name.startsWith('agent.')) throw new OperationError('实例不能通过协作操作控制自己', 'denied', 403);
    if (name === 'agent.merge' && target?.workspaceId === source.workspaceId) {
      throw new OperationError('合回要由父工作区里的代理发起，子工作区里的代理不能合回自己所在的子工作区', 'denied', 403);
    }
    if (name === 'agent.stop' && args.inputs !== undefined) throw new OperationError('只有界面可以核定未确认的用户输入', 'denied', 403);
    const grants = this.grants(source.id).grants;
    const granted = name === 'plugin.call'
      ? pluginToolGranted({ instanceId: target!.id, toolName: args.tool as string }, grants)
      : grants.some((grant) => {
        if (grant.operation !== name) return false;
        if ('roleIds' in grant) return grant.roleIds.includes((args.role as string | undefined) ?? defaultRoleId);
        // list 没有目标，范围决定列出哪些，见 listing。
        if ('targets' in grant) return !target || this.reaches(source, target, grant.targets);
        return true;
      });
    if (!granted) throw new OperationError('调用方未获准对该目标执行此操作', 'denied', 403);
  }

  /**
   * 发消息（含建代理时的首条消息）的来源：界面上用户发的是人；另一台工作机的 Line 照原文转达用户的话仍是人，带经由，它自己的说明是代理来信；
   * 模型调用是代理来信，插件发的按 Kite 来源。
   */
  private origin(caller: OperationCaller): InputOrigin {
    if (caller.kind === 'ui') {
      if (!caller.via) return { source: 'human' };
      return caller.relayed ? { source: 'human', via: caller.via } : { source: 'agent', from: caller.via };
    }
    const source = this.kite.store.instance(caller.instanceId);
    return source && this.agent(source) ? { source: 'agent', from: { kind: 'agent', instance: source.id, title: source.title } } : { source: 'kite' };
  }

  private agent(instance: PluginInstance): boolean { return !!this.kite.catalog.get(instance.definitionId).agent; }

  /** 目标沿创建来源往上能走到调用方，就是它的后代。 */
  private descendant(source: PluginInstance, target: PluginInstance): boolean {
    const seen = new Set<string>();
    for (let id = target.origin?.instanceId; id && !seen.has(id); id = this.kite.store.instance(id)?.origin?.instanceId) {
      if (id === source.id) return true;
      seen.add(id);
    }
    return false;
  }

  /** 工作区是 ancestor 下面某一层本机持有的子工作区。 */
  private under(workspaceId: string, ancestor: string): boolean {
    for (let w = this.kite.store.workspace(workspaceId); w?.parentId && holds(w); w = this.kite.store.workspace(w.parentId)) {
      if (w.parentId === ancestor) return true;
    }
    return false;
  }

  /** 子工作区里的只能经后代够到，见 docs/实例操作.md「子工作区」。 */
  private reaches(source: PluginInstance, target: PluginInstance, targets: GrantTargets): boolean {
    const same = target.workspaceId === source.workspaceId;
    switch (targets.kind) {
      case 'created': return target.origin?.instanceId === source.id;
      case 'instances': return same && targets.instanceIds.includes(target.id);
      case 'descendants': return this.descendant(source, target);
      case 'workspace': return same || this.descendant(source, target);
    }
  }

  /**
   * 一次 list 的筛选与每项共有的字段，调用方与开着的窗口只查一次。
   * 列出调用方够得着的实例：界面看这个工作区的全部，代理与插件按这项 list 授权的范围，含子工作区里的后代；workspaces 是要找的工作区。
   */
  private listing(caller: OperationCaller, workspaceId: string, name: 'agent.list' | 'monitor.list' | 'terminal.list') {
    const source = caller.kind === 'ui' ? undefined : this.kite.store.instance(caller.instanceId)!;
    const grant = source && this.grants(source.id).grants.find((grant) => grant.operation === name);
    const range = grant && 'targets' in grant ? grant.targets : undefined;
    const self = this.kite.store.workspace(workspaceId)!;
    const workspaces = source ? [self, ...this.kite.store.descendantWorkspaces(workspaceId)] : [self];
    const names = new Map(workspaces.map((w) => [w.id, w.name]));
    const windows = new Set(workspaces.flatMap((w) => this.kite.store.windows(w.id)).filter((window) => window.state === 'open').map((window) => window.target.instanceId));
    return {
      workspaces: workspaces.map((w) => w.id),
      visible: (target: PluginInstance) => !source || !!range && this.reaches(source, target, range),
      item: (instance: PluginInstance) => ({ instanceId: instance.id, title: instance.title, createdBy: instance.origin?.instanceId ?? null,
        createdAt: instance.createdAt, window: windows.has(instance.id),
        ...(instance.workspaceId !== workspaceId ? { workspace: { id: instance.workspaceId, name: names.get(instance.workspaceId) ?? '' } } : {}),
        operations: this.kite.catalog.get(instance.definitionId).operations.filter((operation) => {
          try { this.authorize(caller, workspaceId, operation, { instanceId: instance.id }); return true; } catch { return false; }
        }) }),
    };
  }

  /**
   * 超出后代范围的协作先在调用方线程上等用户批准：停下一律要；发消息、让它接着做，在对方的执行授权有调用方没有的项时要。
   * 界面上的操作是用户自己做的，不再问。
   */
  private async confirm(caller: OperationCaller, name: OperationName, args: Record<string, unknown>, signal?: AbortSignal): Promise<void> {
    if (caller.kind !== 'model' || !confirmed(name) || typeof args.instanceId !== 'string') return;
    const source = this.kite.store.instance(caller.instanceId)!;
    const target = this.kite.store.instance(args.instanceId)!;
    if (this.descendant(source, target)) return;
    const stop = name.endsWith('.stop');
    if (!stop && !this.exceeds(target, source)) return;
    const decision = await this.kite.waits.approve(source.id, {
      tool: operationContracts[name].tool!, target: `${target.title}（${target.id}）`, mustAsk: true,
      reason: stop ? '要停下的不是这个代理自己交代出去的，须经你批准' : '对方的执行授权比这个代理大，经它做事须经你批准',
    }, signal ?? new AbortController().signal);
    if (decision !== 'once' && decision !== 'remember') throw new OperationError('用户没有批准这次操作', 'denied', 403);
  }

  /** 对方的执行授权有调用方没有的项：工作区写入、额外读写路径、网络主机或沙箱外命令。 */
  private exceeds(target: PluginInstance, source: PluginInstance): boolean {
    const project = this.kite.store.workspaceConstraints(source.workspaceId)?.execution;
    const [theirs, mine] = [target, source].map((instance) => effectiveExecution(instanceExecutionChanges(instance), project).grants);
    const beyond = (items: string[], have: string[]) => items.some((item) => !have.includes(item));
    return (theirs!.workspace === 'write' && mine!.workspace === 'read') || beyond(theirs!.read, mine!.read) || beyond(theirs!.write, mine!.write)
      || beyond(theirs!.network, mine!.network) || beyond(theirs!.unsandboxed, mine!.unsandboxed);
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
    const run = async () => {
      await this.confirm(caller, name, args, signal);
      return contract.output.parse(await this.perform(caller, workspaceId, name, args, check, signal));
    };
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
        }, this.origin(caller), check);
      }
      case 'agent.list': {
        const listing = this.listing(caller, workspaceId, name);
        const reachable = listing.workspaces.flatMap((id) => this.kite.store.threads(id)).filter(listing.visible);
        const agents = await Promise.all(reachable.map(async (instance) => {
          const state = await this.kite.threadState(instance.id);
          const role = instanceRole(instance);
          return { ...listing.item(instance), definitionId: instance.definitionId,
            role: role ? { id: role.id, title: instanceAgent(instance).context.title } : null,
            presentation: instance.presentation, status: instance.status, phase: state.phase, busy: state.busy,
            waitingForResume: state.waitingForResume, recovery: state.recovery?.message ?? null,
            state: state.recovery ? `等确认恢复：${state.recovery.message}` : state.waiting ? '等用户批准'
              : state.phase === 'stopping' ? '正在停止' : state.busy ? '运行中'
              : state.lastOutcome?.kind === 'failed' ? `空闲，上一回合失败：${state.lastOutcome.message}` : '空闲' };
        }));
        check();
        return { agents };
      }
      case 'agent.send': {
        const input = args as OperationInput<'agent.send'>;
        return this.kite.send(input.instanceId, input.text, inputId(caller, input.operationId), this.origin(caller), check, input.attachments);
      }
      case 'agent.resume':
        await this.kite.resume(args.instanceId as string, check);
        return { ok: true };
      case 'agent.merge':
        return this.kite.mergeWorkspace(this.kite.store.instance(args.instanceId as string)!.workspaceId,
          { ...(caller.kind === 'ui' ? {} : { initiator: caller.instanceId }), check });
      case 'agent.stop': {
        const input = args as OperationInput<'agent.stop'>;
        // 只有正在跑的回合会因这次停止收尾；空闲时记下的停止方会落到之后无关的回合上。
        if ((await this.kite.threadState(input.instanceId)).busy) {
          this.kite.reports.stopping(input.instanceId, caller.kind === 'ui' ? { kind: caller.via ? 'line' : 'user' } : { kind: 'agent', instance: caller.instanceId });
        }
        // 代理和 Line 自己发去的消息退给它们；插件发的是 Kite 来源，不退。
        const by = caller.kind === 'model' ? { kind: 'agent' as const, instance: caller.instanceId } : caller.kind === 'ui' ? caller.via : undefined;
        return this.kite.interrupt(input.instanceId, { id: inputId(caller, input.operationId), inputs: input.inputs, ...(by ? { by } : {}) }, check);
      }
      case 'files.diff': return new FileDiffStore(join(this.kite.home, 'diffs', workspaceId)).read(args.diffId as string);
      case 'files.state': return fileSelection(this.kite.store.instance(args.instanceId as string)!.state);
      case 'files.select': return this.kite.selectFile(args as OperationInput<'files.select'>, check);
      case 'files.list':
      case 'files.search':
      case 'files.read': {
        try {
          const files = new WorkspaceFiles(this.kite.workspace(workspaceId).workspace.cwd);
          if (name === 'files.search') return await files.search(args.query as string, args.limit as number);
          return name === 'files.list' ? files.list(args.path as string, args.offset as number, args.limit as number)
            : files.read(args as OperationInput<'files.read'>);
        } catch (error) {
          if (error instanceof KiteError) throw error;
          throw new KiteError(`读取文件失败：${error instanceof Error ? error.message : String(error)}`);
        }
      }
      case 'monitor.start': {
        if (caller.kind === 'ui') throw new OperationError('monitor 由代理开启，唤醒的是开启它的代理', 'denied', 403);
        const input = args as OperationInput<'monitor.start'>;
        const timed = input.at !== undefined || input.minutes !== undefined;
        if ((input.command === undefined) === !timed || (input.at !== undefined && input.minutes !== undefined)) {
          throw new OperationError('来源要写 command，或者 at、minutes 中的一个', 'denied', 400);
        }
        if (input.repeat && !timed) throw new OperationError('repeat 只用于定时', 'denied', 400);
        let at: number | undefined;
        if (timed) {
          at = input.minutes !== undefined ? Date.now() + input.minutes * 60_000 : Date.parse(input.at!);
          if (!Number.isFinite(at)) throw new OperationError('at 不是有效的时间，要写带时区的 ISO 8601', 'denied', 400);
          if (at <= Date.now()) throw new OperationError('at 要晚于现在', 'denied', 400);
          if (at > Date.now() + 366 * 24 * 3_600_000) throw new OperationError('最多约一年以内的时刻', 'denied', 400);
        }
        check();
        return this.kite.monitors.create(workspaceId, {
          instanceId: caller.instanceId, operationId: input.operationId, ...(caller.kind === 'model' ? { turnId: caller.turnId, callId: caller.callId } : {}),
        }, { title: input.title, ...(input.command !== undefined ? { command: input.command } : { at: at!, ...(input.repeat ? { repeat: input.repeat } : {}) }) });
      }
      case 'terminal.run': {
        const input = args as OperationInput<'terminal.run'>;
        const { workspace, checkout } = this.kite.workspace(workspaceId);
        if (workspace.status !== 'open') throw new OperationError('工作区尚未打开', 'denied', 409);
        const script = findScript(workspace.cwd, input.script);
        // 用户起的直接运行；代理和插件起的与这台工作机检出主线上的同名文件一致才直接运行，不一致时代理的经审批，插件的拒绝。
        if (caller.kind !== 'ui') {
          const main = await mainlineScript(checkout, script.name);
          if (main !== script.content) {
            if (caller.kind !== 'model') throw new OperationError('插件只能起与主线一致的预置脚本', 'denied', 403);
            const approved = await this.kite.approveScript(caller.instanceId, { name: script.name, content: script.content,
              reason: main === null ? '主线上没有这个脚本，批准后在沙箱外运行' : '脚本与主线上的不一致，批准后在沙箱外运行' }, signal ?? new AbortController().signal);
            if (!approved) throw new OperationError('没有获准运行这个预置脚本', 'denied', 403);
          }
        }
        check();
        return this.kite.terminals.runScript(workspaceId, script, { restart: input.restart, origin: caller.kind === 'ui' ? undefined
          : { instanceId: caller.instanceId, operationId: input.operationId, turnId: caller.turnId, callId: caller.callId } }, signal);
      }
      case 'terminal.read': {
        const input = args as OperationInput<'terminal.read'>;
        return this.kite.terminals.read(input.instanceId, input.offset, input.limit);
      }
      case 'terminal.select': {
        check();
        const input = args as OperationInput<'terminal.select'>;
        return this.kite.terminals.selectPort(input.instanceId, input.port);
      }
      case 'terminal.stop': {
        check();
        const target = this.kite.store.instance(args.instanceId as string)!;
        const owner = caller.kind !== 'ui' && target.origin?.instanceId === caller.instanceId;
        await this.kite.terminals.stop(target.id, caller.kind === 'ui' ? '已在界面上停止' : owner ? '代理自己停下了这个命令' : '另一个代理停下了这个终端', owner);
        return { ok: true };
      }
      case 'monitor.list': {
        const listing = this.listing(caller, workspaceId, name);
        return { monitors: listing.workspaces.flatMap((id) => this.kite.monitors.list(id)).flatMap((summary) => {
          const instance = this.kite.store.instance(summary.instanceId)!;
          return listing.visible(instance) ? [{ ...summary, ...listing.item(instance) }] : [];
        }) };
      }
      case 'terminal.list': {
        const listing = this.listing(caller, workspaceId, name);
        return { terminals: listing.workspaces.flatMap((id) => this.kite.store.instances(id))
          .filter((instance) => instance.definitionId === terminalDefinitionId && instance.status === 'open' && listing.visible(instance))
          .map((instance) => ({ ...this.kite.terminals.describe(instance), ...listing.item(instance) })) };
      }
      case 'monitor.stop':
        check();
        await this.kite.archiveInstance(args.instanceId as string);
        return { ok: true };
      case 'monitor.read': {
        const instance = this.kite.store.instance(args.instanceId as string)!;
        return this.kite.lineInbox()?.id === instance.id ? this.kite.monitor.inbox() : this.kite.monitors.read(instance);
      }
      case 'monitor.delegate':
      case 'monitor.dismiss':
      case 'monitor.hosting': {
        if (this.kite.lineInbox()?.id !== args.instanceId) throw new OperationError('只有 Line 的收件箱有这个操作', 'denied', 409);
        check();
        if (name === 'monitor.delegate') return this.kite.monitor.delegate(args.item as string);
        if (name === 'monitor.dismiss') { this.kite.monitor.dismiss(args.item as string); return { ok: true }; }
        const input = args as OperationInput<'monitor.hosting'>;
        const current = this.kite.monitor.delegation();
        const until = input.until === undefined ? current.until : input.until ?? undefined;
        const timeoutMinutes = input.timeoutMinutes === undefined ? current.timeoutMinutes : input.timeoutMinutes ?? undefined;
        return this.kite.monitor.configureDelegation({ ...(until !== undefined ? { until } : {}), ...(timeoutMinutes !== undefined ? { timeoutMinutes } : {}) });
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
        .filter(([key]) => key !== 'operationId' && key !== 'inputs' && key !== 'attachments'))).strict();
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
    const allowed = new Set([...grants.flatMap(grantTools), ...bindings.map((binding) => binding.modelName)]);
    return { plugins: this.pluginTools(instance.id, instance.workspaceId, bindings), allowed, sources: bindings.map(pluginToolSource) };
  }

  private pluginTools(instanceId: string, workspaceId: string, bindings: PluginToolBinding[]): Tool[] {
    return bindings.map(({ modelName, description, parameters, instanceId: targetId, toolName }) => ({
      name: modelName, description, parameters, deferred: { group: targetId },
      validate(value) { parse(pluginArguments, value); },
      execute: (value, context) => this.invokeModel(instanceId, workspaceId, 'plugin.call', {
        instanceId: targetId, tool: toolName, arguments: value,
      }, context),
    }));
  }
}
