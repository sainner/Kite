/**
 * 网页搜索与抓取的外部服务：DeepSeek 用账号里的模型 API Key，Tavily、Exa 用凭据里的搜索服务 Key。
 * 各家的请求与结果在这里统一成 SearchHit、FetchedPage；接口见 docs/harness-主循环.md「web_search」「web_fetch」里的链接。
 */
import { z } from 'zod';
import { searchProviders } from '../account-data/credentials.ts';

/** 换家时依次试的顺序。 */
export const webServices = ['deepseek', ...searchProviders] as const;
export type WebService = (typeof webServices)[number];
export const webServiceTitles: Record<WebService, string> = { deepseek: 'DeepSeek', tavily: 'Tavily', exa: 'Exa' };

export interface ServiceKey { provider: WebService; key: string }
export interface SearchHit { title: string; url: string; site?: string; date?: string; text: string }
export interface FetchedPage { title?: string; content: string }

const SEARCH_TIMEOUT_MS = 30_000;
const FETCH_TIMEOUT_MS = 60_000;

/** 错误说明给模型看，只带状态与服务自己的简短说明，不回显整段正文。 */
const failures: Record<number, string> = {
  401: 'Key 无效', 402: '余额或额度不足', 403: '拒绝了这次请求', 404: '取不到可用的内容', 408: '请求超时',
  429: '请求太快被限流', 432: '超出套餐额度', 433: '超出按量付费的限额', 504: '服务那边超时',
};

/** 三家的错误写法：Exa 是 {error}，DeepSeek 是 OpenAI 的 {error: {message}}，Tavily 是 {detail} 或 {detail: {error}}。 */
function serviceMessage(body: unknown): string | undefined {
  const value = body as { error?: { message?: unknown }; detail?: { error?: unknown } } | null | undefined;
  return [value?.error, value?.error?.message, value?.detail, value?.detail?.error]
    .find((entry): entry is string => typeof entry === 'string' && entry.trim() !== '')?.trim().slice(0, 200);
}

async function post(url: string, key: string, body: unknown, signal: AbortSignal, timeoutMs: number): Promise<unknown> {
  const timed = AbortSignal.any([signal, AbortSignal.timeout(timeoutMs)]);
  let response: Response;
  try {
    response = await fetch(url, { method: 'POST', signal: timed, redirect: 'error',
      headers: { authorization: `Bearer ${key}`, 'content-type': 'application/json', accept: 'application/json', 'user-agent': 'kite-web/0.1' },
      body: JSON.stringify(body) });
  } catch (error) {
    signal.throwIfAborted();
    throw new Error(timed.aborted ? '请求超时' : `连不上服务：${error instanceof Error ? error.message : String(error)}`);
  }
  const parsed: unknown = await response.json().catch(() => undefined);
  if (!response.ok) {
    const reason = failures[response.status] ?? (response.status >= 500 ? '服务暂时出错' : '请求被拒绝');
    const detail = serviceMessage(parsed);
    throw new Error(`${reason}（HTTP ${response.status}）${detail ? `：${detail}` : ''}`);
  }
  if (parsed === undefined) throw new Error('响应不是 JSON');
  return parsed;
}

const text = z.string().nullish().transform((value) => value?.trim() || undefined);
/** 各家日期写法不一（RFC 3339、YYYY-MM-DD），能认出日期的只留到日。 */
const day = text.transform((value) => value && (/^\d{4}-\d{2}-\d{2}/.exec(value)?.[0] ?? value));
const parse = <T extends z.ZodType>(schema: T, value: unknown): z.output<T> => {
  const result = schema.safeParse(value);
  if (!result.success) throw new Error('响应格式与接口说明不符');
  return result.data;
};
const hit = (entry: { title?: string | undefined; url: string; site?: string | undefined; date?: string | undefined; text?: string | undefined }): SearchHit =>
  ({ title: entry.title ?? entry.url, url: entry.url, ...(entry.site ? { site: entry.site } : {}), ...(entry.date ? { date: entry.date } : {}), text: entry.text ?? '' });
const page = (title: string | undefined, content: string | undefined): FetchedPage => {
  if (!content) throw new Error('没有取到正文');
  return { ...(title ? { title } : {}), content };
};

interface Adapter {
  search(key: string, query: string, count: number, signal: AbortSignal): Promise<SearchHit[]>;
  fetch(key: string, url: string, signal: AbortSignal): Promise<FetchedPage>;
}

/** https://api-docs.deepseek.com/guides/search/ ：summary 是给模型读的长摘要。 */
const deepseek: Adapter = {
  async search(key, query, count, signal) {
    const body = parse(z.object({ results: z.array(z.object({ title: text, url: z.string(), summary: text, snippet: text, site_name: text, date: day })) }),
      await post('https://api.deepseek.com/v1/tools/search', key, { query, count }, signal, SEARCH_TIMEOUT_MS));
    return body.results.map((entry) => hit({ title: entry.title, url: entry.url, site: entry.site_name, date: entry.date, text: entry.summary ?? entry.snippet }));
  },
  async fetch(key, url, signal) {
    const body = parse(z.object({ title: text, content: text }), await post('https://api.deepseek.com/v1/tools/fetch', key, { url }, signal, FETCH_TIMEOUT_MS));
    return page(body.title, body.content);
  },
};

/** https://docs.tavily.com/documentation/api-reference/endpoint/search 与 extract；extract 的失败在 200 的 failed_results 里。 */
const tavily: Adapter = {
  async search(key, query, count, signal) {
    const body = parse(z.object({ results: z.array(z.object({ title: text, url: z.string(), content: text, published_date: day })) }),
      await post('https://api.tavily.com/search', key, { query, max_results: count, include_published_date: true }, signal, SEARCH_TIMEOUT_MS));
    return body.results.map((entry) => hit({ title: entry.title, url: entry.url, date: entry.published_date, text: entry.content }));
  },
  async fetch(key, url, signal) {
    const body = parse(z.object({ results: z.array(z.object({ raw_content: text })), failed_results: z.array(z.object({ error: text })).nullish() }),
      await post('https://api.tavily.com/extract', key, { urls: [url], format: 'markdown' }, signal, FETCH_TIMEOUT_MS));
    const failed = body.failed_results?.[0];
    if (!body.results.length && failed) throw new Error(failed.error ?? '取不到这个网页');
    return page(undefined, body.results[0]?.raw_content);
  },
};

/** https://exa.ai/docs/reference/search 与 get-contents；结果只带高亮片段，正文要另取。contents 的失败在 statuses 里。 */
const exa: Adapter = {
  async search(key, query, count, signal) {
    const body = parse(z.object({ results: z.array(z.object({ title: text, url: z.string(), publishedDate: day, highlights: z.array(z.string()).nullish() })) }),
      await post('https://api.exa.ai/search', key, { query, numResults: count, type: 'auto', contents: { highlights: { maxCharacters: 1000 } } }, signal, SEARCH_TIMEOUT_MS));
    return body.results.map((entry) => hit({ title: entry.title, url: entry.url, date: entry.publishedDate, text: entry.highlights?.join(' … ') }));
  },
  async fetch(key, url, signal) {
    const body = parse(z.object({ results: z.array(z.object({ title: text, text })),
      statuses: z.array(z.object({ status: z.string(), error: z.object({ tag: text }).nullish() })).nullish() }),
      await post('https://api.exa.ai/contents', key, { urls: [url], text: true }, signal, FETCH_TIMEOUT_MS));
    const status = body.statuses?.[0];
    if (!body.results.length && status?.status === 'error') throw new Error(`取不到这个网页（${status.error?.tag ?? 'error'}）`);
    return page(body.results[0]?.title, body.results[0]?.text);
  },
};

const adapters: Record<WebService, Adapter> = { deepseek, tavily, exa };

/**
 * 按服务的固定顺序（DeepSeek、Tavily、Exa）逐个试，同一家几把 Key 按给的顺序；一家失败就换下一家，前面的失败随结果带回。
 * 全部失败时抛出的错误逐家列出原因。
 */
async function firstSuccess<T>(keys: ServiceKey[], signal: AbortSignal, run: (adapter: Adapter, key: string) => Promise<T>):
  Promise<{ service: WebService; value: T; skipped: string[] }> {
  const ordered = webServices.flatMap((service) => keys.filter((key) => key.provider === service));
  if (!ordered.length) throw new Error('没有可用的搜索服务：在 Kite 账号的凭据里添加 DeepSeek 的 API Key，或 Tavily、Exa 的搜索服务 Key');
  const skipped: string[] = [];
  for (const { provider: service, key } of ordered) {
    try { return { service, value: await run(adapters[service], key), skipped }; }
    catch (error) {
      signal.throwIfAborted();
      skipped.push(`${webServiceTitles[service]}：${error instanceof Error ? error.message : String(error)}`);
    }
  }
  throw new Error(`各家服务都没成功。${skipped.join('；')}`);
}

export const searchWeb = (keys: ServiceKey[], query: string, count: number, signal: AbortSignal) =>
  firstSuccess(keys, signal, (adapter, key) => adapter.search(key, query, count, signal));

export const fetchWeb = (keys: ServiceKey[], url: string, signal: AbortSignal) =>
  firstSuccess(keys, signal, (adapter, key) => adapter.fetch(key, url, signal));
