/**
 * 假的 Anthropic Messages 端点：用预设回复驱动真实的 Claude Code，不调模型、不耗额度。
 * 主循环请求（带 tools）按最后一条用户消息决定回复：
 *  - 含 tool_result → 结束回合，回一句「工具完成」；
 *  - RUN <命令>        → 调一次 Bash 执行这条命令；
 *  - PAR <命令1> ;; <命令2> → 一次回复里并行调两个 Bash；
 *  - BG <秒>           → 后台 Bash 睡几秒；
 *  - SLOW <秒>         → 等几秒再回显，用来在回合进行中插消息；
 *  - 含「冲突」        → 用 Bash 以会话分支一侧解决冲突并提交（模拟 agent 解决合并冲突）；
 *  - 其他              → 回显。
 * 其他请求（标题生成之类，不带 tools）一律回一句短文本。
 */
export interface Logged { at: number; main: boolean; body: any; lastUserText: string; hasToolResult: boolean }

function lastUser(body: any): { text: string; hasToolResult: boolean } {
  const msgs = body.messages ?? [];
  for (let i = msgs.length - 1; i >= 0; i--) {
    const m = msgs[i];
    if (m.role !== 'user') continue;
    if (typeof m.content === 'string') return { text: m.content, hasToolResult: false };
    const blocks = m.content as any[];
    return {
      text: blocks.filter((b) => b.type === 'text').map((b) => b.text).join('\n'),
      hasToolResult: blocks.some((b) => b.type === 'tool_result'),
    };
  }
  return { text: '', hasToolResult: false };
}

let seq = 0;
function sse(model: string, content: any[], stop: string): string {
  const ev: Array<[string, unknown]> = [[
    'message_start',
    { type: 'message_start', message: { id: `msg_fake_${++seq}`, type: 'message', role: 'assistant', model, content: [], stop_reason: null, stop_sequence: null, usage: { input_tokens: 10, output_tokens: 1 } } },
  ]];
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

const bash = (command: string, extra: Record<string, unknown> = {}) =>
  ({ type: 'tool_use', id: `toolu_fake_${++seq}`, name: 'Bash', input: { command, description: 'fake', ...extra } });

export function startFakeApi() {
  const log: Logged[] = [];
  const server = Bun.serve({
    port: 0,
    idleTimeout: 120,
    async fetch(req) {
      const url = new URL(req.url);
      if (req.method !== 'POST') return Response.json({}, { status: 404 });
      const body: any = await req.json().catch(() => ({}));
      if (url.pathname.endsWith('/count_tokens')) return Response.json({ input_tokens: 100 });
      if (!url.pathname.endsWith('/v1/messages')) return Response.json({}, { status: 404 });
      const main = Array.isArray(body.tools) && body.tools.length > 0;
      const { text, hasToolResult } = lastUser(body);
      log.push({ at: Date.now(), main, body, lastUserText: text, hasToolResult });
      const model = body.model ?? 'claude-fake';
      let content: any[] = [{ type: 'text', text: 'ok' }];
      let stop = 'end_turn';
      if (main) {
        let m: RegExpExecArray | null;
        if (hasToolResult) content = [{ type: 'text', text: '工具完成' }];
        else if ((m = /PAR (.+?) ;; (.+)$/m.exec(text))) { content = [bash(m[1]!), bash(m[2]!)]; stop = 'tool_use'; }
        else if ((m = /RUN (.+)$/m.exec(text))) { content = [bash(m[1]!)]; stop = 'tool_use'; }
        else if ((m = /BG (\d+)/.exec(text))) { content = [bash(`sleep ${m[1]}; echo bg-done`, { run_in_background: true })]; stop = 'tool_use'; }
        else if (text.includes('冲突')) { content = [bash('git checkout --ours -- . && git add -A && git commit -q --no-edit')]; stop = 'tool_use'; }
        else {
          if ((m = /SLOW (\d+)/.exec(text))) await Bun.sleep(Number(m[1]) * 1000);
          content = [{ type: 'text', text: `echo: ${text.slice(-60)}` }];
        }
      }
      if (body.stream === false) {
        return Response.json({ id: `msg_fake_${++seq}`, type: 'message', role: 'assistant', model, content, stop_reason: stop, stop_sequence: null, usage: { input_tokens: 10, output_tokens: 5 } });
      }
      return new Response(sse(model, content, stop), { headers: { 'content-type': 'text/event-stream' } });
    },
  });
  return { port: server.port, log, stop: () => server.stop(true) };
}
