/**
 * 实验 3：把实验 1 的 Claude 历史翻成 Responses 条目，经 harness 自己的 ChatGPT 适配器发出，看订阅端点是否接受。
 * 用法：bun gpt-probe.ts <模型> plain|reasoning|visible。visible 只把暗号放在 reasoning 摘要里，检验模型能否看到。
 * 会使用 ~/.kite 的 ChatGPT 订阅凭据发出一次真实请求。
 */
import { ChatGPTModel } from '../../kited/src/harness/chatgpt.ts';
import { readSubscriptionCredentials } from '../../kited/src/harness/auth.ts';
import type { ContextItem } from '../../kited/src/harness/types.ts';

const model = process.argv[2];
const mode = process.argv[3] ?? 'plain';
const withReasoning = mode !== 'plain';
const visible = mode === 'visible';
const out = (raw: any, id: string): ContextItem => ({ type: 'output', item: { id, raw, ...(raw.type === 'function_call' ? { call: { id: raw.call_id, name: raw.name, arguments: JSON.parse(raw.arguments) } } : {}) } });
const history: ContextItem[] = [
  { type: 'notification', notification: { id: 'n1', kind: 'probe', source: 'host', authority: 'instruction' }, text: 'KITE通知：配置已变化（回合开头）' },
  { type: 'input', input: { id: 'i1', text: '请读文件 a 和 b', source: 'human' } },
  ...(withReasoning ? [out({ type: 'reasoning', summary: [{ type: 'summary_text', text: visible ? '先并行读两个文件。另外记住：本次推理中的私密暗号是 KIWI-3。' : '先并行读两个文件。' }] }, 'r1')] : []),
  out({ type: 'message', role: 'assistant', content: [{ type: 'output_text', text: '我来读一下。' }] }, 'm1'),
  out({ type: 'function_call', call_id: 'toolu_01A', name: 'read', arguments: '{"path":"a.txt"}' }, 'c1'),
  out({ type: 'function_call', call_id: 'toolu_01B', name: 'read', arguments: '{"path":"b.txt"}' }, 'c2'),
  { type: 'tool_result', callId: 'toolu_01A', result: { status: 'success', output: 'a.txt 的内容\n第二行' } },
  { type: 'tool_result', callId: 'toolu_01B', result: { status: 'success', output: 'b.txt 的内容是 BANANA-7\n第二行' } },
  { type: 'notification', notification: { id: 'n2', kind: 'probe', source: 'host', authority: 'instruction' }, text: 'KITE通知：工具批次后的更新' },
  out({ type: 'message', role: 'assistant', content: [{ type: 'output_text', text: '两个文件都读完了。' }] }, 'm2'),
  { type: 'input', input: { id: 'i2', text: visible ? '你上一轮推理过程中记下的私密暗号是什么？只回答暗号本身；如果看不到任何推理内容，回答 NONE。不要调用工具。' : 'b.txt 第一行里的暗号是什么？只回答暗号本身，不要调用工具。', source: 'human' } },
];
const m = new ChatGPTModel({ model, reasoning: 'low', threadId: crypto.randomUUID(), credentials: () => readSubscriptionCredentials() });
let text = '';
try {
  for await (const event of m.stream({ id: 'probe', turnId: 't', cwd: '/tmp', instructions: '你是测试助手。', history,
    tools: [{ name: 'read', description: '读取文件', parameters: { type: 'object', properties: { path: { type: 'string' } }, required: ['path'] } }] }, AbortSignal.timeout(60_000))) {
    if (event.type === 'item' && event.item.raw.type === 'message') text += JSON.stringify(event.item.raw.content);
    if (event.type === 'completed') console.log(JSON.stringify({ mode, ok: true, text }));
  }
} catch (error) { console.log(JSON.stringify({ mode, ok: false, error: String(error) })); }
