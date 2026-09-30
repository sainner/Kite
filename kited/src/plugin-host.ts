/** 一个 MCP 连接只代表一个插件实例；身份、状态和工作区权限均由宿主绑定。 */
import { createHash } from 'node:crypto';
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import type { Client, JsonSchemaType, JsonSchemaValidator, Tool as McpTool } from '@modelcontextprotocol/client';
import { z } from 'zod';
import type { Kite } from './kite.ts';
import { KiteError } from './errors.ts';
import { OperationError } from './operations.ts';
import { processGroupAlive } from './harness/command.ts';
import type { startPluginProcess } from './plugin-process.ts';
import type { OperationCaller, OperationGrant } from './operation-contract.ts';
import { bindPluginTool, toolRevision, toolVisible, type PluginToolBinding } from './plugin-tools.ts';

const object = z.record(z.string(), z.unknown());
const stateSchema = z.object({ revision: z.string(), value: object }).strict();
const processMarkerSchema = z.object({ pid: z.number().int().min(2) }).strict();
type PluginProcess = Awaited<ReturnType<typeof startPluginProcess>>;
const revision = (value: unknown) => createHash('sha256').update(JSON.stringify(value)).digest('hex');

export class PluginHost {
  private processes = new Map<string, Promise<PluginProcess>>();
  private calls = new Map<string, Promise<unknown>>();
  private stopping = new Set<string>();
  private closingWorkspaces = new Set<string>();
  private closing = false;
  private validators = new Map<string, JsonSchemaValidator<unknown>>();
  constructor(private kite: Kite) {}

  private instance(id: string) {
    if (this.closing || this.stopping.has(id)) throw new KiteError('插件正在停止', 409);
    const instance = this.kite.store.instance(id);
    if (!instance) throw new KiteError('没有这个插件实例', 404);
    if (this.closingWorkspaces.has(instance.workspaceId)) throw new KiteError('工作区正在归档', 409);
    if (instance.status !== 'open' || this.kite.workspace(instance.workspaceId).workspace.status !== 'open') throw new KiteError('插件或工作区尚未打开', 409);
    const installed = this.kite.catalog.get(instance.definitionId);
    if (installed.runtime !== 'bun' || instance.config.packageRevision !== installed.revision) throw new KiteError('实例绑定的插件包与已安装内容不符', 409);
    return instance;
  }
  private marker(id: string) { return join(this.kite.home, 'sessions', id, 'plugin-process.json'); }
  private previousProcessAlive(id: string): boolean {
    const path = this.marker(id);
    if (!existsSync(path)) return false;
    const { pid } = processMarkerSchema.parse(JSON.parse(readFileSync(path, 'utf8')));
    if (processGroupAlive(pid)) return true;
    rmSync(path, { force: true });
    return false;
  }
  status(id: string): { phase: 'stopped' | 'running' | 'blocked' } {
    this.instance(id);
    if (this.processes.has(id)) return { phase: 'running' };
    return { phase: this.previousProcessAlive(id) ? 'blocked' : 'stopped' };
  }
  private async open(id: string): Promise<PluginProcess> {
    const { definitionId } = this.instance(id);
    const cached = this.processes.get(id);
    if (cached) {
      const connected = await cached;
      if (!connected.closed) return connected;
      await connected.close();
      if (this.processes.get(id) === cached) this.processes.delete(id);
      return this.open(id);
    }
    if (this.status(id).phase === 'blocked') throw new KiteError('上次插件进程仍未确认退出，请先检查工作机', 409);
    const opening = (async () => {
      const { startPluginProcess } = await import('./plugin-process.ts');
      this.instance(id);
      const connected = await startPluginProcess({ bundle: this.kite.catalog.package(definitionId).bundle,
        configure: (client) => this.configure(id, client),
        onProcess: (pid, active) => {
          if (active) {
            mkdirSync(join(this.kite.home, 'sessions', id), { recursive: true });
            writeFileSync(this.marker(id), JSON.stringify({ pid }), { mode: 0o600 });
          } else {
            rmSync(this.marker(id), { force: true });
            if (this.processes.get(id) === opening) this.processes.delete(id);
          }
        },
      });
      try { this.instance(id); } catch (error) { await connected.close(); throw error; }
      return connected;
    })();
    this.processes.set(id, opening);
    try { return await opening; }
    catch (error) { if (this.processes.get(id) === opening) this.processes.delete(id); throw error; }
  }
  private configure(id: string, client: Client): void {
    const state = () => { const value = object.parse(this.instance(id).state.plugin ?? {}); return { revision: revision(value), value }; };
    client.setRequestHandler('kite/state.get', { params: z.object({}).strict(), result: stateSchema }, async () => state());
    client.setRequestHandler('kite/state.replace', {
      params: z.object({ expectedRevision: z.string(), value: object }).strict(), result: stateSchema,
    }, async ({ expectedRevision, value }) => {
      const instance = this.instance(id);
      if (state().revision !== expectedRevision) throw new KiteError('插件状态版本已变化', 409);
      if (Buffer.byteLength(JSON.stringify(value)) > 1024 * 1024) throw new KiteError('插件状态超过 1 MiB');
      // 比较与写入在同一同步段完成；宿主数据库是唯一状态来源。
      this.kite.store.setInstanceState(id, { plugin: value });
      this.kite.bus.emit({ type: 'workspace.changed', workspaceId: instance.workspaceId, status: 'open' });
      return state();
    });
    client.setRequestHandler('kite/operation', {
      params: z.object({ name: z.string(), arguments: object }).strict(), result: z.object({ value: z.unknown() }).strict(),
    }, async (request, context) => {
      const instance = this.instance(id);
      return { value: await this.kite.operations.invoke({ kind: 'plugin', instanceId: id }, instance.workspaceId,
        request.name, request.arguments, context.mcpReq.signal) };
    });
  }
  private async listTools(process: PluginProcess, cancellation?: AbortSignal): Promise<{ tools: McpTool[] }> {
    const signal = AbortSignal.any([AbortSignal.timeout(5000), ...(cancellation ? [cancellation] : [])]);
    // SDK 已负责分页和页数上限；执行授权核验必须取新声明，不能相信插件给出的缓存期限。
    const { tools } = await process.client.listTools(undefined, { timeout: 5000, signal, cacheMode: 'refresh' });
    if (tools.length > 256) throw new KiteError('插件工具目录超过 256 项');
    if (new Set(tools.map((tool) => tool.name)).size !== tools.length) throw new KiteError('插件工具名称重复');
    return { tools };
  }
  async tools(id: string) { return this.listTools(await this.open(id)); }
  async resource(id: string, uri: string) { const process = await this.open(id); return process.client.readResource({ uri }, { timeout: 5000 }); }

  private async validator(tool: McpTool): Promise<JsonSchemaValidator<unknown>> {
    const key = toolRevision(tool);
    const cached = this.validators.get(key);
    if (cached) return cached;
    const { AjvJsonSchemaValidator } = await import('@modelcontextprotocol/client/validators/ajv');
    // 每份声明单独编译，避免不同插件的同名 $id 复用别人的 schema。
    const validate = new AjvJsonSchemaValidator().getValidator(tool.inputSchema as JsonSchemaType);
    if (tool.outputSchema) new AjvJsonSchemaValidator().getValidator(tool.outputSchema as JsonSchemaType);
    if (this.validators.size >= 256) this.validators.clear();
    this.validators.set(key, validate);
    return validate;
  }

  async bindings(grants: OperationGrant[]): Promise<PluginToolBinding[]> {
    const instances = new Map<string, Set<string>>();
    for (const grant of grants) if (grant.operation === 'plugin.call') {
      const names = instances.get(grant.instanceId) ?? new Set<string>();
      grant.tools.forEach((name) => names.add(name));
      instances.set(grant.instanceId, names);
    }
    const selected = await Promise.all([...instances].map(async ([id, names]) => {
      const { tools } = await this.tools(id);
      const bindings: PluginToolBinding[] = [];
      for (const name of names) {
        const tool = tools.find((tool) => tool.name === name);
        if (!tool || !toolVisible(tool, 'model')) throw new KiteError('插件未声明可供模型或其他插件调用的工具');
        if (tool.execution?.taskSupport === 'required') throw new KiteError('暂不支持必须作为 MCP task 执行的插件工具');
        await this.validator(tool);
        bindings.push(bindPluginTool(this.instance(id), tool));
      }
      return bindings;
    }));
    return selected.flat();
  }

  async call(caller: OperationCaller, id: string, name: string, operationId: string, args: Record<string, unknown>,
    signal: AbortSignal | undefined, check: () => void, binding?: PluginToolBinding): Promise<unknown> {
    this.instance(id);
    check();
    if (signal?.aborted) throw new OperationError('插件操作提交前已取消', 'cancelled');
    const actor = `${caller.kind === 'ui' ? 'ui' : `${caller.kind}:${caller.instanceId}`}:plugin:${id}`;
    const key = JSON.stringify([actor, operationId]);
    const request = JSON.stringify({ name, args });
    const saved = this.kite.store.operationReceipt(actor, operationId);
    if (saved) {
      if (saved.request !== request) throw new OperationError('operationId 已用于其他参数', 'denied');
      const active = this.calls.get(key);
      if (active) return active;
      if (saved.result === null) throw new OperationError('上次插件操作结果尚未确认；请查询状态，不能自动重放', 'unknown');
      const result = JSON.parse(saved.result);
      if (result.error) throw new OperationError(result.error, result.outcome, result.status);
      return result.value;
    }
    this.kite.store.beginOperation(actor, operationId, request);
    const execution = (async () => {
      let process: PluginProcess | undefined;
      let submitted = false;
      try {
        process = await this.open(id);
        const tool = (await this.listTools(process, signal)).tools.find((tool) => tool.name === name);
        if (!tool || !toolVisible(tool, caller.kind === 'ui' ? 'app' : 'model')) throw new OperationError('插件工具不存在或未向调用方开放', 'denied', 403);
        if (binding && (binding.packageRevision !== this.instance(id).config.packageRevision || binding.toolRevision !== toolRevision(tool))) {
          throw new OperationError('插件工具声明已变化，请重新授权；已有会话需要新建', 'denied');
        }
        const validation = (await this.validator(tool))(args);
        if (!validation.valid) throw new OperationError(`插件工具参数无效：${validation.errorMessage}`, 'denied', 400);
        this.instance(id);
        check();
        submitted = true;
        const result = await process.client.callTool({ name, arguments: args }, { timeout: 30_000, signal, toolDefinition: tool });
        this.kite.store.finishOperation(actor, operationId, { value: result });
        return result;
      } catch (error) {
        if (!submitted) {
          const failure = error instanceof OperationError ? error : signal?.aborted ? new OperationError('插件操作提交前已取消', 'cancelled')
            : new OperationError(`插件操作未提交：${String(error)}`, 'denied');
          this.kite.store.finishOperation(actor, operationId, { error: failure.message, outcome: failure.outcome, status: failure.status });
          throw failure;
        }
        let message = `插件操作结果尚未确认：${String(error)}`;
        // 只关闭这次调用使用的进程，不能让旧调用的迟到失败停止后来新建的执行器。
        try { await process?.close(); } catch (stopError) { message += `；${String(stopError)}`; }
        this.kite.store.finishOperation(actor, operationId, { error: message, outcome: 'unknown' });
        throw new OperationError(message, 'unknown');
      }
    })();
    this.calls.set(key, execution);
    try { return await execution; } finally { this.calls.delete(key); }
  }
  async stop(id: string): Promise<void> {
    this.stopping.add(id);
    const opening = this.processes.get(id);
    try {
      if (opening) {
        // 启动失败已在启动器内清理；成功启动的进程必须确认关闭。
        const connected = await opening.catch(() => undefined);
        await connected?.close();
        if (this.processes.get(id) === opening) this.processes.delete(id);
      } else if (this.previousProcessAlive(id)) throw new KiteError('上次插件进程仍存活，当前宿主不认领旧 PID；请先在工作机确认退出', 409);
    } finally { this.stopping.delete(id); }
  }
  async closeWorkspace(workspaceId: string): Promise<() => void> {
    this.closingWorkspaces.add(workspaceId);
    const release = () => { this.closingWorkspaces.delete(workspaceId); };
    try {
      const ids = this.kite.workspace(workspaceId).instances.filter((instance) => this.kite.catalog.get(instance.definitionId).runtime === 'bun').map((instance) => instance.id);
      await Promise.all(ids.map((id) => this.stop(id)));
      return release;
    } catch (error) { release(); throw error; }
  }
  async close(): Promise<void> {
    this.closing = true;
    await Promise.all([...this.processes.keys()].map((id) => this.stop(id)));
    await Promise.allSettled([...this.calls.values()]);
  }
}
