/**
 * 假的 Anthropic Messages 端点：用预设回复驱动真实的 Claude Code，不调模型、不耗额度。
 * 主循环请求（带 tools）按最后一条用户消息决定回复：
 *  - 含 tool_result → 结束回合，回一句「工具完成」；
 *  - 文本含 SLEEP n → 调 Bash 睡 n 秒；
 *  - 其他 → 回显。
 * 其他请求（标题生成之类，不带 tools）一律回一句短文本。
 */
export interface Logged {
  at: number; // Date.now()
  path: string;
  main: boolean;
  body: any;
  lastUserText: string;
  hasToolResult: boolean;
}

function lastUser(body: any): { text: string; hasToolResult: boolean } {
  const msgs = body.messages ?? [];
  for (let i = msgs.length - 1; i >= 0; i--) {
    const m = msgs[i];
    if (m.role !== 'user') continue;
    if (typeof m.content === 'string') return { text: m.content, hasToolResult: false };
    const blocks = m.content as any[];
    const text = blocks.filter((b) => b.type === 'text').map((b) => b.text).join('\n');
    return { text, hasToolResult: blocks.some((b) => b.type === 'tool_result') };
  }
  return { text: '', hasToolResult: false };
}

function sse(events: Array<[string, unknown]>): string {
  return events.map(([e, d]) => `event: ${e}\ndata: ${JSON.stringify(d)}\n\n`).join('');
}

let seq = 0;
function reply(model: string, content: any[], stop: string): string {
  const id = `msg_fake_${++seq}`;
  const ev: Array<[string, unknown]> = [
    ['message_start', { type: 'message_start', message: { id, type: 'message', role: 'assistant', model, content: [], stop_reason: null, stop_sequence: null, usage: { input_tokens: 10, output_tokens: 1 } } }],
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
  return sse(ev);
}

export function startFakeApi() {
  const log: Logged[] = [];
  /** 回显回复额外附带的字符数，用来把历史撑大、模拟长对话。 */
  const config = { pad: 0 };
  const waiters: Array<{ pred: (l: Logged) => boolean; resolve: (l: Logged) => void }> = [];
  const server = Bun.serve({
    port: 0,
    idleTimeout: 60,
    async fetch(req) {
      const url = new URL(req.url);
      const at = Date.now();
      if (req.method !== 'POST') return Response.json({}, { status: 404 });
      const body = await req.json().catch(() => ({}));
      if (url.pathname.endsWith('/count_tokens')) return Response.json({ input_tokens: 100 });
      if (!url.pathname.endsWith('/v1/messages')) return Response.json({}, { status: 404 });
      const main = Array.isArray(body.tools) && body.tools.length > 0;
      const { text, hasToolResult } = lastUser(body);
      const entry: Logged = { at, path: url.pathname, main, body, lastUserText: text, hasToolResult };
      log.push(entry);
      for (const w of [...waiters]) if (w.pred(entry)) { waiters.splice(waiters.indexOf(w), 1); w.resolve(entry); }
      const model = body.model ?? 'claude-fake';
      let content: any[]; let stop = 'end_turn';
      if (!main) content = [{ type: 'text', text: 'ok' }];
      else if (hasToolResult) content = [{ type: 'text', text: '工具完成' }];
      else {
        const m = /SLEEP (\d+)/.exec(text);
        const bg = /BG (\d+)/.exec(text);
        if (bg) { content = [{ type: 'tool_use', id: `toolu_fake_${++seq}`, name: 'Bash', input: { command: `sleep ${bg[1]}; echo bg-done`, description: 'background sleep', run_in_background: true } }]; stop = 'tool_use'; }
        else if (m) { content = [{ type: 'tool_use', id: `toolu_fake_${++seq}`, name: 'Bash', input: { command: `sleep ${m[1]}; echo slept`, description: 'sleep' } }]; stop = 'tool_use'; }
        else content = [{ type: 'text', text: `echo: ${text.slice(-40)}` + (config.pad ? '\n' + '长'.repeat(config.pad) : '') }];
      }
      if (body.stream === false) {
        return Response.json({ id: `msg_fake_${++seq}`, type: 'message', role: 'assistant', model, content, stop_reason: stop, stop_sequence: null, usage: { input_tokens: 10, output_tokens: 5 } });
      }
      return new Response(reply(model, content, stop), { headers: { 'content-type': 'text/event-stream' } });
    },
  });
  return {
    port: server.port,
    log,
    config,
    /** 等到第一条满足条件的主循环请求（已到达的也算）。 */
    waitFor(pred: (l: Logged) => boolean, timeoutMs = 60000): Promise<Logged> {
      const hit = log.find((l) => l.main && pred(l));
      if (hit) return Promise.resolve(hit);
      return new Promise((resolve, reject) => {
        const t = setTimeout(() => reject(new Error('等待请求超时')), timeoutMs);
        waiters.push({ pred: (l) => l.main && pred(l), resolve: (l) => { clearTimeout(t); resolve(l); } });
      });
    },
    stop: () => server.stop(true),
  };
}
