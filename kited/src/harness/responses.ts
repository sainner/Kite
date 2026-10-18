/**
 * OpenAI Responses 协议的流式传输：把历史转成请求条目、解析 SSE、产出模型事件。
 * ChatGPT 订阅与 DeepSeek 的兼容接口共用；端点、认证与请求参数由各自的适配器决定。
 */
import { z } from 'zod';
import { modelText } from './input.ts';
import { TOOL_SEARCH } from './tool-search.ts';
import type { ContextItem, JsonObject, ModelEvent, ModelItem, ModelRequest } from './types.ts';

const object = z.record(z.string(), z.json());

function asObject(value: unknown, label: string): JsonObject {
  const result = object.safeParse(value);
  if (!result.success) throw new Error(`模型响应中的 ${label} 格式无效`);
  return result.data;
}

function text(value: unknown, label: string): string {
  if (typeof value !== 'string' || !value) throw new Error(`模型响应缺少 ${label}`);
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
        if (size > 16 * 1024 * 1024) throw new Error('单条模型响应事件过大');
      }
      if (buffer.length > 16 * 1024 * 1024) throw new Error('单条模型响应事件过大');
      if (done) {
        if (buffer.trim() || data.length) throw new Error('模型响应在 SSE 事件中途断开');
        return;
      }
    }
  } finally {
    signal.removeEventListener('abort', abort);
    await reader.cancel().catch(() => {});
    reader.releaseLock();
  }
}

function outputItem(raw: JsonObject, fallbackId: string, format: ModelItem['format']): ModelItem {
  const id = typeof raw.id === 'string' && raw.id ? raw.id : fallbackId;
  const item: ModelItem = { id, raw, ...(format ? { format } : {}) };
  if (raw.type === 'function_call') {
    if (raw.status === 'incomplete') throw new Error('工具参数生成未完成');
    const callId = text(raw.call_id, 'call_id');
    let arguments_: unknown;
    try { arguments_ = JSON.parse(text(raw.arguments, '工具参数')); }
    catch { throw new Error('模型返回的工具参数不是完整 JSON'); }
    const args = z.json().safeParse(arguments_);
    if (!args.success) throw new Error('模型返回的工具参数格式无效');
    return { ...item, call: { id: callId, name: text(raw.name, '工具名'), arguments: args.data } };
  }
  // tool_search 由 Kite 执行，参数是对象而不是 JSON 字符串；服务端执行的搜索没有声明，不会出现。
  if (raw.type === 'tool_search_call' && raw.execution === 'client') {
    const args = z.json().safeParse(raw.arguments);
    if (!args.success) throw new Error('模型返回的搜索参数格式无效');
    return { ...item, call: { id: text(raw.call_id, 'call_id'), name: TOOL_SEARCH, arguments: args.data } };
  }
  if (typeof raw.type === 'string' && (raw.type.endsWith('_call') || raw.type === 'tool_search_call')) {
    throw new Error(`当前模型适配器不支持输出调用类型 ${raw.type}`);
  }
  return item;
}

const assistantMessage = (text: string): JsonObject => ({ type: 'message', role: 'assistant', content: [{ type: 'output_text', text }] });

/** 助手消息各段的文字（正文或拒绝说明），空段跳过；遇到别的内容类型报错，不悄悄丢掉。 */
export function messageTexts(raw: JsonObject): string[] {
  return (Array.isArray(raw.content) ? raw.content : []).flatMap((part): string[] => {
    const entry: JsonObject = part && typeof part === 'object' && !Array.isArray(part) ? part : {};
    const value = entry.type === 'output_text' ? entry.text : entry.type === 'refusal' ? entry.refusal : undefined;
    if (typeof value !== 'string') throw new Error(`不能转换模型消息里的内容 ${String(entry.type)}`);
    return value ? [value] : [];
  });
}

/**
 * 别的厂商产生的条目只交正文与工具调用，条目 ID 对方也不认。推理只交还给产生它的厂商：thinking 的签名只有 Anthropic 能校验，
 * 只带摘要的 reasoning 条目会被订阅端点静默丢弃（2026-10-08 实测），OpenAI 的推理是加密的，DeepSeek 的推理是明文。
 */
export function portableItem(item: ModelItem): JsonObject | [] {
  if (item.call?.name === TOOL_SEARCH) return { type: 'tool_search_call', execution: 'client', call_id: item.call.id, status: 'completed', arguments: item.call.arguments };
  if (item.call) return { type: 'function_call', call_id: item.call.id, name: item.call.name, arguments: JSON.stringify(item.call.arguments) };
  const raw = item.raw;
  if (item.format === 'anthropic') {
    if (raw.type === 'text') return typeof raw.text === 'string' && raw.text ? assistantMessage(raw.text) : [];
    if (raw.type === 'thinking' || raw.type === 'redacted_thinking') return [];
    throw new Error(`不能把 Claude 条目 ${String(raw.type)} 交给当前模型`);
  }
  if (raw.type === 'reasoning') return [];
  if (raw.type === 'message') {
    const texts = messageTexts(raw);
    return texts.length ? assistantMessage(texts.join('')) : [];
  }
  throw new Error(`不能把条目 ${String(raw.type)} 交给当前模型`);
}

/**
 * 历史转成 input。format 是这个适配器自己产出的条目格式，这些条目原样交回，别家的经 portableItem 转换。
 */
export function responsesInput(history: ContextItem[], { format, functions = {} }: {
  format?: ModelItem['format'];
  /** 经搜索加载的函数与声明的函数一样带上的字段（如 ChatGPT 的 strict: false）。 */
  functions?: JsonObject;
} = {}): JsonObject[] {
  const searches = new Set<string>();
  return history.flatMap<JsonObject>((entry): JsonObject | [] => {
    switch (entry.type) {
      case 'input': return { role: 'user', content: [{ type: 'input_text', text: modelText(entry.input) }] };
      case 'output':
        if (entry.item.call?.name === TOOL_SEARCH) searches.add(entry.item.call.id);
        return entry.item.format === format ? entry.item.raw : portableItem(entry.item);
      case 'tool_result': {
        // 搜索的结果只能是 tool_search_output；没加载到也要交回一个空的，调用才算有了结果。
        if (searches.has(entry.callId)) return { type: 'tool_search_output', execution: 'client', call_id: entry.callId, status: 'completed',
          tools: (entry.result.tools ?? []).map((tool) => ({ type: 'function', ...tool, ...functions, defer_loading: true })) };
        const { status, output, images: attached } = entry.result;
        const text = status === 'success' ? output : `[${status}] ${output}`;
        return { type: 'function_call_output', call_id: entry.callId, output: attached?.length
          ? [{ type: 'input_text', text }, ...attached.map((image) => ({
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
}

/**
 * 声明照旧、前缀不变，不用 allowed_tools：它列不进 tool_search，用了这次就不能加载插件工具；关掉的工具在调用时拒绝。
 * 有工具却一个都不放行时（压缩摘要）禁止调用；没有工具的请求（轻量任务）照常 auto。
 */
export const responsesToolChoice = (request: ModelRequest) => request.tools.length && request.allowedTools?.length === 0 ? 'none' : 'auto';

/** 工具声明：tool_search 声明成由 Kite 执行的搜索，其余是函数。 */
export function responsesTools(tools: ModelRequest['tools'], extra: JsonObject = {}): JsonObject[] {
  return tools.map((tool): JsonObject => tool.name === TOOL_SEARCH
    ? { type: 'tool_search', execution: 'client', description: tool.description, parameters: tool.parameters }
    : { type: 'function', ...tool, ...extra });
}

/** 解析一次请求的 SSE 正文；format 标在产出的条目上，缺省为 OpenAI 自己的条目。 */
export async function* responseEvents(body: ReadableStream<Uint8Array>, request: ModelRequest, signal: AbortSignal,
  format?: ModelItem['format']): AsyncIterable<ModelEvent> {
  const seen = new Set<string>();
  let completed = false;
  let index = 0;
  for await (const data of events(body, signal)) {
    if (data === '[DONE]') {
      if (!completed) throw new Error('模型响应未完成便收到 DONE');
      continue;
    }
    let value: unknown;
    try { value = JSON.parse(data); } catch { throw new Error('模型 SSE 事件不是完整 JSON'); }
    const event = asObject(value, '事件');
    if (completed) throw new Error('模型响应完成后仍收到事件');
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
      // OpenAI 只给推理摘要，DeepSeek 给明文推理（reasoning_text）。
      case 'response.output_text.delta': case 'response.output_text.done':
      case 'response.reasoning_summary_text.delta': case 'response.reasoning_summary_text.done':
      case 'response.reasoning_text.delta': case 'response.reasoning_text.done':
      case 'response.function_call_arguments.delta': case 'response.function_call_arguments.done': {
        const replace = event.type.endsWith('.done');
        const field = event.type.includes('function_call_arguments') ? 'arguments'
          : event.type.includes('reasoning') ? 'thinking' : 'text';
        const value = replace ? event[field === 'arguments' ? 'arguments' : 'text'] : event.delta;
        if (typeof value !== 'string') throw new Error('模型内容增量无效');
        const part = event.type.includes('reasoning_summary') ? event.summary_index : event.content_index;
        if (part !== undefined && (typeof part !== 'number' || !Number.isSafeInteger(part) || part < 0)) {
          throw new Error('模型内容分段序号无效');
        }
        yield { type: 'delta', text: value, field,
          ...(typeof event.item_id === 'string' ? { itemId: event.item_id } : {}),
          ...(typeof part === 'number' ? { part } : {}), ...(replace ? { replace: true } : {}) };
        break;
      }
      case 'response.output_item.done': {
        const raw = asObject(event.item, '输出条目');
        const item = outputItem(raw, `${request.id}:${event.output_index ?? index}`, format);
        if (seen.has(item.id)) throw new Error('模型响应包含重复输出条目');
        seen.add(item.id); index++;
        yield { type: 'item', item };
        break;
      }
      case 'response.completed': {
        const reply = asObject(event.response, '完整响应');
        if (reply.status !== undefined && reply.status !== 'completed') throw new Error('模型响应状态不是 completed');
        // 有些传输只在完成事件里携带完整输出；补齐缺失项，不重复已交付的项。
        if (Array.isArray(reply.output)) {
          for (const [position, output] of reply.output.entries()) {
            const item = outputItem(asObject(output, '输出条目'), `${request.id}:${position}`, format);
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
        throw new Error(`模型返回 ${event.type}，本次请求未成功完成`);
      default:
        // 其余生命周期事件不改变执行状态。
        break;
    }
  }
  if (!completed) throw new Error('模型响应流在完成之前关闭');
}
