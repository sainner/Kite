import { afterEach, beforeEach, expect, test } from 'bun:test';
import { existsSync, readFileSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { readModelAccounts, type AccountReadOptions, type ModelAccountsSnapshot } from '../../src/model-accounts.ts';
import { useTemp, writeFiles } from '../util.ts';

const temp = useTemp();
const keys = ['OPENAI_API_KEY', 'OPENAI_ADMIN_KEY', 'ANTHROPIC_API_KEY', 'ANTHROPIC_ADMIN_KEY', 'DEEPSEEK_API_KEY'] as const;
let savedEnv: Array<string | undefined>;
beforeEach(() => {
  savedEnv = keys.map((key) => process.env[key]);
  for (const key of keys) delete process.env[key];
});
afterEach(() => {
  keys.forEach((key, index) => {
    if (savedEnv[index] === undefined) delete process.env[key];
    else process.env[key] = savedEnv[index];
  });
});

function jwt(claims: Record<string, unknown>): string {
  const encoded = (value: unknown) => Buffer.from(JSON.stringify(value)).toString('base64url');
  return `${encoded({ alg: 'RS256', typ: 'JWT' })}.${encoded(claims)}.${Buffer.from('仅测试的签名').toString('base64url')}`;
}

function chatgptAuth(home: string, expired = false) {
  const accessToken = jwt({ exp: expired ? 1 : Math.floor(Date.now() / 1000) + 3600, sub: 'chatgpt-test-user' });
  const idToken = jwt({ email: 'chatgpt@kite.test', 'https://api.openai.com/auth': {
    chatgpt_account_id: 'chatgpt-test-account', chatgpt_plan_type: 'plus',
  } });
  const content = JSON.stringify({ auth_mode: 'chatgpt', tokens: {
    access_token: accessToken, account_id: 'chatgpt-test-account', id_token: idToken, refresh_token: '刷新令牌不得返回',
  } });
  writeFiles(home, { 'auth/chatgpt/auth.json': content });
  return { accessToken, idToken, content, path: join(home, 'auth/chatgpt/auth.json') };
}

const claudeToken = 'sk-ant-oat01-test-subscription-secret';
const claudeLogin = async () => ({ accessToken: claudeToken, subscriptionType: 'max' });
const noClaudeLogin = async () => undefined;
const reset = 2_000_000_000;
const resetISO = new Date(reset * 1000).toISOString();
const chatgptUsage = {
  plan_type: 'plus',
  rate_limit: {
    primary_window: { used_percent: 25, limit_window_seconds: 18_000, reset_at: reset },
    secondary_window: { used_percent: 62.5, limit_window_seconds: 604_800, reset_at: reset + 100 },
  },
  additional_rate_limits: [{ metered_feature: 'codex_review', limit_name: '代码审查', rate_limit: {
    primary_window: { used_percent: 90, limit_window_seconds: 604_800, reset_at: reset + 200 },
  } }],
  credits: { has_credits: true, unlimited: false, balance: '12.50' },
};
const claudeUsage = {
  five_hour: { utilization: 20, resets_at: resetISO },
  seven_day: { utilization: 70, resets_at: resetISO },
};

interface SeenRequest { url: URL; headers: Headers; method: string }
function endpoint(reply: (request: Request, url: URL) => Response) {
  const seen: SeenRequest[] = [];
  const server = Bun.serve({ hostname: '127.0.0.1', port: 0, fetch(request) {
    return reply(request, new URL(request.url));
  } });
  const localFetch: NonNullable<AccountReadOptions['fetch']> = (url, init) => {
    const parsed = new URL(url);
    if (!['chatgpt.com', 'api.openai.com', 'api.anthropic.com', 'api.deepseek.com'].includes(parsed.hostname)) {
      throw new Error(`测试禁止访问此地址：${parsed.origin}`);
    }
    seen.push({ url: parsed, headers: new Headers(init.headers), method: init.method ?? 'GET' });
    return fetch(`${server.url.origin}${parsed.pathname}${parsed.search}`, init);
  };
  return { seen, fetch: localFetch, stop: () => server.stop(true) };
}

function account(snapshot: ModelAccountsSnapshot, id: string) {
  const found = snapshot.accounts.find((value) => value.id === id);
  if (!found) throw new Error(`缺少账号 ${id}`);
  return found;
}

function noSecrets(snapshot: ModelAccountsSnapshot, secrets: string[]) {
  const serialized = JSON.stringify(snapshot);
  for (const secret of secrets) expect(serialized).not.toContain(secret);
}

// 临时文件凭据、Bun HTTP 认证头与两家订阅响应共同决定展示账号，不能只验证 JSON 转换。
test('工作机读取自己的订阅凭据并经认证请求取得账号、额度和重置时间', async () => {
  const home = temp('kite-model-accounts-');
  const auth = chatgptAuth(home);
  const before = statSync(auth.path).mtimeMs;
  const api = endpoint((_request, url) => {
    if (url.pathname === '/backend-api/wham/usage') return Response.json(chatgptUsage);
    if (url.pathname === '/api/oauth/usage') return Response.json(claudeUsage);
    if (url.pathname === '/api/oauth/profile') return Response.json({ account: { email: 'claude@kite.test' } });
    return Response.json({}, { status: 404 });
  });
  try {
    const snapshot = await readModelAccounts(home, { fetch: api.fetch, claudeLogin });
    expect(snapshot.checkedAt).toBeGreaterThan(0);
    const chatgpt = account(snapshot, 'chatgpt');
    expect(chatgpt).toMatchObject({ kind: 'subscription', status: 'ready', identity: 'chatgpt@kite.test', plan: 'plus' });
    expect(chatgpt.quotas).toHaveLength(3);
    expect(chatgpt.quotas).toEqual(expect.arrayContaining([
      expect.objectContaining({ remainingPercent: 75, windowMinutes: 300, resetsAt: reset }),
      expect.objectContaining({ remainingPercent: 37.5, windowMinutes: 10_080, resetsAt: reset + 100 }),
      expect.objectContaining({ remainingPercent: 10, windowMinutes: 10_080, resetsAt: reset + 200 }),
    ]));
    expect(chatgpt.credits).toEqual({ value: 12.5, unlimited: false });
    const claude = account(snapshot, 'claude');
    expect(claude).toMatchObject({ kind: 'subscription', status: 'ready', identity: 'claude@kite.test' });
    expect(claude.quotas).toEqual(expect.arrayContaining([
      expect.objectContaining({ remainingPercent: 80, windowMinutes: 300, resetsAt: reset }),
      expect.objectContaining({ remainingPercent: 30, windowMinutes: 10_080, resetsAt: reset }),
    ]));
    expect(api.seen).toHaveLength(3);
    const chatgptRequest = api.seen.find((value) => value.url.hostname === 'chatgpt.com')!;
    expect(chatgptRequest.url.href).toBe('https://chatgpt.com/backend-api/wham/usage');
    expect(chatgptRequest.headers.get('authorization')).toBe(`Bearer ${auth.accessToken}`);
    expect(chatgptRequest.headers.get('chatgpt-account-id')).toBe('chatgpt-test-account');
    const claudeRequests = api.seen.filter((value) => value.url.hostname === 'api.anthropic.com');
    expect(claudeRequests.map((value) => value.url.pathname).sort()).toEqual(['/api/oauth/profile', '/api/oauth/usage']);
    for (const request of claudeRequests) expect(request.headers.get('authorization')).toBe(`Bearer ${claudeToken}`);
    expect(api.seen.every((value) => value.method === 'GET')).toBe(true);
    expect(readFileSync(auth.path, 'utf8')).toBe(auth.content);
    expect(statSync(auth.path).mtimeMs).toBe(before);
    noSecrets(snapshot, [auth.accessToken, auth.idToken, claudeToken, '刷新令牌不得返回']);
  } finally { await api.stop(); }
}, 1000);

// 两家异步查询的错误必须各自收口；HOME 中的 Codex 凭据是刻意放置的越界诱饵，不能被 Kite 借用。
test('订阅认证、限流和畸形响应独立失败且不会回退到 Codex 凭据或泄漏令牌', async () => {
  const home = temp('kite-model-accounts-errors-');
  const legacyDir = join(process.env.HOME!, '.codex');
  const legacyPath = join(legacyDir, 'auth.json');
  // preload 已把 HOME 隔离；禁止单独绕过基础设施运行时碰到使用者的凭据。
  expect(process.env.USER).toBe('kite-test');
  const hadDirectory = existsSync(legacyDir);
  const oldLegacy = existsSync(legacyPath) ? readFileSync(legacyPath) : undefined;
  const decoy = jwt({ exp: Math.floor(Date.now() / 1000) + 3600 });
  writeFiles(legacyDir, { 'auth.json': JSON.stringify({ auth_mode: 'chatgpt', tokens: {
    access_token: decoy, account_id: '不得借用的Codex账号',
  } }) });
  let scenario = '';
  let auth = chatgptAuth(home);
  const api = endpoint((_request, url) => {
    if (url.pathname === '/backend-api/wham/usage') {
      if (scenario === 'chatgpt-401') return Response.json({ error: auth.accessToken }, { status: 401 });
      if (scenario === 'chatgpt-malformed') return new Response(`坏的 JSON ${auth.accessToken}`);
      return Response.json(chatgptUsage);
    }
    if (url.pathname === '/api/oauth/usage') {
      if (scenario === 'claude-429') return Response.json({ error: claudeToken }, { status: 429 });
      if (scenario === 'claude-malformed') return Response.json({ five_hour: { utilization: '未知', resets_at: resetISO } });
      return Response.json(claudeUsage);
    }
    if (url.pathname === '/api/oauth/profile') return Response.json({ account: { email: 'claude@kite.test' } });
    return Response.json({}, { status: 404 });
  });
  try {
    for (const [name, chatgptStatus, claudeStatus] of [
      ['chatgpt-401', 'reauthentication', 'ready'],
      ['claude-429', 'ready', 'unavailable'],
      ['chatgpt-malformed', 'unavailable', 'ready'],
      ['claude-malformed', 'ready', 'unavailable'],
      ['expired', 'reauthentication', 'ready'],
      ['missing', 'unconfigured', 'ready'],
    ] as const) {
      scenario = name;
      auth = chatgptAuth(home, name === 'expired');
      if (name === 'missing') rmSync(auth.path);
      api.seen.length = 0;
      const snapshot = await readModelAccounts(home, { fetch: api.fetch, claudeLogin });
      const chatgpt = account(snapshot, 'chatgpt');
      const claude = account(snapshot, 'claude');
      expect({ scenario, status: chatgpt.status }).toEqual({ scenario, status: chatgptStatus });
      expect({ scenario, status: claude.status }).toEqual({ scenario, status: claudeStatus });
      for (const provider of [chatgpt, claude]) {
        if (provider.status !== 'ready') {
          expect(provider.quotas).toEqual([]);
          expect(provider.credits).toBeUndefined();
        } else expect(provider.quotas.length).toBeGreaterThan(0);
      }
      if (name === 'expired' || name === 'missing') {
        expect(api.seen.some((value) => value.url.hostname === 'chatgpt.com')).toBe(false);
      }
      noSecrets(snapshot, [auth.accessToken, auth.idToken, decoy, claudeToken, '刷新令牌不得返回']);
    }
  } finally {
    await api.stop();
    if (oldLegacy) writeFileSync(legacyPath, oldLegacy);
    else rmSync(legacyPath, { force: true });
    if (!hadDirectory) rmSync(legacyDir, { recursive: true, force: true });
  }
}, 1000);

// 组织费用的分页游标、UTC 统计区间和两家金额单位是外部 HTTP 合同；读到部分页面不能展示合计或余额。
test('API 普通密钥只确认配置，管理密钥完整读分页后才展示本月组织费用', async () => {
  const home = temp('kite-model-accounts-costs-');
  Object.assign(process.env, { OPENAI_API_KEY: 'sk-openai-test-secret', ANTHROPIC_API_KEY: 'sk-ant-test-secret' });
  let scenario = 'complete';
  const api = endpoint((_request, url) => {
    const page = url.searchParams.get('page');
    const isOpenAI = url.pathname === '/v1/organization/costs';
    const isAnthropic = url.pathname === '/v1/organizations/cost_report';
    if (!isOpenAI && !isAnthropic) return Response.json({}, { status: 404 });
    if (page && scenario === (isOpenAI ? 'openai-forbidden' : 'anthropic-throttled')) {
      return Response.json({ error: isOpenAI ? process.env.OPENAI_ADMIN_KEY : process.env.ANTHROPIC_ADMIN_KEY }, {
        status: isOpenAI ? 403 : 429,
      });
    }
    const results = isOpenAI
      ? (page ? [{ amount: { value: 2.25, currency: 'usd' } }]
        : [{ amount: { value: 1.25, currency: 'usd' } }, { amount: { value: 0.5, currency: 'usd' } }])
      : (page ? [{ amount: '250', currency: 'USD' }] : [{ amount: '123', currency: 'USD' }, { amount: '77', currency: 'USD' }]);
    return Response.json({ data: [{ results }], has_more: !page,
      next_page: page || scenario === 'missing-cursor' ? null : (isOpenAI ? 'openai-second' : 'anthropic-second') });
  });
  try {
    const ordinary = await readModelAccounts(home, { fetch: api.fetch, claudeLogin: noClaudeLogin });
    for (const id of ['openai-api', 'anthropic-api']) {
      expect(account(ordinary, id)).toMatchObject({ kind: 'api', status: 'ready', quotas: [] });
      expect(account(ordinary, id).cost).toBeUndefined();
      expect(account(ordinary, id).credits).toBeUndefined();
      expect(account(ordinary, id).message).toBeTruthy();
    }
    expect(api.seen).toHaveLength(0);
    Object.assign(process.env, { OPENAI_ADMIN_KEY: 'sk-openai-admin-test-secret', ANTHROPIC_ADMIN_KEY: 'sk-ant-admin-test-secret' });
    const now = new Date();
    const monthStart = Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), 1) / 1000;
    const complete = await readModelAccounts(home, { fetch: api.fetch, claudeLogin: noClaudeLogin });
    expect(account(complete, 'openai-api').cost).toMatchObject({ value: 4, currency: 'USD', from: monthStart });
    expect(account(complete, 'anthropic-api').cost).toMatchObject({ value: 4.5, currency: 'USD', from: monthStart });
    for (const id of ['openai-api', 'anthropic-api']) expect(account(complete, id).credits).toBeUndefined();
    expect(api.seen).toHaveLength(4);
    for (const [host, cursor] of [['api.openai.com', 'openai-second'], ['api.anthropic.com', 'anthropic-second']]) {
      const requests = api.seen.filter((value) => value.url.hostname === host);
      expect(requests).toHaveLength(2);
      expect(requests[0]!.url.searchParams.get('page')).toBeNull();
      expect(requests[1]!.url.searchParams.get('page')).toBe(cursor!);
      for (const request of requests) {
        if (host === 'api.openai.com') {
          expect(request.url.searchParams.get('start_time')).toBe(String(monthStart));
          expect(Number(request.url.searchParams.get('end_time'))).toBeGreaterThanOrEqual(monthStart);
          expect(request.headers.get('authorization')).toBe(`Bearer ${process.env.OPENAI_ADMIN_KEY}`);
        } else {
          expect(Date.parse(request.url.searchParams.get('starting_at')!)).toBe(monthStart * 1000);
          expect(request.headers.get('x-api-key')).toBe(process.env.ANTHROPIC_ADMIN_KEY!);
          expect(request.headers.get('anthropic-version')).toBe('2023-06-01');
        }
      }
    }
    for (const name of ['openai-forbidden', 'anthropic-throttled', 'missing-cursor']) {
      scenario = name;
      const snapshot = await readModelAccounts(home, { fetch: api.fetch, claudeLogin: noClaudeLogin });
      for (const id of ['openai-api', 'anthropic-api']) {
        const failed = name === 'missing-cursor' || name.startsWith(id.split('-')[0]!);
        expect(account(snapshot, id).status).toBe(failed ? 'unavailable' : 'ready');
        if (failed) expect(account(snapshot, id).cost).toBeUndefined();
        else expect(account(snapshot, id).cost?.value).toBe(id === 'openai-api' ? 4 : 4.5);
        expect(account(snapshot, id).credits).toBeUndefined();
      }
      noSecrets(snapshot, keys.flatMap((key) => process.env[key] ? [process.env[key]!] : []));
    }
    noSecrets(complete, keys.flatMap((key) => process.env[key] ? [process.env[key]!] : []));
  } finally { await api.stop(); }
}, 1000);

// DeepSeek 余额用金额字符串且可能同时返回多种币种；不可用仍是有数值的余额，不能和接口错误混为零。
test('DeepSeek 经密钥认证保留多币种及不足余额，畸形金额不会被当成零', async () => {
  const home = temp('kite-model-accounts-deepseek-');
  const secret = 'sk-deepseek-test-secret';
  let reply: unknown = { is_available: true, balance_infos: [
    { currency: 'CNY', total_balance: '123.45', granted_balance: '23.45', topped_up_balance: '100.00' },
    { currency: 'USD', total_balance: '4.50', granted_balance: '0.00', topped_up_balance: '4.50' },
  ] };
  const api = endpoint((_request, url) => url.pathname === '/user/balance'
    ? Response.json(reply) : Response.json({}, { status: 404 }));
  try {
    const missing = await readModelAccounts(home, { fetch: api.fetch, claudeLogin: noClaudeLogin });
    expect(account(missing, 'deepseek-api').status).toBe('unconfigured');
    expect(api.seen).toHaveLength(0);
    process.env.DEEPSEEK_API_KEY = secret;
    const loaded = await readModelAccounts(home, { fetch: api.fetch, claudeLogin: noClaudeLogin });
    expect(account(loaded, 'deepseek-api')).toMatchObject({ kind: 'api', status: 'ready', balances: [
      { currency: 'CNY', total: 123.45, granted: 23.45, toppedUp: 100 },
      { currency: 'USD', total: 4.5, granted: 0, toppedUp: 4.5 },
    ] });
    expect(api.seen).toHaveLength(1);
    expect(api.seen[0]!.url.href).toBe('https://api.deepseek.com/user/balance');
    expect(api.seen[0]!.method).toBe('GET');
    expect(api.seen[0]!.headers.get('authorization')).toBe(`Bearer ${secret}`);
    noSecrets(loaded, [secret]);
    reply = { is_available: false, balance_infos: [
      { currency: 'CNY', total_balance: '0.00', granted_balance: '0.00', topped_up_balance: '0.00' },
      { currency: 'USD', total_balance: '-0.25', granted_balance: '0.00', topped_up_balance: '-0.25' },
    ] };
    const insufficient = await readModelAccounts(home, { fetch: api.fetch, claudeLogin: noClaudeLogin });
    expect(account(insufficient, 'deepseek-api').balances).toEqual([
      { currency: 'CNY', total: 0, granted: 0, toppedUp: 0 },
      { currency: 'USD', total: -0.25, granted: 0, toppedUp: -0.25 },
    ]);
    expect(account(insufficient, 'deepseek-api').message).toBeTruthy();
    for (const amount of ['', 'unknown', 'Infinity']) {
      reply = { is_available: true, balance_infos: [
        { currency: 'CNY', total_balance: amount, granted_balance: '0', topped_up_balance: '0' },
      ] };
      const malformed = await readModelAccounts(home, { fetch: api.fetch, claudeLogin: noClaudeLogin });
      expect(account(malformed, 'deepseek-api').status).toBe('unavailable');
      expect(account(malformed, 'deepseek-api').balances).toBeUndefined();
      noSecrets(malformed, [secret]);
    }
  } finally { await api.stop(); }
}, 1000);
