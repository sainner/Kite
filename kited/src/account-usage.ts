/**
 * 账号在这台工作机上的 token 用量：kited 扫描本机会话记录按小时汇总保存，按天由按小时相加，
 * 不读上游统计，不受本地记录保留期限制。每次请求按价格表折算成美元一起保存。
 */
import { createReadStream } from 'node:fs';
import { readdir } from 'node:fs/promises';
import { basename, join } from 'node:path';
import { createInterface } from 'node:readline';
import { z } from 'zod';
import { requestCost, type RequestTokens } from './token-prices.ts';

export interface UsageDay {
  date: string;
  tokens: number;
  /** 本地时间 0–23 时每小时的 token。 */
  hours: number[];
  /** 按价格表折算的美元，不含未计价的 token。 */
  cost: number;
  /** 本地时间 0–23 时每小时折算的美元。 */
  costHours: number[];
  /** 价格表里没有对应模型的 token，已计入 tokens。 */
  unpriced: number;
}

/** 按本地日期分组，每天 24 个小时的 token、折算的美元与未计价的 token。 */
export type HourlyUsage = Map<string, { tokens: number[]; cost: number[]; unpriced: number[] }>;

export interface AccountUsage {
  /** 最近 53 周里有用量的日期，升序；日期为 YYYY-MM-DD。 */
  days: UsageDay[];
  lifetimeTokens: number;
  lifetimeCost: number;
}

/**
 * kited 自己保存的按小时汇总。同一小时取 token 较多的那次扫描：本地记录只增不减，被清理后重扫得到的较小值不覆盖已存的数；
 * token 相同时取这次的金额，价格表更新后仍在本地的记录按新价格重算。
 */
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

/** cost 为 undefined 表示这次请求的模型不在价格表里。 */
function addTokens(usage: HourlyUsage, time: Date, tokens: number, cost: number | undefined): void {
  if (Number.isNaN(time.getTime()) || tokens <= 0) return;
  const date = localDate(time);
  const day = usage.get(date) ?? { tokens: Array<number>(24).fill(0), cost: Array<number>(24).fill(0), unpriced: Array<number>(24).fill(0) };
  const hour = time.getHours();
  day.tokens[hour]! += tokens;
  if (cost === undefined) day.unpriced[hour]! += tokens;
  else day.cost[hour]! += cost;
  usage.set(date, day);
}

/** OpenAI 的输入 token 含缓存命中与缓存写入，计价时拆开。 */
const openaiTokens = (input: number, cached: number, written: number, output: number): RequestTokens =>
  ({ input: Math.max(0, input - cached - written), cacheRead: cached, cacheWrite: written, output });

/** kited 保存的各天里最近 53 周的部分；累计取保存的全部日子。没有记录时为 undefined。 */
export function localUsage(days: UsageDay[]): AccountUsage | undefined {
  if (!days.length) return undefined;
  const since = localDate(new Date(Date.now() - historyDays * 86_400_000));
  return { lifetimeTokens: days.reduce((sum, day) => sum + day.tokens, 0), lifetimeCost: days.reduce((sum, day) => sum + day.cost, 0),
    days: days.filter((day) => day.date > since) };
}

/** 目录下按文件名挑出的文件；目录不存在时为空。 */
async function filesUnder(directory: string, match: (file: string) => boolean): Promise<string[]> {
  try { return (await readdir(directory, { recursive: true })).filter(match).map((file) => join(directory, file)); }
  catch (error) {
    if ((error as NodeJS.ErrnoException).code === 'ENOENT') return [];
    throw error;
  }
}

/** 逐行读 JSONL，只解析含任一 marker 的行，解析失败的行跳过。 */
async function* jsonLines(file: string, ...markers: string[]): AsyncGenerator<unknown> {
  for await (const line of createInterface({ input: createReadStream(file), crlfDelay: Infinity })) {
    if (!markers.some((marker) => line.includes(marker))) continue;
    try { yield JSON.parse(line); } catch {}
  }
}

const claudeUsageLine = z.object({
  type: z.literal('assistant'), timestamp: z.string(), requestId: z.string().optional(),
  message: z.object({ id: z.string(), model: z.string().optional(), usage: z.object({
    input_tokens: z.number().finite().default(0), output_tokens: z.number().finite().default(0),
    cache_creation_input_tokens: z.number().finite().nullish(), cache_read_input_tokens: z.number().finite().nullish(),
    cache_creation: z.object({ ephemeral_1h_input_tokens: z.number().finite().nullish() }).nullish(),
    speed: z.string().nullish(),
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
      const written = tokens.cache_creation_input_tokens ?? 0, read = tokens.cache_read_input_tokens ?? 0;
      // 缓存写入分 5 分钟和 1 小时两种，单价不同；没有细分时按 5 分钟计。
      const written1h = tokens.cache_creation?.ephemeral_1h_input_tokens ?? 0;
      addTokens(usage, new Date(timestamp), tokens.input_tokens + tokens.output_tokens + written + read,
        requestCost(message.model, { input: tokens.input_tokens, cacheRead: read, cacheWrite: Math.max(0, written - written1h),
          cacheWrite1h: written1h, output: tokens.output_tokens, fast: tokens.speed === 'fast' }));
    }
  }
  return usage;
}

/** 请求所用的模型在请求配置里：配置只在第一次用到时记一行，请求开始时引用它的 ID。 */
const kiteRecord = z.discriminatedUnion('type', [
  z.object({ type: z.literal('request.configured'), snapshot: z.object({ id: z.string(), settings: z.object({ model: z.object({ model: z.string() }) }) }) }),
  z.object({ type: z.literal('request.started'), requestId: z.string(), configurationId: z.string() }),
  z.object({ type: z.literal('request.completed'), at: z.number(), requestId: z.string(), usage: z.object({
    input_tokens: z.number().finite(), output_tokens: z.number().finite(), total_tokens: z.number().finite().optional(),
    input_tokens_details: z.object({ cached_tokens: z.number().finite().nullish(), cache_write_tokens: z.number().finite().nullish() }).nullish(),
  }) }),
]);
/** 模型写在每一轮开头的 turn_context 里，之后的用量事件都按它计价。 */
const codexRecord = z.union([
  z.object({ type: z.literal('turn_context'), payload: z.object({ model: z.string() }) }),
  z.object({ timestamp: z.string(), payload: z.object({ type: z.literal('token_count'), info: z.object({
    total_token_usage: z.object({ total_tokens: z.number().finite() }),
    last_token_usage: z.object({ input_tokens: z.number().finite(), cached_input_tokens: z.number().finite().nullish(),
      cache_write_input_tokens: z.number().finite().nullish(), output_tokens: z.number().finite(), total_tokens: z.number().finite() }),
  }) }) }),
]);

/**
 * 扫这台机器上用 ChatGPT 订阅的会话记录，按本地时间的小时汇总 token：Kite 自研 harness 的线程日志（只接 ChatGPT），
 * 以及 Codex CLI 的会话记录。Codex 在累计用量不变时也会重发用量事件，累计值变了才计；恢复会话时复制过来的旧事件按时间与累计值去重。
 */
export async function scanChatgptUsage(kiteHome: string, codexDirectory: string): Promise<HourlyUsage> {
  const usage: HourlyUsage = new Map();
  const seen = new Set<string>();
  for (const file of await filesUnder(join(kiteHome, 'sessions'), (file) => basename(file) === 'journal.jsonl')) {
    const configurations = new Map<string, string>(), requests = new Map<string, string>();
    for await (const raw of jsonLines(file, '"request.configured"', '"request.started"', '"request.completed"')) {
      const parsed = kiteRecord.safeParse(raw);
      if (!parsed.success) continue;
      const record = parsed.data;
      if (record.type === 'request.configured') configurations.set(record.snapshot.id, record.snapshot.settings.model.model);
      else if (record.type === 'request.started') {
        const model = configurations.get(record.configurationId);
        if (model) requests.set(record.requestId, model);
      } else if (!seen.has(record.requestId)) {
        seen.add(record.requestId);
        const tokens = record.usage, details = tokens.input_tokens_details;
        addTokens(usage, new Date(record.at), tokens.total_tokens ?? tokens.input_tokens + tokens.output_tokens,
          requestCost(requests.get(record.requestId), openaiTokens(tokens.input_tokens, details?.cached_tokens ?? 0,
            details?.cache_write_tokens ?? 0, tokens.output_tokens)));
      }
    }
  }
  for (const folder of ['sessions', 'archived_sessions']) {
    for (const file of await filesUnder(join(codexDirectory, folder), (file) => file.endsWith('.jsonl'))) {
      let total = 0;
      let model: string | undefined;
      for await (const raw of jsonLines(file, '"turn_context"', '"token_count"')) {
        const parsed = codexRecord.safeParse(raw);
        if (!parsed.success) continue;
        if ('type' in parsed.data) { model = parsed.data.payload.model; continue; }
        const { timestamp, payload: { info } } = parsed.data;
        const key = `${timestamp}:${info.total_token_usage.total_tokens}`;
        if (info.total_token_usage.total_tokens === total || seen.has(key)) continue;
        total = info.total_token_usage.total_tokens;
        seen.add(key);
        const last = info.last_token_usage;
        addTokens(usage, new Date(timestamp), last.total_tokens, requestCost(model, openaiTokens(last.input_tokens,
          last.cached_input_tokens ?? 0, last.cache_write_input_tokens ?? 0, last.output_tokens)));
      }
    }
  }
  return usage;
}
