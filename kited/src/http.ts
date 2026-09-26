/** HTTP 接口，只监听本机。事件流用 SSE。 */
import { KiteError } from './errors.ts';
import type { DisplayEnvelope } from './transcript.ts';
import type { Kite } from './kite.ts';

async function body(req: Request): Promise<Record<string, unknown>> {
  try { return (await req.json()) as Record<string, unknown>; } catch { throw new KiteError('请求体不是 JSON'); }
}

const str = (v: unknown, name: string): string => {
  if (typeof v !== 'string') throw new KiteError(`缺少 ${name}`);
  return v;
};

function handle<R extends Request>(fn: (req: R) => Promise<unknown> | unknown) {
  return async (req: R) => {
    try {
      const out = await fn(req);
      return out instanceof Response ? out : Response.json(out ?? { ok: true });
    } catch (e) {
      const status = e instanceof KiteError ? e.status : 500;
      return Response.json({ error: (e as Error).message }, { status });
    }
  };
}

/** 同一个事件发给几个订阅者时只序列化一次：工具结果可能很大。 */
const encoded = new WeakMap<DisplayEnvelope, string>();
function encode(e: DisplayEnvelope): string {
  let text = encoded.get(e);
  if (text === undefined) {
    text = `id: ${e.cursor}\nevent: ${e.type}\ndata: ${JSON.stringify(e)}\n\n`;
    encoded.set(e, text);
  }
  return text;
}

async function events(kite: Kite, session: string | undefined): Promise<Response> {
  if (session) await kite.history(session);
  let unsubscribe = () => {};
  let heartbeat: Timer | undefined;
  const stream = new ReadableStream<string>({
    start(controller) {
      // 订阅与快照在同一同步段，历史之后的第一条事件不会漏；重连总以当前快照替换旧副本。
      unsubscribe = kite.events.subscribe(session, (e) => controller.enqueue(encode(e)));
      if (session) {
        const history = kite.historyNow(session);
        controller.enqueue(`id: ${history.cursor}\nevent: history\ndata: ${JSON.stringify({ type: 'history', ...history })}\n\n`);
      }
      if (!session) controller.enqueue(`event: ready\ndata: ${JSON.stringify({ type: 'ready' })}\n\n`);
      heartbeat = setInterval(() => controller.enqueue(': \n\n'), 15_000);
      controller.enqueue(': connected\n\n');
    },
    cancel() { unsubscribe(); clearInterval(heartbeat); },
  });
  return new Response(stream, { headers: { 'content-type': 'text/event-stream', 'cache-control': 'no-cache' } });
}

export function serve(kite: Kite, port: number) {
  return Bun.serve({
    hostname: '127.0.0.1',
    port,
    idleTimeout: 60,
    routes: {
      '/projects': {
        GET: handle(() => kite.projects()),
        POST: handle(async (req) => kite.registerProject(str((await body(req)).path, 'path'))),
      },
      '/sessions': {
        GET: handle((req) => kite.sessions(new URL(req.url).searchParams.get('project') ?? undefined)),
        POST: handle(async (req) => {
          const b = await body(req);
          if (b.runtime !== undefined && b.runtime !== 'harness' && b.runtime !== 'claude') throw new KiteError('runtime 必须是 harness 或 claude');
          return kite.createSession(str(b.project, 'project'), str(b.prompt, 'prompt'), b.runtime);
        }),
      },
      '/sessions/:id': { GET: handle((req) => kite.session(req.params.id)) },
      '/sessions/:id/history': { GET: handle((req) => kite.history(req.params.id)) },
      '/sessions/:id/messages': {
        POST: handle(async (req) => {
          const b = await body(req);
          return kite.send(req.params.id, str(b.text, 'text'), b.id === undefined ? undefined : str(b.id, 'id'));
        }),
      },
      '/sessions/:id/interrupt': { POST: handle((req) => kite.interrupt(req.params.id)) },
      '/sessions/:id/messages/:message/cancel': { POST: handle((req) => kite.cancel(req.params.id, req.params.message)) },
      '/sessions/:id/resume': { POST: handle((req) => kite.resume(req.params.id)) },
      '/sessions/:id/recover': { POST: handle((req) => kite.recover(req.params.id)) },
      '/sessions/:id/snapshots': { GET: handle((req) => kite.snapshots(req.params.id)) },
      '/sessions/:id/restore': {
        POST: handle(async (req) => kite.restore(req.params.id, str((await body(req)).commit, 'commit'))),
      },
      '/sessions/:id/adopt': { POST: handle((req) => kite.adopt(req.params.id)) },
      '/sessions/:id/archive': {
        POST: handle(async (req) => kite.archive(req.params.id, (await body(req)).force === true)),
      },
      '/events': { GET: handle((req) => events(kite, new URL(req.url).searchParams.get('session') ?? undefined)) },
    },
    fetch: () => Response.json({ error: '没有这个接口' }, { status: 404 }),
  });
}
