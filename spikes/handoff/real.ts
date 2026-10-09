/**
 * 实验 7：真实 Anthropic API。先真实跑一轮 Claude（取得带签名的 thinking），再用 kited 的生产翻译代码
 * 追加一段 harness 回合（OpenAI 风格 call_ ID、应被丢弃的加密 reasoning），resume 后问只有工具结果里才有的暗号。
 * 用本机默认 Claude 配置目录与登录，会消耗订阅额度（两次小请求）。用法：bun real.ts <工作目录> [模型]
 */
import { mkdirSync, writeFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { claudeOptions } from '../../kited/src/claude/options.ts';
import { harnessToClaude } from '../../kited/src/handoff/handoff.ts';
import { appendClaudeEntries, readClaudeEntries } from '../../kited/src/handoff/claude-records.ts';
import type { JournalEvent, JournalRecord } from '../../kited/src/harness/types.ts';
import { Inbox, kiteServer } from './native.ts';
const { query } = await import('../../kited/node_modules/@anthropic-ai/claude-agent-sdk/sdk.mjs');

const cwd = resolve(process.argv[2]);
const model = process.argv[3] ?? 'sonnet';
mkdirSync(cwd, { recursive: true });
const base = claudeOptions(cwd);
// 去掉本机 Claude Code 会话带进来的变量，按 kited 的方式启动。
const env = Object.fromEntries(Object.entries(base.env!).filter(([key]) => !/^(CLAUDECODE|CLAUDE_PID|CLAUDE_EFFORT|CLAUDE_CODE_(ENTRYPOINT|MESSAGING_.*|EXECPATH|SESSION_ID|CHILD_SESSION|SESSION_ATTENDED))$/.test(key)));
const options = { ...base, env, model, effort: 'max' as const, mcpServers: { kite: kiteServer() } };

async function turn(extra: Record<string, unknown>, text: string) {
  const inbox = new Inbox();
  const q = query({ prompt: inbox, options: { ...options, ...extra } });
  inbox.push(text, crypto.randomUUID());
  let result: any;
  for await (const m of q) if (m.type === 'result') { result = m; inbox.close(); }
  return result;
}

const sessionId = crypto.randomUUID();
const first = await turn({ sessionId, title: '真实翻译实验' }, '不要调用工具。一个三位数，各位数字之和是 19，百位数字比个位数字大 3，把百位和个位对调后得到的数比原数小 297，'
  + '而且十位数字是个位数字的两倍减一。请仔细推理，检查所有条件，最后只回答这个三位数。');
const native = readClaudeEntries(cwd, sessionId);
const thinking = native.some((entry) => entry.type === 'assistant'
  && (entry.message as any).content.some((block: any) => block.type === 'thinking' && block.signature));
console.log(JSON.stringify({ step: 'native', ok: !first.is_error, answer: first.result, signedThinking: thinking }));

let seq = 0;
const at = Date.now();
const records = ([
  { type: 'input.received', input: { id: 'h1', text: '读一下 secret.txt', source: 'human' } },
  { type: 'turn.started', turnId: 't1' },
  { type: 'request.started', turnId: 't1', requestId: 'r1', inputIds: ['h1'], contextId: 'c', configurationId: 'g' },
  { type: 'model.item', turnId: 't1', requestId: 'r1', item: { id: 'rs_1', raw: { type: 'reasoning', summary: [], encrypted_content: 'gAAAAopaque' } } },
  { type: 'model.item', turnId: 't1', requestId: 'r1', item: { id: 'msg_1', raw: { type: 'message', role: 'assistant', content: [{ type: 'output_text', text: '我来读取。' }] } } },
  { type: 'model.item', turnId: 't1', requestId: 'r1', item: { id: 'fc_1', raw: { type: 'function_call', call_id: 'call_Pv8QZ2xKfT3mLwN9aB4cD7eH', name: 'read', arguments: '{"path":"secret.txt"}' },
    call: { id: 'call_Pv8QZ2xKfT3mLwN9aB4cD7eH', name: 'read', arguments: { path: 'secret.txt' } } } },
  { type: 'tool.started', turnId: 't1', requestId: 'r1', callId: 'call_Pv8QZ2xKfT3mLwN9aB4cD7eH' },
  { type: 'tool.finished', turnId: 't1', requestId: 'r1', callId: 'call_Pv8QZ2xKfT3mLwN9aB4cD7eH', result: { status: 'success', output: '文件内容：暗号是 MANGO-42。' } },
  { type: 'request.completed', turnId: 't1', requestId: 'r1', responseId: 'resp_1', needsFollowUp: true },
  { type: 'request.started', turnId: 't1', requestId: 'r2', inputIds: [], contextId: 'c', configurationId: 'g' },
  { type: 'model.item', turnId: 't1', requestId: 'r2', item: { id: 'msg_2', raw: { type: 'message', role: 'assistant', content: [{ type: 'output_text', text: '读完了。' }] } } },
  { type: 'request.completed', turnId: 't1', requestId: 'r2', responseId: 'resp_2', needsFollowUp: false },
  { type: 'turn.finished', turnId: 't1', outcome: { kind: 'completed' } },
] as JournalEvent[]).map((event) => ({ ...event, version: 1, seq: ++seq, at: at + seq })) as JournalRecord[];
const parent = native.findLast((entry) => entry.uuid && !entry.isSidechain)?.uuid ?? null;
const translated = harnessToClaude(records, 0, { nativeId: sessionId, cwd, model, parent })!;
await appendClaudeEntries(cwd, sessionId, translated.entries);
writeFileSync(resolve(cwd, 'synthesized.json'), JSON.stringify(translated.entries, null, 2));

const second = await turn({ resume: sessionId }, '刚才 read 工具读到的暗号是什么？只回答暗号本身，不要调用工具。');
console.log(JSON.stringify({ step: 'resumed', ok: !second.is_error, subtype: second.subtype, answer: second.result, errors: second.errors }));
