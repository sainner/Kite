/**
 * 对端请求按进度超时（src/peer-fetch.ts 的 peerJSON 的 stallMs）：等响应头、等下一段正文都不超过 stallMs，总时长不限。
 * 本地 Bun.serve 扮演对端，正文用 ReadableStream 一段段写出；三个请求并行，整个测试约 0.5 秒。
 */
import { afterEach, expect, test } from 'bun:test';
import { peerJSON, type PeerFetch } from '../../src/peer-fetch.ts';

const servers: Array<{ stop(force?: boolean): unknown }> = [];
afterEach(() => { for (const server of servers.splice(0)) void server.stop(true); });

const STALL_MS = 250;
/** 慢端点每两段之间的间隔，远小于 STALL_MS；十段合起来约两倍 STALL_MS。 */
const GAP_MS = 50;
const PARTS = ['{"items":[', '1,', '2,', '3,', '4,', '5,', '6,', '7,', '8', ']}'];

/*
 * 依赖 Bun 运行时：Bun.serve 的流式正文写一段发一段；fetch 的响应头到了以后，正文读到一半时中止，挂着的读取能立即结束，
 * 等响应头时中止，fetch 以中止原因失败。只按总时长中止的实现会让慢端点失败，只管响应头的实现会让挂住的正文一直等下去。
 */
test('正文分段慢慢到、总时长超过 stallMs 但每段间隔都短于它时照常解析出 JSON；发完响应头和一小段就不再发、或一直不发响应头时，约 stallMs 后以没有响应失败', async () => {
  const encoder = new TextEncoder();
  const server = Bun.serve({
    hostname: '127.0.0.1', port: 0,
    fetch(request) {
      const path = new URL(request.url).pathname;
      if (path === '/slow') {
        let next = 0;
        return new Response(new ReadableStream({
          async pull(controller) {
            if (next > 0) await new Promise((resolve) => setTimeout(resolve, GAP_MS));
            if (next === PARTS.length) controller.close();
            else controller.enqueue(encoder.encode(PARTS[next++]));
          },
        }), { headers: { 'content-type': 'application/json' } });
      }
      if (path === '/stuck') {
        // 发出第一段后既不再写也不关闭。
        return new Response(new ReadableStream({ start(controller) { controller.enqueue(encoder.encode(PARTS[0])); } }),
          { headers: { 'content-type': 'application/json' } });
      }
      if (path === '/silent') return new Promise<Response>(() => {});
      return new Response('{}', { status: 404 });
    },
  });
  servers.push(server);
  const fetcher: PeerFetch = (address, path, init) => fetch(address + path, init);
  const peer = { id: 'peer-test', address: `http://127.0.0.1:${server.port}` };
  const timed = async (path: string) => {
    const started = performance.now();
    try {
      const value = await peerJSON<unknown>(fetcher, peer, path, { stallMs: STALL_MS });
      return { value, ms: performance.now() - started };
    } catch (error) {
      return { error: error as Error, ms: performance.now() - started };
    }
  };

  const [slow, stuck, silent] = await Promise.all(['/slow', '/stuck', '/silent'].map(timed));
  expect(slow).toMatchObject({ value: { items: [1, 2, 3, 4, 5, 6, 7, 8] } });
  expect(slow!.ms).toBeGreaterThan(STALL_MS * 1.5);
  for (const failed of [stuck!, silent!]) {
    expect(failed.error?.message).toMatch(/超过 \d+ 秒没有响应/);
    expect(failed.ms).toBeGreaterThan(STALL_MS * 0.8);
    expect(failed.ms).toBeLessThan(STALL_MS * 3);
  }
});
