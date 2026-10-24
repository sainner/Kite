/**
 * DeepSeek 的 Responses 兼容接口，用 API Key 按量计费；循环与工具执行仍由 HarnessRunner 管理。
 * 接口与 OpenAI 的差别见 https://api-docs.deepseek.com/zh-cn/guides/responses_api ：无状态，没有 include、prompt_cache_key，
 * tool_choice 没有 allowed_tools，推理以明文 reasoning_text 给出、交回时并进相邻的助手消息，上下文缓存自动按前缀命中。
 * 文档没列由客户端执行的 tool_search，deepseek-flash 实测可用，defer_loading 与 additional_tools 被忽略，见 spikes/tool-search。
 */
import { connect, responseEvents, responsesInput, responsesToolChoice, responsesTools, retryableStatus } from './responses.ts';
import { ModelRequestError, type JsonObject, type Model, type ModelEvent, type ModelRequest } from './types.ts';

const ENDPOINT = 'https://api.deepseek.com/responses';
/** V4 系列的上下文窗口是 1M，harness 按它自动压缩。 */
export const DEEPSEEK_CONTEXT_WINDOW = 1_000_000;

export interface DeepSeekModelOptions {
  model: string;
  reasoning?: string;
  /** 每次请求重新取，换了 Key 下一次请求生效。 */
  key(): Promise<string | undefined>;
  /** 测试注入 HTTP 传输；生产使用 fetch 和固定官方端点。 */
  fetch?: (url: string, init: RequestInit) => Promise<Response>;
}

const assistantSide = (item: JsonObject) => item.type === 'reasoning' || item.type === 'function_call' || item.type === 'tool_search_call'
  || (item.type === 'message' && item.role === 'assistant');

/**
 * 思考模式带工具时，Chat Completions 要求此前每段助手输出都交回推理，缺了整次请求 400；别的厂商产生的段没有 DeepSeek 的推理，
 * 补一个只含空格的推理占位（第三方客户端的做法，空串在 V4 上会被拒）。Responses 接口是否同样要求尚未实测。
 */
function withReasoning(input: JsonObject[]): JsonObject[] {
  const result: JsonObject[] = [];
  let run: JsonObject[] = [];
  const flush = () => {
    if (run.length && !run.some((item) => item.type === 'reasoning')) {
      result.push({ type: 'reasoning', summary: [], content: [{ type: 'reasoning_text', text: ' ' }] });
    }
    result.push(...run);
    run = [];
  };
  for (const item of input) {
    if (assistantSide(item)) run.push(item);
    else { flush(); result.push(item); }
  }
  flush();
  return result;
}

const failures: Record<number, string> = {
  400: '拒绝了这次请求，可能是上下文超出窗口或含有当前型号不支持的内容',
  401: 'API Key 无效，请在 Kite 账号的凭据里更换',
  402: '账户余额不足，充值后重试',
  429: '请求速率受限，请稍后重试',
};

export class DeepSeekModel implements Model {
  constructor(private options: DeepSeekModelOptions) {}

  async *stream(request: ModelRequest, signal: AbortSignal): AsyncIterable<ModelEvent> {
    signal.throwIfAborted();
    const key = await this.options.key();
    if (!key) throw new Error('没有 DeepSeek 的 API Key：在 Kite 账号的凭据里添加，或给 kited 设置 DEEPSEEK_API_KEY');
    signal.throwIfAborted();
    // DeepSeek 自己的条目原样交回，推理随之交回。
    const input = withReasoning(responsesInput(request.history, { format: 'deepseek' }));
    const response = await connect(signal, () => (this.options.fetch ?? fetch)(ENDPOINT, {
      method: 'POST', signal, redirect: 'error',
      headers: { authorization: `Bearer ${key}`, 'content-type': 'application/json', accept: 'text/event-stream', 'user-agent': 'kite-harness/0.1' },
      body: JSON.stringify({
        model: this.options.model, instructions: request.instructions, input,
        ...(request.tools.length ? { tools: responsesTools(request.tools), tool_choice: responsesToolChoice(request) } : {}),
        // 上游把 medium、xhigh 归到 high。
        reasoning: { effort: this.options.reasoning ?? 'medium' }, stream: true,
      }),
    }));
    if (!response.ok) {
      await response.body?.cancel();
      const reason = failures[response.status] ?? (response.status >= 500 ? '服务暂时不可用，请稍后重试' : '请求失败');
      throw new ModelRequestError(`DeepSeek ${reason}（HTTP ${response.status}）`, retryableStatus(response.status));
    }
    if (!response.body) throw new ModelRequestError('DeepSeek 响应没有正文', true);
    yield* responseEvents(response.body, request, signal, 'deepseek');
  }
}
