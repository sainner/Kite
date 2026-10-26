/**
 * web_fetch 读网页前按执行授权核对目标网站（docs/harness-主循环.md「web_fetch」），口径与 shell 连外网相同。
 * 不连网：核对没通过时 execute 返回 error、不取 Key；核对通过后才取 Key，Key 为空时以「没有可用的搜索服务」结束，
 * 所以「keys 被调用」就表示放行了。
 */
import { expect, test } from 'bun:test';
import { tmpdir } from 'node:os';
import type { ExecutionPolicy } from '../../src/execution/sandbox.ts';
import type { Tool } from '../../src/harness/types.ts';
import { webTools } from '../../src/web/tools.ts';

type Ask = { host: string; port?: number };

function gate(policy: ExecutionPolicy, answer: (target: Ask) => boolean) {
  const asks: Ask[] = [];
  let keyCalls = 0;
  const tools = webTools({
    keys: async () => { keyCalls += 1; return []; },
    policy: () => policy,
    askNetwork: async (target) => { asks.push({ ...target }); return answer(target); },
  });
  const fetchTool = tools.find((tool) => tool.name === 'web_fetch') as Tool;
  return {
    asks,
    get keyCalls() { return keyCalls; },
    /** 读一次，返回结果是放行（取了 Key）还是被拦下。 */
    async read(url: string): Promise<'read' | 'blocked'> {
      const before = keyCalls;
      const result = await fetchTool.execute({ url }, { cwd: tmpdir(), signal: new AbortController().signal })
        .then((value) => ({ ok: true as const, value }), (error: unknown) => ({ ok: false as const, error }));
      if (result.ok) {
        expect(result.value.status).toBe('error');
        expect(keyCalls).toBe(before);
        return 'blocked';
      }
      expect(String(result.error)).toContain('没有可用的搜索服务');
      expect(keyCalls).toBe(before + 1);
      return 'read';
    },
  };
}

// 两部分的配合：shell「允许并记住」往网络许可里写「主机:端口」（kite.ts 的 askNetwork），web_fetch 要认同一种写法；
// 匹配规则来自上游 @anthropic-ai/sandbox-runtime 的 matchesDomainPatternWithPort（深层导入）：
// 「主机:端口」只放行同一端口，「*.github.io」覆盖子域名、不覆盖 github.io 本身。上游升级改了这些规则时这里会失败。
test('记住过的主机:端口与通配子域名直接读，域名本身和别的端口交给 askNetwork，拒绝就不读', async () => {
  const g = gate({ read: [], write: [], network: ['example.com:443', '*.github.io'] },
    (target) => target.host === 'github.io');

  expect(await g.read('https://example.com/docs')).toBe('read');
  expect(await g.read('https://foo.github.io/page')).toBe('read');
  expect(g.asks).toEqual([]);

  expect(await g.read('https://github.io/')).toBe('read');
  expect(await g.read('http://example.com:8080/')).toBe('blocked');
  expect(g.asks.map(({ host, port }) => ({ host, port }))).toEqual([
    { host: 'github.io', port: 443 },
    { host: 'example.com', port: 8080 },
  ]);
});

// 两部分的配合：项目禁止的名单与网络许可同时命中时以禁止为准，且不落到问人那一步；禁止名单的通配同样走上游匹配规则。
test('项目禁止的主机即使在网络许可里也不读，不问人也不取 Key', async () => {
  const g = gate({ read: [], write: [], network: ['docs.example.com'], deniedNetwork: ['*.example.com'] }, () => true);

  expect(await g.read('https://docs.example.com/a')).toBe('blocked');
  expect(g.asks).toEqual([]);
  expect(g.keyCalls).toBe(0);
});
