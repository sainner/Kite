/** 实验 5：合成插话与图片工具结果，比对实验 4 的第 2 次请求。用法：bun synth-midturn.ts <输出目录> */
import { fakeApi, isolated, kiteServer } from './native.ts';
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
const { query } = await import('../../kited/node_modules/@anthropic-ai/claude-agent-sdk/sdk.mjs');
const out = resolve(process.argv[2]);
const cwd = join(out, 'work');
const PNG = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';
const sessionId = crypto.randomUUID();
let parent: string | null = null;
const rows: any[] = [];
const entry = (fields: any) => { const uuid = crypto.randomUUID(); rows.push({ parentUuid: parent, isSidechain: false, sessionId, timestamp: new Date().toISOString(), uuid, ...fields }); parent = uuid; return uuid; };
entry({ type: 'user', message: { role: 'user', content: '请看图' }, origin: { kind: 'human' } });
entry({ type: 'assistant', message: { id: 'msg_y1', type: 'message', role: 'assistant', model: 'claude-sonnet-4-5', content: [{ type: 'tool_use', id: 'toolu_02A', name: 'mcp__kite__read', input: { path: 'slow.png' } }], stop_reason: null, stop_sequence: null, usage: { input_tokens: 0, output_tokens: 0 } } });
entry({ type: 'user', message: { role: 'user', content: [{ tool_use_id: 'toolu_02A', type: 'tool_result', content: [{ type: 'text', text: JSON.stringify({ status: 'success', output: '图片' }) }, { type: 'image', source: { type: 'base64', media_type: 'image/png', data: PNG } }] }] } });
entry({ type: 'attachment', attachment: { type: 'queued_command', prompt: '顺便补充一句插话', source_uuid: crypto.randomUUID(), commandMode: 'prompt', origin: { kind: 'human' }, humanTurn: true } });
const api = fakeApi();
const { options, cfg } = isolated(join(out, 'synth-midturn'), api.port, cwd);
const dir = join(cfg, 'projects', cwd.replace(/[^a-zA-Z0-9]/g, '-'));
mkdirSync(dir, { recursive: true });
writeFileSync(join(dir, `${sessionId}.jsonl`), rows.map((r) => JSON.stringify(r)).join('\n') + '\n');
// 不发新消息：以 resume 后续接未完成的回合为目标太复杂，这里改为发一条新消息后比对前缀。
const inbox = { async *[Symbol.asyncIterator]() { yield { type: 'user', message: { role: 'user', content: '下一条' }, parent_tool_use_id: null }; } };
const q = query({ prompt: inbox, options: { ...options, resume: sessionId, model: 'claude-sonnet-4-5', mcpServers: { kite: kiteServer() } } });
for await (const m of q) if (m.type === 'result') break;
api.stop();
const synth = api.log.filter((l) => l.main)[0].body.messages;
const native = JSON.parse(readFileSync(join(out, 'midturn-requests.json'), 'utf8'))[1].messages;
const strip = (m: any[]) => JSON.parse(JSON.stringify(m), (k, v) => k === 'cache_control' ? undefined : v);
const prefix = strip(synth).slice(0, native.length);
// 原生第 2 次请求末尾是 tool_result+插话；合成历史之后紧跟新消息，CLI 会并进同一条 user 消息。
console.log(JSON.stringify(strip(native).slice(0, -1)) === JSON.stringify(prefix.slice(0, -1)));
writeFileSync(join(out, 'synth-midturn-request.json'), JSON.stringify(synth, null, 2));
console.log(JSON.stringify(strip(native).at(-1)).slice(0, 2000)); console.log(JSON.stringify(prefix.at(-1)).slice(0, 2000));
