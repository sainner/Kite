/**
 * 实验：在 mod.ts 压缩过的会话上追加一次 Kite 重组——分界之后拷贝当前主链、助手消息换新 message.id，再更新 last-prompt——
 * 恢复后检查请求里是否还有重复。用法：bun cleanup.ts <mod.ts 的输出目录>
 */
import { appendFileSync, readFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { drive, fakeApi, isolated, sessionFile } from '../handoff/native.ts';

const out = resolve(process.argv[2]);
const cwd = join(out, 'work');
const api = fakeApi();
const { options, cfg } = isolated(join(out, 'mod'), api.port, cwd);
const file = (await import('node:fs')).readdirSync(join(cfg, 'projects', cwd.replace(/[^a-zA-Z0-9]/g, '-'))).find((name) => name.endsWith('.jsonl'))!;
const path = join(cfg, 'projects', cwd.replace(/[^a-zA-Z0-9]/g, '-'), file);
const id = file.replace('.jsonl', '');
const rows = readFileSync(path, 'utf8').split('\n').filter(Boolean).map((line) => JSON.parse(line));
const byId = new Map(rows.filter((row) => row.uuid).map((row) => [row.uuid, row]));
const leaf = rows.findLast((row) => row.type === 'last-prompt').leafUuid;
// 从叶子沿 parentUuid 走到根（CLI 写的压缩分界），得到当前主链。
const chain: any[] = [];
for (let row = byId.get(leaf); row; row = row.parentUuid ? byId.get(row.parentUuid) : undefined) chain.unshift(row);
const body = chain.filter((row) => !(row.type === 'system' && row.subtype === 'compact_boundary'));
let at = Date.now();
const write = (row: any) => appendFileSync(path, JSON.stringify(row) + '\n');
const boundary = crypto.randomUUID();
write({ parentUuid: null, logicalParentUuid: leaf, isSidechain: false, type: 'system', subtype: 'compact_boundary', content: 'Conversation compacted',
  isMeta: false, timestamp: new Date(++at).toISOString(), uuid: boundary, level: 'info', compactMetadata: { trigger: 'manual', preTokens: 0 },
  userType: 'external', entrypoint: 'sdk-ts', cwd, sessionId: id, kiteRebase: 'cleanup' });
const ids = new Map<string, string>();
const messageIds = new Map<string, string>();
let parent = boundary;
for (const row of body) {
  const uuid = crypto.randomUUID();
  ids.set(row.uuid, uuid);
  const owner = row.sourceToolAssistantUUID ? ids.get(row.sourceToolAssistantUUID) : undefined;
  const message = row.type === 'assistant' ? { ...row.message, id: messageIds.get(row.message.id) ?? messageIds.set(row.message.id, `msg_kite_${crypto.randomUUID()}`).get(row.message.id) } : row.message;
  write({ ...row, uuid, parentUuid: owner ?? parent, timestamp: new Date(++at).toISOString(), ...(message ? { message } : {}),
    ...(owner ? { sourceToolAssistantUUID: owner } : {}), kiteRebase: 'cleanup' });
  parent = uuid;
}
write({ type: 'last-prompt', lastPrompt: '第四个问题', leafUuid: parent, sessionId: id, kiteRebase: 'cleanup' });
await drive({ ...options, resume: id, model: 'claude-sonnet-4-5' }, [{ id: crypto.randomUUID(), text: '第五个问题' }]);
api.stop();
const messages = api.log.filter((entry) => entry.main).at(-1).body.messages;
const brief = messages.map((message: any) => `${message.role}: ${(typeof message.content === 'string' ? [message.content]
  : message.content.map((block: any) => block.type === 'text' ? block.text : block.type === 'tool_use' ? `tool_use ${block.id}` : block.type === 'tool_result' ? `tool_result ${block.tool_use_id}` : block.type)).join(' | ').replace(/\s+/g, ' ').slice(0, 120)}`);
console.log(JSON.stringify({ chain: body.length, resumed: brief }, null, 2));
