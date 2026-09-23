/** HTTP 接口，只监听本机。事件流用 SSE。 */
import { KiteError } from './errors.ts';
import type { Envelope } from './events.ts';
import type { Kite } from './kite.ts';

async function body(req: Request): Promise<Record<string, unknown>> {
  try { return (await req.json()) as Record<string, unknown>; } catch { throw new KiteError('请求体不是 JSON'); }
}

const str = (v: unknown, name: string): string => {
  if (typeof v !== 'string') throw new KiteError(`缺少 ${name}`);
  return v;
};

function handle(fn: (req: Request & { params: Record<string, string> }) => Promise<unknown> | unknown) {
  return async (req: Request & { params: Record<string, string> }) => {
    try {
      const out = await fn(req);
      return out instanceof Response ? out : Response.json(out ?? { ok: true });
    } catch (e) {
      const status = e instanceof KiteError ? e.status : 500;
      return Response.json({ error: (e as Error).message }, { status });
    }
  };
}

function events(kite: Kite, session: string | undefined): Response {
  let unsubscribe = () => {};
  let heartbeat: Timer | undefined;
  const stream = new ReadableStream<string>({
    start(controller) {
      const send = (e: Envelope) => controller.enqueue(`event: ${e.type}\ndata: ${JSON.stringify(e)}\n\n`);
      unsubscribe = kite.bus.subscribe(session, send);
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
          return kite.createSession(str(b.project, 'project'), str(b.prompt, 'prompt'));
        }),
      },
      '/sessions/:id': { GET: handle((req) => kite.session(req.params.id!)) },
      '/sessions/:id/messages': {
        POST: handle(async (req) => kite.send(req.params.id!, str((await body(req)).text, 'text'))),
      },
      '/sessions/:id/interrupt': { POST: handle((req) => kite.interrupt(req.params.id!)) },
      '/sessions/:id/snapshots': { GET: handle((req) => kite.snapshots(req.params.id!)) },
      '/sessions/:id/restore': {
        POST: handle(async (req) => kite.restore(req.params.id!, str((await body(req)).commit, 'commit'))),
      },
      '/sessions/:id/adopt': { POST: handle((req) => kite.adopt(req.params.id!)) },
      '/sessions/:id/archive': {
        POST: handle(async (req) => kite.archive(req.params.id!, (await body(req)).force === true)),
      },
      '/events': { GET: (req) => events(kite, new URL(req.url).searchParams.get('session') ?? undefined) },
    },
    fetch: () => Response.json({ error: '没有这个接口' }, { status: 404 }),
  });
}
