/**
 * Claude 线程的压缩摘要：在不落盘的分叉上（resume + forkSession + persistSession: false）让 Claude 基于完整原生上下文作答。
 * 系统提示、模型与工具声明和主会话一致，请求前缀能命中主会话的缓存；工具不放行调用，最多一次请求。
 * 2026-10-09 在 CLI 2.1.280 上验证，见 spikes/compaction/summary.ts。
 */
import { query, type Options } from '@anthropic-ai/claude-agent-sdk';
import { claudeOptions } from './options.ts';
import type { JsonObject, Model, ModelEvent, ModelRequest } from '../harness/types.ts';

export class ClaudeSummaryModel implements Model {
  constructor(private options: {
    cwd: string; nativeId: string;
    configuration: Pick<Options, 'model' | 'effort' | 'systemPrompt'>;
    mcpServers?: Options['mcpServers'];
    /** 宿主停止会话时取消摘要。 */
    signal?: AbortSignal;
  }) {}

  /** 只用历史末尾的摘要指令；上下文取自原生会话，不用中立历史重建。 */
  async *stream(request: ModelRequest, signal: AbortSignal): AsyncIterable<ModelEvent> {
    const instruction = request.history.at(-1);
    if (instruction?.type !== 'feedback') throw new Error('摘要请求缺少指令');
    signal = this.options.signal ? AbortSignal.any([signal, this.options.signal]) : signal;
    signal.throwIfAborted();
    const controller = new AbortController();
    const abort = () => controller.abort();
    signal.addEventListener('abort', abort, { once: true });
    let text = '';
    let result: { subtype: string; is_error: boolean; uuid: string; usage?: unknown; errors?: string[] } | undefined;
    try {
      for await (const message of query({ prompt: instruction.text, options: {
        ...claudeOptions(this.options.cwd), ...this.options.configuration, mcpServers: this.options.mcpServers,
        resume: this.options.nativeId, forkSession: true, persistSession: false, maxTurns: 1, abortController: controller,
      } })) {
        if (message.type === 'assistant' && message.parent_tool_use_id === null) {
          for (const block of message.message.content) if (block.type === 'text') text += block.text;
        }
        if (message.type === 'result') result = message;
      }
    } finally {
      signal.removeEventListener('abort', abort);
    }
    signal.throwIfAborted();
    if (!result || result.is_error || result.subtype !== 'success') {
      throw new Error(result?.errors?.join('\n') || `Claude 未完成摘要（${result?.subtype ?? '没有结果'}）`);
    }
    yield { type: 'item', item: { id: `summary:${request.id}`, raw: { type: 'message', role: 'assistant', content: [{ type: 'output_text', text }] } } };
    yield { type: 'completed', responseId: result.uuid, ...(result.usage ? { usage: JSON.parse(JSON.stringify(result.usage)) as JsonObject } : {}) };
  }
}
