/**
 * 实验：在已运行的原生会话末尾追加压缩分界（compact_boundary）和一份重组的历史——第一轮原样拷贝、第二轮换成摘要、
 * 第三轮原样拷贝——resume 后检查发给模型的消息，以及 SDK 显示接口（getSessionMessages）能否读到分界之前的条目。
 * 用本机假 Anthropic 端点，不消耗额度。用法：bun rebase.ts <输出目录>
 */
import { appendFileSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { drive, fakeApi, isolated, sessionFile } from '../handoff/native.ts';
const { getSessionMessages } = await import('../../kited/node_modules/@anthropic-ai/claude-agent-sdk/sdk.mjs');

const out = resolve(process.argv[2]);
const cwd = join(out, 'work');
mkdirSync(cwd, { recursive: true });
writeFileSync(join(cwd, 'a.txt'), 'a'); writeFileSync(join(cwd, 'b.txt'), 'b');
const api = fakeApi();
const { options, cfg } = isolated(join(out, 'rebase'), api.port, cwd);
// 显示接口在本进程读会话，须指向同一隔离配置目录。
process.env.CLAUDE_CONFIG_DIR = cfg;
const model = 'claude-sonnet-4-5';
const sessionId = crypto.randomUUID();
await drive({ ...options, sessionId, model }, [
  { id: crypto.randomUUID(), text: '请读文件 a 和 b' },
  { id: crypto.randomUUID(), text: '第二个问题' },
  { id: crypto.randomUUID(), text: '第三个问题' },
]);
const file = sessionFile(cfg, sessionId);
const native = readFileSync(file, 'utf8').split('\n').filter(Boolean).map((line) => JSON.parse(line));
const nativeRequests = api.log.filter((entry) => entry.main).map((entry) => entry.body);

// 主链上的对话条目，按人发消息分成三轮。
const chain = native.filter((row) => row.uuid && !row.isSidechain && ['user', 'assistant', 'attachment'].includes(row.type));
const starts = chain.flatMap((row, index) => row.type === 'user' && typeof row.message?.content === 'string' && row.origin?.kind === 'human' ? [index] : []);
if (starts.length !== 3) throw new Error(`期望三轮，实际 ${starts.length}`);
const turns = [chain.slice(starts[0], starts[1]), chain.slice(starts[1], starts[2]), chain.slice(starts[2])];
const leaf = native.filter((row) => row.uuid && !row.isSidechain).at(-1).uuid;

let at = Date.now();
const ids = new Map<string, string>();
let parent: string;
const write = (row: any) => { appendFileSync(file, JSON.stringify(row) + '\n'); };
const base = () => ({ isSidechain: false, userType: 'external', entrypoint: 'sdk-ts', cwd, sessionId, timestamp: new Date(++at).toISOString() });
const boundary = crypto.randomUUID();
// 字段顺序照原生分界：CLI 加载时只在每行开头一段里找 "compact_boundary"，type、subtype 靠后就认不出来。
write({ parentUuid: null, logicalParentUuid: leaf, isSidechain: false, type: 'system', subtype: 'compact_boundary', content: 'Conversation compacted',
  isMeta: false, timestamp: new Date(++at).toISOString(), uuid: boundary, level: 'info', compactMetadata: { trigger: 'manual', preTokens: 0 },
  userType: 'external', entrypoint: 'sdk-ts', cwd, sessionId, kite: { rebase: 'spike' } });
parent = boundary;
const copy = (row: any) => {
  const uuid = crypto.randomUUID();
  ids.set(row.uuid, uuid);
  // 工具结果挂在各自的调用下；其余接在上一条后面。
  const owner = row.sourceToolAssistantUUID ? ids.get(row.sourceToolAssistantUUID) : undefined;
  // 同一 message.id 的助手条目会被合并成一条消息；拷贝换新 id，否则分界之前的原条目也会并进来（第一次运行观察到重复）。
  const message = row.type === 'assistant' && process.env.KEEP_MESSAGE_ID !== '1' ? { ...row.message, id: `${row.message.id}_rebase` } : row.message;
  write({ ...row, ...base(), uuid, parentUuid: owner ?? parent, ...(message ? { message } : {}),
    ...(owner ? { sourceToolAssistantUUID: owner } : {}), kite: { rebase: 'spike' } });
  parent = uuid;
};
for (const row of turns[0]) copy(row);
{
  const uuid = crypto.randomUUID();
  write({ parentUuid: parent, ...base(), type: 'user', message: { role: 'user', content: '以下是先前一段对话的摘要，它替代了那段对话的原文：\n\n第二轮问了第二个问题，已经回答。' }, uuid, kite: { rebase: 'spike' } });
  parent = uuid;
}
for (const row of turns[2]) copy(row);
// 恢复与显示都从 last-prompt 记的叶子取主链；不更新它，新输入会接到分界之前的旧叶子上。
const prompt = native.findLast((row) => row.type === 'last-prompt');
write({ ...prompt, leafUuid: parent });
const rebased = await getSessionMessages(sessionId, { dir: cwd, includeSystemMessages: true });

const before = api.log.length;
await drive({ ...options, resume: sessionId, model }, [{ id: crypto.randomUUID(), text: '第四个问题' }]);
api.stop();
const resumed = api.log.slice(before).filter((entry) => entry.main)[0].body;
const brief = (messages: any[]) => messages.map((message: any) => `${message.role}: ${(typeof message.content === 'string' ? [message.content]
  : message.content.map((block: any) => block.type === 'text' ? block.text : block.type === 'tool_use' ? `tool_use ${block.id}` : block.type === 'tool_result' ? `tool_result ${block.tool_use_id}` : block.type)).join(' | ').replace(/\s+/g, ' ').slice(0, 140)}`);
const display = await getSessionMessages(sessionId, { dir: cwd, includeSystemMessages: true });
const result = {
  nativeThirdRequest: brief(nativeRequests[nativeRequests.length - 1].messages),
  resumedRequest: brief(resumed.messages),
  // 第一轮的消息应与原生请求逐字节一致（含 thinking 签名）。
  firstTurnIdentical: JSON.stringify(resumed.messages.slice(0, 3)) === JSON.stringify(nativeRequests[nativeRequests.length - 1].messages.slice(0, 3)),
  sameSystem: JSON.stringify(resumed.system) === JSON.stringify(nativeRequests[0].system),
  sameTools: JSON.stringify(resumed.tools) === JSON.stringify(nativeRequests[0].tools),
  rebasedDisplay: rebased.map((message: any) => `${message.type}${message.subtype ? ':' + message.subtype : ''} ${ids.has(message.uuid) ? '原文' : [...ids.values()].includes(message.uuid) ? '拷贝' : message.uuid === boundary ? '分界' : ''}`),
  display: display.map((message: any) => `${message.type}${message.subtype ? ':' + message.subtype : ''} ${ids.has(message.uuid) ? '原文' : [...ids.values()].includes(message.uuid) ? '拷贝' : message.uuid === boundary ? '分界' : ''}`),
};
writeFileSync(join(out, 'result.json'), JSON.stringify(result, null, 2));
writeFileSync(join(out, 'requests.json'), JSON.stringify({ native: nativeRequests, resumed }, null, 2));
console.log(JSON.stringify(result, null, 2));
