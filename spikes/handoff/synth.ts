/**
 * 实验 2：只用中立内容（人发消息、通知正文、助手块、工具调用与结果）合成 Claude 原生 jsonl，
 * resume 后发同一条消息，比对请求与原生会话第 3 次请求是否一致。
 * 用法：bun synth.ts <实验 1 的输出目录> <变体：full|nothinking|minimal>
 */
import { fakeApi, isolated, drive } from './native.ts';
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';

type Neutral =
  | { kind: 'human'; text: string }
  | { kind: 'notice'; hook: 'UserPromptSubmit' | 'PostToolBatch'; text: string }
  | { kind: 'assistant'; messageId: string; blocks: any[] }
  | { kind: 'result'; callId: string; content: any[]; isError?: boolean };

const out = resolve(process.argv[2]);
const variant = process.argv[3] ?? 'full';
const cwd = join(out, 'work');

// 按「中立表示」构造，模拟从 harness journal 翻译过来的内容；不读原生记录的任何 opaque 字段。
const neutral: Neutral[] = [
  { kind: 'human', text: '请读文件 a 和 b' },
  { kind: 'notice', hook: 'UserPromptSubmit', text: 'KITE通知：配置已变化（回合开头）' },
  { kind: 'assistant', messageId: 'msg_x1', blocks: [
    ...(variant === 'full' ? [{ type: 'thinking', thinking: '先并行读两个文件。', signature: 'sig-fake-anthropic' }] : []),
    { type: 'text', text: '我来读一下。' },
    { type: 'tool_use', id: 'toolu_01A', name: 'mcp__kite__read', input: { path: 'a.txt' } },
    { type: 'tool_use', id: 'toolu_01B', name: 'mcp__kite__read', input: { path: 'b.txt' } },
  ] },
  { kind: 'result', callId: 'toolu_01A', content: [{ type: 'text', text: 'a.txt 的内容\n第二行' }] },
  { kind: 'result', callId: 'toolu_01B', content: [{ type: 'text', text: 'b.txt 的内容\n第二行' }] },
  { kind: 'notice', hook: 'PostToolBatch', text: 'KITE通知：工具批次后的更新' },
  { kind: 'assistant', messageId: 'msg_x2', blocks: [{ type: 'text', text: '两个文件都读完了。' }] },
];

const sessionId = crypto.randomUUID();
const minimal = variant === 'minimal';
let parent: string | null = null;
let at = Date.parse('2026-10-08T00:00:00Z');
const rows: any[] = [];
const toolOwner = new Map<string, string>();
function entry(fields: Record<string, unknown>) {
  const uuid = crypto.randomUUID();
  const row = { parentUuid: parent, isSidechain: false, ...(minimal ? {} : { userType: 'external', entrypoint: 'sdk-ts', cwd, version: '2.1.280', gitBranch: '' }),
    sessionId, timestamp: new Date(at += 1000).toISOString(), uuid, ...fields };
  rows.push(row); parent = uuid; return uuid;
}
for (const item of neutral) {
  if (item.kind === 'human') entry({ type: 'user', message: { role: 'user', content: item.text }, origin: { kind: 'human' } });
  else if (item.kind === 'notice') entry({ type: 'attachment', attachment: {
    type: 'hook_additional_context', content: [item.text], hookName: item.hook, toolUseID: `hook-${crypto.randomUUID()}`, hookEvent: item.hook } });
  else if (item.kind === 'assistant') {
    // 原生按块拆成多条、共用 message.id；这里也按块拆，tool_result 挂到对应 tool_use 那条下面。
    for (const block of item.blocks) {
      const id = entry({ type: 'assistant', message: { id: item.messageId, type: 'message', role: 'assistant', model: 'claude-sonnet-4-5',
        content: [block], stop_reason: null, stop_sequence: null, usage: { input_tokens: 0, output_tokens: 0 } } });
      if (block.type === 'tool_use') toolOwner.set(block.id, id);
    }
  } else {
    const saved = parent;
    // 并行工具：原生让每个结果挂在各自 tool_use 条目下，链按最后一个结果继续。
    parent = toolOwner.get(item.callId)!;
    entry({ type: 'user', message: { role: 'user', content: [{ tool_use_id: item.callId, type: 'tool_result', content: item.content, ...(item.isError ? { is_error: true } : {}) }] },
      sourceToolAssistantUUID: toolOwner.get(item.callId) });
    void saved;
  }
}
const cfgRoot = join(out, `synth-${variant}`);
const api = fakeApi();
const { options, cfg } = isolated(cfgRoot, api.port, cwd);
const dir = join(cfg, 'projects', cwd.replace(/[^a-zA-Z0-9]/g, '-'));
mkdirSync(dir, { recursive: true });
writeFileSync(join(dir, `${sessionId}.jsonl`), rows.map((row) => JSON.stringify(row)).join('\n') + '\n');
await drive({ ...options, resume: sessionId, model: 'claude-sonnet-4-5' }, [{ id: crypto.randomUUID(), text: '第二个问题' }]);
api.stop();
const synthRequest = api.log.filter((l) => l.main)[0].body;
const nativeRequest = JSON.parse(readFileSync(join(out, 'native-requests.json'), 'utf8'))[2];
writeFileSync(join(out, `synth-${variant}-request.json`), JSON.stringify(synthRequest, null, 2));
const strip = (body: any) => ({ ...body, metadata: undefined });
const same = (key: string) => JSON.stringify(strip(nativeRequest)[key]) === JSON.stringify(strip(synthRequest)[key]);
console.log(JSON.stringify({ variant, messages: same('messages'), system: same('system'), tools: same('tools'), thinking: same('thinking'),
  whole: JSON.stringify(strip(nativeRequest)) === JSON.stringify(strip(synthRequest)) }));
