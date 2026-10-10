import { expect, test } from 'bun:test';
import { appendFileSync, rmSync } from 'node:fs';
import { join } from 'node:path';
import { localDate, scanChatgptUsage, scanClaudeUsage, type AccountUsage, type HourlyUsage } from '../../src/account-usage.ts';
import { readModelAccounts, type AccountReadOptions } from '../../src/model-accounts.ts';
import { Store } from '../../src/store.ts';
import { useTemp, writeFiles } from '../util.ts';

const temp = useTemp();

/** 本地时区 n 天前的中午，避开时区换日边界。 */
function noon(daysAgo: number): Date {
  const now = new Date();
  return new Date(now.getFullYear(), now.getMonth(), now.getDate() - daysAgo, 12, 0, 0);
}

interface Usage { input: number; output: number; creation?: number; creation1h?: number; read?: number; model?: string; fast?: boolean }
/**
 * 一行 Claude Code 会话记录里的 assistant 消息，形状照 2026-10 的真实记录：cache_creation_input_tokens 是两种缓存写入之和，
 * cache_creation 再分出 1 小时与 5 分钟；speed 为 standard 或 fast。
 */
function assistant(time: Date, message: string, request: string, usage: Usage): string {
  const creation = usage.creation ?? 0;
  const creation1h = usage.creation1h ?? 0;
  return JSON.stringify({ type: 'assistant', timestamp: time.toISOString(), requestId: request, message: {
    id: message, model: usage.model ?? 'claude-sonnet-5', usage: {
      input_tokens: usage.input, cache_creation_input_tokens: creation,
      cache_read_input_tokens: usage.read ?? 0, output_tokens: usage.output,
      cache_creation: { ephemeral_1h_input_tokens: creation1h, ephemeral_5m_input_tokens: creation - creation1h },
      speed: usage.fast ? 'fast' : 'standard',
    },
  } });
}
const lines = (...values: string[]) => values.map((value) => `${value}\n`).join('');
/** 一天 24 个小时的值，只列出非零的小时。 */
const hours = (used: Record<number, number>) => Array.from({ length: 24 }, (_, hour) => used[hour] ?? 0);
/** 美元换成微美元（百万分之一美元）并舍到 0.001，期望金额直接写手算的数，不受浮点累加误差影响。 */
const micro = (dollars: number) => Math.round(dollars * 1e9) / 1000;
const hourlyInMicro = (usage: HourlyUsage) => [...usage].map(([date, day]) => [date, { ...day, cost: day.cost.map(micro) }]);
const accountInMicro = (usage: AccountUsage | undefined) => usage && { ...usage, lifetimeCost: micro(usage.lifetimeCost),
  days: usage.days.map((day) => ({ ...day, cost: micro(day.cost), costHours: day.costHours.map(micro) })) };

// 依赖 Claude Code 会话记录的格式：一次响应按内容块写成多行，每行带同一 message.id、requestId 与相同的 usage；
// 子 agent 的记录写在 projects/<项目>/<会话>/subagents/ 下。重复计数或漏扫子目录都会让用量偏离实际。
// 计价依赖：模型在同一行的 message.model，可能逐行不同；cache_creation.ephemeral_1h_input_tokens 是 1 小时缓存写入，
// 其余缓存写入是 5 分钟；usage.speed 为 fast 时整次按两倍计。
test('扫描 Claude Code 会话记录时同一响应的多行只计一次，子 agent 记录计入，非用量行忽略，金额按每行的模型与缓存写入时长折算', async () => {
  const claude = temp('kite-claude-usage-scan-');
  const day = noon(1);
  const response = assistant(day, 'msg_a', 'req_a', { input: 634, output: 26_576, creation: 100, creation1h: 60, read: 2000 });
  writeFiles(claude, {
    'projects/-Users-me-app/session-1.jsonl': lines(
      JSON.stringify({ type: 'user', timestamp: day.toISOString(), message: { role: 'user', content: '你好' } }),
      response, response, response,
      JSON.stringify({ type: 'assistant', timestamp: day.toISOString(), requestId: 'req_n', message: { id: 'msg_n', model: 'claude-sonnet-5' } }),
    ),
    'projects/-Users-me-other/session-2.jsonl': lines(assistant(day, 'msg_b', 'req_b', { input: 10, output: 20, model: 'claude-opus-5', fast: true })),
    'projects/-Users-me-app/session-1/subagents/agent-1.jsonl': lines(
      assistant(day, 'msg_c', 'req_c', { input: 1, output: 2, read: 3 }),
      assistant(day, 'msg_c', 'req_c', { input: 1, output: 2, read: 3 }),
    ),
  });
  const days = await scanClaudeUsage(claude);
  // 每百万 token 的美元。claude-sonnet-5：输入 2、输出 10、缓存读 0.2、5 分钟写 2.5、1 小时写 4；claude-opus-5：输入 5、输出 25。
  // msg_a：634×2 + 26_576×10 + 2000×0.2 + 40×2.5 + 60×4 = 267_768 微美元
  // msg_b（opus，fast）：(10×5 + 20×25)×2 = 1_100；msg_c：1×2 + 2×10 + 3×0.2 = 22.6
  expect(hourlyInMicro(days)).toEqual([[localDate(day), {
    tokens: hours({ 12: 634 + 26_576 + 100 + 2000 + 10 + 20 + 1 + 2 + 3 }),
    cost: hours({ 12: 268_890.6 }),
    unpriced: hours({}),
  }]]);
}, 1000);

const claudeFetch: NonNullable<AccountReadOptions['fetch']> = async (url) => {
  const { hostname, pathname } = new URL(url);
  if (hostname !== 'api.anthropic.com') throw new Error(`测试禁止访问此地址：${url}`);
  if (pathname === '/api/oauth/usage') return Response.json({ five_hour: { utilization: 20, resets_at: new Date(2_000_000_000_000).toISOString() } });
  if (pathname === '/api/oauth/profile') return Response.json({ account: { email: 'claude@kite.test' } });
  return Response.json({}, { status: 404 });
};
const claudeLogin = async () => ({ accessToken: 'sk-ant-oat01-test', subscriptionType: 'max' });

// Claude Code 约 30 天后清理会话记录；kited 的 sqlite 要留住已清理日子的用量与金额，同时让仍在增长的当天取新值。
// 扫描、Store 合并与 readModelAccounts 输出三处配合，单看任一处都确认不了。
test('Claude Code 清理旧会话记录后，kited 保存的那天用量与金额仍在，新一天的增长照常累加', async () => {
  const home = temp('kite-claude-usage-store-');
  const claude = join(home, 'claude');
  const store = new Store(join(home, 'kite.sqlite'));
  const older = noon(3);
  const newer = noon(1);
  const olderFile = join(claude, 'projects/-Users-me-app/old.jsonl');
  const newerFile = join(claude, 'projects/-Users-me-app/new.jsonl');
  writeFiles(claude, {
    'projects/-Users-me-app/old.jsonl': lines(assistant(older, 'msg_1', 'req_1', { input: 100, output: 200 })),
    'projects/-Users-me-app/new.jsonl': lines(assistant(newer, 'msg_2', 'req_2', { input: 30, output: 40, read: 5 })),
  });
  const read = async () => {
    const snapshot = await readModelAccounts(home, { usage: store, claudeDirectory: claude, codexDirectory: join(home, 'codex'), claudeLogin, fetch: claudeFetch });
    return accountInMicro(snapshot.accounts.find((value) => value.id === 'claude')?.usage);
  };
  // claude-sonnet-5，微美元：msg_1 100×2 + 200×10 = 2200；msg_2 30×2 + 40×10 + 5×0.2 = 461；msg_3 1×2 + 9×10 = 92。
  const olderDay = { date: localDate(older), tokens: 300, hours: hours({ 12: 300 }), cost: 2200, costHours: hours({ 12: 2200 }), unpriced: 0 };
  try {
    expect(await read()).toEqual({ lifetimeTokens: 375, lifetimeCost: 2661, days: [
      olderDay,
      { date: localDate(newer), tokens: 75, hours: hours({ 12: 75 }), cost: 461, costHours: hours({ 12: 461 }), unpriced: 0 },
    ] });
    rmSync(olderFile);
    appendFileSync(newerFile, lines(assistant(newer, 'msg_3', 'req_3', { input: 1, output: 9 })));
    expect(await read()).toEqual({ lifetimeTokens: 385, lifetimeCost: 2753, days: [
      olderDay,
      { date: localDate(newer), tokens: 85, hours: hours({ 12: 85 }), cost: 553, costHours: hours({ 12: 553 }), unpriced: 0 },
    ] });
  } finally { store.close(); }
}, 1000);

/** 本地时区 n 天前 hour 时 minute 分 second 秒。 */
const at = (daysAgo: number, hour: number, minute: number, second = 0) => {
  const day = noon(daysAgo);
  return new Date(day.getFullYear(), day.getMonth(), day.getDate(), hour, minute, second);
};
/** Kite 自研 harness 线程日志里的请求配置快照，形状照 2026-10 的真实记录；同一配置在一个线程里只记一次。 */
function configured(time: Date, seq: number, id: string, model: string): string {
  return JSON.stringify({ version: 1, seq, at: time.getTime(), type: 'request.configured', snapshot: {
    id, settings: { model: { model, reasoning: 'medium' }, contextWindow: 272_000, maxRequestsPerTurn: 100 }, tools: [] } });
}
/** Kite 自研 harness 线程日志里的请求开始，用 configurationId 引用此前记下的配置。 */
function started(time: Date, seq: number, request: string, configuration: string): string {
  return JSON.stringify({ version: 1, seq, at: time.getTime(), type: 'request.started', turnId: 'turn_1', requestId: request,
    inputIds: [], contextId: `ctx_${request}`, configurationId: configuration });
}
/** Kite 自研 harness 线程日志里的一次请求完成，形状照 2026-10 的真实记录；input 含 cached 与 written。 */
function completed(time: Date, seq: number, request: string, usage: { input: number; cached?: number; written?: number; output: number; total?: number }): string {
  return JSON.stringify({ version: 1, seq, at: time.getTime(), type: 'request.completed', turnId: 'turn_1', requestId: request,
    responseId: `resp_${request}`, needsFollowUp: false, usage: {
      input_tokens: usage.input, input_tokens_details: { cached_tokens: usage.cached ?? 0, cache_write_tokens: usage.written ?? 0 },
      output_tokens: usage.output, output_tokens_details: { reasoning_tokens: 0 },
      ...(usage.total === undefined ? {} : { total_tokens: usage.total }),
    } });
}
/** Codex CLI 每轮开头的 turn_context，形状照 2026-10 的真实记录；之后的 token_count 属于这一轮的模型。 */
function turnContext(time: Date, ordinal: number, model: string): string {
  return JSON.stringify({ timestamp: time.toISOString(), ordinal, type: 'turn_context', payload: {
    turn_id: `turn_${ordinal}`, cwd: '/Users/me/app', model, effort: 'medium', summary: 'auto' } });
}
interface CodexUsage { input: number; cached?: number; written?: number; output: number; reasoning?: number }
/**
 * Codex CLI 会话记录里的 token_count 事件，形状照 2026-10 的真实记录；total 为会话累计的 total_tokens，last 为这一次请求：
 * input 含 cached 与 written，output 含 reasoning，total_tokens 是 input 与 output 之和。
 */
function tokenCount(time: Date, ordinal: number, total: number, last: CodexUsage): string {
  const usage = (value: CodexUsage) => ({ input_tokens: value.input, cached_input_tokens: value.cached ?? 0,
    cache_write_input_tokens: value.written ?? 0, output_tokens: value.output, reasoning_output_tokens: value.reasoning ?? 0,
    total_tokens: value.input + value.output });
  return JSON.stringify({ timestamp: time.toISOString(), ordinal, type: 'event_msg', payload: { type: 'token_count',
    info: { total_token_usage: usage({ input: total, output: 0 }), last_token_usage: usage(last), model_context_window: 258_400 },
    rate_limits: { primary: { used_percent: 3, window_minutes: 300 } } } });
}

// 依赖两种本机记录的格式与重发行为：Kite harness 的 journal.jsonl 每次请求写一行 request.completed，usage 可能没有
// total_tokens，同一 requestId 出现多次只算一次；Codex CLI 在累计值不变时也会换个时间重发 token_count，有的 info 为 null，
// 恢复会话时把旧事件连同原时间戳复制进新文件（可能在 archived_sessions 下）。任何一处重复计数或漏计都会让 ChatGPT 的按小时用量偏离实际。
// 计价依赖：journal 的 request.completed 不带模型，模型在 request.configured 的 snapshot.settings.model.model，每个配置只记一次，
// 切回用过的配置时不再重记，request.started 用 configurationId 引用它；Codex 的模型在每轮开头的 turn_context.payload.model。
// 价格表里没有的模型（Codex 自动审查用的 codex-auto-review）只计 token，记为未计价。
test('扫描 ChatGPT 本机记录时重发与恢复会话复制的事件只计一次，用量落在本地时间对应的小时，金额按请求所属的模型折算，表外模型记为未计价', async () => {
  const home = temp('kite-chatgpt-usage-scan-');
  const kite = join(home, 'kite');
  const codex = join(home, 'codex');
  const day = noon(1);
  const solConfiguration = configured(at(1, 12, 4), 2, 'cfg_sol', 'gpt-6.1-sol');
  const solStarted = started(at(1, 12, 4), 3, 'req_a', 'cfg_sol');
  const first = completed(at(1, 12, 5), 4, 'req_a', { input: 5081, cached: 4000, written: 1000, output: 13, total: 5094 });
  writeFiles(kite, {
    'sessions/thread-1/journal.jsonl': lines(
      JSON.stringify({ version: 1, seq: 1, at: at(1, 12, 4).getTime(), type: 'turn.started', turnId: 'turn_1' }),
      solConfiguration, solStarted, first,
      configured(at(1, 12, 6), 5, 'cfg_astra', 'gpt-6-astra'),
      started(at(1, 12, 6), 6, 'req_b', 'cfg_astra'),
      completed(at(1, 12, 6), 7, 'req_b', { input: 100, output: 20 }),
      started(at(1, 12, 7), 8, 'req_c', 'cfg_sol'),
      completed(at(1, 12, 7), 9, 'req_c', { input: 300, cached: 200, output: 10 }),
      first,
    ),
    'sessions/thread-2/journal.jsonl': lines(solConfiguration, solStarted, first),
  });
  const t1 = at(1, 15, 1);
  const t2 = at(1, 15, 2);
  const firstRequest = { input: 28_000, cached: 20_000, output: 879, reasoning: 300 };
  const secondRequest = { input: 900, cached: 800, written: 60, output: 100 };
  writeFiles(codex, {
    'sessions/2026/10/08/rollout-a.jsonl': lines(
      JSON.stringify({ timestamp: at(1, 15, 0).toISOString(), ordinal: 0, type: 'session_meta', payload: { id: 'session-a' } }),
      turnContext(at(1, 15, 0), 1, 'gpt-6-astra'),
      JSON.stringify({ timestamp: at(1, 15, 0).toISOString(), ordinal: 2, type: 'event_msg', payload: { type: 'token_count', info: null } }),
      tokenCount(t1, 20, 28_879, firstRequest),
      tokenCount(at(1, 15, 1, 30), 21, 28_879, firstRequest),
      tokenCount(t2, 29, 29_879, secondRequest),
    ),
    'archived_sessions/rollout-b.jsonl': lines(
      JSON.stringify({ timestamp: at(1, 15, 3).toISOString(), ordinal: 0, type: 'session_meta', payload: { id: 'session-b' } }),
      turnContext(at(1, 15, 0), 1, 'gpt-6-astra'),
      tokenCount(t2, 2, 29_879, secondRequest),
      turnContext(at(1, 15, 3, 30), 8, 'gpt-6-astra'),
      tokenCount(at(1, 15, 4), 9, 30_379, { input: 400, output: 100 }),
    ),
    'sessions/2026/10/08/rollout-c.jsonl': lines(
      JSON.stringify({ timestamp: at(1, 16, 0).toISOString(), ordinal: 0, type: 'session_meta', payload: { id: 'session-c' } }),
      turnContext(at(1, 16, 0), 1, 'codex-auto-review'),
      tokenCount(at(1, 16, 1), 4, 2034, { input: 2000, cached: 1500, output: 34 }),
    ),
  });
  const usage = await scanChatgptUsage(kite, codex);
  // 每百万 token 的美元。gpt-6.1-sol：输入 2、缓存读 0.1、缓存写 2.5、输出 10；gpt-6-astra：输入 10、缓存读 1、缓存写 12.5、输出 50。
  // 12 时（微美元）：req_a（sol）81×2 + 4000×0.1 + 1000×2.5 + 13×10 = 3192；req_b（astra）100×10 + 20×50 = 2000；
  //   req_c（切回 sol）100×2 + 200×0.1 + 10×10 = 320。
  // 15 时（astra）：8000×10 + 20_000×1 + 879×50 = 143_950；40×10 + 800×1 + 60×12.5 + 100×50 = 6950；400×10 + 100×50 = 9000。
  expect(hourlyInMicro(usage)).toEqual([[localDate(day), {
    tokens: hours({ 12: 5094 + 120 + 310, 15: 28_879 + 1000 + 500, 16: 2034 }),
    cost: hours({ 12: 3192 + 2000 + 320, 15: 143_950 + 6950 + 9000 }),
    unpriced: hours({ 16: 2034 }),
  }]]);
}, 1000);
