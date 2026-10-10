/**
 * 上下文编辑器的 token 计数。有对应厂商的 API Key 时调官方计数接口取准确值（两家都免费，只限频率）；
 * 没有 Key 或接口失败时，OpenAI 按公开的 o200k 分词在本机估算（GPT-5 系列与它一致），Claude 没有公开分词器，只能不给。
 * Claude 订阅登录只能在 Claude Code 里用，不拿来计数。
 */
import { createHash } from 'node:crypto';
import type { ApiKey } from './account-client.ts';
import { agentModels, defaultAgentModel } from './agents/models.ts';

export type TokenCountMethod = 'api' | 'o200k' | 'none';

export interface TokenCountResult {
  tokens?: number;
  method: TokenCountMethod;
  exact: boolean;
}

export interface TokenCountOptions {
  apiKeys: () => Promise<ApiKey[]>;
  /** 会话标题与点阵签名这类轻任务实际用的模型。 */
  lightModel: string;
  fetch?: typeof fetch;
}

/** 账号里的 Key 隔一会儿才重读；接口限频后这一家暂停官方计数一分钟。 */
const KEY_TTL = 5 * 60_000;
const COOLDOWN = 60_000;
const CACHE_LIMIT = 4_000;
const CONCURRENCY = 4;

/** 分词表有几 MB，第一次计数时才加载，不拖慢服务启动。 */
let o200k: Promise<(text: string) => number> | undefined;
const loadO200k = () => o200k ??= import('gpt-tokenizer/encoding/o200k_base').then((module) => module.countTokens);

type Vendor = 'openai' | 'anthropic';

export class TokenCounter {
  private keys?: { at: number; value: Promise<ApiKey[]> };
  private cache = new Map<string, number>();
  /** 每个模型的计数接口给一条消息加的固定开销，从结果里扣掉，只剩这段文字本身。 */
  private overheads = new Map<string, Promise<number>>();
  private cooldown = new Map<Vendor, number>();
  private running = 0;
  private waiting: (() => void)[] = [];

  constructor(private options: TokenCountOptions) {}

  /** 场景只用来推出模型：角色传自己的默认模型，轻任务场景用轻任务模型，其他按默认模型。 */
  modelFor(scene?: string): string {
    return scene === 'thread.title' || scene === 'template.emblem' ? this.options.lightModel : defaultAgentModel;
  }

  async count(texts: string[], model: string): Promise<TokenCountResult[]> {
    const claude = agentModels.claude.find((entry) => entry.id === model);
    const vendor: Vendor = claude ? 'anthropic' : 'openai';
    const apiModel = claude ? `claude-${claude.name.replaceAll('.', '-')}` : model;
    const key = await this.key(vendor);
    return Promise.all(texts.map(async (text): Promise<TokenCountResult> => {
      if (!text) return { tokens: 0, method: key ? 'api' : vendor === 'openai' ? 'o200k' : 'none', exact: true };
      if (key && (this.cooldown.get(vendor) ?? 0) < Date.now()) {
        try {
          return { tokens: await this.official(vendor, apiModel, key, text), method: 'api', exact: true };
        } catch (error) {
          console.warn('[token 计数]', vendor, (error as Error).message);
        }
      }
      if (vendor === 'anthropic') return { method: 'none', exact: false };
      const count = await loadO200k();
      return { tokens: this.cached(`o200k:${digest(text)}`, () => count(text)), method: 'o200k', exact: model.startsWith('gpt-5') };
    }));
  }

  private async key(vendor: Vendor): Promise<string | undefined> {
    if (!this.keys || Date.now() - this.keys.at > KEY_TTL) {
      this.keys = { at: Date.now(), value: this.options.apiKeys().catch(() => []) };
    }
    return (await this.keys.value).find((key) => key.provider === vendor && key.key)?.key;
  }

  private async official(vendor: Vendor, model: string, key: string, text: string): Promise<number> {
    const id = `api:${vendor}:${model}:${digest(text)}`;
    const hit = this.cache.get(id);
    if (hit !== undefined) return hit;
    let overhead = this.overheads.get(`${vendor}:${model}`);
    if (!overhead) {
      // 「.」本身算一个 token，多出来的是消息结构。
      overhead = this.request(vendor, model, key, '.').then((count) => Math.max(0, count - 1));
      overhead.catch(() => this.overheads.delete(`${vendor}:${model}`));
      this.overheads.set(`${vendor}:${model}`, overhead);
    }
    const tokens = Math.max(0, await this.request(vendor, model, key, text) - await overhead);
    return this.cached(id, () => tokens);
  }

  private async request(vendor: Vendor, model: string, key: string, text: string): Promise<number> {
    await this.slot();
    try {
      const response = await (this.options.fetch ?? fetch)(vendor === 'anthropic'
        ? 'https://api.anthropic.com/v1/messages/count_tokens' : 'https://api.openai.com/v1/responses/input_tokens', {
        method: 'POST',
        signal: AbortSignal.timeout(10_000),
        headers: vendor === 'anthropic'
          ? { 'x-api-key': key, 'anthropic-version': '2023-06-01', 'content-type': 'application/json' }
          : { authorization: `Bearer ${key}`, 'content-type': 'application/json' },
        body: JSON.stringify(vendor === 'anthropic'
          ? { model, messages: [{ role: 'user', content: text }] } : { model, input: text }),
      });
      if (response.status === 429) this.cooldown.set(vendor, Date.now() + COOLDOWN);
      if (!response.ok) throw new Error(`计数接口返回 ${response.status}`);
      const tokens = (await response.json() as { input_tokens?: unknown }).input_tokens;
      if (typeof tokens !== 'number') throw new Error('计数接口没有返回 input_tokens');
      return tokens;
    } finally {
      this.running--;
      this.waiting.shift()?.();
    }
  }

  /** 同时最多几个官方计数请求，其余排队；打开一份很长的提示词时不一下子打满限频。 */
  private async slot(): Promise<void> {
    if (this.running >= CONCURRENCY) await new Promise<void>((resolve) => this.waiting.push(resolve));
    this.running++;
  }

  private cached(id: string, count: () => number): number {
    const hit = this.cache.get(id);
    if (hit !== undefined) return hit;
    const value = count();
    this.cache.set(id, value);
    if (this.cache.size > CACHE_LIMIT) this.cache.delete(this.cache.keys().next().value!);
    return value;
  }
}

function digest(text: string): string {
  return createHash('sha256').update(text).digest('hex');
}
