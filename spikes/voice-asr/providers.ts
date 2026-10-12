/** 各家流式识别的客户端：按真实语速推 16 kHz 单声道 s16le 的 PCM，记下中间结果出现的时刻和说完到定稿的耗时。 */
import { fileURLToPath } from 'node:url';

export interface Context {
  /** 最近的对话，从旧到新，一轮一段。 */
  turns: string[];
  /** 从对话里摘出来的英文标识、文件名、命令，给只收词表的识别用。 */
  words: string[];
}

export interface Run {
  final: string;
  /** 中间结果：距开始推音频多少毫秒、当时的全文。 */
  partials: { at: number; text: string }[];
  /** 最后一包推出去到拿到定稿的毫秒数。 */
  latency: number;
  error?: string;
}

export interface Provider {
  name: string;
  /** 缺什么配置；能跑时为 null。 */
  missing(): string | null;
  recognize(pcm: Uint8Array, context: Context | null): Promise<Run>;
}

/** 每包 200 毫秒，豆包文档说双向流式这个大小最优，几家都按这个节奏推。 */
const chunkMs = 200;
const bytesPerMs = 32;
/** 最后一包推完后最多等多久。 */
const settleMs = 20_000;

/** 从 start 起按真实语速逐包推出去，返回最后一包推出去的时刻。 */
async function pace(pcm: Uint8Array, start: number, send: (chunk: Uint8Array, last: boolean) => void) {
  const size = chunkMs * bytesPerMs;
  for (let index = 0, offset = 0; offset < pcm.length; index++, offset += size) {
    await Bun.sleep(Math.max(0, start + index * chunkMs - performance.now()));
    send(pcm.subarray(offset, offset + size), offset + size >= pcm.length);
  }
  return performance.now();
}

function deadline<T>(promise: Promise<T>, ms: number, what: string): Promise<T> {
  return Promise.race([promise, Bun.sleep(ms).then(() => { throw new Error(`${what}超时`); })]);
}

/** 豆包流式语音识别 2.0（火山引擎），双向流式优化版加二遍识别：边说边出字，每句判停后用非流式模型再识别一遍。 */
export const doubao: Provider = {
  name: '豆包 2.0',
  missing: () => process.env.VOLC_API_KEY || (process.env.VOLC_APP_KEY && process.env.VOLC_ACCESS_KEY)
    ? null : '设 VOLC_API_KEY（新版控制台），或 VOLC_APP_KEY 与 VOLC_ACCESS_KEY（旧版控制台）',
  async recognize(pcm, context) {
    const headers: Record<string, string> = {
      'X-Api-Resource-Id': process.env.VOLC_RESOURCE_ID ?? 'volc.seedasr.sauc.duration',
      'X-Api-Connect-Id': crypto.randomUUID(),
      ...process.env.VOLC_API_KEY ? { 'X-Api-Key': process.env.VOLC_API_KEY }
        : { 'X-Api-App-Key': process.env.VOLC_APP_KEY!, 'X-Api-Access-Key': process.env.VOLC_ACCESS_KEY! },
    };
    const request = {
      user: { uid: 'kite-voice-spike' },
      audio: { format: 'pcm', codec: 'raw', rate: 16000, bits: 16, channel: 1 },
      request: {
        model_name: 'bigmodel', enable_nonstream: true, enable_itn: true, enable_punc: true, enable_ddc: true,
        show_utterances: true, result_type: 'full',
        // 对话上下文从新到旧，最多 20 轮、800 token，超出由服务端截掉旧的
        ...context && { corpus: { context: JSON.stringify({
          context_type: 'dialog_ctx', context_data: context.turns.slice(-20).reverse().map((text) => ({ text })),
        }) } },
      },
    };
    const socket = new WebSocket('wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async', { headers } as never);
    socket.binaryType = 'arraybuffer';
    const partials: Run['partials'] = [];
    let start = 0, end = 0, final = '';
    const done = new Promise<number>((resolve, reject) => {
      socket.onmessage = (event) => {
        const message = parseVolc(event.data as ArrayBuffer);
        if ('error' in message) { reject(new Error(message.error)); return; }
        const text = String((message.json as { result?: { text?: string } }).result?.text ?? '');
        if (text && start) partials.push({ at: performance.now() - start, text });
        if (message.last) { final = text; resolve(performance.now()); }
      };
      socket.onerror = () => reject(new Error('连接出错'));
      socket.onclose = (event) => reject(new Error(`连接关闭 ${event.code} ${event.reason}`));
    });
    // 建连失败时它先于 await 被拒，错误在后面 await 时再接
    done.catch(() => {});
    try {
      await deadline(new Promise((resolve, reject) => { socket.onopen = resolve; socket.onerror = () => reject(new Error('连不上')); }), 10_000, '建连');
      socket.send(volcFrame(0b0001, 0b0000, 0b0001, new TextEncoder().encode(JSON.stringify(request))));
      start = performance.now();
      end = await pace(pcm, start, (chunk, last) => socket.send(volcFrame(0b0010, last ? 0b0010 : 0b0000, 0b0000, chunk)));
      const finished = await deadline(done, settleMs, '等定稿');
      return { final, partials, latency: finished - end };
    } catch (error) {
      return { final, partials, latency: NaN, error: (error as Error).message };
    } finally {
      socket.onclose = null;
      socket.close();
    }
  },
};

/** 火山二进制协议的一帧：4 字节头、4 字节大端长度、gzip 过的负载。 */
function volcFrame(type: number, flags: number, serialization: number, payload: Uint8Array) {
  const body = Bun.gzipSync(payload);
  const frame = new Uint8Array(8 + body.length);
  frame.set([0x11, (type << 4) | flags, (serialization << 4) | 0b0001, 0]);
  new DataView(frame.buffer).setUint32(4, body.length);
  frame.set(body, 8);
  return frame;
}

function parseVolc(data: ArrayBuffer): { error: string } | { last: boolean; json: unknown } {
  const bytes = new Uint8Array(data), view = new DataView(data);
  const type = bytes[1]! >> 4, flags = bytes[1]! & 0x0f, compression = bytes[2]! & 0x0f;
  let offset = (bytes[0]! & 0x0f) * 4;
  const decode = (from: number, size: number) => {
    const raw = bytes.subarray(from, from + size);
    return new TextDecoder().decode(compression === 1 ? Bun.gunzipSync(raw) : raw);
  };
  if (type === 0b1111) return { error: `${view.getUint32(offset)} ${decode(offset + 8, view.getUint32(offset + 4))}` };
  if (flags & 0b0001) offset += 4;
  return { last: (flags & 0b0010) !== 0, json: JSON.parse(decode(offset + 4, view.getUint32(offset))) };
}

/** 千问实时识别（百炼），服务端 VAD 分句：每句有确认的前缀 text 和待定的 stash，判停后给这一句的定稿。 */
export const qwen: Provider = {
  name: '千问实时',
  missing: () => process.env.DASHSCOPE_API_KEY ? null : '设 DASHSCOPE_API_KEY',
  async recognize(pcm, context) {
    const model = process.env.QWEN_ASR_MODEL ?? 'qwen3-asr-flash-realtime';
    const url = process.env.QWEN_ASR_URL ?? `wss://dashscope.aliyuncs.com/api-ws/v1/realtime?model=${model}`;
    const socket = new WebSocket(url, { headers: { Authorization: `Bearer ${process.env.DASHSCOPE_API_KEY}` } } as never);
    const partials: Run['partials'] = [];
    const sentences: string[] = [];
    let start = 0, end = 0;
    let updated!: () => void;
    const ready = new Promise<void>((resolve) => { updated = resolve; });
    const done = new Promise<number>((resolve, reject) => {
      socket.onmessage = (event) => {
        const message = JSON.parse(String(event.data)) as Record<string, any>;
        switch (message.type) {
          case 'session.updated': updated(); break;
          case 'conversation.item.input_audio_transcription.text':
            if (start) partials.push({ at: performance.now() - start, text: sentences.join('') + (message.text ?? '') + (message.stash ?? '') });
            break;
          case 'conversation.item.input_audio_transcription.completed':
            sentences.push(message.transcript ?? '');
            if (start) partials.push({ at: performance.now() - start, text: sentences.join('') });
            break;
          case 'conversation.item.input_audio_transcription.failed':
          case 'error': reject(new Error(JSON.stringify(message.error))); break;
          case 'session.finished': resolve(performance.now()); break;
        }
      };
      socket.onerror = () => reject(new Error('连接出错'));
      socket.onclose = (event) => reject(new Error(`连接关闭 ${event.code} ${event.reason}`));
    });
    // 建连失败时它先于 await 被拒，错误在后面 await 时再接
    done.catch(() => {});
    try {
      await deadline(new Promise((resolve, reject) => { socket.onopen = resolve; socket.onerror = () => reject(new Error('连不上')); }), 10_000, '建连');
      socket.send(JSON.stringify({ type: 'session.update', event_id: crypto.randomUUID(), session: {
        input_audio_format: 'pcm', sample_rate: 16000,
        input_audio_transcription: {
          ...process.env.QWEN_ASR_LANGUAGE && { language: process.env.QWEN_ASR_LANGUAGE },
          // 背景文本上限 1 万 token，留最近的对话
          ...context && { corpus: { text: context.turns.join('\n\n').slice(-6000) } },
        },
        // QWEN_MANUAL=1 时不按停顿分句，说完一次提交
        turn_detection: process.env.QWEN_MANUAL ? null
          : { type: 'server_vad', threshold: 0.2, silence_duration_ms: Number(process.env.QWEN_VAD_SILENCE_MS ?? 800) },
      } }));
      await deadline(Promise.race([ready, done.then(() => {})]), 10_000, '等会话配置');
      start = performance.now();
      end = await pace(pcm, start, (chunk) => socket.send(JSON.stringify({
        type: 'input_audio_buffer.append', event_id: crypto.randomUUID(), audio: Buffer.from(chunk).toString('base64'),
      })));
      if (process.env.QWEN_MANUAL) socket.send(JSON.stringify({ type: 'input_audio_buffer.commit', event_id: crypto.randomUUID() }));
      socket.send(JSON.stringify({ type: 'session.finish', event_id: crypto.randomUUID() }));
      const finished = await deadline(done, settleMs, '等定稿');
      return { final: sentences.join(''), partials, latency: finished - end };
    } catch (error) {
      return { final: sentences.join(''), partials, latency: NaN, error: (error as Error).message };
    } finally {
      socket.onclose = null;
      socket.close();
    }
  },
};

/** Apple 本地识别（SpeechAnalyzer 的听写模块），只收词表，给的是从对话里摘出来的英文标识和文件名。 */
export const apple: Provider = {
  name: 'Apple 本地',
  missing: () => process.platform === 'darwin' ? null : '只能在 macOS 上跑',
  async recognize(pcm, context) {
    const binary = await appleBinary();
    const directory = `${process.env.TMPDIR ?? '/tmp'}/kite-voice-spike-${crypto.randomUUID()}`;
    const audio = `${directory}/audio.pcm`, words = `${directory}/words.txt`;
    await Bun.write(audio, pcm);
    await Bun.write(words, (context?.words ?? []).join('\n'));
    const child = Bun.spawn([binary, audio, words], { env: process.env, stdout: 'pipe', stderr: 'pipe' });
    const [out, err, code] = await Promise.all([new Response(child.stdout).text(), new Response(child.stderr).text(), child.exited]);
    await Bun.$`rm -rf ${directory}`.quiet();
    const partials: Run['partials'] = [];
    let final = '', latency = NaN, error = code === 0 ? undefined : err.trim() || `退出码 ${code}`;
    for (const line of out.split('\n').filter(Boolean)) {
      const message = JSON.parse(line) as { partial?: string; at?: number; final?: string; latency?: number; error?: string };
      if (message.partial !== undefined) partials.push({ at: message.at!, text: message.partial });
      if (message.final !== undefined) ({ final, latency } = { final: message.final, latency: message.latency! });
      if (message.error) error = message.error;
    }
    return { final, partials, latency, error };
  },
};

let compiled: Promise<string> | undefined;
/** apple.swift 编一次放进临时目录，同一次运行里复用。 */
function appleBinary() {
  compiled ??= (async () => {
    const source = fileURLToPath(new URL('apple.swift', import.meta.url));
    const output = `${process.env.TMPDIR ?? '/tmp'}/kite-voice-spike-apple`;
    await Bun.$`xcrun swiftc -parse-as-library -O ${source} -o ${output}`.quiet();
    return output;
  })();
  return compiled;
}

export const providers = [doubao, qwen, apple];
