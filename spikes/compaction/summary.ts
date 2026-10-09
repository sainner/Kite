/**
 * 实验：在已运行的原生会话上用 resume + forkSession + persistSession: false 发一条摘要指令、禁用工具，
 * 检查发给模型的请求前缀是否与正常续接相同（能命中缓存），以及会话目录里是否多出文件、原会话是否被改动。
 * 用本机假 Anthropic 端点，不消耗额度。用法：bun summary.ts <输出目录>
 */
import { mkdirSync, readdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { drive, fakeApi, isolated, sessionFile } from '../handoff/native.ts';
const { query } = await import('../../kited/node_modules/@anthropic-ai/claude-agent-sdk/sdk.mjs');

const out = resolve(process.argv[2]);
const cwd = join(out, 'work');
mkdirSync(cwd, { recursive: true });
writeFileSync(join(cwd, 'a.txt'), 'a'); writeFileSync(join(cwd, 'b.txt'), 'b');
const api = fakeApi();
const { options, cfg } = isolated(join(out, 'summary'), api.port, cwd);
const model = 'claude-sonnet-4-5';
const sessionId = crypto.randomUUID();
await drive({ ...options, sessionId, model }, [
  { id: crypto.randomUUID(), text: '请读文件 a 和 b' },
  { id: crypto.randomUUID(), text: '第二个问题' },
]);
const file = sessionFile(cfg, sessionId);
const before = readFileSync(file, 'utf8');
const filesBefore = readdirSync(dirname(file)).sort();

// 正常续接作对照：同样带 hook，比较前缀。
const marker = api.log.length;
await drive({ ...options, resume: sessionId, forkSession: true, persistSession: false, model }, [{ id: crypto.randomUUID(), text: '对照问题' }]);
const control = api.log.slice(marker).filter((entry) => entry.main)[0]?.body;

const start = api.log.length;
let text = '';
let result: any;
for await (const message of query({ prompt: '请把上面的对话写成摘要，只输出摘要正文。', options: {
  ...options, resume: sessionId, forkSession: true, persistSession: false, model, maxTurns: 1,
} })) {
  if (message.type === 'assistant') for (const block of message.message.content) if (block.type === 'text') text += block.text;
  if (message.type === 'result') result = message;
}
api.stop();
const requests = api.log.slice(start);
const summary = requests.find((entry) => entry.main)?.body ?? requests.at(-1)?.body;
const report = {
  result: result?.subtype, text,
  requests: requests.map((entry) => ({ main: entry.main, tools: entry.body.tools?.length ?? 0, messages: entry.body.messages?.length })),
  // 除最后一条用户消息外，与对照请求逐字节一致即可命中同一前缀缓存。
  samePrefix: !!control && !!summary && JSON.stringify(summary.messages.slice(0, -1)) === JSON.stringify(control.messages.slice(0, -1)),
  sameSystem: !!control && JSON.stringify(summary?.system) === JSON.stringify(control.system),
  sameTools: !!control && JSON.stringify(summary?.tools) === JSON.stringify(control.tools),
  originalUnchanged: readFileSync(file, 'utf8') === before,
  newFiles: readdirSync(dirname(file)).sort().filter((name) => !filesBefore.includes(name)),
};
writeFileSync(join(out, 'result.json'), JSON.stringify(report, null, 2));
console.log(JSON.stringify(report, null, 2));
