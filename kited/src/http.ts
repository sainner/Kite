/** HTTP 接口：本机监听信任回环客户端，远程监听只接受已核验组网身份的内部代理。事件流用 SSE。 */
import { KiteError, OperationError } from './errors.ts';
import type { EventScope } from './events.ts';
import { inScope } from './transcript/feed.ts';
import { z } from 'zod';
import type { Server } from 'bun';
import type { Kite } from './kite.ts';
import { operationCatalog } from './operations/contract.ts';
import { roleSelection } from './roles.ts';
import { agentDefinitionSchema } from './agents/definition.ts';
import type { Network } from './network.ts';
import { publisherConfig, type CatalogPublisher } from './catalog-publisher.ts';

async function body(req: Request): Promise<Record<string, unknown>> {
  try { return (await req.json()) as Record<string, unknown>; } catch { throw new KiteError('请求体不是 JSON'); }
}

const str = (v: unknown, name: string): string => {
  if (typeof v !== 'string') throw new KiteError(`缺少 ${name}`);
  return v;
};

/** 登记本机文件夹写 path；clone 远程写 remote，path 可选，默认放在 ~/code/<域名>/<owner>/<repo>。 */
const checkoutRequest = z.union([
  z.object({ path: z.string().min(1) }).strict(),
  z.object({ remote: z.string().trim().min(1).max(2048), path: z.string().min(1).optional() }).strict(),
]);

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

/** Git 网络操作和轻任务可能长时间没有响应数据，由各自的生命周期控制结束。 */
function long<R extends Request>(fn: (req: R) => Promise<Response>) {
  return (req: R, server: Server<undefined>) => {
    server.timeout(req, 0);
    return fn(req);
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
        ? { ...meta, type: 'catalog.snapshot', workspaces: kite.workspaces(), modelAccounts: kite.modelAccounts.current() ?? null }
        : 'workspaceId' in scope
          ? { ...meta, type: 'workspace.model', workspaceId: scope.workspaceId, model: kite.workspace(scope.workspaceId) }
          : { ...meta, type: 'thread.history', ...kite.historyNow(scope.threadId) };
      controller.enqueue(encode(initial));
      unsubscribe = kite.events.subscribe((e) => inScope(e, scope), (e) => controller.enqueue(encode(e)));
      // 额度不随客户端轮询：首次有客户端连上时查一次，之后靠会话响应和显式刷新推送。
      if (scope === 'catalog') kite.modelAccounts.ensure();
      heartbeat = setInterval(() => controller.enqueue(': \n\n'), 15_000);
      controller.enqueue(': connected\n\n');
    },
    cancel() { unsubscribe(); clearInterval(heartbeat); },
  });
  return new Response(stream, { headers: { 'content-type': 'text/event-stream', 'cache-control': 'no-cache' } });
}

/** 只监听回环地址仍挡不住 DNS 重绑定：网页换成同源后可读 /machine 再发请求，因此只接受回环主机名。 */
function local<R extends Request>(fn: (req: R) => Promise<unknown> | unknown) {
  return handle((req: R) => {
    let host = '';
    try { host = new URL(`http://${req.headers.get('host') ?? ''}`).hostname; } catch { /* 按非本机地址拒绝。 */ }
    if (host !== '127.0.0.1' && host !== 'localhost') throw new KiteError('只接受本机地址的请求', 403);
    return fn(req);
  });
}

export interface Listen {
  hostname: string;
  port: number;
  /** remote 监听要求内部代理凭据，不做本机主机名检查。 */
  remote?: boolean;
  /** 本机监听管理此设备的组网状态。 */
  network?: Network;
  publisher?: CatalogPublisher;
  /** 仅 kite-net 持有；代理已核验来源和本节点属于同一组网用户。 */
  proxyToken?: string;
}

export function serve(kite: Kite, listen: Listen) {
  // 代理负责同账号认证，工作机身份检查防止地址复用时操作错机器。
  const access = <R extends Request>(fn: (req: R) => Promise<unknown> | unknown) => listen.remote
    ? handle((req: R) => {
      if (!listen.proxyToken || req.headers.get('X-Kite-Network') !== listen.proxyToken) throw new KiteError('设备未通过组网认证', 401);
      return fn(req);
    })
    : local(fn);
  const bound = <R extends Request>(fn: (req: R) => Promise<unknown> | unknown) => access((req: R) => {
    const machine = req.headers.get('X-Kite-Machine');
    if (!machine) throw new KiteError('缺少 X-Kite-Machine，请先读取 /machine');
    if (machine !== kite.machine().id) throw new KiteError('连接地址对应的工作机已改变，请重新选择工作机', 409);
    return fn(req);
  });
  // 本机网络设置不对远程设备开放。
  const localOnly = <R extends Request>(fn: (req: R) => Promise<Response>) =>
    listen.remote ? handle<R>(() => { throw new KiteError('没有这个接口', 404); }) : fn;
  const network = () => {
    if (!listen.network) throw new KiteError('这个服务没有组网', 404);
    return listen.network;
  };
  return Bun.serve({
    hostname: listen.hostname,
    port: listen.port,
    idleTimeout: 60,
    routes: {
      '/catalog/account': {
        GET: localOnly(bound(() => listen.publisher?.status() ?? {})),
        PUT: localOnly(bound(async (req) => {
          if (!listen.publisher) throw new KiteError('此服务不支持目录上报', 404);
          const parsed = publisherConfig.safeParse(await body(req));
          if (!parsed.success) throw new KiteError('目录上报设置无效');
          await listen.publisher.configure(parsed.data);
          return listen.publisher.status();
        })),
      },
      '/network': {
        GET: localOnly(bound(() => network().status())),
        PUT: localOnly(bound(async (req) => {
          const parsed = z.object({ enabled: z.boolean() }).strict().safeParse(await body(req));
          if (!parsed.success) throw new KiteError('组网设置无效');
          return parsed.data.enabled ? network().enable() : network().disable();
        })),
      },
      '/network/account': { PUT: localOnly(bound(async (req) => {
        const config = z.object({ deviceId: z.uuid(), controlURL: z.url().startsWith('https://'), authKey: z.string().min(1) }).strict().safeParse(await body(req));
        if (!config.success) throw new KiteError('入网设置无效');
        return network().joinAccount(config.data);
      })) },
      '/machine': { GET: access(() => kite.machine()) },
      '/subscription-logins': { POST: bound(async (req) => {
        const parsed = z.object({ id: z.uuid(), provider: z.enum(['chatgpt', 'claude']) }).strict().safeParse(await body(req));
        if (!parsed.success) throw new KiteError('订阅登录请求无效');
        return Response.json(kite.subscriptionLogins.start(parsed.data.provider, parsed.data.id), { headers: { 'Cache-Control': 'no-store' } });
      }) },
      '/subscription-logins/:id': {
        GET: bound((req) => Response.json(kite.subscriptionLogins.get(req.params.id), { headers: { 'Cache-Control': 'no-store' } })),
        POST: bound(async (req) => { kite.subscriptionLogins.submit(req.params.id, str((await body(req)).code, 'code')); return { ok: true }; }),
        DELETE: bound(async (req) => { await kite.subscriptionLogins.cancel(req.params.id); return { ok: true }; }),
      },
      '/model-accounts': { GET: bound(async () => Response.json(kite.modelAccounts.current() ?? await kite.modelAccounts.refresh(), { headers: { 'Cache-Control': 'no-store' } })) },
      '/model-accounts/refresh': { POST: bound(async () => Response.json(await kite.modelAccounts.refresh(), { headers: { 'Cache-Control': 'no-store' } })) },
      '/instances/:id/agent-capabilities': { GET: bound((req) => kite.agentCapabilities(req.params.id)) },
      '/projects': {
        GET: bound(() => kite.projects()),
      },
      '/checkouts': {
        GET: bound((req) => kite.checkouts(new URL(req.url).searchParams.get('project') ?? undefined)),
        POST: long(bound(async (req) => {
          const parsed = checkoutRequest.safeParse(await body(req));
          if (!parsed.success) throw new KiteError('登记检出要写 path（本机文件夹）或 remote（远程地址）');
          return kite.registerCheckout(parsed.data);
        })),
      },
      '/checkouts/:id/sync': { GET: bound((req) => kite.checkoutSync(req.params.id)) },
      '/checkouts/:id/push': {
        POST: long(bound(async (req) => {
          const parsed = z.object({ message: z.string().max(10_000).optional() }).strict().safeParse(await body(req));
          if (!parsed.success) throw new KiteError('推送请求无效');
          return kite.pushCheckout(req.params.id, parsed.data.message);
        })),
      },
      '/workspaces': {
        GET: bound((req) => {
          // 聚合和游标在同一同步段读取；客户端可以跳过这份列表已覆盖的事件。
          const workspaces = kite.workspaces(new URL(req.url).searchParams.get('project') ?? undefined);
          return Response.json(workspaces, { headers: { 'X-Kite-Cursor': kite.events.cursor, 'Cache-Control': 'no-store' } });
        }),
        POST: bound(async (req) => {
          const b = await body(req);
          return kite.createWorkspace(str(b.checkout, 'checkout'), b.name === undefined ? '' : str(b.name, 'name'),
            b.prompt === undefined ? undefined : str(b.prompt, 'prompt'), roleSelection(b.role));
        }),
      },
      '/plugin-definitions': {
        GET: bound(() => kite.catalog.definitions()),
        POST: bound(async (req) => kite.catalog.install(await body(req))),
      },
      '/workspaces/:id/agent-options': { GET: bound((req) => kite.agentOptions(req.params.id)) },
      '/context-templates': { GET: bound(() => kite.contextTemplates.list()) },
      '/context-templates/:id': { PUT: bound(async (req) => {
        const b = await body(req);
        return kite.updateContextTemplate(req.params.id, str(b.expectedRevision, 'expectedRevision'), b.definition);
      }) },
      '/roles': {
        GET: bound(() => kite.roleCatalog()),
        POST: bound(async (req) => kite.createRole((await body(req)).role)),
      },
      '/roles/:id': { PUT: bound(async (req) => {
        const b = await body(req);
        return kite.updateRole(req.params.id, str(b.expectedRevision, 'expectedRevision'), b.role);
      }) },
      '/roles/:id/emblem': { PUT: bound(async (req) => kite.emblems.save(req.params.id, (await body(req)).emblem)) },
      '/roles/:id/emblem/generate': { POST: bound(async (req) => {
        const b = await body(req);
        return kite.emblems.generate(req.params.id, b.force === true);
      }) },
      '/workspaces/:id/plugin-instances': { POST: bound(async (req) => {
        const parsed = z.object({ id: z.uuid(), definitionId: z.string().min(1), title: z.string().trim().min(1).optional() }).strict().safeParse(await body(req));
        if (!parsed.success) throw new KiteError('插件实例请求无效');
        return kite.createPluginInstance(req.params.id, parsed.data.id, parsed.data.definitionId, parsed.data.title);
      }) },
      '/instances/:id/plugin/tools': { GET: bound((req) => kite.plugins.tools(req.params.id)) },
      '/instances/:id/plugin/views/:view': { GET: bound((req) => kite.plugins.view(req.params.id, req.params.view)) },
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
      '/threads/:id/title': {
        GET: bound((req) => kite.threadTitle(req.params.id)),
        PUT: bound(async (req) => {
          const revision = { expectedRevision: z.string().min(1) };
          const parsed = z.discriminatedUnion('mode', [
            z.object({ ...revision, mode: z.literal('auto') }).strict(),
            z.object({ ...revision, mode: z.literal('manual'), title: z.string().trim().min(1).max(80) }).strict(),
          ]).safeParse(await body(req));
          if (!parsed.success) throw new KiteError('标题设置无效');
          return kite.configureThreadTitle(req.params.id, parsed.data.expectedRevision, parsed.data);
        }),
      },
      '/threads/:id/state': { GET: bound((req) => kite.threadState(req.params.id)) },
      '/threads/:id/title/regenerate': { POST: long(bound(async (req) => {
        const parsed = z.object({ expectedRevision: z.string().min(1) }).strict().safeParse(await body(req));
        if (!parsed.success) throw new KiteError('标题重新生成请求无效');
        return kite.regenerateThreadTitle(req.params.id, parsed.data.expectedRevision);
      })) },
      '/instances/:id/agent-config': {
        GET: bound((req) => kite.agentConfig(req.params.id)),
        PUT: bound(async (req) => {
          const b = await body(req);
          return kite.configureAgent(req.params.id, str(b.expectedRevision, 'expectedRevision'), b.agent);
        }),
      },
      '/instances/:id/role': { PUT: bound(async (req) => {
        const b = await body(req);
        return kite.configureRole(req.params.id, str(b.expectedRevision, 'expectedRevision'), {
          id: str(b.roleId, 'roleId'), revision: str(b.roleRevision, 'roleRevision'),
        });
      }) },
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
          const choice = z.object({ model: agentDefinitionSchema.shape.model.optional(), tools: agentDefinitionSchema.shape.tools.optional(),
            maxRequestsPerTurn: agentDefinitionSchema.shape.maxRequestsPerTurn.optional() })
            .safeParse({ model: b.model, tools: b.tools, maxRequestsPerTurn: b.maxRequestsPerTurn });
          if (!choice.success) throw new KiteError('代理创建参数无效');
          return kite.createThread(req.params.id, str(b.prompt, 'prompt'), { ...choice.data, role: roleSelection(b.role) });
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
      '/threads/:id/compactions': { POST: bound(async (req) => {
        const parsed = z.object({ id: z.string().min(1), from: z.string().min(1), through: z.string().min(1) }).strict().safeParse(await body(req));
        if (!parsed.success) throw new KiteError('压缩请求无效');
        await kite.compact(req.params.id, parsed.data);
        return { ok: true };
      }) },
      '/threads/:id/compactions/:compaction': { DELETE: bound(async (req) => {
        await kite.revertCompaction(req.params.id, req.params.compaction);
        return { ok: true };
      }) },
      '/threads/:id/messages/:message/cancel': { POST: bound((req) => kite.cancel(req.params.id, req.params.message)) },
      '/workspaces/:id/snapshots': { GET: bound((req) => kite.snapshots(req.params.id)) },
      '/workspaces/:id/restore': {
        POST: bound(async (req) => kite.restore(req.params.id, str((await body(req)).commit, 'commit'))),
      },
      '/workspaces/:id/adopt': { POST: long(bound((req) => kite.adopt(req.params.id))) },
      '/instances/:id/archive': { POST: bound((req) => kite.archiveInstance(req.params.id)) },
      '/workspaces/:id/archive': { POST: bound(async (req) => kite.archiveWorkspace(req.params.id, (await body(req)).force === true)) },
      '/events': { GET: bound((req) => events(kite, eventScope(req.url))) },
    },
    fetch: () => Response.json({ error: '没有这个接口' }, { status: 404 }),
  });
}
