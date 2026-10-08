/** 工作机只读账号与额度；凭据留在所属机器，返回值不包含令牌或密钥。 */
import { readFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { homedir, userInfo } from 'node:os';
import { join } from 'node:path';
import { z } from 'zod';
import { parseSubscriptionCredentials } from './harness/auth.ts';

export interface AccountQuota {
  id: string;
  label: string;
  remainingPercent: number;
  windowMinutes?: number;
  /** Unix 秒。 */
  resetsAt?: number;
}

export interface ModelAccount {
  id: string;
  provider: string;
  kind: 'subscription' | 'api';
  status: 'ready' | 'unconfigured' | 'reauthentication' | 'unavailable';
  identity?: string;
  plan?: string;
  message?: string;
  quotas: AccountQuota[];
  credits?: { value?: number; unlimited: boolean };
  cost?: { value: number; currency: string; from: number; to: number };
  balances?: Array<{ currency: string; total: number; granted: number; toppedUp: number }>;
}

export interface ModelAccountsSnapshot { checkedAt: number; accounts: ModelAccount[] }
export interface ClaudeLogin { accessToken: string; subscriptionType?: string }
export interface AccountReadOptions {
  fetch?: (url: string, init: RequestInit) => Promise<Response>;
  claudeLogin?: () => Promise<ClaudeLogin | undefined>;
}

const object = z.record(z.string(), z.unknown());
const text = (value: unknown): string | undefined => typeof value === 'string' && value.length > 0 ? value : undefined;
const number = (value: unknown): number | undefined => typeof value === 'number' && Number.isFinite(value) ? value : undefined;
const record = (value: unknown): Record<string, unknown> => object.safeParse(value).data ?? {};
const remaining = (used: number) => Math.max(0, Math.min(100, 100 - used));
const chatgptWindow = z.object({ used_percent: z.number().finite(),
  limit_window_seconds: z.number().positive().nullish(), reset_at: z.number().finite().nullish() });
const chatgptLimit = z.object({ primary_window: chatgptWindow.nullish(), secondary_window: chatgptWindow.nullish() });
const chatgptUsage = z.object({ rate_limit: chatgptLimit.nullish(),
  additional_rate_limits: z.array(z.object({ metered_feature: z.string().min(1), limit_name: z.string(), rate_limit: chatgptLimit.nullish() })).nullish(),
  credits: z.object({ has_credits: z.boolean(), unlimited: z.boolean(), balance: z.union([z.string(), z.number().finite()]).nullish() }).nullish(),
}).refine((value) => 'rate_limit' in value || 'credits' in value);
const claudeWindow = z.object({ utilization: z.number().finite(),
  resets_at: z.string().refine((value) => Number.isFinite(Date.parse(value))).nullish() });
const claudeUsage = z.object({ five_hour: claudeWindow.nullish(), seven_day: claudeWindow.nullish(),
  seven_day_opus: claudeWindow.nullish(), seven_day_sonnet: claudeWindow.nullish(),
}).refine((value) => Object.keys(value).length > 0);

class AccountReadError extends Error {
  constructor(message: string, readonly status: ModelAccount['status'] = 'unavailable') { super(message); }
}

function jwtClaims(token: unknown): Record<string, unknown> {
  try { return record(JSON.parse(Buffer.from(String(token).split('.')[1] ?? '', 'base64url').toString())); }
  catch { return {}; }
}

async function optionalJSON(path: string): Promise<Record<string, unknown> | undefined> {
  try { return object.parse(JSON.parse(await readFile(path, 'utf8'))); }
  catch (error) {
    if ((error as NodeJS.ErrnoException).code === 'ENOENT') return undefined;
    throw new AccountReadError('登录信息无法读取，请在工作机重新登录。', 'reauthentication');
  }
}

/** 对齐固定版本 Claude SDK 的原生存储规则，不读取其他配置目录的登录。 */
export async function readClaudeLogin(): Promise<ClaudeLogin | undefined> {
  if (process.env.CLAUDE_CODE_OAUTH_TOKEN) return { accessToken: process.env.CLAUDE_CODE_OAUTH_TOKEN };
  const directory = process.env.CLAUDE_CONFIG_DIR ?? join(homedir(), '.claude');
  let stored: Record<string, unknown> | undefined;
  if (process.platform === 'darwin') {
    const configured = process.env.CLAUDE_SECURESTORAGE_CONFIG_DIR ?? process.env.CLAUDE_CONFIG_DIR;
    const suffix = configured ? `-${createHash('sha256').update(configured.normalize('NFC')).digest('hex').slice(0, 8)}` : '';
    const username = process.env.USER || userInfo().username;
    const child = Bun.spawn(['/usr/bin/security', 'find-generic-password', '-a', /^[a-zA-Z0-9._-]+$/.test(username) ? username : 'claude-code-user',
      '-w', '-s', `Claude Code-credentials${suffix}`], { env: process.env, stdout: 'pipe', stderr: 'ignore' });
    const timeout = setTimeout(() => child.kill(), 5_000);
    try {
      const output = await new Response(child.stdout).text();
      const code = await child.exited;
      if (code === 0) stored = object.parse(JSON.parse(output));
      else if (code !== 44) throw new AccountReadError('无法读取 Claude 登录，请在工作机解锁钥匙串后重试。');
    } finally { clearTimeout(timeout); }
  }
  stored ??= await optionalJSON(join(directory, '.credentials.json'));
  const oauth = record(stored?.claudeAiOauth);
  const accessToken = text(oauth.accessToken);
  return accessToken ? { accessToken, subscriptionType: text(oauth.subscriptionType) } : undefined;
}

export async function readModelAccounts(home: string, options: AccountReadOptions = {}): Promise<ModelAccountsSnapshot> {
  const transport = options.fetch ?? fetch;
  const checkedAt = Math.floor(Date.now() / 1_000);
  // 整轮有同一个截止时间，包括费用分页；一个提供方失败不影响其他账号。
  const signal = AbortSignal.timeout(12_000);
  async function get(url: string, headers: Record<string, string>) {
    const response = await transport(url, { headers, signal, redirect: 'error' });
    if (!response.ok) {
      if (response.status === 401) throw new AccountReadError('登录已失效，请在工作机重新授权。', 'reauthentication');
      if (response.status === 403) throw new AccountReadError('当前凭据没有查询权限。');
      if (response.status === 429) throw new AccountReadError('查询过于频繁，请稍后刷新。');
      throw new AccountReadError(`服务暂时不可用（${response.status}）。`);
    }
    const parsed = object.safeParse(await response.json());
    if (!parsed.success) throw new AccountReadError('服务返回的额度格式无法识别。');
    return parsed.data;
  }
  async function read(id: string, provider: string, kind: ModelAccount['kind'], load: (account: ModelAccount) => Promise<void>) {
    const account: ModelAccount = { id, provider, kind, status: 'unconfigured', quotas: [] };
    try { await load(account); }
    catch (error) {
      account.status = error instanceof AccountReadError ? error.status : 'unavailable';
      account.message = error instanceof AccountReadError ? error.message : '暂时无法查询，请稍后刷新。';
      account.quotas = [];
      delete account.cost;
      delete account.credits;
      delete account.balances;
    }
    return account;
  }
  const accounts = await Promise.all([
    read('chatgpt', 'ChatGPT', 'subscription', async (account) => {
      const path = join(home, 'auth', 'chatgpt', 'auth.json');
      const login = await optionalJSON(path);
      if (!login) return;
      const tokens = record(login.tokens);
      const claims = jwtClaims(tokens.id_token ?? tokens.access_token);
      account.identity = text(claims.email) ?? text(record(claims['https://api.openai.com/profile']).email);
      account.plan = text(record(claims['https://api.openai.com/auth']).chatgpt_plan_type);
      let credentials;
      try { credentials = parseSubscriptionCredentials(login); }
      catch { throw new AccountReadError('ChatGPT 登录已失效，请在工作机的 Kite 认证目录重新登录。', 'reauthentication'); }
      const data = await get('https://chatgpt.com/backend-api/wham/usage', {
        authorization: `Bearer ${credentials.accessToken}`, 'ChatGPT-Account-Id': credentials.accountId,
      });
      const parsed = chatgptUsage.safeParse(data);
      if (!parsed.success) throw new AccountReadError('服务返回的订阅额度格式无法识别。');
      account.identity ??= credentials.accountId;
      account.plan = text(data.plan_type) ?? account.plan;
      const buckets = [{ id: 'codex', label: '', limit: parsed.data.rate_limit },
        ...(parsed.data.additional_rate_limits ?? []).map((value) => ({
          id: value.metered_feature, label: value.limit_name, limit: value.rate_limit,
        }))];
      for (const bucket of buckets) {
        for (const key of ['primary_window', 'secondary_window'] as const) {
          const window = bucket.limit?.[key];
          if (!window) continue;
          const minutes = window.limit_window_seconds == null ? undefined : window.limit_window_seconds / 60;
          const period = minutes === undefined ? (key === 'primary_window' ? '主要额度' : '次要额度')
            : minutes === 10080 ? '每周' : minutes >= 60 ? `${minutes / 60} 小时` : `${minutes} 分钟`;
          account.quotas.push({ id: `${bucket.id}:${key}`, label: [bucket.label, period].filter(Boolean).join(' · '),
            remainingPercent: remaining(window.used_percent), windowMinutes: minutes, resetsAt: window.reset_at ?? undefined });
        }
      }
      const credits = parsed.data.credits;
      if (credits && (credits.has_credits || credits.unlimited)) {
        const balance = typeof credits.balance === 'string' && credits.balance.trim() ? Number(credits.balance) : number(credits.balance);
        account.credits = { unlimited: credits.unlimited,
          ...(balance !== undefined && Number.isFinite(balance) ? { value: balance } : {}) };
      }
      account.status = 'ready';
      if (!account.quotas.length && !account.credits) account.message = '服务未返回可查询的额度。';
    }),
    read('claude', 'Claude', 'subscription', async (account) => {
      const login = await (options.claudeLogin ?? readClaudeLogin)();
      if (!login) return;
      account.plan = login.subscriptionType;
      const headers = { authorization: `Bearer ${login.accessToken}`, 'anthropic-beta': 'oauth-2025-04-20' };
      // 身份接口的失败不抹掉成功取得的额度。
      const [usage, profile] = await Promise.all([
        get('https://api.anthropic.com/api/oauth/usage', headers),
        get('https://api.anthropic.com/api/oauth/profile', headers).catch(() => undefined),
      ]);
      const parsed = claudeUsage.safeParse(usage);
      if (!parsed.success) throw new AccountReadError('服务返回的订阅额度格式无法识别。');
      account.identity = text(record(profile?.account).email);
      const windows: Array<[keyof z.infer<typeof claudeUsage>, string, number]> = [
        ['five_hour', '5 小时', 300], ['seven_day', '每周', 10080],
        ['seven_day_opus', 'Opus · 每周', 10080], ['seven_day_sonnet', 'Sonnet · 每周', 10080],
      ];
      for (const [key, label, windowMinutes] of windows) {
        const window = parsed.data[key];
        if (!window) continue;
        account.quotas.push({ id: key, label, remainingPercent: remaining(window.utilization), windowMinutes,
          ...(window.resets_at != null ? { resetsAt: Date.parse(window.resets_at) / 1000 } : {}) });
      }
      account.status = 'ready';
      if (!account.quotas.length) account.message = '服务未返回可查询的订阅额度。';
    }),
    read('deepseek-api', 'DeepSeek', 'api', async (account) => {
      const key = process.env.DEEPSEEK_API_KEY;
      if (!key) return;
      account.identity = '工作机 API Key';
      const data = await get('https://api.deepseek.com/user/balance', { authorization: `Bearer ${key}` });
      const decimal = z.string().regex(/^-?\d+(\.\d+)?$/).transform(Number).pipe(z.number().finite());
      const parsed = z.object({
        is_available: z.boolean(),
        balance_infos: z.array(z.object({ currency: z.enum(['CNY', 'USD']),
          total_balance: decimal, granted_balance: decimal, topped_up_balance: decimal })).min(1),
      }).safeParse(data);
      if (!parsed.success) throw new AccountReadError('服务返回的余额格式无法识别。');
      account.balances = parsed.data.balance_infos.map((balance) => ({ currency: balance.currency,
        total: balance.total_balance, granted: balance.granted_balance, toppedUp: balance.topped_up_balance }));
      account.status = 'ready';
      if (!parsed.data.is_available) account.message = '当前余额不足以调用 API。';
    }),
    ...(['openai', 'anthropic'] as const).map((provider) => read(`${provider}-api`, provider === 'openai' ? 'OpenAI' : 'Anthropic', 'api', async (account) => {
      const prefix = provider.toUpperCase();
      const key = process.env[`${prefix}_API_KEY`];
      const admin = process.env[`${prefix}_ADMIN_KEY`];
      if (!key && !admin) return;
      account.identity = admin ? '组织管理凭据' : '工作机 API Key';
      account.status = 'ready';
      account.message = '供应商未提供此凭据可查询的余额。';
      if (!admin) {
        account.message = '已配置 API Key；查询组织费用需要管理凭据，余额暂不可查询。';
        return;
      }
      // 组织费用不是余额，也不等于某个 API Key 的费用；完整取完分页才展示合计。
      const today = new Date(checkedAt * 1000);
      const from = Date.UTC(today.getUTCFullYear(), today.getUTCMonth(), 1) / 1000;
      const url = new URL(provider === 'openai' ? 'https://api.openai.com/v1/organization/costs' : 'https://api.anthropic.com/v1/organizations/cost_report');
      if (provider === 'openai') {
        url.searchParams.set('start_time', String(from)); url.searchParams.set('end_time', String(checkedAt));
      } else {
        url.searchParams.set('starting_at', new Date(from * 1000).toISOString());
        url.searchParams.set('ending_at', today.toISOString());
      }
      url.searchParams.set('limit', '31');
      const headers: Record<string, string> = provider === 'openai' ? { authorization: `Bearer ${admin}` }
        : { 'x-api-key': admin, 'anthropic-version': '2023-06-01' };
      const pages = new Set<string>();
      let value = 0;
      while (true) {
        const data = await get(url.toString(), headers);
        if (!Array.isArray(data.data)) throw new AccountReadError('服务返回的费用格式无法识别。');
        for (const raw of data.data) {
          const bucket = record(raw);
          if (!Array.isArray(bucket.results)) throw new AccountReadError('服务返回的费用格式无法识别。');
          for (const rawResult of bucket.results) {
            const result = record(rawResult);
            const amount = provider === 'openai' ? record(result.amount) : result;
            const cost = provider === 'openai' ? number(amount.value)
              : typeof amount.amount === 'string' && amount.amount.trim() ? Number(amount.amount) / 100 : undefined;
            if (cost === undefined || !Number.isFinite(cost) || text(amount.currency)?.toLowerCase() !== 'usd') {
              throw new AccountReadError('服务返回的费用金额或币种无法识别。');
            }
            value += cost;
          }
        }
        if (data.has_more === false) break;
        const next = text(data.next_page);
        if (!next || pages.has(next) || pages.size >= 31) throw new AccountReadError('费用分页不完整，请稍后刷新。');
        pages.add(next); url.searchParams.set('page', next);
      }
      account.cost = { value, currency: 'USD', from, to: checkedAt };
    })),
  ]);
  return { checkedAt, accounts };
}
