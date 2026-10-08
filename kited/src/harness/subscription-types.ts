/** 只读使用 ChatGPT 登录凭据，不由模型适配器刷新或改写。 */
export interface SubscriptionCredentials {
  accessToken: string;
  accountId: string;
}

export interface SubscriptionModelOptions {
  model: string;
  reasoning?: string;
  threadId: string;
  credentials(signal: AbortSignal): Promise<SubscriptionCredentials>;
  /** 每个响应的头交给额度观测，不影响请求本身。 */
  observeLimits?(headers: Headers): void;
  /** 测试注入 HTTP 传输；生产使用 fetch 和固定官方订阅端点。 */
  fetch?: (url: string, init: RequestInit) => Promise<Response>;
}
