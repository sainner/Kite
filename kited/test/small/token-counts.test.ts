import { expect, setSystemTime, test } from 'bun:test';
import type { ApiKey } from '../../src/account-client.ts';
import { TokenCounter, type TokenCountResult } from '../../src/token-counts.ts';

const scenarios = [
  { vendor: 'openai', model: 'gpt-6.1-sol', other: 'sonnet', fallback: 'o200k' },
  { vendor: 'anthropic', model: 'sonnet', other: 'gpt-6.1-sol', fallback: 'none' },
] as const;

// 真实缺陷：四个官方请求占满槽位后收到 429，排队请求仍继续联网。
// 需一起验证异步槽位交接、厂商冷却与回退；固定时间并用 HTTP promise 控制响应，不等真实一分钟。
for (const scenario of scenarios) test(`${scenario.vendor} 计数限频后排队请求回退，另一厂商可用，满一分钟后恢复四路并发`, async () => {
  const start = 1_900_000_000_000;
  const keys: ApiKey[] = [
    { id: 'openai', name: '测试 OpenAI', provider: 'openai', key: 'test-openai' },
    { id: 'anthropic', name: '测试 Anthropic', provider: 'anthropic', key: 'test-anthropic' },
  ];
  const calls = { openai: 0, anthropic: 0 };
  let active = 0;
  let peak = 0;
  let window: { entered: ReturnType<typeof Promise.withResolvers<void>>; held: Array<ReturnType<typeof Promise.withResolvers<Response>>> } | undefined;
  const pending: Array<Promise<TokenCountResult[]>> = [];
  const counter = new TokenCounter({ apiKeys: async () => keys, lightModel: 'gpt-6.1-sol', fetch: (async (input) => {
    const host = new URL(input instanceof Request ? input.url : input.toString()).hostname;
    const vendor = host === 'api.openai.com' ? 'openai' : host === 'api.anthropic.com' ? 'anthropic' : undefined;
    if (!vendor) throw new Error(`测试未提供此地址的响应：${host}`);
    calls[vendor]++;
    peak = Math.max(peak, ++active);
    try {
      if (vendor === scenario.vendor && window && window.held.length < 4) {
        const response = Promise.withResolvers<Response>();
        window.held.push(response);
        if (window.held.length === 4) window.entered.resolve();
        return await response.promise;
      }
      return Response.json({ input_tokens: 100 });
    } finally { active--; }
  }) as typeof fetch });
  const round = (label: string) => {
    const gate = { entered: Promise.withResolvers<void>(), held: [] as Array<ReturnType<typeof Promise.withResolvers<Response>>> };
    window = gate;
    const requests = Array.from({ length: 8 }, (_, index) => counter.count([`${label} ${index}`], scenario.model));
    pending.push(...requests);
    return { gate, requests };
  };
  const fallback = (result: TokenCountResult) => {
    expect(result).toMatchObject({ method: scenario.fallback, exact: false });
    if (scenario.fallback === 'o200k') expect(result.tokens).toBeGreaterThan(0);
    else expect(result.tokens).toBeUndefined();
  };
  try {
    setSystemTime(new Date(start));
    // 先完成两家的固定消息开销探测，后面的窗口只观察实际文本请求。
    expect((await counter.count(['预热当前厂商'], scenario.model))[0]?.method).toBe('api');
    expect((await counter.count(['预热另一厂商'], scenario.other))[0]?.method).toBe('api');
    const before = calls[scenario.vendor];
    const initial = round('首次并发');
    await initial.gate.entered.promise;
    initial.gate.held[0]!.resolve(new Response(null, { status: 429 }));
    await Promise.race(initial.requests);
    for (const held of initial.gate.held.slice(1)) held.resolve(Response.json({ input_tokens: 100 }));
    const results = (await Promise.all(initial.requests)).flat();
    expect(calls[scenario.vendor] - before).toBe(4);
    expect(results.filter((result) => result.method === 'api')).toHaveLength(3);
    const estimates = results.filter((result) => result.method !== 'api');
    expect(estimates).toHaveLength(5);
    estimates.forEach(fallback);

    expect((await counter.count(['冷却时另一厂商的请求'], scenario.other))[0]?.method).toBe('api');
    setSystemTime(new Date(start + 59_999));
    fallback((await counter.count(['冷却到期前的新文本'], scenario.model))[0]!);
    expect(calls[scenario.vendor] - before).toBe(4);

    setSystemTime(new Date(start + 60_000));
    const resumed = round('冷却到期后的并发');
    await resumed.gate.entered.promise;
    for (const held of resumed.gate.held) held.resolve(Response.json({ input_tokens: 100 }));
    expect((await Promise.all(resumed.requests)).flat().map((result) => result.method)).toEqual(Array(8).fill('api'));
    expect(calls[scenario.vendor] - before).toBe(12);
    expect(peak).toBe(4);
    expect(active).toBe(0);
  } finally {
    for (const held of window?.held ?? []) held.resolve(Response.json({ input_tokens: 100 }));
    await Promise.allSettled(pending);
    setSystemTime();
  }
}, 1000);
