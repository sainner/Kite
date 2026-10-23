/**
 * 对端请求（src/peer-fetch.ts）：peerJSON 按进度超时（stallMs）：等响应头、等下一段正文都不超过 stallMs，总时长不限；
 * peerDownload 按段取，卡住的段换个请求重取。本地 Bun.serve 扮演对端，正文用 ReadableStream 一段段写出。
 */
import { afterEach, expect, test } from 'bun:test';
import { randomBytes } from 'node:crypto';
import { peerDownload, peerJSON, SEGMENT_BYTES, type PeerFetch } from '../../src/peer-fetch.ts';

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

/*
 * 依赖 Bun 运行时：fetch 的正文读到一半时中止，挂着的读取能结束，再发一个新请求重取这一段；几路同时取的各段乱序完成，
 * 按位置拼回整份。单看代码看不出中止、重来与并发拼接合起来的时序问题。
 * 整份 3.5 MiB 多一点，末段不满一段；第二段（从 1 MiB 起）的第一次请求发完响应头和一小块就挂住，第二次正常给，
 * 所以它最后完成，晚于后面两段。另一个路径忽略 Range、回 200 整份，像不认 Range 的旧版对端。
 */
test('按段取时某段发了一小块就挂住，约 stallMs 后换个请求重取这一段，乱序完成的各段按位置拼回整份；对端忽略 Range 回 200 时整份照收', async () => {
  const content = randomBytes(3 * SEGMENT_BYTES + 512 * 1024 + 7);
  const stuckStart = SEGMENT_BYTES;
  const requested: Record<string, string[]> = { '/ranged': [], '/whole': [] };
  const server = Bun.serve({
    hostname: '127.0.0.1', port: 0, idleTimeout: 0,
    fetch(request) {
      const path = new URL(request.url).pathname;
      const range = request.headers.get('range') ?? '';
      requested[path]?.push(range);
      if (path === '/whole') return new Response(content);
      const match = /^bytes=(\d+)-(\d*)$/.exec(range);
      if (path !== '/ranged' || !match) return new Response('没有这个接口', { status: 404 });
      const start = Number(match[1]);
      const end = Math.min(match[2] ? Number(match[2]) : content.length - 1, content.length - 1);
      const headers = { 'Content-Range': `bytes ${start}-${end}/${content.length}` };
      if (start === stuckStart && requested['/ranged']!.filter((value) => value === range).length === 1) {
        // 发出响应头和开头一小块后既不再写也不关闭。
        return new Response(new ReadableStream({ start(controller) { controller.enqueue(content.subarray(start, start + 4096)); } }),
          { status: 206, headers });
      }
      return new Response(content.subarray(start, end + 1), { status: 206, headers });
    },
  });
  servers.push(server);
  const fetcher: PeerFetch = (address, path, init) => fetch(address + path, init);
  const peer = { id: 'peer-test', address: `http://127.0.0.1:${server.port}` };
  const download = async (path: string) => {
    const out = Buffer.alloc(content.length);
    const size = await peerDownload(fetcher, peer, path, (offset, bytes) => { bytes.copy(out, offset); }, { stallMs: STALL_MS });
    return { size, out };
  };

  const [ranged, whole] = await Promise.all([download('/ranged'), download('/whole')]);
  expect(ranged.size).toBe(content.length);
  expect(ranged.out.equals(content)).toBe(true);
  expect(whole.size).toBe(content.length);
  expect(whole.out.equals(content)).toBe(true);

  const starts = requested['/ranged']!.map((range) => Number(/^bytes=(\d+)-/.exec(range)?.[1]));
  expect(requested['/ranged']![0]).toBe(`bytes=0-${SEGMENT_BYTES - 1}`);
  expect([...new Set(starts)].sort((a, b) => a - b)).toEqual([0, 1, 2, 3].map((index) => index * SEGMENT_BYTES));
  expect(starts.filter((start) => start === stuckStart)).toHaveLength(2);
  expect(requested['/whole']).toHaveLength(1);
});
