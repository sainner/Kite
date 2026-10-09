/**
 * 实验 1：用 kited 实际的 Claude 配置 + 假端点跑一段原生会话，记录原生 jsonl 与每次主循环请求。
 * 回合 1：模型先 thinking，再并行调两个 kite 工具；工具结果回来后回文本。回合 2：回文本。
 * hook 注入：UserPromptSubmit 与 PostToolBatch 都给 additionalContext（模拟 Kite 通知）。
 * 用法：bun native.ts <输出目录>
 */
const SDK = '../../kited/node_modules/@anthropic-ai/claude-agent-sdk/sdk.mjs';
const { query, createSdkMcpServer, tool } = await import(SDK);
import { claudeOptions } from '../../kited/src/claude/options.ts';
import { z } from '../../kited/node_modules/zod/index.js';
import { mkdirSync, writeFileSync, readdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';

export function fakeApi() {
  const log: any[] = [];
  let seq = 0;
  const sse = (events: Array<[string, unknown]>) => events.map(([e, d]) => `event: ${e}\ndata: ${JSON.stringify(d)}\n\n`).join('');
  const reply = (model: string, content: any[], stop: string) => {
    const id = `msg_fake_${++seq}`;
    const ev: Array<[string, unknown]> = [['message_start', { type: 'message_start', message: { id, type: 'message', role: 'assistant', model, content: [], stop_reason: null, stop_sequence: null, usage: { input_tokens: 10, output_tokens: 1 } } }]];
    content.forEach((block, index) => {
      if (block.type === 'text') {
        ev.push(['content_block_start', { type: 'content_block_start', index, content_block: { type: 'text', text: '' } }]);
        ev.push(['content_block_delta', { type: 'content_block_delta', index, delta: { type: 'text_delta', text: block.text } }]);
      } else if (block.type === 'thinking') {
        ev.push(['content_block_start', { type: 'content_block_start', index, content_block: { type: 'thinking', thinking: '', signature: '' } }]);
        ev.push(['content_block_delta', { type: 'content_block_delta', index, delta: { type: 'thinking_delta', thinking: block.thinking } }]);
        ev.push(['content_block_delta', { type: 'content_block_delta', index, delta: { type: 'signature_delta', signature: block.signature } }]);
      } else {
        ev.push(['content_block_start', { type: 'content_block_start', index, content_block: { type: 'tool_use', id: block.id, name: block.name, input: {} } }]);
        ev.push(['content_block_delta', { type: 'content_block_delta', index, delta: { type: 'input_json_delta', partial_json: JSON.stringify(block.input) } }]);
      }
      ev.push(['content_block_stop', { type: 'content_block_stop', index }]);
    });
    ev.push(['message_delta', { type: 'message_delta', delta: { stop_reason: stop, stop_sequence: null }, usage: { output_tokens: 5 } }]);
    ev.push(['message_stop', { type: 'message_stop' }]);
    return sse(ev);
  };
  const server = Bun.serve({ port: 0, idleTimeout: 60, async fetch(req) {
    const url = new URL(req.url);
    if (req.method !== 'POST') return Response.json({}, { status: 404 });
    const body = await req.json().catch(() => ({}));
    if (url.pathname.endsWith('/count_tokens')) return Response.json({ input_tokens: 100 });
    if (!url.pathname.endsWith('/v1/messages')) return Response.json({}, { status: 404 });
    const main = Array.isArray(body.tools) && body.tools.length > 0;
    log.push({ main, body });
    const model = body.model ?? 'claude-fake';
    const last = body.messages?.at(-1);
    const blocks = typeof last?.content === 'string' ? [{ type: 'text', text: last.content }] : last?.content ?? [];
    const hasResult = blocks.some((b: any) => b.type === 'tool_result');
    const text = blocks.filter((b: any) => b.type === 'text').map((b: any) => b.text).join('\n');
    let content: any[]; let stop = 'end_turn';
    if (!main) content = [{ type: 'text', text: 'ok' }];
    else if (hasResult) content = [{ type: 'text', text: '两个文件都读完了。' }];
    else if (text.includes('读文件')) {
      content = [
        { type: 'thinking', thinking: '先并行读两个文件。', signature: 'sig-fake-anthropic' },
        { type: 'text', text: '我来读一下。' },
        { type: 'tool_use', id: 'toolu_01A', name: 'mcp__kite__read', input: { path: 'a.txt' } },
        { type: 'tool_use', id: 'toolu_01B', name: 'mcp__kite__read', input: { path: 'b.txt' } },
      ]; stop = 'tool_use';
    } else if (text.includes('结构化')) {
      content = [{ type: 'tool_use', id: 'toolu_03A', name: 'mcp__kite__read', input: { path: 'x.err' } }, { type: 'tool_use', id: 'toolu_03B', name: 'mcp__kite__read', input: { path: 'x.ok' } }]; stop = 'tool_use';
    } else if (text.includes('看图')) {
      content = [{ type: 'tool_use', id: 'toolu_02A', name: 'mcp__kite__read', input: { path: 'slow.png' } }]; stop = 'tool_use';
    } else content = [{ type: 'text', text: `收到：${text.slice(-20)}` }];
    return new Response(reply(model, content, stop), { headers: { 'content-type': 'text/event-stream' } });
  } });
  return { port: server.port, log, stop: () => server.stop(true) };
}

export function isolated(root: string, port: number, cwd: string) {
  const base = claudeOptions(cwd);
  const home = join(root, 'home'); const cfg = join(root, 'claude-config');
  mkdirSync(home, { recursive: true }); mkdirSync(cfg, { recursive: true });
  // 只保留 kited 显式设置的开关和基础变量，不继承本会话的 CLAUDE_* 与凭据。
  const explicit = Object.fromEntries(Object.entries(base.env!).filter(([key, value]) => process.env[key] !== value));
  const env: Record<string, string | undefined> = {
    PATH: '/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin', TMPDIR: process.env.TMPDIR, LANG: 'en_US.UTF-8',
    USER: process.env.USER, SHELL: '/bin/zsh', ...explicit,
    HOME: home, CLAUDE_CONFIG_DIR: cfg, ANTHROPIC_BASE_URL: `http://127.0.0.1:${port}`, ANTHROPIC_API_KEY: 'sk-ant-fake',
  };
  return { options: { ...base, env }, cfg };
}

const PNG = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';
export function kiteServer() {
  return createSdkMcpServer({ name: 'kite', alwaysLoad: true, tools: [
    tool('read', '读取文件', { path: z.string() }, async (args: any) => {
      if (args.path.endsWith('.err')) return { content: [{ type: 'text', text: JSON.stringify({ status: 'error', output: '失败了' }) }], structuredContent: { status: 'error', output: '失败了' }, isError: true };
      if (args.path.endsWith('.ok')) return { content: [{ type: 'text', text: JSON.stringify({ status: 'success', output: '成功' }) }], structuredContent: { status: 'success', output: '成功' } };
      if (!args.path.endsWith('.png')) return { content: [{ type: 'text', text: `${args.path} 的内容\n第二行` }] };
      await Bun.sleep(2500);
      return { content: [{ type: 'text', text: JSON.stringify({ status: 'success', output: '图片' }) }, { type: 'image', data: PNG, mimeType: 'image/png' }] };
    }),
  ] });
}

export class Inbox {
  buf: any[] = []; wake?: () => void; closed = false;
  push(text: string, id: string) { this.buf.push({ type: 'user', message: { role: 'user', content: text }, parent_tool_use_id: null, uuid: id, client_composed: true, origin: { kind: 'human' } }); this.wake?.(); }
  close() { this.closed = true; this.wake?.(); }
  async *[Symbol.asyncIterator]() {
    while (true) {
      while (this.buf.length) yield this.buf.shift();
      if (this.closed) return;
      await new Promise<void>((r) => (this.wake = r)); this.wake = undefined;
    }
  }
}

/** 跑若干条消息，每条等到 result 再发下一条。返回 SDK 消息。 */
export async function drive(options: any, messages: Array<{ id: string; text: string }>) {
  const inbox = new Inbox();
  const seen: any[] = [];
  let resolveResult: (() => void) | undefined;
  const q = query({ prompt: inbox, options: { ...options, mcpServers: { kite: kiteServer() }, hooks: {
    UserPromptSubmit: [{ hooks: [async () => ({ hookSpecificOutput: { hookEventName: 'UserPromptSubmit', additionalContext: 'KITE通知：配置已变化（回合开头）' } })] }],
    PostToolBatch: [{ hooks: [async () => ({ hookSpecificOutput: { hookEventName: 'PostToolBatch', additionalContext: 'KITE通知：工具批次后的更新' } })] }],
  } } });
  const loop = (async () => { for await (const m of q) { seen.push(m); if (m.type === 'result') resolveResult?.(); } })();
  for (const m of messages) {
    const done = new Promise<void>((r) => (resolveResult = r));
    inbox.push(m.text, m.id);
    await done;
  }
  inbox.close();
  await loop;
  return seen;
}

export function sessionFile(cfg: string, sessionId: string): string {
  const projects = join(cfg, 'projects');
  for (const dir of readdirSync(projects)) {
    const path = join(projects, dir, `${sessionId}.jsonl`);
    try { readFileSync(path); return path; } catch {}
  }
  throw new Error('找不到会话文件');
}

if (import.meta.main) {
  const out = (await import("node:path")).resolve(process.argv[2]);
  mkdirSync(out, { recursive: true });
  const cwd = join(out, 'work'); mkdirSync(cwd, { recursive: true });
  writeFileSync(join(cwd, 'a.txt'), 'a'); writeFileSync(join(cwd, 'b.txt'), 'b');
  const api = fakeApi();
  const { options, cfg } = isolated(join(out, 'native'), api.port, cwd);
  const sessionId = crypto.randomUUID();
  await drive({ ...options, sessionId, model: 'claude-sonnet-4-5', title: '实验' }, [
    { id: crypto.randomUUID(), text: '请读文件 a 和 b' },
    { id: crypto.randomUUID(), text: '第二个问题' },
  ]);
  api.stop();
  const file = sessionFile(cfg, sessionId);
  writeFileSync(join(out, 'native.jsonl'), readFileSync(file));
  writeFileSync(join(out, 'native-requests.json'), JSON.stringify(api.log.filter((l) => l.main).map((l) => l.body), null, 2));
  console.log(JSON.stringify({ sessionId, file, requests: api.log.filter((l) => l.main).length }));
}
