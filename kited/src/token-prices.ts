/**
 * 用量折算金额的价格表：各模型每百万 token 的美元单价，取官方 API 价格页的标准档，2026-10-10 核对：
 * https://platform.claude.com/docs/en/about-claude/pricing 、https://developers.openai.com/api/docs/pricing 。
 * 订阅账号不按 token 计费，折算的是同样用量走 API 要花多少。表里没有的模型不计价，例如 Codex 的 codex-auto-review。
 * OpenAI 的长上下文档（输入超过 272K）只有价格页旗舰表列出的几个型号有，其他型号按短上下文计。
 */

import { agentModels } from './agents/models.ts';

/** 一次请求的 token 按计价类别分开，几类互不包含。 */
export interface RequestTokens {
  /** 未命中缓存的输入。 */
  input: number;
  cacheRead: number;
  /** 缓存写入；Claude 是 5 分钟缓存，OpenAI 只有这一种。 */
  cacheWrite: number;
  /** Claude 的 1 小时缓存写入。 */
  cacheWrite1h?: number;
  output: number;
  /** Claude 的快速模式，各类单价都翻倍。 */
  fast?: boolean;
}

/** 每百万 token 的美元单价。价格页上没有缓存写入价的模型不会产生缓存写入，计价时按输入价兜底；只有 Claude 分 1 小时写入。 */
interface Rates { input: number; cacheRead: number; cacheWrite?: number; cacheWrite1h?: number; output: number }
/** 提示超过 long.above 个 token 的请求整次按 long.rates 计价；提示含缓存读写。 */
type ModelPrice = Rates & { long?: { above: number; rates: Rates } };

/** 价格表核对的日期，随表一起给 App 展示。 */
export const pricesChecked = '2026-10-10';

/** Claude 的缓存写入是输入单价的 1.25 倍（5 分钟）与 2 倍（1 小时），缓存命中通常是 0.1 倍。 */
const claude = (input: number, output: number, read = 0.1): Rates =>
  ({ input, output, cacheRead: input * read, cacheWrite: input * 1.25, cacheWrite1h: input * 2 });
const openai = (input: number, cacheRead: number, output: number, cacheWrite?: number): Rates =>
  ({ input, output, cacheRead, ...(cacheWrite === undefined ? {} : { cacheWrite }) });

const prices: Record<string, ModelPrice> = {
  'claude-fable-5-1': claude(10, 50, 0.025),
  'claude-fable-5': claude(10, 50),
  'claude-opus-5-5': claude(4, 20, 0.05),
  'claude-opus-5': claude(5, 25),
  'claude-opus-4-8': claude(5, 25),
  'claude-opus-4-7': claude(5, 25),
  'claude-opus-4-6': claude(5, 25),
  'claude-opus-4-5': claude(5, 25),
  'claude-opus-4-1': claude(15, 75),
  'claude-opus-4': claude(15, 75),
  'claude-sonnet-5-5': claude(2, 10, 0.05),
  'claude-sonnet-5': claude(2, 10),
  'claude-sonnet-4-6': claude(3, 15),
  'claude-sonnet-4-5': claude(3, 15),
  'claude-sonnet-4': claude(3, 15),
  'claude-haiku-5-5': { ...claude(0.1, 0.5), long: { above: 100_000, rates: claude(0.5, 2.5) } },
  'claude-haiku-4-5': claude(1, 5),
  'claude-3-5-haiku': claude(0.8, 4),
  'gpt-6-astra': { ...openai(10, 1, 50, 12.5), long: { above: 272_000, rates: openai(20, 2, 75, 25) } },
  'gpt-6.1-sol': { ...openai(2, 0.1, 10, 2.5), long: { above: 272_000, rates: openai(4, 0.2, 15, 5) } },
  'gpt-6-sol': openai(2, 0.2, 10, 2.5),
  'gpt-6-luna': { ...openai(0.1, 0.01, 0.5, 0.125), long: { above: 272_000, rates: openai(0.2, 0.02, 0.75, 0.25) } },
  'gpt-5.6-sol': openai(4, 0.4, 20, 5),
  'gpt-5.6-terra': openai(2, 0.2, 12, 2.5),
  'gpt-5.6-luna': openai(0.2, 0.02, 1.2, 0.25),
  'gpt-5.5': openai(5, 0.5, 30),
  'gpt-5.4': openai(2.5, 0.25, 15),
  'gpt-5.4-mini': openai(0.75, 0.075, 4.5),
  'gpt-5.4-nano': openai(0.2, 0.02, 1.25),
  'gpt-5.3-codex': openai(1.75, 0.175, 14),
  'gpt-5.2': openai(1.75, 0.175, 14),
  'gpt-5.1': openai(1.25, 0.125, 10),
  'gpt-5.1-codex-max': openai(1.25, 0.125, 10),
  'gpt-5': openai(1.25, 0.125, 10),
  'gpt-5-codex': openai(1.25, 0.125, 10),
  'gpt-5-mini': openai(0.25, 0.025, 2),
  'gpt-5-nano': openai(0.05, 0.005, 0.4),
};

/** 带日期的快照与上下文后缀按基础型号计。 */
const priceOf = (model: string): ModelPrice | undefined => prices[model.replace(/\[[^\]]*\]$/, '').replace(/-(\d{8}|\d{4}-\d{2}-\d{2})$/, '')];

/** 一次请求按 API 价格折算的美元；没有模型或表里没有时为 undefined。 */
export function requestCost(model: string | undefined, tokens: RequestTokens): number | undefined {
  const price = model ? priceOf(model) : undefined;
  if (!price) return undefined;
  const write1h = tokens.cacheWrite1h ?? 0;
  const prompt = tokens.input + tokens.cacheRead + tokens.cacheWrite + write1h;
  const rates = price.long && prompt > price.long.above ? price.long.rates : price;
  const cacheWrite = rates.cacheWrite ?? rates.input;
  const cost = tokens.input * rates.input + tokens.cacheRead * rates.cacheRead + tokens.cacheWrite * cacheWrite
    + write1h * (rates.cacheWrite1h ?? cacheWrite) + tokens.output * rates.output;
  return cost / 1_000_000 * (tokens.fast ? 2 : 1);
}

/**
 * 给 App 展示的价格表：只列 Kite 模型目录里的模型，按目录的先后排，用目录里的显示名。
 * 计价仍用整张表，Codex、Claude Code 里用到的其他型号照样折算。Claude 目录用 opus、sonnet 这类别名，按显示名找到型号。
 */
export function tokenPrices() {
  const entries = [
    ...agentModels.claude.map((model) => ({ model, provider: 'Anthropic', price: priceOf(`claude-${model.name.replaceAll('.', '-')}`) })),
    ...agentModels.models.map((model) => ({ model, provider: 'OpenAI', price: priceOf(model.id) })),
  ];
  return { checked: pricesChecked,
    models: entries.flatMap(({ model, provider, price }) => price ? [{ model: model.name, provider, ...price }] : []) };
}
