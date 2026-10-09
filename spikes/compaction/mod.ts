/**
 * 实验：用 mod 的 session.compact 接管 Claude Code 的压缩，验证回合中途的自动压缩会不会经过 hook、hook 交回的带 handle 消息是否原样保留、
 * $.model.fork 能否在压缩中写摘要，以及压缩后会话文件的形态和恢复是否一致。
 * 第三轮的工具调用回复报出很大的输入用量，把引擎推过自动压缩阈值；之后的请求发生在同一回合的工具结果之后。
 * 用本机假 Anthropic 端点，不消耗额度。用法：bun mod.ts <输出目录>
 */
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { drive, isolated, sessionFile } from '../handoff/native.ts';
const { getSessionMessages } = await import('../../kited/node_modules/@anthropic-ai/claude-agent-sdk/sdk.mjs');

const out = resolve(process.argv[2]);
const cwd = join(out, 'work');
mkdirSync(cwd, { recursive: true });
writeFileSync(join(cwd, 'a.txt'), 'a'); writeFileSync(join(cwd, 'b.txt'), 'b');

const log: any[] = [];
let seq = 0;
const sse = (events: Array<[string, unknown]>) => events.map(([event, data]) => `event: ${event}\ndata: ${JSON.stringify(data)}\n\n`).join('');
function reply(model: string, content: any[], stop: string, input: number) {
  const id = `msg_fake_${++seq}`;
  const events: Array<[string, unknown]> = [['message_start', { type: 'message_start', message: { id, type: 'message', role: 'assistant', model, content: [],
    stop_reason: null, stop_sequence: null, usage: { input_tokens: input, output_tokens: 1 } } }]];
  content.forEach((block, index) => {
    if (block.type === 'text') {
      events.push(['content_block_start', { type: 'content_block_start', index, content_block: { type: 'text', text: '' } }]);
      events.push(['content_block_delta', { type: 'content_block_delta', index, delta: { type: 'text_delta', text: block.text } }]);
    } else if (block.type === 'thinking') {
      events.push(['content_block_start', { type: 'content_block_start', index, content_block: { type: 'thinking', thinking: '', signature: '' } }]);
      events.push(['content_block_delta', { type: 'content_block_delta', index, delta: { type: 'thinking_delta', thinking: block.thinking } }]);
      events.push(['content_block_delta', { type: 'content_block_delta', index, delta: { type: 'signature_delta', signature: block.signature } }]);
    } else {
      events.push(['content_block_start', { type: 'content_block_start', index, content_block: { type: 'tool_use', id: block.id, name: block.name, input: {} } }]);
      events.push(['content_block_delta', { type: 'content_block_delta', index, delta: { type: 'input_json_delta', partial_json: JSON.stringify(block.input) } }]);
    }
    events.push(['content_block_stop', { type: 'content_block_stop', index }]);
  });
  events.push(['message_delta', { type: 'message_delta', delta: { stop_reason: stop, stop_sequence: null }, usage: { output_tokens: 5 } }]);
  events.push(['message_stop', { type: 'message_stop' }]);
  return sse(events);
}
const textOf = (message: any) => typeof message?.content === 'string' ? message.content
  : (message?.content ?? []).map((block: any) => block.type === 'text' ? block.text : '').join('\n');
const server = Bun.serve({ port: 0, idleTimeout: 60, async fetch(request) {
  const url = new URL(request.url);
  if (request.method !== 'POST') return Response.json({}, { status: 404 });
  const body: any = await request.json().catch(() => ({}));
  if (url.pathname.endsWith('/count_tokens')) return Response.json({ input_tokens: 100 });
  if (!url.pathname.endsWith('/v1/messages')) return Response.json({}, { status: 404 });
  const last = body.messages?.at(-1);
  const text = textOf(last);
  const hasResult = Array.isArray(last?.content) && last.content.some((block: any) => block.type === 'tool_result');
  log.push({ at: Date.now(), tools: body.tools?.length ?? 0, last: text.slice(-60), hasResult, body });
  const model = body.model ?? 'claude-fake';
  if (text.includes('写成摘要')) return new Response(reply(model, [{ type: 'text', text: '第二轮里用户问了第二个问题，已答复。' }], 'end_turn', 120), { headers: { 'content-type': 'text/event-stream' } });
  if (hasResult) return new Response(reply(model, [{ type: 'text', text: '两个文件都读完了。' }], 'end_turn', 120), { headers: { 'content-type': 'text/event-stream' } });
  if (text.includes('请读文件')) return new Response(reply(model, [
    { type: 'thinking', thinking: '先并行读两个文件。', signature: 'sig-fake-anthropic' },
    { type: 'text', text: '我来读一下。' },
    { type: 'tool_use', id: 'toolu_01A', name: 'mcp__kite__read', input: { path: 'a.txt' } },
    { type: 'tool_use', id: 'toolu_01B', name: 'mcp__kite__read', input: { path: 'b.txt' } },
  // 报出接近窗口的输入用量，工具结果回来之后、下一次请求之前应触发自动压缩。
  ], 'tool_use', 180_000), { headers: { 'content-type': 'text/event-stream' } });
  return new Response(reply(model, [{ type: 'text', text: `收到：${text.slice(-12)}` }], 'end_turn', 120), { headers: { 'content-type': 'text/event-stream' } });
} });

const { options: base, cfg } = isolated(join(out, 'mod'), server.port, cwd);
process.env.CLAUDE_CONFIG_DIR = cfg;
const { DISABLE_COMPACT: _, ...env } = base.env as Record<string, string>;
const options = { ...base, env: { ...env, CLAUDE_CODE_AUTO_COMPACT_WINDOW: '200000', CLAUDE_AUTOCOMPACT_PCT_OVERRIDE: '50',
  ...(process.env.KITE_SPIKE_SHAPE ? { KITE_SPIKE_SHAPE: process.env.KITE_SPIKE_SHAPE } : {}),
  ...(process.env.KITE_SPIKE_DEFER ? { KITE_SPIKE_DEFER: process.env.KITE_SPIKE_DEFER } : {}) },
  settings: { ...(base.settings as object), autoCompactEnabled: true },
  plugins: [...(base.plugins ?? []), { type: 'local', path: join(import.meta.dir, 'mod-plugin'), skipMcpDiscovery: true }],
  stderr: (text: string) => { stderr.push(text); } };
const stderr: string[] = [];
const model = 'claude-sonnet-4-5';
const sessionId = crypto.randomUUID();
const seen = await drive({ ...options, sessionId, model }, [
  { id: crypto.randomUUID(), text: '第一个问题' },
  { id: crypto.randomUUID(), text: '第二个问题' },
  { id: crypto.randomUUID(), text: '请读文件 a 和 b' },
]);
const firstRun = log.length;
await drive({ ...options, resume: sessionId, model }, [{ id: crypto.randomUUID(), text: '第四个问题' }]);
server.stop(true);

const brief = (messages: any[]) => messages.map((message: any) => `${message.role}: ${(typeof message.content === 'string' ? [message.content]
  : message.content.map((block: any) => block.type === 'text' ? block.text : block.type === 'tool_use' ? `tool_use ${block.id}` : block.type === 'tool_result' ? `tool_result ${block.tool_use_id}` : block.type)).join(' | ').replace(/\s+/g, ' ').slice(0, 160)}`);
const readRequest = log.find((entry) => entry.last.includes('请读文件') && !entry.hasResult && entry.tools > 0);
const afterTools = log.find((entry) => entry.hasResult);
const rows = readFileSync(sessionFile(cfg, sessionId), 'utf8').split('\n').filter(Boolean).map((line) => JSON.parse(line));
const display = await getSessionMessages(sessionId, { dir: cwd, includeSystemMessages: true });
const report = {
  requests: log.map((entry, index) => `${index}${index >= firstRun ? '（恢复后）' : ''} tools=${(entry.body.tools ?? []).map((item: any) => item.name).join(',')} 结果=${entry.hasResult} 末尾=${entry.last.replace(/\s+/g, ' ')}`),
  readRequest: readRequest && brief(readRequest.body.messages),
  afterTools: afterTools && brief(afterTools.body.messages),
  // 默认形状下，第一轮两条消息与压缩前请求逐字节一致。
  firstTurnKept: !!readRequest && !!afterTools && JSON.stringify(afterTools.body.messages.slice(0, 2)) === JSON.stringify(readRequest.body.messages.slice(0, 2)),
  sameSystem: !!readRequest && JSON.stringify(afterTools?.body.system) === JSON.stringify(readRequest.body.system),
  sameTools: !!readRequest && JSON.stringify(afterTools?.body.tools) === JSON.stringify(readRequest.body.tools),
  resumed: brief(log.at(-1).body.messages),
  sdkSystem: seen.filter((message: any) => message.type === 'system').map((message: any) => `${message.subtype}${message.compact_metadata ? ' ' + JSON.stringify(message.compact_metadata) : ''}`),
  file: rows.map((row) => `${row.type}${row.subtype ? ':' + row.subtype : ''}${row.isCompactSummary ? ' [summary]' : ''}${row.compactMetadata ? ' ' + JSON.stringify(row.compactMetadata).slice(0, 200) : ''}${row.message ? ' ' + textOf(row.message).replace(/\s+/g, ' ').slice(0, 40) : ''}`),
  display: display.map((message: any) => `${message.type} ${textOf(message.message).replace(/\s+/g, ' ').slice(0, 30)}`),
};
writeFileSync(join(out, 'stderr.txt'), stderr.join(''));
writeFileSync(join(out, 'result.json'), JSON.stringify(report, null, 2));
writeFileSync(join(out, 'requests.json'), JSON.stringify(log.map((entry) => entry.body), null, 2));
console.log(JSON.stringify(report, null, 2));
