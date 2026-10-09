import { expect, test } from 'bun:test';
import { appendFileSync, rmSync } from 'node:fs';
import { join } from 'node:path';
import { localDate, scanChatgptUsage, scanClaudeUsage } from '../../src/account-usage.ts';
import { readModelAccounts, type AccountReadOptions } from '../../src/model-accounts.ts';
import { Store } from '../../src/store.ts';
import { useTemp, writeFiles } from '../util.ts';

const temp = useTemp();

/** 本地时区 n 天前的中午，避开时区换日边界。 */
function noon(daysAgo: number): Date {
  const now = new Date();
  return new Date(now.getFullYear(), now.getMonth(), now.getDate() - daysAgo, 12, 0, 0);
}

interface Usage { input: number; output: number; creation?: number; read?: number }
/** 一行 Claude Code 会话记录里的 assistant 消息，形状照 2026-10 的真实记录。 */
function assistant(time: Date, message: string, request: string, usage: Usage): string {
  return JSON.stringify({ type: 'assistant', timestamp: time.toISOString(), requestId: request, message: {
    id: message, model: 'claude-sonnet-5', usage: {
      input_tokens: usage.input, cache_creation_input_tokens: usage.creation ?? 0,
      cache_read_input_tokens: usage.read ?? 0, output_tokens: usage.output,
    },
  } });
}
const lines = (...values: string[]) => values.map((value) => `${value}\n`).join('');
/** 一天 24 个小时的 token，只列出有用量的小时。 */
const hours = (used: Record<number, number>) => Array.from({ length: 24 }, (_, hour) => used[hour] ?? 0);

// 依赖 Claude Code 会话记录的格式：一次响应按内容块写成多行，每行带同一 message.id、requestId 与相同的 usage；
// 子 agent 的记录写在 projects/<项目>/<会话>/subagents/ 下。重复计数或漏扫子目录都会让用量偏离实际。
test('扫描 Claude Code 会话记录时同一响应的多行只计一次，子 agent 记录计入，非用量行忽略', async () => {
  const claude = temp('kite-claude-usage-scan-');
  const day = noon(1);
  const response = assistant(day, 'msg_a', 'req_a', { input: 634, output: 26_576, creation: 100, read: 2000 });
  writeFiles(claude, {
    'projects/-Users-me-app/session-1.jsonl': lines(
      JSON.stringify({ type: 'user', timestamp: day.toISOString(), message: { role: 'user', content: '你好' } }),
      response, response, response,
      JSON.stringify({ type: 'assistant', timestamp: day.toISOString(), requestId: 'req_n', message: { id: 'msg_n', model: 'claude-sonnet-5' } }),
    ),
    'projects/-Users-me-other/session-2.jsonl': lines(assistant(day, 'msg_b', 'req_b', { input: 10, output: 20 })),
    'projects/-Users-me-app/session-1/subagents/agent-1.jsonl': lines(
      assistant(day, 'msg_c', 'req_c', { input: 1, output: 2, read: 3 }),
      assistant(day, 'msg_c', 'req_c', { input: 1, output: 2, read: 3 }),
    ),
  });
  const days = await scanClaudeUsage(claude);
  expect([...days]).toEqual([[localDate(day), hours({ 12: 634 + 26_576 + 100 + 2000 + 10 + 20 + 1 + 2 + 3 })]]);
}, 1000);

const claudeFetch: NonNullable<AccountReadOptions['fetch']> = async (url) => {
  const { hostname, pathname } = new URL(url);
  if (hostname !== 'api.anthropic.com') throw new Error(`测试禁止访问此地址：${url}`);
  if (pathname === '/api/oauth/usage') return Response.json({ five_hour: { utilization: 20, resets_at: new Date(2_000_000_000_000).toISOString() } });
  if (pathname === '/api/oauth/profile') return Response.json({ account: { email: 'claude@kite.test' } });
  return Response.json({}, { status: 404 });
};
const claudeLogin = async () => ({ accessToken: 'sk-ant-oat01-test', subscriptionType: 'max' });

// Claude Code 约 30 天后清理会话记录；kited 的 sqlite 要留住已清理日子的用量，同时让仍在增长的当天取新值。
// 扫描、Store 合并与 readModelAccounts 输出三处配合，单看任一处都确认不了。
test('Claude Code 清理旧会话记录后，kited 保存的那天用量仍在，新一天的增长照常累加', async () => {
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
    const snapshot = await readModelAccounts(home, { usage: store, claudeDirectory: claude, claudeLogin, fetch: claudeFetch });
    return snapshot.accounts.find((value) => value.id === 'claude')?.usage;
  };
  try {
    expect(await read()).toEqual({ scope: 'machine', lifetimeTokens: 375, days: [
      { date: localDate(older), tokens: 300, hours: hours({ 12: 300 }) },
      { date: localDate(newer), tokens: 75, hours: hours({ 12: 75 }) },
    ] });
    rmSync(olderFile);
    appendFileSync(newerFile, lines(assistant(newer, 'msg_3', 'req_3', { input: 1, output: 9 })));
    expect(await read()).toEqual({ scope: 'machine', lifetimeTokens: 385, days: [
      { date: localDate(older), tokens: 300, hours: hours({ 12: 300 }) },
      { date: localDate(newer), tokens: 85, hours: hours({ 12: 85 }) },
    ] });
  } finally { store.close(); }
}, 1000);

/** 本地时区 n 天前 hour 时 minute 分 second 秒。 */
const at = (daysAgo: number, hour: number, minute: number, second = 0) => {
  const day = noon(daysAgo);
  return new Date(day.getFullYear(), day.getMonth(), day.getDate(), hour, minute, second);
};
/** Kite 自研 harness 线程日志里的一次请求完成，形状照 2026-10 的真实记录。 */
function completed(time: Date, seq: number, request: string, usage: { input: number; output: number; total?: number }): string {
  return JSON.stringify({ version: 1, seq, at: time.getTime(), type: 'request.completed', turnId: 'turn_1', requestId: request,
    responseId: `resp_${request}`, needsFollowUp: false, usage: {
      input_tokens: usage.input, input_tokens_details: { cached_tokens: 0, cache_write_tokens: 0 },
      output_tokens: usage.output, output_tokens_details: { reasoning_tokens: 0 },
      ...(usage.total === undefined ? {} : { total_tokens: usage.total }),
    } });
}
/** Codex CLI 会话记录里的 token_count 事件，形状照 2026-10 的真实记录；total 为会话累计，last 为这一次请求。 */
function tokenCount(time: Date, ordinal: number, total: number, last: number): string {
  const usage = (tokens: number) => ({ input_tokens: tokens, cached_input_tokens: 0, cache_write_input_tokens: 0,
    output_tokens: 0, reasoning_output_tokens: 0, total_tokens: tokens });
  return JSON.stringify({ timestamp: time.toISOString(), ordinal, type: 'event_msg', payload: { type: 'token_count',
    info: { total_token_usage: usage(total), last_token_usage: usage(last), model_context_window: 258_400 },
    rate_limits: { primary: { used_percent: 3, window_minutes: 300 } } } });
}

// 依赖两种本机记录的格式与重发行为：Kite harness 的 journal.jsonl 每次请求写一行 request.completed，usage 可能没有
// total_tokens，同一 requestId 出现多次只算一次；Codex CLI 在累计值不变时也会换个时间重发 token_count，有的 info 为 null，
// 恢复会话时把旧事件连同原时间戳复制进新文件（可能在 archived_sessions 下）。任何一处重复计数或漏计都会让 ChatGPT 的按小时用量偏离实际。
test('扫描 ChatGPT 本机记录时重发与恢复会话复制的事件只计一次，用量落在本地时间对应的小时', async () => {
  const home = temp('kite-chatgpt-usage-scan-');
  const kite = join(home, 'kite');
  const codex = join(home, 'codex');
  const day = noon(1);
  const first = completed(at(1, 12, 5), 3, 'req_a', { input: 5081, output: 13, total: 5094 });
  writeFiles(kite, {
    'sessions/thread-1/journal.jsonl': lines(
      JSON.stringify({ version: 1, seq: 1, at: at(1, 12, 4).getTime(), type: 'turn.started', turnId: 'turn_1' }),
      first,
      completed(at(1, 12, 6), 5, 'req_b', { input: 100, output: 20 }),
      first,
    ),
    'sessions/thread-2/journal.jsonl': lines(first),
  });
  const t1 = at(1, 15, 1);
  const t2 = at(1, 15, 2);
  writeFiles(codex, {
    'sessions/2026/10/08/rollout-a.jsonl': lines(
      JSON.stringify({ timestamp: at(1, 15, 0).toISOString(), ordinal: 0, type: 'session_meta', payload: { id: 'session-a' } }),
      JSON.stringify({ timestamp: at(1, 15, 0).toISOString(), ordinal: 1, type: 'event_msg', payload: { type: 'token_count', info: null } }),
      tokenCount(t1, 20, 28_879, 28_879),
      tokenCount(at(1, 15, 1, 30), 21, 28_879, 28_879),
      tokenCount(t2, 29, 29_879, 1000),
    ),
    'archived_sessions/rollout-b.jsonl': lines(
      JSON.stringify({ timestamp: at(1, 15, 3).toISOString(), ordinal: 0, type: 'session_meta', payload: { id: 'session-b' } }),
      tokenCount(t2, 1, 29_879, 1000),
      tokenCount(at(1, 15, 4), 9, 30_379, 500),
    ),
  });
  const usage = await scanChatgptUsage(kite, codex);
  expect([...usage]).toEqual([[localDate(day), hours({ 12: 5094 + 120, 15: 28_879 + 1000 + 500 })]]);
}, 1000);
