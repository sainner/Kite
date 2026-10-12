/**
 * 千问实时识别（百炼）的流式客户端。不按停顿分句，说完一次提交：边收音频边出中间结果，提交后给整段定稿。
 * 上下文放在 corpus.text，上限 1 万 token。协议见百炼 Qwen-ASR-Realtime 的客户端与服务端事件。
 */
export const dashscopeRealtimeURL = 'wss://dashscope.aliyuncs.com/api-ws/v1/realtime';

/** tsconfig 带了 DOM 库，全局 WebSocket 用的是浏览器的类型，没有 Bun 的请求头选项。 */
const BunWebSocket = WebSocket as unknown as new (url: URL, options: Bun.WebSocketOptions) => WebSocket;

export interface Recognition {
  /** 16 kHz 单声道 s16le 的 PCM；会话配好之前先攒着。 */
  append(pcm: Uint8Array): void;
  /** 提交全部音频，等整段定稿。 */
  finish(timeoutMs?: number): Promise<string>;
  close(): void;
}

export interface RecognitionOptions {
  key: string;
  model: string;
  context: string;
  url?: string;
  /** 已确认的部分加上还可能改的部分，每次都是到目前为止的全文。 */
  partial(text: string): void;
  /** 会话中途出错或断开；finish 等待中的错误由 finish 抛出，不再报到这里。 */
  failed(error: Error): void;
}

type ServerEvent = { type: string; text?: string; stash?: string; transcript?: string; error?: { message?: string; code?: string } };

export function recognize(options: RecognitionOptions): Recognition {
  const url = new URL(options.url ?? dashscopeRealtimeURL);
  url.searchParams.set('model', options.model);
  const socket = new BunWebSocket(url, { headers: { Authorization: `Bearer ${options.key}` } });
  const queued: string[] = [];
  const sentences: string[] = [];
  let ready = false;
  let closed = false;
  let finishing: { resolve(text: string): void; reject(error: Error): void } | undefined;
  const send = (event: Record<string, unknown>) => {
    const text = JSON.stringify({ event_id: crypto.randomUUID(), ...event });
    if (ready) socket.send(text);
    else queued.push(text);
  };
  const fail = (error: Error) => {
    if (closed) return;
    closed = true;
    socket.close();
    if (finishing) finishing.reject(error);
    else options.failed(error);
  };

  socket.onopen = () => {
    socket.send(JSON.stringify({ type: 'session.update', event_id: crypto.randomUUID(), session: {
      input_audio_format: 'pcm', sample_rate: 16000, turn_detection: null,
      input_audio_transcription: options.context ? { corpus: { text: options.context } } : {},
    } }));
  };
  socket.onmessage = (message) => {
    const event = JSON.parse(String(message.data)) as ServerEvent;
    switch (event.type) {
      case 'session.updated':
        ready = true;
        for (const text of queued.splice(0)) socket.send(text);
        break;
      case 'conversation.item.input_audio_transcription.text':
        options.partial(sentences.join('') + (event.text ?? '') + (event.stash ?? ''));
        break;
      case 'conversation.item.input_audio_transcription.completed':
        sentences.push(event.transcript ?? '');
        options.partial(sentences.join(''));
        break;
      case 'conversation.item.input_audio_transcription.failed':
      case 'error':
        fail(new Error(`语音识别出错：${event.error?.message ?? event.error?.code ?? '未知错误'}`));
        break;
      case 'session.finished':
        closed = true;
        socket.close();
        finishing?.resolve(sentences.join(''));
        break;
    }
  };
  socket.onerror = () => fail(new Error('连不上语音识别服务'));
  socket.onclose = (event) => fail(new Error(event.code === 1000 ? '语音识别服务提前断开' : `语音识别服务断开（${event.code}）`));

  return {
    append(pcm) {
      if (!closed) send({ type: 'input_audio_buffer.append', audio: Buffer.from(pcm).toString('base64') });
    },
    finish(timeoutMs = 15_000) {
      if (closed) return Promise.reject(new Error('语音识别已结束'));
      const done = new Promise<string>((resolve, reject) => { finishing = { resolve, reject }; });
      send({ type: 'input_audio_buffer.commit' });
      send({ type: 'session.finish' });
      const timer = setTimeout(() => fail(new Error('等语音识别定稿超时')), timeoutMs);
      return done.finally(() => clearTimeout(timer));
    },
    close() {
      if (closed) return;
      closed = true;
      socket.close();
    },
  };
}
