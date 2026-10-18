/** ChatGPT 订阅 Responses 传输。循环与工具执行仍由 HarnessRunner 管理。 */
import { responseEvents, responsesInput, responsesToolChoice, responsesTools } from './responses.ts';
import type { SubscriptionModelOptions } from './subscription-types.ts';
import type { Model, ModelEvent, ModelRequest } from './types.ts';

const ENDPOINT = 'https://chatgpt.com/backend-api/codex/responses';
/** harness 主动采用的运行窗口，写入每次请求的配置；订阅响应不提供窗口，不把目录的最大能力当作当前设置。 */
export const CHATGPT_CONTEXT_WINDOW = 272_000;

export class ChatGPTModel implements Model {
  constructor(private options: SubscriptionModelOptions) {}

  async *stream(request: ModelRequest, signal: AbortSignal): AsyncIterable<ModelEvent> {
    signal.throwIfAborted();
    const auth = await this.options.credentials(signal);
    signal.throwIfAborted();
    const input = responsesInput(request.history, { functions: { strict: false } });
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
        tools: responsesTools(request.tools, { strict: false }),
        tool_choice: responsesToolChoice(request),
        parallel_tool_calls: true, store: false, stream: true,
        include: ['reasoning.encrypted_content'],
        reasoning: { effort: this.options.reasoning ?? 'medium', summary: 'concise' },
        prompt_cache_key: this.options.threadId,
      }),
    });
    // 限流的 429 也带额度头。
    this.options.observeLimits?.(response.headers);
    if (!response.ok) {
      await response.body?.cancel();
      if (response.status === 401) throw new Error('订阅认证失败（401），请在当前凭据所属的认证目录重新登录后重试。');
      if (response.status === 429) throw new Error('订阅额度或请求速率受限（429），请稍后重试。');
      throw new Error(`订阅模型请求失败（HTTP ${response.status}）`);
    }
    if (!response.body) throw new Error('订阅响应没有正文');
    yield* responseEvents(response.body, request, signal);
  }
}
