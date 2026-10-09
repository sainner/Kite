/**
 * 假的 Anthropic Messages 端点：用预设回复驱动真实的 Claude Code，不调模型、不耗额度。
 * 整个测试进程共用一个，由 test/setup.ts 启动。
 *
 * 主循环使用流式请求，按最后一条用户消息回显；HOLD <标记> 挂起请求，release(标记) 后回显。
 * STREAM <标记> 先发文本增量，release(标记) 后才结束消息，供测试观察真正生成中的历史记录。
 * STREAM_RESULT <标记> 在工具后的回复做同样的分段，供插话与工具结果交接时观察增量。
 * READ <JSON 对象或数组> 调一次或一批 Kite read，下一次请求回显工具结果，不调用其他工具。
 * PATCH、SHELL <JSON 对象或数组> 同样调用 Kite patch、shell；HOLD_RESULT <标记> 把工具后的请求挂起，供测试核对快照时序。
 * AGENT_START 等 AGENT_* 命令调用对应 Kite 操作工具，使用同一参数和回显协议。
 * USAGE <JSON 对象> 把对象并入这次回复 message_start 的 usage，供测试报出指定的输入用量（如缓存读写的 token 数）。
 * 正文不由测试决定的请求（如压缩摘要指令）用 holdNext 按条件挂起。
 * 非流式的辅助请求一律回一句短文本。工具集合可以为空，不能用它判断是不是主循环。
 */

export interface Logged {
  at: number;
  /** 主循环的流式请求。 */
  main: boolean;
  body: any;
  /** 最后一条用户消息里的文本。 */
  lastUserText: string;
  /** 这次回复发出的工具调用 id。 */
  toolUseIds: string[];
  /** 因 HOLD 挂起过的标记。 */
  hold?: string;
}

export interface FakeApi {
  url: string;
  log: Logged[];
  /** 等到满足条件的请求（已收到的也算）。 */
  waitRequest(pred: (l: Logged) => boolean, timeoutMs?: number): Promise<Logged>;
  /** 等到有一次请求因 HOLD <标记> 挂起（已挂起的也算），即 agent 正在工作。 */
  held(tag: string, timeoutMs?: number): Promise<Logged>;
  /** 放行 HOLD <标记> 挂着的请求；之后同标记的请求不再挂起。 */
  release(tag: string): void;
  /** 下一次满足条件的请求按标记挂起（只挂一次），之后同样用 held、release。 */
  holdNext(tag: string, pred: (l: Logged) => boolean): void;
  /** 放行所有挂着的请求，测试收尾用。 */
  releaseAll(): void;
  /** 关掉端点，连同还开着的连接。 */
  stop(): Promise<void>;
}

function lastUser(body: any, skipResults = false): { text: string; results: any[] } {
  const msgs = body.messages ?? [];
  for (let i = msgs.length - 1; i >= 0; i--) {
    const m = msgs[i];
    if (m.role !== 'user') continue;
    if (typeof m.content === 'string') return { text: m.content, results: [] };
    const blocks = m.content as any[];
    if (skipResults && blocks.some((b) => b.type === 'tool_result')) continue;
    return { text: blocks.filter((b) => b.type === 'text').map((b) => b.text).join('\n'),
      results: blocks.filter((b) => b.type === 'tool_result') };
  }
  return { text: '', results: [] };
}

let seq = 0;
type Reply = { type: 'text'; text: string } | { type: 'tool_use'; id: string; name: string; input: unknown };
function sse(model: string, content: Reply[], stop: string, usage: Record<string, unknown> = {}): string {
  const ev: Array<[string, unknown]> = [
    ['message_start', { type: 'message_start', message: {
      id: `msg_fake_${++seq}`, type: 'message', role: 'assistant', model, content: [],
      stop_reason: null, stop_sequence: null, usage: { input_tokens: 10, output_tokens: 1, ...usage },
    } }],
  ];
  content.forEach((block, index) => {
    if (block.type === 'text') {
      ev.push(['content_block_start', { type: 'content_block_start', index, content_block: { type: 'text', text: '' } }]);
      ev.push(['content_block_delta', { type: 'content_block_delta', index, delta: { type: 'text_delta', text: block.text } }]);
    } else {
      ev.push(['content_block_start', { type: 'content_block_start', index, content_block: { type: 'tool_use', id: block.id, name: block.name, input: {} } }]);
      ev.push(['content_block_delta', { type: 'content_block_delta', index, delta: { type: 'input_json_delta', partial_json: JSON.stringify(block.input) } }]);
    }
    ev.push(['content_block_stop', { type: 'content_block_stop', index }]);
  });
  ev.push(['message_delta', { type: 'message_delta', delta: { stop_reason: stop, stop_sequence: null }, usage: { output_tokens: 5 } }]);
  ev.push(['message_stop', { type: 'message_stop' }]);
  return ev.map(([e, d]) => `event: ${e}\ndata: ${JSON.stringify(d)}\n\n`).join('');
}

export function startFakeApi(): FakeApi {
  const log: Logged[] = [];
  const waiters: Array<{ pred: (l: Logged) => boolean; resolve: (l: Logged) => void }> = [];
  const released = new Set<string>();
  const holding = new Map<string, Array<() => void>>();
  const holdRules: Array<{ tag: string; pred: (l: Logged) => boolean }> = [];

  const notify = (l: Logged) => {
    for (const w of [...waiters]) if (w.pred(l)) { waiters.splice(waiters.indexOf(w), 1); w.resolve(l); }
  };

  function waitRequest(pred: (l: Logged) => boolean, timeoutMs = 10_000): Promise<Logged> {
    const hit = log.find(pred);
    if (hit) return Promise.resolve(hit);
    return new Promise((resolve, reject) => {
      const w = { pred, resolve: (l: Logged) => { clearTimeout(t); resolve(l); } };
      const t = setTimeout(() => { waiters.splice(waiters.indexOf(w), 1); reject(new Error('等待假端点的请求超时')); }, timeoutMs);
      waiters.push(w);
    });
  }

  function release(tag: string) {
    released.add(tag);
    for (const go of holding.get(tag) ?? []) go();
    holding.delete(tag);
  }

  const server = Bun.serve({
    port: 0,
    idleTimeout: 0,
    async fetch(req) {
      const url = new URL(req.url);
      if (req.method !== 'POST') return Response.json({}, { status: 404 });
      const body: any = await req.json().catch(() => ({}));
      if (url.pathname.endsWith('/count_tokens')) return Response.json({ input_tokens: 100 });
      if (!url.pathname.endsWith('/v1/messages')) return Response.json({}, { status: 404 });
      const main = body.stream === true;
      const { text, results } = lastUser(body);
      const model = body.model ?? 'claude-fake';
      let content: Reply[] = [{ type: 'text', text: main ? `echo: ${text.slice(-60)}` : 'ok' }];
      const call = main && /^(READ|PATCH|SHELL|AGENT_START|AGENT_LIST|AGENT_SEND|AGENT_RESUME|AGENT_STOP) (.+)$/m.exec(text);
      if (results.length) {
        content = [{ type: 'text', text: results.map((result) => typeof result.content === 'string'
          ? result.content : result.content.filter((block: any) => block.type === 'text').map((block: any) => block.text).join('\n')).join('\n') }];
      } else if (call) {
        const args = JSON.parse(call[2]!);
        content = (Array.isArray(args) ? args : [args]).map((input) => ({
          type: 'tool_use', id: `toolu_fake_${++seq}`, name: `mcp__kite__${call[1]!.toLowerCase()}`, input,
        }));
      }
      const toolUseIds = content.flatMap((block) => block.type === 'tool_use' ? [block.id] : []);
      const stop = toolUseIds.length ? 'tool_use' : 'end_turn';
      const match = main && (results.length
        ? /HOLD_RESULT (\S+)/.exec(lastUser(body, true).text)
        : /HOLD (\S+)/.exec(text));
      const streaming = main && (results.length
        ? /^STREAM_RESULT (\S+)/m.exec(lastUser(body, true).text)
        : /^STREAM (\S+)/m.exec(text));
      const tag = match ? match[1] : streaming ? streaming[1] : undefined;
      let hold = tag && !released.has(tag) ? tag : undefined;
      const entry: Logged = { at: Date.now(), main, body, lastUserText: text, toolUseIds };
      const rule = hold ? undefined : holdRules.find((r) => r.pred(entry));
      if (rule) {
        holdRules.splice(holdRules.indexOf(rule), 1);
        if (!released.has(rule.tag)) hold = rule.tag;
      }
      entry.hold = hold;
      log.push(entry);
      let go: Promise<void> | undefined;
      if (hold) {
        const tag = hold;
        go = new Promise<void>((resolve) => holding.set(tag, [...(holding.get(tag) ?? []), resolve]));
        notify(entry);
        if (!streaming) await go;
      } else {
        notify(entry);
      }
      if (!main) {
        return Response.json({ id: `msg_fake_${++seq}`, type: 'message', role: 'assistant', model,
          content, stop_reason: stop, stop_sequence: null,
          usage: { input_tokens: 10, output_tokens: 5 } });
      }
      const usage = !results.length ? /^USAGE (\{.*\})$/m.exec(text) : null;
      const response = sse(model, content, stop, usage ? JSON.parse(usage[1]!) : {});
      const headers = { 'content-type': 'text/event-stream' };
      if (streaming && hold && go) {
        const bytes = new TextEncoder();
        const split = response.indexOf('event: content_block_stop');
        let cancelled = false;
        return new Response(new ReadableStream<Uint8Array>({
          start(controller) {
            controller.enqueue(bytes.encode(response.slice(0, split)));
            void go!.then(() => {
              if (cancelled) return;
              controller.enqueue(bytes.encode(response.slice(split)));
              controller.close();
            });
          },
          cancel() { cancelled = true; release(hold); },
        }), { headers });
      }
      return new Response(response, { headers });
    },
  });

  return {
    url: `http://127.0.0.1:${server.port}`,
    log,
    waitRequest,
    held: (tag, timeoutMs) => waitRequest((l) => l.hold === tag, timeoutMs),
    release,
    holdNext(tag, pred) { holdRules.push({ tag, pred }); },
    releaseAll() {
      holdRules.length = 0;
      for (const tag of holding.keys()) release(tag);
    },
    stop: () => server.stop(true),
  };
}
