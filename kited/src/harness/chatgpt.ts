/** ChatGPT 订阅 Responses 传输。循环与工具执行仍由 HarnessRunner 管理。 */
import { z } from 'zod';
import type { SubscriptionModelOptions } from './subscription-types.ts';
import type { JsonObject, Model, ModelEvent, ModelItem, ModelRequest } from './types.ts';

const ENDPOINT = 'https://chatgpt.com/backend-api/codex/responses';
const object = z.record(z.string(), z.json());

function asObject(value: unknown, label: string): JsonObject {
  const result = object.safeParse(value);
  if (!result.success) throw new Error(`订阅响应中的 ${label} 格式无效`);
  return result.data;
}

function text(value: unknown, label: string): string {
  if (typeof value !== 'string' || !value) throw new Error(`订阅响应缺少 ${label}`);
  return value;
}

/** SSE 按行解码，保留跨 chunk 的 UTF-8 字符；多 data 行用换行连接。 */
async function* events(body: ReadableStream<Uint8Array>, signal: AbortSignal): AsyncIterable<string> {
  const reader = body.getReader();
  const decoder = new TextDecoder('utf-8', { fatal: true });
  let buffer = '';
  let data: string[] = [];
  let size = 0;
  const abort = () => { void reader.cancel().catch(() => {}); };
  signal.addEventListener('abort', abort, { once: true });
  try {
    while (true) {
      signal.throwIfAborted();
      const { done, value } = await reader.read();
      signal.throwIfAborted();
      buffer += decoder.decode(value, { stream: !done });
      while (true) {
        const newline = buffer.indexOf('\n');
        if (newline < 0) break;
        const line = buffer.slice(0, newline).replace(/\r$/, '');
        buffer = buffer.slice(newline + 1);
        if (!line) {
          if (data.length) yield data.join('\n');
          data = []; size = 0;
        } else if (line.startsWith('data:')) {
          data.push(line.slice(5).replace(/^ /, ''));
          size += line.length;
        }
        if (size > 16 * 1024 * 1024) throw new Error('单条订阅响应事件过大');
      }
      if (buffer.length > 16 * 1024 * 1024) throw new Error('单条订阅响应事件过大');
      if (done) {
        if (buffer.trim() || data.length) throw new Error('订阅响应在 SSE 事件中途断开');
        return;
      }
    }
  } finally {
    signal.removeEventListener('abort', abort);
    await reader.cancel().catch(() => {});
    reader.releaseLock();
  }
}

function outputItem(raw: JsonObject, fallbackId: string): ModelItem {
  const id = typeof raw.id === 'string' && raw.id ? raw.id : fallbackId;
  if (raw.type === 'function_call') {
    if (raw.status === 'incomplete') throw new Error('工具参数生成未完成');
    const callId = text(raw.call_id, 'call_id');
    let arguments_: unknown;
    try { arguments_ = JSON.parse(text(raw.arguments, '工具参数')); }
    catch { throw new Error('订阅模型返回的工具参数不是完整 JSON'); }
    const args = z.json().safeParse(arguments_);
    if (!args.success) throw new Error('订阅模型返回的工具参数格式无效');
    return { id, raw, call: { id: callId, name: text(raw.name, '工具名'), arguments: args.data } };
  }
  if (typeof raw.type === 'string' && (raw.type.endsWith('_call') || raw.type === 'tool_search_call')) {
    throw new Error(`当前订阅适配器不支持输出调用类型 ${raw.type}`);
  }
  return { id, raw };
}

export class ChatGPTModel implements Model {
  constructor(private options: SubscriptionModelOptions) {}

  async *stream(request: ModelRequest, signal: AbortSignal): AsyncIterable<ModelEvent> {
    signal.throwIfAborted();
    const auth = await this.options.credentials(signal);
    signal.throwIfAborted();
    const input = request.history.map((entry): JsonObject => {
      switch (entry.type) {
        case 'input': return { role: 'user', content: [{ type: 'input_text', text: entry.input.text }] };
        case 'output': return entry.item.raw;
        case 'tool_result': {
          const { status, output, images } = entry.result;
          const text = status === 'success' ? output : `[${status}] ${output}`;
          return { type: 'function_call_output', call_id: entry.callId, output: images?.length
            ? [{ type: 'input_text', text }, ...images.map((image) => ({
              type: 'input_image', image_url: `data:${image.mediaType};base64,${image.data}`, detail: 'high' }))]
            : text };
        }
        case 'feedback': return { role: 'developer', content: [{ type: 'input_text', text: entry.text }] };
        case 'notification': return {
          role: entry.notification.authority === 'instruction' ? 'developer' : 'user',
          content: [{ type: 'input_text', text: entry.text }],
        };
      }
    });
    const response = await (this.options.fetch ?? fetch)(ENDPOINT, {
      method: 'POST', signal, redirect: 'error',
      headers: {
        authorization: `Bearer ${auth.accessToken}`, 'ChatGPT-Account-Id': auth.accountId,
        'content-type': 'application/json', accept: 'text/event-stream',
        originator: 'kite', 'user-agent': 'kite-harness/0.1',
        session_id: this.options.threadId,
      },
      body: JSON.stringify({
        model: this.options.model, instructions: request.instructions, input,
        tools: request.tools.map((tool) => ({ type: 'function', ...tool, strict: false })),
        tool_choice: request.allowedTools === undefined || request.allowedTools.length === request.tools.length ? 'auto'
          : request.allowedTools.length === 0 ? 'none' : { type: 'allowed_tools', mode: 'auto',
            tools: request.allowedTools.map((name) => ({ type: 'function', name })) },
        parallel_tool_calls: true, store: false, stream: true,
        include: ['reasoning.encrypted_content'],
        reasoning: { effort: this.options.reasoning ?? 'medium', summary: 'auto' },
        prompt_cache_key: this.options.threadId,
      }),
    });
    if (!response.ok) {
      await response.body?.cancel();
      if (response.status === 401) throw new Error('订阅认证失败（401），请在当前凭据所属的认证目录重新登录后重试。');
      if (response.status === 429) throw new Error('订阅额度或请求速率受限（429），请稍后重试。');
      throw new Error(`订阅模型请求失败（HTTP ${response.status}）`);
    }
    if (!response.body) throw new Error('订阅响应没有正文');
    const seen = new Set<string>();
    let completed = false;
    let index = 0;
    for await (const data of events(response.body, signal)) {
      if (data === '[DONE]') {
        if (!completed) throw new Error('订阅响应未完成便收到 DONE');
        continue;
      }
      let value: unknown;
      try { value = JSON.parse(data); } catch { throw new Error('订阅 SSE 事件不是完整 JSON'); }
      const event = asObject(value, '事件');
      if (completed) throw new Error('订阅响应完成后仍收到事件');
      switch (event.type) {
        case 'response.output_item.added': {
          const raw = asObject(event.item, '输出条目');
          const kind = raw.type === 'reasoning' ? 'thinking' : raw.type === 'function_call' ? 'tool_use'
            : raw.type === 'message' ? 'text' : undefined;
          if (!kind) break;
          const itemId = text(raw.id, 'item id');
          yield { type: 'item.started', itemId, kind,
            ...(kind === 'tool_use' ? { callId: text(raw.call_id, 'call_id'), name: text(raw.name, '工具名') } : {}) };
          if (kind === 'tool_use' && typeof raw.arguments === 'string' && raw.arguments) {
            yield { type: 'delta', itemId, field: 'arguments', text: raw.arguments, replace: true };
          }
          break;
        }
        case 'response.output_text.delta': case 'response.output_text.done':
        case 'response.reasoning_summary_text.delta': case 'response.reasoning_summary_text.done':
        case 'response.function_call_arguments.delta': case 'response.function_call_arguments.done': {
          const replace = event.type.endsWith('.done');
          const field = event.type.includes('function_call_arguments') ? 'arguments'
            : event.type.includes('reasoning_summary') ? 'thinking' : 'text';
          const value = replace ? event[field === 'arguments' ? 'arguments' : 'text'] : event.delta;
          if (typeof value !== 'string') throw new Error('订阅内容增量无效');
          const part = field === 'thinking' ? event.summary_index : event.content_index;
          if (part !== undefined && (typeof part !== 'number' || !Number.isSafeInteger(part) || part < 0)) {
            throw new Error('订阅内容分段序号无效');
          }
          yield { type: 'delta', text: value, field,
            ...(typeof event.item_id === 'string' ? { itemId: event.item_id } : {}),
            ...(typeof part === 'number' ? { part } : {}), ...(replace ? { replace: true } : {}) };
          break;
        }
        case 'response.output_item.done': {
          const raw = asObject(event.item, '输出条目');
          const item = outputItem(raw, `${request.id}:${event.output_index ?? index}`);
          if (seen.has(item.id)) throw new Error('订阅响应包含重复输出条目');
          seen.add(item.id); index++;
          yield { type: 'item', item };
          break;
        }
        case 'response.completed': {
          const reply = asObject(event.response, '完整响应');
          if (reply.status !== undefined && reply.status !== 'completed') throw new Error('订阅响应状态不是 completed');
          // 有些传输只在完成事件里携带完整输出；补齐缺失项，不重复已交付的项。
          if (Array.isArray(reply.output)) {
            for (const [position, output] of reply.output.entries()) {
              const item = outputItem(asObject(output, '输出条目'), `${request.id}:${position}`);
              if (!seen.has(item.id)) { seen.add(item.id); yield { type: 'item', item }; }
            }
          }
          completed = true;
          yield { type: 'completed', responseId: text(reply.id, 'response id'), needsFollowUp: reply.end_turn === false,
            ...(reply.usage && typeof reply.usage === 'object' ? { usage: asObject(reply.usage, '用量') } : {}),
          };
          break;
        }
        case 'response.failed': case 'response.incomplete': case 'error':
          // 不回显未知服务端正文，避免诊断意外带入请求或凭据。
          throw new Error(`订阅模型返回 ${event.type}，本次请求未成功完成`);
        default:
          // 其余生命周期事件不改变执行状态。
          break;
      }
    }
    if (!completed) throw new Error('订阅响应流在完成之前关闭');
  }
}
