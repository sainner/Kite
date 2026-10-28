/**
 * 比较「识别时就润色」和「识别后再整理一次」：每段样本跑四种做法，按真实语速推音频，打印各自的结果、关键词和说完到出字的耗时。
 *   现行：qwen3-asr-flash-realtime 说完一次提交，带对话，定稿做确定性恢复（直接用 kited 的 voice/ 代码）
 *   现行 + DeepSeek：现行的结果再按 kited 的「语音整理」模板交给 DeepSeek 整理
 *   新型号：qwen-audio-3.1-asr-flash-message，不润色，对话里的标识符作热词（不带对话，见 message），同样做确定性恢复
 *   新型号 + 润色：同上，打开 disfluency_removal_enabled
 * 用法：bun spikes/voice-polish/run.ts <样本目录> [只跑哪几种，逗号分隔：current,deepseek,message,polish]
 * 密钥写在样本目录的 .env：DASHSCOPE_API_KEY（北京地域百炼），DEEPSEEK_API_KEY；新型号的地址可用 QWEN_MESSAGE_URL 改，
 * 业务空间用 DASHSCOPE_WORKSPACE 带上。DeepSeek 的型号与思考强度可用 DEEPSEEK_MODEL、DEEPSEEK_REASONING 改。
 */
import { readdir } from 'node:fs/promises';
import { join } from 'node:path';
import { assembleContext, bindContext, sceneValues } from '../../kited/src/harness/context/assembler.ts';
import { DeepSeekModel } from '../../kited/src/harness/deepseek.ts';
import { LightTasks } from '../../kited/src/light-tasks.ts';
import { recognize } from '../../kited/src/voice/dashscope.ts';
import { identifiers, restore } from '../../kited/src/voice/restore.ts';
import { voiceTemplate, voiceTidyTemplate } from '../../kited/src/voice/sessions.ts';
import { exactHits, termHits } from '../voice-asr/score.ts';

const [root, only] = process.argv.slice(2);
if (!root) {
  console.error('用法：bun run.ts <样本目录> [current,deepseek,message,polish]');
  process.exit(1);
}
const env = Bun.file(join(root, '.env'));
if (await env.exists()) {
  for (const line of (await env.text()).split('\n')) {
    const match = line.match(/^\s*([A-Z_][A-Z0-9_]*)\s*=\s*(.*?)\s*$/);
    if (match && process.env[match[1]!] === undefined) process.env[match[1]!] = match[2]!.replace(/^(['"])(.*)\1$/, '$2');
  }
}
const dashscope = process.env.DASHSCOPE_API_KEY;
if (!dashscope) {
  console.error('样本目录的 .env 里要有 DASHSCOPE_API_KEY');
  process.exit(1);
}
const methods = (only ?? 'current,deepseek,message,polish').split(',');
if (methods.includes('deepseek') && !process.env.DEEPSEEK_API_KEY) {
  console.error('没有 DEEPSEEK_API_KEY，跳过「现行 + DeepSeek」');
  methods.splice(methods.indexOf('deepseek'), 1);
}

const BunWebSocket = WebSocket as unknown as new (url: string, options: Bun.WebSocketOptions) => WebSocket;
const tasks = new LightTasks({
  model: ({ model }) => new DeepSeekModel({ ...model, key: async () => process.env.DEEPSEEK_API_KEY }),
  onResult: ({ error }) => { if (error) console.error(`  DeepSeek 出错：${error}`); },
});

/** 对话按空行分轮，从旧到新，第一轮是用户说的，之后用户和 agent 交替。 */
function turns(conversation: string | null) {
  return (conversation ?? '').split(/\n\s*\n/).map((turn) => turn.trim()).filter(Boolean)
    .map((text, index) => ({ role: index % 2 ? 'agent' as const : 'user' as const, text }));
}

/** 按每 100 毫秒一包、真实语速推音频，返回最后一包推出去的时刻。 */
async function pace(pcm: Uint8Array, send: (chunk: Uint8Array) => void) {
  const size = 3200;
  const start = performance.now();
  for (let offset = 0, index = 0; offset < pcm.length; offset += size, index++) {
    const wait = start + index * 100 - performance.now();
    if (wait > 0) await Bun.sleep(wait);
    send(pcm.subarray(offset, offset + size));
  }
  return performance.now();
}

interface Result { text: string; latency: number; error?: string }

/** 现行做法，和 kited 的 VoiceSession 一样组装上下文、定稿后恢复。 */
async function current(pcm: Uint8Array, conversation: string | null): Promise<Result & { known: Map<string, string> }> {
  const messages = turns(conversation).map(({ role, text }) => `${role === 'user' ? '用户' : 'agent'}：${text}`).join('\n\n');
  const { instructions, input } = assembleContext(bindContext(voiceTemplate, sceneValues<'thread.voice'>({ 'voice.messages': messages })));
  const context = [instructions, input].filter(Boolean).join('\n\n');
  const known = identifiers(context);
  let failure: Error | undefined;
  const recognition = recognize({ key: dashscope!, model: 'qwen3-asr-flash-realtime', context, partial: () => {}, failed: (error) => { failure = error; } });
  const last = await pace(pcm, (chunk) => recognition.append(chunk));
  try {
    const text = await recognition.finish();
    return { text: restore(text, known), latency: performance.now() - last, known };
  } catch (error) {
    return { text: '', latency: NaN, error: String(failure ?? error), known };
  }
}

async function tidy(text: string): Promise<Result> {
  const { instructions, input } = assembleContext(bindContext(voiceTidyTemplate, sceneValues<'thread.voice_tidy'>({ 'tidy.text': text })));
  const start = performance.now();
  try {
    const result = await tasks.generateText({ purpose: 'thread.voice_tidy', instructions, input: input!,
      model: { model: process.env.DEEPSEEK_MODEL ?? 'deepseek-flash', reasoning: process.env.DEEPSEEK_REASONING ?? 'low' },
      maxOutputChars: Math.ceil(text.length * 1.5) + 100 });
    return { text: result.text, latency: performance.now() - start };
  } catch (error) {
    return { text: '', latency: NaN, error: String(error) };
  }
}

/**
 * 新型号走 DashScope 的 run-task 双工协议：服务端按静音断句，每句的定稿是 sentence_end 为 true 的那条。
 * 不带对话：带了 input.context 润色就不起作用，连数字也不再规整（2026-10-29 同一段合成录音对照过），只用对话里的标识符作热词，最多 50 个。
 */
async function message(pcm: Uint8Array, known: Map<string, string>, polish: boolean): Promise<Result> {
  const vocabulary = Object.fromEntries([...known.values()].slice(-50).map((word) => [word, 4]));
  const id = crypto.randomUUID();
  const url = process.env.QWEN_MESSAGE_URL ?? 'wss://dashscope.aliyuncs.com/api-ws/v1/inference';
  const socket = new BunWebSocket(url, { headers: { Authorization: `Bearer ${dashscope}`,
    ...process.env.DASHSCOPE_WORKSPACE ? { 'X-DashScope-WorkSpace': process.env.DASHSCOPE_WORKSPACE } : {} } });
  const sentences = new Map<number, string>();
  let last = NaN;
  return await new Promise<Result>((resolve) => {
    const done = (result: Result) => { socket.close(); resolve(result); };
    const timer = setTimeout(() => done({ text: '', latency: NaN, error: '超时' }), 120_000);
    socket.onopen = () => socket.send(JSON.stringify({
      header: { action: 'run-task', task_id: id, streaming: 'duplex' },
      payload: { task_group: 'audio', task: 'asr', function: 'recognition', model: 'qwen-audio-3.1-asr-flash-message',
        parameters: { format: 'pcm', sample_rate: 16000, intermediate_result_enabled: true, disfluency_removal_enabled: polish,
          vad_model: 'near_meeting_16k', max_sentence_silence: 6000, ...Object.keys(vocabulary).length ? { vocabulary } : {} },
        input: {} },
    }));
    socket.onmessage = async (event) => {
      const data = JSON.parse(String(event.data)) as { header: { event: string; error_message?: string; error_code?: string };
        payload?: { output?: { sentence?: { sentence_id: number; text?: string; sentence_end?: boolean; heartbeat?: boolean } } } };
      switch (data.header.event) {
        case 'task-started':
          last = await pace(pcm, (chunk) => socket.send(chunk));
          socket.send(JSON.stringify({ header: { action: 'finish-task', task_id: id, streaming: 'duplex' }, payload: { input: {} } }));
          break;
        case 'result-generated': {
          const sentence = data.payload?.output?.sentence;
          if (sentence && !sentence.heartbeat && sentence.sentence_id > 0) sentences.set(sentence.sentence_id, sentence.text ?? '');
          break;
        }
        case 'task-finished':
          clearTimeout(timer);
          done({ text: restore([...sentences.entries()].sort(([a], [b]) => a - b).map(([, text]) => text).join(''), known),
            latency: performance.now() - last });
          break;
        case 'task-failed':
          clearTimeout(timer);
          done({ text: '', latency: NaN, error: `${data.header.error_code ?? ''} ${data.header.error_message ?? ''}`.trim() });
          break;
      }
    };
    socket.onerror = () => { clearTimeout(timer); done({ text: '', latency: NaN, error: '连不上' }); };
  });
}

/** 任意格式的录音转成 16 kHz 单声道 s16le，取出 WAV 的 data 块。 */
async function toPcm(path: string) {
  const wav = `${process.env.TMPDIR ?? '/tmp'}/kite-voice-polish-${crypto.randomUUID()}.wav`;
  await Bun.$`afconvert -f WAVE -d LEI16@16000 -c 1 ${path} ${wav}`.quiet();
  const bytes = new Uint8Array(await Bun.file(wav).arrayBuffer());
  await Bun.$`rm -f ${wav}`.quiet();
  const view = new DataView(bytes.buffer);
  for (let offset = 12; offset + 8 <= bytes.length;) {
    const tag = new TextDecoder().decode(bytes.subarray(offset, offset + 4)), size = view.getUint32(offset + 4, true);
    if (tag === 'data') return bytes.slice(offset + 8, offset + 8 + size);
    offset += 8 + size + (size % 2);
  }
  throw new Error(`${path} 转出来的 WAV 没有 data 块`);
}

async function text(path: string) {
  const file = Bun.file(path);
  return await file.exists() ? (await file.text()).trim() : null;
}

const labels: Record<string, string> = { current: '现行', deepseek: '现行 + DeepSeek', message: '新型号', polish: '新型号 + 润色' };
const rows: { sample: string; spoken: string | null; terms: string[]; results: Record<string, Result> }[] = [];
const samples = (await readdir(root, { withFileTypes: true })).filter((entry) => entry.isDirectory()).map((entry) => entry.name).sort();
for (const sample of samples) {
  const directory = join(root, sample);
  const audio = (await readdir(directory)).find((file) => file.startsWith('audio.'));
  if (!audio) continue;
  const pcm = await toPcm(join(directory, audio));
  const conversation = await text(join(directory, 'context.txt'));
  const terms = ((await text(join(directory, 'terms.txt'))) ?? '').split('\n').map((line) => line.trim()).filter(Boolean);
  const spoken = await text(join(directory, 'spoken.txt'));
  const results: Record<string, Result> = {};
  // 现行一定要跑：DeepSeek 整理它的结果，标识符表也从它的上下文来
  const base = await current(pcm, conversation);
  if (methods.includes('current') || methods.includes('deepseek')) results.current = base;
  if (methods.includes('deepseek') && base.text) {
    const tidied = await tidy(base.text);
    results.deepseek = { ...tidied, latency: base.latency + tidied.latency };
  }
  if (methods.includes('message')) results.message = await message(pcm, base.known, false);
  if (methods.includes('polish')) results.polish = await message(pcm, base.known, true);
  rows.push({ sample, spoken, terms, results });
  console.log(`\n${sample}${conversation ? '（带对话）' : ''}${spoken ? `\n  稿子：${spoken}` : ''}`);
  for (const [method, result] of Object.entries(results)) {
    const hits = termHits(result.text, terms), exact = exactHits(result.text, terms);
    console.log(`  ${labels[method]}｜${Number.isFinite(result.latency) ? `${Math.round(result.latency)} 毫秒` : '—'}`
      + `${terms.length ? `｜关键词 ${hits.hit.length}/${terms.length}，照原样 ${exact.length}` : ''}${result.error ? `｜出错：${result.error}` : ''}\n    ${result.text}`);
  }
}

console.log('\n汇总（耗时是说完到出字的中位数，「现行 + DeepSeek」含整理）');
for (const method of Object.keys(labels)) {
  const group = rows.map((row) => ({ row, result: row.results[method] })).filter(({ result }) => result && !result.error);
  if (!group.length) continue;
  const latencies = group.map(({ result }) => result!.latency).sort((a, b) => a - b);
  const total = group.reduce((sum, { row }) => sum + row.terms.length, 0);
  const hit = group.reduce((sum, { row, result }) => sum + termHits(result!.text, row.terms).hit.length, 0);
  const exact = group.reduce((sum, { row, result }) => sum + exactHits(result!.text, row.terms).length, 0);
  console.log(`${labels[method]}｜${group.length} 段｜关键词 ${hit}/${total}，照原样 ${exact}/${total}｜耗时 ${Math.round(latencies[Math.floor(latencies.length / 2)]!)} 毫秒`);
}
const output = join(root, `results-${new Date().toISOString().replaceAll(':', '-')}.json`);
await Bun.write(output, JSON.stringify(rows, null, 2));
console.log(`\n明细写在 ${output}`);
await tasks.close();
