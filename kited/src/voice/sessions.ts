/**
 * App 与工作机之间的语音输入：一次录音一条 WebSocket。App 推 16 kHz 单声道 s16le 的 PCM，说完发 {"type":"finish"}；
 * 这里带着会话最近的对话连识别服务，推回 {"type":"partial","text"}，最后推 {"type":"final","text"} 或 {"type":"error","message"} 后关闭。
 * 识别是辅助生成的一类：模板给上下文的写法和识别模型，凭据用账号里的语音识别凭据。
 */
import type { ServerWebSocket } from 'bun';
import type { ContextTemplate } from '../context-templates.ts';
import { KiteError } from '../errors.ts';
import { assembleContext } from '../harness/context/assembler.ts';
import type { ContextDefinition } from '../harness/context/types.ts';
import type { History } from '../transcript/protocol.ts';
import { recognize, type Recognition } from './dashscope.ts';
import { speechModels, type SpeechProvider } from './models.ts';
import { identifiers, restore } from './restore.ts';

export const voiceTemplate: ContextDefinition = {
  version: 2, id: 'kite.voice.context', title: '语音识别', scene: 'thread.voice',
  blocks: [{ type: 'paragraph', id: 'scene', title: '场景', parts: [{
    type: 'text', text: '用户在 Kite 里口述发给编程 agent 的消息。下面是这个会话最近的对话，其中出现过的名称、标识符、文件名和命令照原样写。',
  }] }],
  input: [{ type: 'paragraph', id: 'messages', title: '近期对话', parts: [{ type: 'variable', name: 'thread.messages' }] }],
};

/** 最近的请求和回复，从最近往前取到 6000 字；代码不略去，标识符多半在代码里。 */
export function voiceMaterial(history: History): string {
  const parts: string[] = [];
  let size = 0;
  for (const record of history.records.toReversed()) {
    if (record.generation === 'streaming' || record.generation === 'interrupted') continue;
    const { block } = record;
    const text = block.type === 'human' ? `用户：${block.text}` : block.type === 'text' ? `agent：${block.text}` : undefined;
    if (!text?.trim()) continue;
    const part = text.trim().slice(-1_500);
    if (size + part.length > 6_000 || parts.length >= 40) break;
    parts.unshift(part);
    size += part.length + 2;
  }
  return parts.join('\n\n');
}

export interface VoiceSocket {
  /** 正在输入的会话；新会话还没有实例时为空，不带对话。 */
  thread?: string;
  session?: VoiceSession;
}

export interface VoiceOptions {
  /** 账号里的语音识别凭据。 */
  keys(): Promise<{ provider: SpeechProvider; key: string }[]>;
  template(): ContextTemplate;
  history(thread: string): Promise<History>;
  /** 识别服务地址，测试换成本机假服务。 */
  url?: string;
}

export class VoiceSessions {
  constructor(private options: VoiceOptions) {}

  open(socket: ServerWebSocket<VoiceSocket>) { socket.data.session = new VoiceSession(socket, this.options); }
  message(socket: ServerWebSocket<VoiceSocket>, message: string | Buffer) { socket.data.session?.receive(message); }
  close(socket: ServerWebSocket<VoiceSocket>) { socket.data.session?.close(); }
}

class VoiceSession {
  private recognition?: Recognition;
  /** 识别服务连上之前收到的音频。 */
  private pending: Uint8Array[] = [];
  private known = new Map<string, string>();
  private finishing = false;
  private ended = false;

  constructor(private socket: ServerWebSocket<VoiceSocket>, options: VoiceOptions) {
    void this.start(options);
  }

  receive(message: string | Buffer) {
    if (this.ended) return;
    if (typeof message !== 'string') {
      const chunk = new Uint8Array(message);
      if (this.recognition) this.recognition.append(chunk);
      else this.pending.push(chunk);
      return;
    }
    let type: unknown;
    try { type = (JSON.parse(message) as { type?: unknown }).type; } catch { /* 下面按未知消息处理。 */ }
    if (type !== 'finish') return this.fail(new KiteError('未知的语音消息'));
    this.finishing = true;
    if (this.recognition) void this.complete();
  }

  close() {
    this.ended = true;
    this.recognition?.close();
  }

  private async start(options: VoiceOptions) {
    try {
      const template = options.template();
      const model = speechModels.find((entry) => entry.id === template.model?.model) ?? speechModels[0]!;
      const thread = this.socket.data.thread;
      // 凭据要问账号服务，和读会话记录同时进行
      const [keys, history] = await Promise.all([options.keys(), thread ? options.history(thread) : undefined]);
      const key = keys.find((entry) => entry.provider === model.vendor)?.key;
      if (!key) throw new KiteError('没有语音识别凭据：在 Kite 账号的凭据里添加千问（百炼）的 API Key');
      const messages = history ? voiceMaterial(history) : '';
      const { instructions, input } = assembleContext({ definition: template.definition, bindings: { 'thread.messages': { text: messages } } });
      const context = [instructions, input].filter(Boolean).join('\n\n');
      if (this.ended) return;
      this.known = identifiers(context);
      this.recognition = recognize({
        key, model: model.id, context, url: options.url,
        partial: (text) => this.send({ type: 'partial', text }),
        failed: (error) => this.fail(error),
      });
      for (const chunk of this.pending.splice(0)) this.recognition.append(chunk);
      if (this.finishing) await this.complete();
    } catch (error) {
      this.fail(error);
    }
  }

  private async complete() {
    try {
      const text = await this.recognition!.finish();
      if (this.ended) return;
      this.send({ type: 'final', text: restore(text, this.known) });
      this.ended = true;
      this.socket.close(1000);
    } catch (error) {
      this.fail(error);
    }
  }

  private fail(error: unknown) {
    if (this.ended) return;
    this.ended = true;
    this.recognition?.close();
    this.send({ type: 'error', message: error instanceof Error ? error.message : String(error) });
    this.socket.close(1011);
  }

  private send(message: Record<string, unknown>) {
    if (this.socket.readyState === 1) this.socket.send(JSON.stringify(message));
  }
}
