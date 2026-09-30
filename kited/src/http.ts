/** HTTP 接口，只监听本机。事件流用 SSE。 */
import { KiteError } from './errors.ts';
import type { EventScope } from './events.ts';
import { inScope } from './transcript.ts';
import { z } from 'zod';
import type { Kite } from './kite.ts';
import type { Project, RuntimeKind } from './model.ts';
import { operationCatalog } from './operation-contract.ts';
import { OperationError } from './operations.ts';

async function body(req: Request): Promise<Record<string, unknown>> {
  try { return (await req.json()) as Record<string, unknown>; } catch { throw new KiteError('请求体不是 JSON'); }
}

const str = (v: unknown, name: string): string => {
  if (typeof v !== 'string') throw new KiteError(`缺少 ${name}`);
  return v;
};

function runtimeKind(value: unknown): RuntimeKind | undefined {
  if (value === undefined || value === 'harness' || value === 'claude') return value;
  throw new KiteError('runtime 必须是 harness 或 claude');
}

/** 跨工作机关联使用完整项目身份；名称只用于显示，不参与推断。 */
function projectIdentity(value: unknown): Project | undefined {
  if (value === undefined) return undefined;
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw new KiteError('project 必须是项目身份对象');
  const p = value as Record<string, unknown>;
  const id = str(p.id, 'project.id');
  const name = str(p.name, 'project.name');
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(id)) throw new KiteError('project.id 必须是 UUID');
  if (!name.trim()) throw new KiteError('项目名称不能为空');
  if (typeof p.createdAt !== 'number' || !Number.isSafeInteger(p.createdAt) || p.createdAt < 0) throw new KiteError('project.createdAt 必须是毫秒时间戳');
  return { id, name, createdAt: p.createdAt };
}

function handle<R extends Request>(fn: (req: R) => Promise<unknown> | unknown) {
  return async (req: R) => {
    try {
      const out = await fn(req);
      return out instanceof Response ? out : Response.json(out ?? { ok: true });
    } catch (e) {
      const status = e instanceof KiteError ? e.status : 500;
      return Response.json({ error: (e as Error).message, ...(e instanceof OperationError ? { outcome: e.outcome } : {}) }, { status });
    }
  };
}

/** 同一个事件发给几个订阅者时只序列化一次：工具结果可能很大。 */
type EventFrame = { type: string; cursor: string };
const encoded = new WeakMap<EventFrame, string>();
function encode(e: EventFrame): string {
  let text = encoded.get(e);
  if (text === undefined) {
    text = `id: ${e.cursor}\nevent: ${e.type}\ndata: ${JSON.stringify(e)}\n\n`;
    encoded.set(e, text);
  }
  return text;
}

function eventScope(url: string): EventScope {
  const params = new URL(url).searchParams;
  if (params.size === 0) return 'catalog';
  if (params.size !== 1) throw new KiteError('事件订阅只能选择一个工作区或线程');
  const [key, id] = [...params][0]!;
  if (!id.trim() || !['workspace', 'thread'].includes(key)) throw new KiteError('事件订阅使用非空的 workspace 或 thread');
  return key === 'workspace' ? { workspaceId: id } : { threadId: id };
}

async function events(kite: Kite, scope: EventScope): Promise<Response> {
  if (scope !== 'catalog') {
    if ('threadId' in scope) await kite.threadState(scope.threadId);
    else kite.workspace(scope.workspaceId);
  }
  let unsubscribe = () => {};
  let heartbeat: Timer | undefined;
  const stream = new ReadableStream<string>({
    start(controller) {
      // 首帧与订阅在同一同步段，重连总用当前快照替换旧副本。
      const meta = { version: 1, cursor: kite.events.cursor, at: Date.now() };
      const initial = scope === 'catalog'
        ? { ...meta, type: 'catalog.snapshot', workspaces: kite.workspaces() }
        : 'workspaceId' in scope
          ? { ...meta, type: 'workspace.model', workspaceId: scope.workspaceId, model: kite.workspace(scope.workspaceId) }
          : { ...meta, type: 'thread.history', ...kite.historyNow(scope.threadId) };
      controller.enqueue(encode(initial));
      unsubscribe = kite.events.subscribe((e) => inScope(e, scope), (e) => controller.enqueue(encode(e)));
      heartbeat = setInterval(() => controller.enqueue(': \n\n'), 15_000);
      controller.enqueue(': connected\n\n');
    },
    cancel() { unsubscribe(); clearInterval(heartbeat); },
  });
  return new Response(stream, { headers: { 'content-type': 'text/event-stream', 'cache-control': 'no-cache' } });
}

export function serve(kite: Kite, port: number) {
  // 身份检查只防止地址复用时操作错工作机；网络认证由远程接入层另行承担。
  const bound = <R extends Request>(fn: (req: R) => Promise<unknown> | unknown) => handle((req: R) => {
    const machine = req.headers.get('X-Kite-Machine');
    if (!machine) throw new KiteError('缺少 X-Kite-Machine，请先读取 /machine');
    if (machine !== kite.machine().id) throw new KiteError('连接地址对应的工作机已改变，请重新选择工作机', 409);
    return fn(req);
  });
  return Bun.serve({
    hostname: '127.0.0.1',
    port,
    idleTimeout: 60,
    routes: {
      '/machine': { GET: handle(() => kite.machine()) },
      '/projects': {
        GET: bound(() => kite.projects()),
      },
      '/checkouts': {
        GET: bound((req) => kite.checkouts(new URL(req.url).searchParams.get('project') ?? undefined)),
        POST: bound(async (req) => {
          const b = await body(req);
          return kite.registerCheckout(str(b.path, 'path'), projectIdentity(b.project));
        }),
      },
      '/workspaces': {
        GET: bound((req) => {
          // 聚合和游标在同一同步段读取；客户端可以跳过这份列表已覆盖的事件。
          const workspaces = kite.workspaces(new URL(req.url).searchParams.get('project') ?? undefined);
          return Response.json(workspaces, { headers: { 'X-Kite-Cursor': kite.events.cursor, 'Cache-Control': 'no-store' } });
        }),
        POST: bound(async (req) => {
          const b = await body(req);
          const runtime = runtimeKind(b.runtime);
          return kite.createWorkspace(str(b.checkout, 'checkout'), b.name === undefined ? '' : str(b.name, 'name'),
            b.prompt === undefined ? undefined : str(b.prompt, 'prompt'), runtime);
        }),
      },
      '/plugin-definitions': {
        GET: bound(() => kite.catalog.definitions()),
        POST: bound(async (req) => kite.catalog.install(await body(req))),
      },
      '/workspaces/:id/plugin-instances': { POST: bound(async (req) => {
        const parsed = z.object({ id: z.uuid(), definitionId: z.string().min(1), title: z.string().trim().min(1).optional() }).strict().safeParse(await body(req));
        if (!parsed.success) throw new KiteError('插件实例请求无效');
        return kite.createPluginInstance(req.params.id, parsed.data.id, parsed.data.definitionId, parsed.data.title);
      }) },
      '/instances/:id/plugin/tools': { GET: bound((req) => kite.plugins.tools(req.params.id)) },
      '/instances/:id/plugin/tools/:tool': { POST: bound(async (req) => {
        const parsed = z.object({ operationId: z.string().min(1), arguments: z.record(z.string(), z.unknown()) }).strict().safeParse(await body(req));
        if (!parsed.success) throw new KiteError('插件工具调用无效');
        const instance = kite.store.instance(req.params.id);
        if (!instance) throw new KiteError('没有这个插件实例', 404);
        return kite.operations.invoke({ kind: 'ui' }, instance.workspaceId, 'plugin.call', {
          instanceId: instance.id, tool: req.params.tool, ...parsed.data,
        }, req.signal);
      }) },
      '/instances/:id/plugin/resources': { GET: bound((req) =>
        kite.plugins.resource(req.params.id, str(new URL(req.url).searchParams.get('uri'), 'uri'))) },
      '/instances/:id/plugin/process': {
        GET: bound((req) => kite.plugins.status(req.params.id)),
        DELETE: bound(async (req) => { kite.plugins.status(req.params.id); await kite.plugins.stop(req.params.id); return { ok: true }; }),
      },
      '/operations': { GET: bound(() => operationCatalog()) },
      '/workspaces/:id/operations/:operation': { POST: bound(async (req) =>
        kite.operations.invoke({ kind: 'ui' }, req.params.id, req.params.operation, await body(req), req.signal)) },
      '/workspaces/:id': { GET: bound((req) => kite.workspace(req.params.id)) },
      '/threads/:id': { GET: bound((req) => kite.thread(req.params.id)) },
      '/instances/:id/agent-config': {
        GET: bound((req) => kite.agentConfig(req.params.id)),
        PUT: bound(async (req) => {
          const b = await body(req);
          return kite.configureAgent(req.params.id, str(b.expectedRevision, 'expectedRevision'), b.agent);
        }),
      },
      '/instances/:id/operation-grants': {
        GET: bound((req) => kite.operations.grants(req.params.id)),
        PUT: bound(async (req) => {
          const parsed = z.object({ expectedRevision: z.string().min(1), grants: z.unknown() }).strict().safeParse(await body(req));
          if (!parsed.success) throw new KiteError('授权修改请求无效');
          return kite.configureOperationGrants(req.params.id, parsed.data.expectedRevision, parsed.data.grants);
        }),
      },
      '/instances/:id/execution-grants': {
        GET: bound((req) => kite.executionGrants(req.params.id)),
        PUT: bound(async (req) => {
          const parsed = z.object({ expectedRevision: z.string().min(1), grants: z.unknown() }).strict().safeParse(await body(req));
          if (!parsed.success) throw new KiteError('执行授权修改请求无效');
          return kite.configureExecutionGrants(req.params.id, parsed.data.expectedRevision, parsed.data.grants);
        }),
      },
      '/workspaces/:id/threads': {
        POST: bound(async (req) => {
          const b = await body(req);
          const runtime = runtimeKind(b.runtime);
          return kite.createThread(req.params.id, str(b.prompt, 'prompt'), runtime);
        }),
      },
      '/workspaces/:id/windows': { POST: bound(async (req) => {
        const identity = z.string().trim().min(1);
        const parsed = z.object({ id: z.uuid(), content: z.discriminatedUnion('kind', [
          z.object({ kind: z.literal('create'), definitionId: identity }).strict(),
          z.object({ kind: z.literal('open'), instanceId: identity, viewId: identity }).strict(),
        ]) }).strict().safeParse(await body(req));
        if (!parsed.success) throw new KiteError('窗口请求无效');
        return kite.openWindow(req.params.id, parsed.data);
      }) },
      '/workspaces/:id/windows/:window': { DELETE: bound((req) => kite.closeWindow(req.params.id, req.params.window)) },
      '/threads/:id/history': { GET: bound((req) => kite.history(req.params.id)) },
      '/threads/:id/messages': {
        POST: bound(async (req) => {
          const b = await body(req);
          return kite.operations.invoke({ kind: 'ui' }, kite.thread(req.params.id).workspaceId, 'agent.send', {
            instanceId: req.params.id, text: str(b.text, 'text'), operationId: b.id === undefined ? crypto.randomUUID() : str(b.id, 'id'),
          }, req.signal);
        }),
      },
      '/threads/:id/interrupt': { POST: bound(async (req) => {
        const raw = await req.text();
        let data: unknown;
        try { data = raw ? JSON.parse(raw) : { id: crypto.randomUUID() }; }
        catch { throw new KiteError('请求体不是 JSON'); }
        const parsed = z.object({ id: z.string().min(1), inputs: z.array(z.object({
          id: z.string().min(1), text: z.string().min(1), source: z.enum(['human', 'kite']),
        })).optional() }).safeParse(data);
        if (!parsed.success) throw new KiteError('停止请求无效');
        return kite.operations.invoke({ kind: 'ui' }, kite.thread(req.params.id).workspaceId, 'agent.stop', {
          instanceId: req.params.id, operationId: parsed.data.id, inputs: parsed.data.inputs,
        }, req.signal);
      }) },
      '/threads/:id/resume': { POST: bound(async (req) => {
        const raw = await req.text();
        let data: unknown;
        try { data = raw ? JSON.parse(raw) : {}; } catch { throw new KiteError('请求体不是 JSON'); }
        const parsed = z.object({ operationId: z.string().min(1).optional() }).strict().safeParse(data);
        if (!parsed.success) throw new KiteError('继续请求无效');
        return kite.operations.invoke({ kind: 'ui' }, kite.thread(req.params.id).workspaceId, 'agent.resume', {
          instanceId: req.params.id, operationId: parsed.data.operationId ?? crypto.randomUUID(),
        }, req.signal);
      }) },
      '/threads/:id/recover': { POST: bound((req) => kite.recover(req.params.id)) },
      '/threads/:id/messages/:message/cancel': { POST: bound((req) => kite.cancel(req.params.id, req.params.message)) },
      '/workspaces/:id/snapshots': { GET: bound((req) => kite.snapshots(req.params.id)) },
      '/workspaces/:id/restore': {
        POST: bound(async (req) => kite.restore(req.params.id, str((await body(req)).commit, 'commit'))),
      },
      '/workspaces/:id/adopt': { POST: bound((req) => kite.adopt(req.params.id)) },
      '/threads/:id/archive': { POST: bound((req) => kite.archiveThread(req.params.id)) },
      '/workspaces/:id/archive': { POST: bound(async (req) => kite.archiveWorkspace(req.params.id, (await body(req)).force === true)) },
      '/events': { GET: bound((req) => events(kite, eventScope(req.url))) },
    },
    fetch: () => Response.json({ error: '没有这个接口' }, { status: 404 }),
  });
}
