/** 轻任务共用的一次性文本生成；串行限制后台请求，不创建线程或工具循环。 */
import { randomUUID } from 'node:crypto';
import type { JsonObject, Model } from './harness/types.ts';

export interface LightTaskOptions {
  model(task: { id: string; purpose: string }): Model;
  timeoutMs?: number;
  onResult?(result: { purpose: string; durationMs: number; usage?: JsonObject; error?: string }): void;
}

export interface TextTask {
  purpose: string;
  instructions: string;
  input: string;
  signal?: AbortSignal;
  maxOutputChars?: number;
}

export class LightTasks {
  private tail: Promise<void> = Promise.resolve();
  private stopping = new AbortController();

  constructor(private options: LightTaskOptions) {}

  generateText(task: TextTask): Promise<{ text: string; usage?: JsonObject }> {
    const result = this.tail.then(() => this.generate(task));
    this.tail = result.then(() => {}, () => {});
    return result;
  }

  async close(): Promise<void> {
    this.stopping.abort();
    await this.tail;
  }

  private async generate(task: TextTask): Promise<{ text: string; usage?: JsonObject }> {
    const timeout = new AbortController();
    const signal = AbortSignal.any([this.stopping.signal, timeout.signal, ...(task.signal ? [task.signal] : [])]);
    signal.throwIfAborted();
    const timer = setTimeout(() => timeout.abort(new Error('轻任务生成超时')), this.options.timeoutMs ?? 30_000);
    const started = performance.now();
    let usage: JsonObject | undefined;
    let error: string | undefined;
    try {
      const id = randomUUID();
      let completed = false;
      let text = '';
      const model = this.options.model({ id, purpose: task.purpose });
      for await (const event of model.stream({
        id, turnId: id, cwd: '', instructions: task.instructions, tools: [], allowedTools: [],
        history: [{ type: 'input', input: { id, source: 'human', text: task.input } }],
      }, signal)) {
        signal.throwIfAborted();
        if (completed) throw new Error('轻任务完成后仍收到模型事件');
        if (event.type === 'completed') {
          if (event.needsFollowUp) throw new Error('轻任务未在一次请求内完成');
          completed = true;
          usage = event.usage;
        } else if (event.type === 'item') {
          if (event.item.call) throw new Error('轻任务不能调用工具');
          const raw = event.item.raw;
          if (raw.type !== 'message') continue;
          if (raw.status === 'incomplete') throw new Error('轻任务文本生成未完成');
          if (!Array.isArray(raw.content)) throw new Error('轻任务文本格式无效');
          for (const part of raw.content) {
            if (!part || typeof part !== 'object' || Array.isArray(part)) continue;
            if (part.type === 'refusal') throw new Error('模型未生成轻任务结果');
            if (part.type === 'output_text' && typeof part.text === 'string') text += part.text;
          }
          if (text.length > (task.maxOutputChars ?? 8_192)) throw new Error('轻任务输出超过长度限制');
        }
      }
      signal.throwIfAborted();
      if (!completed || !text.trim()) throw new Error('轻任务没有完整文本结果');
      return { text: text.trim(), ...(usage ? { usage } : {}) };
    } catch (cause) {
      error = cause instanceof Error ? cause.message : String(cause);
      throw cause;
    } finally {
      clearTimeout(timer);
      this.options.onResult?.({ purpose: task.purpose, durationMs: Math.round(performance.now() - started),
        ...(usage ? { usage } : {}), ...(error ? { error } : {}) });
    }
  }
}
