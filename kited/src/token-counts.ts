/**
 * 上下文编辑器的 token 计数：按公开的 o200k 分词在本机估算，GPT-5 系列与它一致，DeepSeek 没有公开分词，也按它估。
 * Claude 没有公开分词器，只能不给；Claude 订阅登录只能在 Claude Code 里用，不拿来计数。
 */
import { createHash } from 'node:crypto';
import { vendorOfModel } from './agents/models.ts';

export type TokenCountMethod = 'o200k' | 'none';

export interface TokenCountResult {
  tokens?: number;
  method: TokenCountMethod;
  exact: boolean;
}

const CACHE_LIMIT = 4_000;

/** 分词表有几 MB，第一次计数时才加载，不拖慢服务启动。 */
let o200k: Promise<(text: string) => number> | undefined;
const loadO200k = () => o200k ??= import('gpt-tokenizer/encoding/o200k_base').then((module) => module.countTokens);

export class TokenCounter {
  private cache = new Map<string, number>();

  async count(texts: string[], model: string): Promise<TokenCountResult[]> {
    if (vendorOfModel(model).id === 'anthropic') return texts.map((text) => text ? { method: 'none', exact: false } : { tokens: 0, method: 'none', exact: true });
    const count = await loadO200k();
    return texts.map((text) => text ? { tokens: this.cached(digest(text), () => count(text)), method: 'o200k', exact: model.startsWith('gpt-5') }
      : { tokens: 0, method: 'o200k', exact: true });
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
