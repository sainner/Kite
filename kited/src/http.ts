/** HTTP 接口：本机监听信任回环客户端，远程监听只接受已核验组网身份的内部代理。事件流用 SSE，语音输入和终端用 WebSocket。 */
import { KiteError } from './errors.ts';
import type { EventScope } from './events.ts';
import { inScope } from './transcript/feed.ts';
import { z } from 'zod';
import type { Server, ServerWebSocket } from 'bun';
import type { Kite } from './kite.ts';
import { operationCatalog } from './operations/contract.ts';
import { inputSchema, inputVia } from './harness/input.ts';
import type { InputVia } from './harness/types.ts';
import { roleSelection } from './roles.ts';
import { agentDefinitionSchema } from './agents/definition.ts';
import { defaultAgentModel } from './agents/models.ts';
import { networkChannelSchema, type Network } from './network.ts';
import { changesSince } from './account-data/replication.ts';
import { credentialType } from './account-data/credentials.ts';
import { INTEGRATIONS } from './account-data/registry.ts';
import { tokenPrices } from './token-prices.ts';
import type { VoiceSocket } from './voice/sessions.ts';
import { requestedSize, type TerminalSocket } from './terminal/terminals.ts';
import { approvalModes } from './execution/grants.ts';
import { hostDirectory, WorkspaceFiles } from './workspace/files.ts';
import { fileContent } from './workspace/file-content.ts';
import { HANDOVER_NEEDS } from './environment.ts';
import type { Payload } from './update/updates.ts';

async function body(req: Request): Promise<Record<string, unknown>> {
  try { return (await req.json()) as Record<string, unknown>; } catch { throw new KiteError('请求体不是 JSON'); }
}

/** 可以不带请求体的接口：空的按 fallback 处理。 */
async function optionalBody(req: Request, fallback: unknown = {}): Promise<unknown> {
  const raw = await req.text();
  try { return raw ? JSON.parse(raw) : fallback; } catch { throw new KiteError('请求体不是 JSON'); }
}

const payload = (value: string): Payload => {
  if (value !== 'runtime' && value !== 'app') throw new KiteError('没有这份内容', 404);
  return value;
};

const str = (v: unknown, name: string): string => {
  if (typeof v !== 'string') throw new KiteError(`缺少 ${name}`);
  return v;
};

/** 添加项目的来源：远程地址，或这台工作机上的文件夹，二选一；addition 是添加时另带的集成方式与环境变量文件。 */
const projectSource = <T extends z.ZodRawShape>(addition: T) => z.union([
  z.object({ remote: z.string().trim().min(1).max(2048), ...addition }).strict(),
  z.object({ path: z.string().min(1), ...addition }).strict(),
]);
const projectAddition = projectSource({ integration: z.enum(INTEGRATIONS).optional(),
  envFiles: z.array(z.object({ path: z.string().min(1).max(512), value: z.string().optional(), from: z.string().min(1).max(4096).optional() }).strict()
    .refine((file) => file.value === undefined || file.from === undefined)).max(32).optional() });

function handle<R extends Request>(fn: (req: R) => Promise<unknown> | unknown) {
  return async (req: R) => {
    try {
      const out = await fn(req);
      return out instanceof Response ? out : Response.json(out ?? { ok: true });
    } catch (e) {
      return errorResponse(e);
    }
  };
}

function errorResponse(e: unknown) {
  const status = e instanceof KiteError ? e.status : 500;
  return Response.json({ error: (e as Error).message, ...(e instanceof KiteError ? e.details() : {}) }, { status });
}

/** 另一台工作机上的 Line 调用时在 X-Kite-Source 声明的来源；只记入输入，不参与授权，可信度等于调用方工作机。 */
function sourceOf(req: Request): InputVia | undefined {
  const raw = req.headers.get('X-Kite-Source');
  if (!raw) return undefined;
  let value: unknown;
  try { value = JSON.parse(raw); } catch { throw new KiteError('X-Kite-Source 不是 JSON'); }
  const parsed = inputVia.safeParse(value);
  if (!parsed.success) throw new KiteError('X-Kite-Source 无效');
  return parsed.data;
}

type SocketData = VoiceSocket | TerminalSocket;

/** Git 网络操作和轻任务可能长时间没有响应数据，由各自的生命周期控制结束。 */
function long<R extends Request>(fn: (req: R) => Promise<Response>) {
  return (req: R, server: Server<SocketData>) => {
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

/** device 是 App 所在设备，事件流连着才算在关注 Kite；其余参数选择范围。 */
function eventScope(url: string): EventScope {
  const params = new URL(url).searchParams;
  params.delete('device');
  if (params.size === 0) return 'catalog';
  if (params.size !== 1) throw new KiteError('事件订阅只能选择一个工作区或线程');
  const [key, id] = [...params][0]!;
  if (!id.trim() || !['workspace', 'thread'].includes(key)) throw new KiteError('事件订阅使用非空的 workspace 或 thread');
  return key === 'workspace' ? { workspaceId: id } : { threadId: id };
}

async function events(kite: Kite, scope: EventScope, device?: string): Promise<Response> {
  if (scope !== 'catalog') {
    if ('threadId' in scope) await kite.threadState(scope.threadId);
    else kite.workspace(scope.workspaceId);
  }
  if (device !== undefined && !device.trim()) throw new KiteError('device 不能为空');
  let unsubscribe = () => {};
  let disconnect = () => {};
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
      if (device) disconnect = kite.attention.connect(device);
    },
    cancel() { unsubscribe(); disconnect(); clearInterval(heartbeat); },
  });
  return new Response(stream, { headers: { 'content-type': 'text/event-stream', 'cache-control': 'no-cache' } });
}

/** 只监听回环地址仍挡不住 DNS 重绑定：网页换成同源后可读 /machine 再发请求，因此只接受回环主机名。 */
function checkLocal(req: Request) {
  let host = '';
  try { host = new URL(`http://${req.headers.get('host') ?? ''}`).hostname; } catch { /* 按非本机地址拒绝。 */ }
  if (host !== '127.0.0.1' && host !== 'localhost') throw new KiteError('只接受本机地址的请求', 403);
}

export interface Listen {
  hostname: string;
  port: number;
  /** remote 监听要求内部代理凭据，不做本机主机名检查。 */
  remote?: boolean;
  /** 本机监听管理此设备的组网状态。 */
  network?: Network;
  /** 仅 kite-net 持有；代理已核验来源和本节点属于同一组网用户。 */
  proxyToken?: string;
}

export function serve(kite: Kite, listen: Listen) {
  // 代理负责同账号认证，工作机身份检查防止地址复用时操作错机器。
  const checkAccess = (req: Request) => {
    if (!listen.remote) return checkLocal(req);
    if (!listen.proxyToken || req.headers.get('X-Kite-Network') !== listen.proxyToken) throw new KiteError('设备未通过组网认证', 401);
  };
  const checkMachine = (req: Request) => {
    const machine = req.headers.get('X-Kite-Machine');
    if (!machine) throw new KiteError('缺少 X-Kite-Machine，请先读取 /machine');
    if (machine !== kite.machine().id) throw new KiteError('连接地址对应的工作机已改变，请重新选择工作机', 409);
  };
  const access = <R extends Request>(fn: (req: R) => Promise<unknown> | unknown) => handle((req: R) => {
    checkAccess(req);
    return fn(req);
  });
  const bound = <R extends Request>(fn: (req: R) => Promise<unknown> | unknown) => access((req: R) => {
    checkMachine(req);
    return fn(req);
  });
  /**
   * 账号级数据的同步带着凭据明文，只给工作机：组网来的请求要出自目录里的一台工作机（按 kite-net 给的来源 IP 核对），
   * 本机监听的请求来自本机，本来就能读本机的数据。
   */
  const peerOnly = <R extends Request>(fn: (req: R) => Promise<unknown> | unknown) => bound(async (req: R) => {
    if (listen.remote && !(await kite.directory.verify(req.headers.get('X-Kite-Peer') ?? ''))) throw new KiteError('只有工作机能同步账号数据', 403);
    return fn(req);
  });
  /** 集成、同步这类工作区上的 Git 操作：请求体可以带 confirmRecovery，先确认恢复再做。 */
  const recoverable = (invalid: string, run: (id: string) => Promise<unknown>) => long(bound(async (req: Request & { params: { id: string } }) => {
    const parsed = z.object({ confirmRecovery: z.literal(true).optional() }).strict().safeParse(await optionalBody(req));
    if (!parsed.success) throw new KiteError(invalid);
    if (parsed.data.confirmRecovery) await kite.confirmWorkspaceRecovery(req.params.id);
    return run(req.params.id);
  }));
  /** 语音输入升级成 WebSocket，检查同 bound；thread 是正在输入的会话，新会话不带。 */
  const voice = (req: Request, server: Server<SocketData>) => {
    try {
      checkAccess(req);
      checkMachine(req);
      const thread = new URL(req.url).searchParams.get('thread') ?? undefined;
      if (thread !== undefined) kite.thread(thread);
      if (server.upgrade(req, { data: { kind: 'voice', thread } })) return undefined;
      throw new KiteError('语音输入需要 WebSocket 连接');
    } catch (e) {
      return errorResponse(e);
    }
  };
  /** 终端接入升级成 WebSocket，检查同 bound；协议见 terminal/terminals.ts。 */
  const terminal = (req: Request & { params: { id: string } }, server: Server<SocketData>) => {
    try {
      checkAccess(req);
      checkMachine(req);
      kite.terminals.check(req.params.id);
      const size = requestedSize(new URL(req.url).searchParams);
      if (server.upgrade(req, { data: { kind: 'terminal', instanceId: req.params.id, ...(size ? { size } : {}) } })) return undefined;
      throw new KiteError('终端需要 WebSocket 连接');
    } catch (e) {
      return errorResponse(e);
    }
  };
  /** 查看器按字节读取工作区文件，边界与文件操作相同；见 workspace/file-content.ts。 */
  const workspaceFile = (req: Request & { params: { id: string } }) => {
    const workspace = kite.store.workspace(req.params.id);
    if (!workspace) throw new KiteError(`没有这个工作区：${req.params.id}`, 404);
    return fileContent(req, new WorkspaceFiles(workspace.cwd), str(new URL(req.url).searchParams.get('path'), 'path'));
  };
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
      '/machines': { GET: bound(() => kite.directory.entries()) },
      '/project-registry': {
        GET: bound(() => kite.registry.list()),
        // 要访问远程、导入文件夹，请求不受空闲超时限制。
        POST: long(bound(async (req) => {
          const parsed = projectAddition.safeParse(await body(req));
          if (!parsed.success) throw new KiteError('添加项目要写 remote 或 path 中的一个，可带 integration 与 envFiles（每项 value 与 from 至多一个）');
          const { integration, envFiles, ...source } = parsed.data;
          return kite.addProject(source, { ...(integration ? { integration } : {}), ...(envFiles ? { envFiles } : {}) });
        })),
      },
      '/project-registry/check': { POST: long(bound(async (req) => {
        const parsed = projectSource({}).safeParse(await body(req));
        if (!parsed.success) throw new KiteError('检查要写 remote 或 path 中的一个');
        return kite.checkProject(parsed.data);
      })) },
      '/host-files': { GET: bound((req) => {
        const query = new URL(req.url).searchParams;
        const number = (name: string) => { const n = Number(query.get(name) ?? NaN); return Number.isInteger(n) && n >= 0 ? n : undefined; };
        return hostDirectory(query.get('path'), number('offset'), number('limit'));
      }) },
      // 本机要先停下这个项目的线程、回收工作树，请求不受空闲超时限制。
      '/project-registry/:id': { DELETE: long(bound(async (req) => { await kite.deleteProject(req.params.id); return { ok: true }; })) },
      '/project-registry/:id/appearance': { PUT: bound(async (req) => kite.registry.setAppearance(req.params.id, await body(req))) },
      '/project-registry/:id/settings': { PUT: bound(async (req) => kite.registry.setSettings(req.params.id, await body(req))) },
      // 推送整个仓库可能很久，请求不受空闲超时限制。
      '/project-registry/:id/remote': { PUT: long(bound(async (req) => kite.setProjectRemote(req.params.id, str((await body(req)).remote, 'remote')))) },
      // 没有远程的项目，其他工作机从这里拉取本机检出（只读）。
      '/git/:project/info/refs': { GET: peerOnly((req) => kite.serveCheckout(req, req.params.project, '/info/refs')) },
      '/git/:project/git-upload-pack': { POST: long(peerOnly((req) => kite.serveCheckout(req, req.params.project, '/git-upload-pack'))) },
      '/project-registry/:id/constraints': {
        GET: bound((req) => kite.registry.constraints(req.params.id)),
        PUT: bound(async (req) => kite.registry.saveConstraints(req.params.id, await body(req))),
      },
      '/credentials': {
        GET: bound((req) => {
          const query = new URL(req.url).searchParams;
          const type = credentialType.optional().safeParse(query.get('type') ?? undefined);
          if (!type.success) throw new KiteError('凭据类型无效');
          return kite.credentials.list(type.data, query.get('projectId') || null);
        }),
        POST: bound(async (req) => Response.json(await kite.credentials.create(await body(req)), { status: 201 })),
      },
      '/credentials/:id': {
        PUT: bound(async (req) => kite.credentials.update(req.params.id, await body(req))),
        DELETE: bound((req) => { kite.credentials.delete(req.params.id); return { ok: true }; }),
      },
      '/git/github/device': { POST: bound(() => kite.github.start()) },
      '/git/github/device/:flow': { POST: bound((req) => kite.github.poll(req.params.flow)) },
      '/git/github/repos': { GET: bound(() => kite.github.repositories()) },
      '/sync/changes': { GET: long(peerOnly((req) => changesSince(kite.accountData, new URL(req.url).searchParams, req.signal))) },
      '/sync/conflicts': { GET: bound(() => kite.conflicts()) },
      '/network': {
        GET: localOnly(bound(() => network().status())),
        PUT: localOnly(bound(async (req) => {
          const parsed = z.object({ enabled: z.boolean() }).strict().safeParse(await body(req));
          if (!parsed.success) throw new KiteError('组网设置无效');
          return parsed.data.enabled ? network().enable() : network().disable();
        })),
      },
      '/network/channel': {
        GET: localOnly(bound(() => ({ channel: network().channel() ?? null }))),
        PUT: localOnly(bound(async (req) => {
          const parsed = networkChannelSchema.safeParse(await body(req));
          if (!parsed.success) throw new KiteError(parsed.error.issues.map((issue) => issue.message).join('；'));
          return network().setChannel(parsed.data);
        })),
        DELETE: localOnly(bound(() => network().setChannel(null))),
      },
      '/network/channel/key': { GET: long(localOnly(bound(async () => ({ publicKey: await network().channelKey() })))) },
      '/network/logout': { POST: localOnly(bound(() => network().logout())) },
      '/machine': { GET: access(() => ({ ...kite.machine(), version: kite.updates.version })) },
      // 自动更新：/update 与取文件的接口跨版本保持兼容，新旧版本靠它们收敛，见 update/updates.ts。
      '/update': { GET: bound(() => kite.updates.status()) },
      '/update/apply': { POST: bound(() => kite.updates.applyNow()) },
      '/update/:build/:payload': { GET: long(peerOnly((req) => kite.updates.listing(req.params.build, payload(req.params.payload)))) },
      '/update/:build/:payload/files': { POST: long(peerOnly(async (req) =>
        kite.updates.files(req.params.build, payload(req.params.payload), (await body(req)).paths, req.signal))) },
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
      '/token-prices': { GET: bound(() => tokenPrices()) },
      '/instances/:id/agent-capabilities': { GET: bound((req) => kite.agentCapabilities(req.params.id)) },
      '/context-variables/:name': { GET: bound((req) => kite.contextVariable({ kind: 'machine' }, req.params.name)) },
      '/workspaces/:id/context-variables/:name': { GET: bound((req) => kite.contextVariable({ kind: 'workspace', id: req.params.id }, req.params.name)) },
      '/instances/:id/context-variables/:name': { GET: bound((req) => kite.contextVariable({ kind: 'instance', id: req.params.id }, req.params.name)) },
      '/workspaces/:id/context-variables/:name/file': { PUT: bound(async (req) => {
        const parsed = z.object({ path: z.string().min(1), content: z.string(), expectedSha256: z.string().nullable() }).strict().safeParse(await body(req));
        if (!parsed.success) throw new KiteError('写回文件要写 path、content 与 expectedSha256');
        return kite.writeContextVariableFile(req.params.id, req.params.name, parsed.data);
      }) },
      '/projects': {
        GET: bound(() => kite.projects()),
      },
      '/checkouts': { GET: bound((req) => kite.checkouts(new URL(req.url).searchParams.get('project') ?? undefined)) },
      '/workspaces': {
        GET: bound((req) => {
          // 聚合和游标在同一同步段读取；客户端可以跳过这份列表已覆盖的事件。
          const workspaces = kite.workspaces(new URL(req.url).searchParams.get('project') ?? undefined);
          return Response.json(workspaces, { headers: { 'X-Kite-Cursor': kite.events.cursor, 'Cache-Control': 'no-store' } });
        }),
        // 本机没有检出时先 clone，请求不受空闲超时限制。
        POST: long(bound(async (req) => {
          const b = await body(req);
          const prompt = b.prompt === undefined ? undefined : str(b.prompt, 'prompt');
          const ids = z.object({ id: z.uuid().optional(), windowId: z.uuid().optional(), messageId: z.uuid().optional() })
            .safeParse({ id: b.id, windowId: b.windowId, messageId: b.messageId });
          if (!ids.success) throw new KiteError('工作区创建参数无效');
          const via = sourceOf(req);
          return kite.createWorkspace(str(b.project, 'project'), prompt, roleSelection(b.role), via, ids.data);
        })),
      },
      '/summary': { GET: bound(() => kite.summary()) },
      // 启用 Line 要建项目与工作区，请求不受空闲超时限制。
      '/line': { POST: long(bound(() => kite.enableLine())) },
      '/attention': {
        GET: bound(() => ({ focusedDevices: kite.attention.devices(), ...(kite.monitor.state()?.away !== undefined ? { awaySince: kite.monitor.state()!.away } : {}) })),
        PUT: bound(async (req) => {
          const parsed = z.object({ device: z.string().trim().min(1).max(200), focused: z.boolean() }).strict().safeParse(await body(req));
          if (!parsed.success) throw new KiteError('关注状态要写 device 与 focused');
          kite.attention.set(parsed.data.device, parsed.data.focused);
          return { focusedDevices: kite.attention.devices() };
        }),
      },
      '/environment': { GET: bound((req) => {
        const params = new URL(req.url).searchParams;
        const needs = z.array(z.enum(HANDOVER_NEEDS)).safeParse(params.get('needs')?.split(',').filter(Boolean) ?? []);
        if (!needs.success) throw new KiteError(`needs 只能是 ${HANDOVER_NEEDS.join('、')}，用逗号分隔`);
        return kite.environment(str(params.get('project') ?? undefined, 'project'), needs.data);
      }) },
      '/workspaces/:id/setup': { POST: bound((req) => kite.retrySetup(req.params.id)) },
      '/workspaces/:id/transfer': { POST: long(bound(async (req) => {
        const parsed = z.object({ to: z.string().min(1), operationId: z.string().min(1), confirmRecovery: z.literal(true).optional() })
          .strict().safeParse(await body(req));
        if (!parsed.success) throw new KiteError('流转要写 to（目标工作机）与 operationId');
        if (parsed.data.confirmRecovery) await kite.confirmWorkspaceRecovery(req.params.id);
        // 不另记回执：执行中的回执会被交接当成结果未知的操作挡住自己。重试照样安全，交接可以重入，目标的还原按 operationId 去重。
        return kite.transferWorkspace(req.params.id, parsed.data.to, { operationId: parsed.data.operationId });
      })) },
      '/workspaces/:id/handover': { POST: long(bound((req) => kite.transfers.handover(req.params.id))) },
      '/workspaces/:id/handover/cancel': { POST: long(bound((req) => kite.transfers.cancel(req.params.id))) },
      // 没有远程的项目：目标机装好后通知源机交出。
      '/workspaces/:id/handover/complete': { POST: long(peerOnly(async (req) => {
        const parsed = z.object({ epoch: z.number().int().positive(), machine: z.string().min(1) }).strict().safeParse(await body(req));
        if (!parsed.success) throw new KiteError('交出通知要写 epoch 与 machine（接收方）');
        return kite.transfers.complete(req.params.id, parsed.data.epoch, parsed.data.machine);
      })) },
      // 工作区副本：其他工作机拉取本机持有的工作区执行数据。
      '/replica': { GET: peerOnly(() => kite.replicaEntries()) },
      '/replica/:id': { POST: long(peerOnly(async (req) => {
        const parsed = z.object({ known: z.record(z.string(), z.object({ size: z.number(), mtime: z.number(), hash: z.string() }).strict()) })
          .strict().safeParse(await body(req));
        if (!parsed.success) throw new KiteError('副本请求要写 known');
        return kite.replicaPage(req.params.id, parsed.data.known);
      })) },
      '/workspaces/:id/lease/check': { POST: long(bound((req) => kite.transfers.check(req.params.id))) },
      '/workspaces/restore': { POST: long(bound(async (req) => {
        const parsed = z.object({ project: z.string().min(1).optional(), workspaceId: z.string().min(1), operationId: z.string().min(1),
          from: z.string().min(1).optional(), force: z.boolean().optional(),
          continue: z.array(z.object({ threadId: z.string().min(1), inputs: z.array(inputSchema) }).strict()).optional() }).strict().safeParse(await body(req));
        if (!parsed.success) throw new KiteError('还原请求要写 workspaceId 与 operationId，可带 project、from（交出它的工作机）或 force（强制接管）');
        const { project, workspaceId, operationId, from, force } = parsed.data;
        return kite.receipts.run({ actor: 'ui', id: operationId, request: JSON.stringify({ name: 'workspace.restore', workspaceId, project, from, force }),
          execute: () => kite.restoreWorkspace(project, workspaceId, { from, force, continue: parsed.data.continue }) });
      })) },
      '/plugin-definitions': {
        GET: bound(() => kite.catalog.definitions()),
        POST: bound(async (req) => kite.installPlugin(await body(req))),
      },
      '/workspaces/:id/agent-options': { GET: bound((req) => kite.agentOptions(req.params.id)) },
      '/context-templates': { GET: bound(() => kite.contextTemplates.list()) },
      '/context-templates/:id': { PUT: bound(async (req) => {
        const { expectedRevision, ...template } = await body(req);
        return kite.updateContextTemplate(req.params.id, str(expectedRevision, 'expectedRevision'), template);
      }) },
      '/context-templates/:id/reset': { POST: bound(async (req) =>
        kite.resetContextTemplate(req.params.id, str((await body(req)).expectedRevision, 'expectedRevision'))) },
      '/token-counts': { POST: bound(async (req) => {
        const parsed = z.object({ texts: z.array(z.string()).max(200), model: z.string().min(1).optional() })
          .strict().safeParse(await body(req));
        if (!parsed.success) throw new KiteError('计数请求无效');
        // 没给模型时（如上下文压缩，实际用会话自己的模型）按默认模型数。
        const model = parsed.data.model ?? defaultAgentModel;
        return { model, results: await kite.tokenCounts.count(parsed.data.texts, model) };
      }) },
      '/roles': {
        GET: bound(() => kite.roleCatalog()),
        POST: bound(async (req) => kite.createRole((await body(req)).role)),
      },
      '/roles/:id': { PUT: bound(async (req) => {
        const b = await body(req);
        return kite.updateRole(req.params.id, str(b.expectedRevision, 'expectedRevision'), b.role);
      }) },
      '/roles/:id/reset': { POST: bound(async (req) =>
        kite.resetRole(req.params.id, str((await body(req)).expectedRevision, 'expectedRevision'))) },
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
      '/workspaces/:id/files/content': { GET: bound(workspaceFile), HEAD: bound(workspaceFile) },
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
      '/threads/:id/reply': { GET: bound((req) => kite.reply(req.params.id)) },
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
      '/instances/:id/approval-mode': {
        GET: bound((req) => kite.approvalMode(req.params.id)),
        PUT: bound(async (req) => kite.configureApprovalMode(req.params.id, await body(req))),
      },
      '/workspaces/:id/threads': {
        POST: bound(async (req) => {
          const b = await body(req);
          const parsed = z.object({ model: agentDefinitionSchema.shape.model.optional(), tools: agentDefinitionSchema.shape.tools.optional(),
            maxRequestsPerTurn: agentDefinitionSchema.shape.maxRequestsPerTurn.optional(), approval: z.enum(approvalModes).optional(),
            windowId: z.uuid().optional(), messageId: z.uuid().optional() })
            .safeParse({ model: b.model, tools: b.tools, maxRequestsPerTurn: b.maxRequestsPerTurn, approval: b.approval, windowId: b.windowId, messageId: b.messageId });
          if (!parsed.success) throw new KiteError('代理创建参数无效');
          const { windowId, messageId, ...choice } = parsed.data;
          return kite.createThread(req.params.id, str(b.prompt, 'prompt'), { ...choice, role: roleSelection(b.role) }, windowId, messageId);
        }),
      },
      '/workspaces/:id/windows': { POST: bound(async (req) => {
        const identity = z.string().trim().min(1);
        const parsed = z.object({ id: z.uuid(), content: z.discriminatedUnion('kind', [
          z.object({ kind: z.literal('create'), definitionId: identity, instanceId: z.uuid().optional(), title: identity.optional(), command: identity.optional() }).strict(),
          z.object({ kind: z.literal('open'), instanceId: identity, viewId: identity }).strict(),
        ]) }).strict().safeParse(await body(req));
        if (!parsed.success) throw new KiteError('窗口请求无效');
        return kite.openWindow(req.params.id, parsed.data);
      }) },
      '/workspaces/:id/windows/:window': { DELETE: bound((req) => kite.closeWindow(req.params.id, req.params.window)) },
      '/threads/:id/history': { GET: bound((req) => kite.history(req.params.id)) },
      '/threads/:id/raw': { GET: bound((req) => {
        const query = new URL(req.url).searchParams;
        const count = (name: string): number => {
          const value = Number(query.get(name) ?? 0);
          if (!Number.isSafeInteger(value) || value < 0) throw new KiteError(`${name} 须为非负整数`);
          return value;
        };
        return kite.rawTranscript(req.params.id, { journal: count('journal'), claude: count('claude') });
      }) },
      '/threads/:id/messages': {
        POST: bound(async (req) => {
          const b = await body(req);
          const via = sourceOf(req);
          // relay：Line 照原文转达用户的话，输入来源仍是人。
          if (b.relay !== undefined && (b.relay !== true || !via)) throw new KiteError('relay 只用于 Line 转达用户原文');
          // 用户在 App 里发送即确认恢复；Line 和其他 agent 的发送仍被恢复阻塞挡住。
          if (b.confirmRecovery !== undefined && (b.confirmRecovery !== true || via)) throw new KiteError('confirmRecovery 只用于用户在 App 里发送');
          if (b.confirmRecovery) await kite.confirmRecovery(req.params.id);
          // skipWaiting：用户没回应线程在等的审批、直接发了这条，消息排进输入以后再按拒绝交回（见 Waits.skip）；提问与密钥请求不阻塞，不用跳过。
          if (b.skipWaiting !== undefined && via) throw new KiteError('skipWaiting 只用于用户在 App 里发送');
          const skip = b.skipWaiting === undefined ? undefined : str(b.skipWaiting, 'skipWaiting');
          const sent = await kite.operations.invoke({ kind: 'ui', ...(via ? { via } : {}), ...(b.relay ? { relayed: true } : {}) }, kite.thread(req.params.id).workspaceId, 'agent.send', {
            instanceId: req.params.id, text: str(b.text, 'text'), operationId: b.id === undefined ? crypto.randomUUID() : str(b.id, 'id'),
          }, req.signal);
          if (skip) kite.waits.skip(req.params.id, skip);
          return sent;
        }),
      },
      '/threads/:id/interrupt': { POST: bound(async (req) => {
        const data = await optionalBody(req, { id: crypto.randomUUID() });
        const parsed = z.object({ id: z.string().min(1), inputs: z.array(inputSchema).optional(), confirmRecovery: z.literal(true).optional() }).safeParse(data);
        if (!parsed.success) throw new KiteError('停止请求无效');
        // 停止没确认就出了异常时，Claude 要先确认恢复才能交回这次停止的收据。
        if (parsed.data.confirmRecovery) await kite.confirmRecovery(req.params.id);
        return kite.operations.invoke({ kind: 'ui' }, kite.thread(req.params.id).workspaceId, 'agent.stop', {
          instanceId: req.params.id, operationId: parsed.data.id, inputs: parsed.data.inputs,
        }, req.signal);
      }) },
      '/threads/:id/resume': { POST: bound(async (req) => {
        const data = await optionalBody(req);
        const parsed = z.object({ operationId: z.string().min(1).optional(), confirmRecovery: z.literal(true).optional() }).strict().safeParse(data);
        if (!parsed.success) throw new KiteError('继续请求无效');
        if (parsed.data.confirmRecovery) await kite.confirmRecovery(req.params.id);
        return kite.operations.invoke({ kind: 'ui' }, kite.thread(req.params.id).workspaceId, 'agent.resume', {
          instanceId: req.params.id, operationId: parsed.data.operationId ?? crypto.randomUUID(),
        }, req.signal);
      }) },
      '/threads/:id/recover': { POST: bound((req) => kite.recover(req.params.id)) },
      '/threads/:id/waiting/:waiting': { POST: bound(async (req) => {
        kite.thread(req.params.id);
        await kite.respondWaiting(req.params.id, req.params.waiting, await body(req), sourceOf(req));
        return { ok: true };
      }) },
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
      '/workspaces/:id/adopt': { POST: recoverable('集成请求无效', (id) => kite.adopt(id)) },
      '/workspaces/:id/sync': { POST: recoverable('同步请求无效', (id) => kite.syncWorkspace(id)) },
      '/instances/:id/archive': { POST: bound((req) => kite.archiveInstance(req.params.id)) },
      '/workspaces/:id/name': { PUT: bound(async (req) => {
        const parsed = z.discriminatedUnion('mode', [
          z.object({ mode: z.literal('auto') }).strict(),
          z.object({ mode: z.literal('manual'), name: z.string() }).strict(),
        ]).safeParse(await body(req));
        if (!parsed.success) throw new KiteError('工作区名称设置无效');
        return kite.nameWorkspace(req.params.id, parsed.data);
      }) },
      '/workspaces/:id/archive': { POST: bound(async (req) => kite.archiveWorkspace(req.params.id, (await body(req)).force === true)) },
      '/events': { GET: bound((req) => events(kite, eventScope(req.url), new URL(req.url).searchParams.get('device') ?? undefined)) },
      '/voice': { GET: voice },
      '/instances/:id/terminal': { GET: terminal },
    },
    websocket: {
      // 终端输出很快而设备读得慢时断开，设备重连时从当前画面接上，不在工作机上无限堆积。
      backpressureLimit: 4 * 1024 * 1024,
      closeOnBackpressureLimit: true,
      open: (socket: ServerWebSocket<SocketData>) => {
        if (socket.data.kind === 'terminal') kite.terminals.attach(socket as ServerWebSocket<TerminalSocket>);
        else kite.voice.open(socket as ServerWebSocket<VoiceSocket>);
      },
      message: (socket: ServerWebSocket<SocketData>, message: string | Buffer) => {
        if (socket.data.kind === 'terminal') kite.terminals.receive(socket as ServerWebSocket<TerminalSocket>, message);
        else kite.voice.message(socket as ServerWebSocket<VoiceSocket>, message);
      },
      close: (socket: ServerWebSocket<SocketData>) => {
        if (socket.data.kind === 'terminal') kite.terminals.detach(socket as ServerWebSocket<TerminalSocket>);
        else kite.voice.close(socket as ServerWebSocket<VoiceSocket>);
      },
    },
    fetch: () => Response.json({ error: '没有这个接口' }, { status: 404 }),
  });
}
