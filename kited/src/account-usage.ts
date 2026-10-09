/**
 * 账号按天的 token 用量与本机记录的按小时分布。上游有按天数据的直接读取，不另存；按天或按小时缺上游的部分
 * 由 kited 扫描本机会话记录按小时汇总保存，不受本地记录保留期限制。
 */
import { createReadStream } from 'node:fs';
import { readdir } from 'node:fs/promises';
import { basename, join } from 'node:path';
import { createInterface } from 'node:readline';
import { z } from 'zod';

export interface UsageDay {
  date: string;
  tokens: number;
  /** 本地时间 0–23 时每小时的 token，只来自这台工作机的记录；没有本机记录的日子省略。 */
  hours?: number[];
}

/** 按本地日期分组，每天 24 个小时的 token。 */
export type HourlyUsage = Map<string, number[]>;

export interface AccountUsage {
  /** account：上游给出整个账号在所有设备上的用量；machine：只含这台工作机上的记录。 */
  scope: 'account' | 'machine';
  /** 最近 53 周里有用量的日期，升序；日期为 YYYY-MM-DD。 */
  days: UsageDay[];
  lifetimeTokens: number;
}

/** kited 自己保存的按小时汇总。合并取较大值：本地记录只增不减，被清理后重扫得到的较小值不覆盖已存的数。 */
export interface UsageStore {
  mergeUsageHours(account: string, usage: HourlyUsage): void;
  /** 有用量的日子，升序，带按小时的分布。 */
  usageDays(account: string): UsageDay[];
}

const historyDays = 53 * 7;

/** 本地时区的日期，与用户看到的「今天」一致。 */
export function localDate(time: Date): string {
  const pad = (value: number) => String(value).padStart(2, '0');
  return `${time.getFullYear()}-${pad(time.getMonth() + 1)}-${pad(time.getDate())}`;
}

function addTokens(usage: HourlyUsage, time: Date, tokens: number): void {
  if (Number.isNaN(time.getTime()) || tokens <= 0) return;
  const date = localDate(time);
  const hours = usage.get(date) ?? Array<number>(24).fill(0);
  hours[time.getHours()]! += tokens;
  usage.set(date, hours);
}

/** 累计缺省为给出的各天之和。 */
function recent(days: UsageDay[], scope: AccountUsage['scope'], lifetimeTokens = days.reduce((sum, day) => sum + day.tokens, 0)): AccountUsage {
  const since = localDate(new Date(Date.now() - historyDays * 86_400_000));
  return { scope, lifetimeTokens, days: days.filter((day) => day.tokens > 0 && day.date > since).sort((a, b) => a.date.localeCompare(b.date)) };
}

const chatgptProfile = z.object({ stats: z.object({
  lifetime_tokens: z.number().finite().nullish(),
  daily_usage_buckets: z.array(z.object({ start_date: z.string().regex(/^\d{4}-\d{2}-\d{2}$/), tokens: z.number().finite() })),
}) });

/** Codex 官方客户端的个人用量（/wham/profiles/me）：整个账号按天的 token。 */
export function chatgptDailyUsage(data: unknown): AccountUsage | undefined {
  const parsed = chatgptProfile.safeParse(data);
  if (!parsed.success) return undefined;
  const days = parsed.data.stats.daily_usage_buckets.map((bucket) => ({ date: bucket.start_date, tokens: bucket.tokens }));
  return recent(days, 'account', parsed.data.stats.lifetime_tokens ?? undefined);
}

/**
 * 上游按天的用量配上本机记录的按小时分布。上游统计有延迟，比上游最后一天还新的日子（通常是今天）用本机的合计；
 * 上游没给按天数据时退回本机记录。
 */
export function withLocalHours(upstream: AccountUsage | undefined, local: UsageDay[]): AccountUsage | undefined {
  if (!upstream) return local.length ? recent(local, 'machine') : undefined;
  const own = new Map(local.map((day) => [day.date, day]));
  const last = upstream.days.at(-1)?.date ?? '';
  const days = upstream.days.map((day) => own.get(day.date)?.hours ? { ...day, hours: own.get(day.date)!.hours } : day);
  days.push(...local.filter((day) => day.date > last));
  return recent(days, 'account', upstream.lifetimeTokens);
}

/** 目录下按文件名挑出的文件；目录不存在时为空。 */
async function filesUnder(directory: string, match: (file: string) => boolean): Promise<string[]> {
  try { return (await readdir(directory, { recursive: true })).filter(match).map((file) => join(directory, file)); }
  catch (error) {
    if ((error as NodeJS.ErrnoException).code === 'ENOENT') return [];
    throw error;
  }
}

/** 逐行读 JSONL，只解析含 marker 的行，解析失败的行跳过。 */
async function* jsonLines(file: string, marker: string): AsyncGenerator<unknown> {
  for await (const line of createInterface({ input: createReadStream(file), crlfDelay: Infinity })) {
    if (!line.includes(marker)) continue;
    try { yield JSON.parse(line); } catch {}
  }
}

const claudeUsageLine = z.object({
  type: z.literal('assistant'), timestamp: z.string(), requestId: z.string().optional(),
  message: z.object({ id: z.string(), usage: z.object({
    input_tokens: z.number().finite().default(0), output_tokens: z.number().finite().default(0),
    cache_creation_input_tokens: z.number().finite().nullish(), cache_read_input_tokens: z.number().finite().nullish(),
  }) }),
});

/**
 * 扫这台机器上 Claude Code 的会话记录（Kite 的 Claude 会话也写在这里），按本地时间的小时汇总输入、输出与缓存 token。
 * 同一次响应按内容块分多行写入，各行带同样的用量，按消息 ID 与请求 ID 去重。
 */
export async function scanClaudeUsage(directory: string): Promise<HourlyUsage> {
  const usage: HourlyUsage = new Map();
  const seen = new Set<string>();
  for (const file of await filesUnder(join(directory, 'projects'), (file) => file.endsWith('.jsonl'))) {
    for await (const raw of jsonLines(file, '"usage"')) {
      const parsed = claudeUsageLine.safeParse(raw);
      if (!parsed.success) continue;
      const { message, requestId, timestamp } = parsed.data;
      const key = `${message.id}:${requestId ?? ''}`;
      if (seen.has(key)) continue;
      seen.add(key);
      const tokens = message.usage;
      addTokens(usage, new Date(timestamp), tokens.input_tokens + tokens.output_tokens
        + (tokens.cache_creation_input_tokens ?? 0) + (tokens.cache_read_input_tokens ?? 0));
    }
  }
  return usage;
}

const kiteRequest = z.object({
  type: z.literal('request.completed'), at: z.number(), requestId: z.string(),
  usage: z.object({ input_tokens: z.number().finite(), output_tokens: z.number().finite(), total_tokens: z.number().finite().optional() }),
});
const codexTokenCount = z.object({
  timestamp: z.string(),
  payload: z.object({ type: z.literal('token_count'), info: z.object({
    total_token_usage: z.object({ total_tokens: z.number().finite() }),
    last_token_usage: z.object({ total_tokens: z.number().finite() }),
  }) }),
});

/**
 * 扫这台机器上用 ChatGPT 订阅的会话记录，按本地时间的小时汇总 token：Kite 自研 harness 的线程日志（只接 ChatGPT），
 * 以及 Codex CLI 的会话记录。Codex 在累计用量不变时也会重发用量事件，累计值变了才计；恢复会话时复制过来的旧事件按时间与累计值去重。
 */
export async function scanChatgptUsage(kiteHome: string, codexDirectory: string): Promise<HourlyUsage> {
  const usage: HourlyUsage = new Map();
  const seen = new Set<string>();
  for (const file of await filesUnder(join(kiteHome, 'sessions'), (file) => basename(file) === 'journal.jsonl')) {
    for await (const raw of jsonLines(file, '"request.completed"')) {
      const parsed = kiteRequest.safeParse(raw);
      if (!parsed.success || seen.has(parsed.data.requestId)) continue;
      seen.add(parsed.data.requestId);
      const tokens = parsed.data.usage;
      addTokens(usage, new Date(parsed.data.at), tokens.total_tokens ?? tokens.input_tokens + tokens.output_tokens);
    }
  }
  for (const folder of ['sessions', 'archived_sessions']) {
    for (const file of await filesUnder(join(codexDirectory, folder), (file) => file.endsWith('.jsonl'))) {
      let total = 0;
      for await (const raw of jsonLines(file, '"token_count"')) {
        const parsed = codexTokenCount.safeParse(raw);
        if (!parsed.success) continue;
        const { timestamp, payload: { info } } = parsed.data;
        const key = `${timestamp}:${info.total_token_usage.total_tokens}`;
        if (info.total_token_usage.total_tokens === total || seen.has(key)) continue;
        total = info.total_token_usage.total_tokens;
        seen.add(key);
        addTokens(usage, new Date(timestamp), info.last_token_usage.total_tokens);
      }
    }
  }
  return usage;
}

/**
 * 组织管理凭据可查的按天 token 用量（OpenAI Usage API、Anthropic Usage Report）。按天的桶每页最多 31 个，
 * 一年拆成按月的窗口并行查询；分页不完整就不给结果，不展示残缺的历史。
 */
export async function apiUsage(provider: 'openai' | 'anthropic', get: (url: string) => Promise<Record<string, unknown>>,
  now: number): Promise<AccountUsage> {
  const day = 86_400;
  const end = Math.floor(now / day) * day + day;
  const windows = Array.from({ length: 12 }, (_, index) => end - (index + 1) * 31 * day).map((from) => [from, from + 31 * day] as const);
  const bucket = provider === 'openai'
    ? z.object({ start_time: z.number(), results: z.array(z.object({ input_tokens: z.number().finite().nullish(), output_tokens: z.number().finite().nullish() }).passthrough()) })
    : z.object({ starting_at: z.string(), results: z.array(z.object({ uncached_input_tokens: z.number().finite().nullish(), output_tokens: z.number().finite().nullish(),
      cache_read_input_tokens: z.number().finite().nullish(),
      cache_creation: z.object({ ephemeral_1h_input_tokens: z.number().finite().nullish(), ephemeral_5m_input_tokens: z.number().finite().nullish() }).nullish(),
    }).passthrough()) });
  const page = z.object({ data: z.array(bucket), has_more: z.boolean() });
  const pages = await Promise.all(windows.map(async ([from, to]) => {
    const url = new URL(provider === 'openai' ? 'https://api.openai.com/v1/organization/usage/completions' : 'https://api.anthropic.com/v1/organizations/usage_report/messages');
    if (provider === 'openai') {
      url.searchParams.set('start_time', String(from)); url.searchParams.set('end_time', String(to));
    } else {
      url.searchParams.set('starting_at', new Date(from * 1000).toISOString()); url.searchParams.set('ending_at', new Date(to * 1000).toISOString());
    }
    url.searchParams.set('bucket_width', '1d'); url.searchParams.set('limit', '31');
    const parsed = page.safeParse(await get(url.toString()));
    if (!parsed.success || parsed.data.has_more) throw new Error('用量分页不完整');
    return parsed.data.data;
  }));
  const days = new Map<string, number>();
  for (const item of pages.flat()) {
    const start = 'start_time' in item ? new Date(item.start_time * 1000) : new Date(item.starting_at);
    // 用量桶按 UTC 划分，日期取 UTC，避免跨时区挪到相邻一天。
    const date = start.toISOString().slice(0, 10);
    let tokens = 0;
    // OpenAI 的 input_tokens 已含缓存命中；Anthropic 把未缓存、缓存写入与缓存读取分开给出。
    for (const result of item.results as Array<Record<string, any>>) {
      tokens += (result.input_tokens ?? 0) + (result.uncached_input_tokens ?? 0) + (result.output_tokens ?? 0)
        + (result.cache_read_input_tokens ?? 0) + (result.cache_creation?.ephemeral_1h_input_tokens ?? 0)
        + (result.cache_creation?.ephemeral_5m_input_tokens ?? 0);
    }
    days.set(date, (days.get(date) ?? 0) + tokens);
  }
  return recent([...days].map(([date, tokens]) => ({ date, tokens })), 'account');
}
