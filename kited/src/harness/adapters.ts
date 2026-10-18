/** 按模型的厂商选模型适配器与 harness 采用的上下文窗口；kited 与独立终端共用。 */
import type { ApiKey } from '../account-data/credentials.ts';
import { vendorOfModel, type ModelVendor } from '../agents/models.ts';
import { readSubscriptionCredentials } from './auth.ts';
import { CHATGPT_CONTEXT_WINDOW, ChatGPTModel } from './chatgpt.ts';
import { DEEPSEEK_CONTEXT_WINDOW, DeepSeekModel } from './deepseek.ts';
import type { Model } from './types.ts';

/** 账号凭据里的第一把 DeepSeek Key（按凭据列表的顺序，同语音识别取 Key），没有时用 kited 环境里的 DEEPSEEK_API_KEY。 */
export async function deepseekKey(apiKeys?: () => Promise<ApiKey[]>): Promise<string | undefined> {
  const stored = apiKeys && (await apiKeys()).find((key) => key.provider === 'deepseek' && key.key)?.key;
  return stored || process.env.DEEPSEEK_API_KEY || undefined;
}

export interface HarnessModelOptions {
  threadId: string;
  /** ChatGPT 登录凭据文件；缺省为 Kite 的独立认证目录。 */
  chatgptAuth?: string;
  /** 账号里的 API 凭据；独立终端没有，DeepSeek 只读环境变量。 */
  apiKeys?: () => Promise<ApiKey[]>;
  /** ChatGPT 订阅响应带回的额度。 */
  observeLimits?(headers: Headers): void;
}

type Choice = { model: string; reasoning: string };
type Adapter = (choice: Choice, options: HarnessModelOptions) => { model: Model; contextWindow: number };

/** 目录里每家由 harness 运行的厂商都要有适配器；厂商表加了一家而这里漏了，编译不过。 */
const adapters: Record<Extract<ModelVendor, { runtime: 'harness' }>['id'], Adapter> = {
  openai: (choice, options) => ({ contextWindow: CHATGPT_CONTEXT_WINDOW, model: new ChatGPTModel({ ...choice, threadId: options.threadId,
    credentials: () => readSubscriptionCredentials(options.chatgptAuth),
    ...(options.observeLimits ? { observeLimits: options.observeLimits } : {}) }) }),
  deepseek: (choice, options) => ({ contextWindow: DEEPSEEK_CONTEXT_WINDOW,
    model: new DeepSeekModel({ ...choice, key: () => deepseekKey(options.apiKeys) }) }),
};

export function harnessModel(choice: Choice, options: HarnessModelOptions): { model: Model; contextWindow: number } {
  const vendor = vendorOfModel(choice.model);
  if (vendor.runtime !== 'harness') throw new Error(`${vendor.title} 的模型不由自研 harness 运行`);
  return adapters[vendor.id](choice, options);
}
