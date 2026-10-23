/** 访问另一台工作机的 kited：组网上经 kite-net 的本机 HTTP 代理，测试里同一进程的几台直接访问；由 Kite 统一决定。 */
export type PeerFetch = (address: string, path: string, init?: RequestInit) => Promise<Response>;

/** 一台在线的工作机：机器 ID 与组网上的访问地址。 */
export interface Peer { id: string; address: string }

/** 对端回了非 2xx：带着状态码，调用方据此分辨对端没有这个接口（旧版）等情形。 */
export class PeerError extends Error {
  constructor(message: string, readonly status: number) { super(message); }
}

/**
 * 组网上按段传：一段 1 MiB、4 路同时传；一段 2 秒没有新数据就换个请求重传，同一段最多试 8 次。
 * 组网上一条连接遇上丢包后可能一直慢下去，路径恢复了也不回来，新开的连接却往往很快；分段、卡住换连接把最慢的情况从几分钟压到几秒，
 * 见 docs/research/2026-10-22-组网传输速度.md。App 的 KitedClient 用同一组数。
 */
export const SEGMENT_BYTES = 1 << 20;
export const SEGMENT_WORKERS = 4;
export const SEGMENT_STALL_MS = 2_000;
export const SEGMENT_ATTEMPTS = 8;

/** 按进度计时：等响应头不超过 waitMs（默认同 stallMs），之后两次收到数据之间不超过 stallMs，总时长不限；不给 stallMs 不计时。 */
interface Limits { stallMs?: number; waitMs?: number; attempts?: number }
interface Exchange { status: number; headers: Headers; body: Buffer }

/**
 * 发一个请求、读完整个回应。超时（见 Limits）或连接出错时换个请求重来，最多 attempts 次，所以请求体要能重发；
 * 调用方的 signal 中止时不重来。对端回的非 2xx 原样交回，由调用方处理。
 */
async function exchange(fetch: PeerFetch, peer: Peer, path: string, init: RequestInit, limits: Limits): Promise<Exchange> {
  for (let attempt = 1; ; attempt++) {
    const stalled = new AbortController();
    let timer: ReturnType<typeof setTimeout> | undefined;
    const arm = (ms: number | undefined) => {
      clearTimeout(timer);
      if (ms) timer = setTimeout(() => stalled.abort(new Error(`工作机 ${peer.id} 超过 ${Math.round(ms / 1000)} 秒没有响应`)), ms);
    };
    arm(limits.waitMs ?? limits.stallMs);
    try {
      const response = await fetch(peer.address, path, { ...init,
        signal: init.signal ? AbortSignal.any([init.signal, stalled.signal]) : stalled.signal,
        headers: { ...init.headers as Record<string, string>, 'X-Kite-Machine': peer.id } });
      const chunks: Uint8Array[] = [];
      if (response.body) {
        const reader = response.body.getReader();
        const cancel = () => { void reader.cancel(stalled.signal.reason).catch(() => {}); };
        stalled.signal.addEventListener('abort', cancel, { once: true });
        try {
          for (;;) {
            arm(limits.stallMs);
            const { value, done } = await reader.read();
            if (stalled.signal.aborted) throw stalled.signal.reason;
            if (done) break;
            chunks.push(value);
          }
        } finally { stalled.signal.removeEventListener('abort', cancel); }
      }
      return { status: response.status, headers: response.headers, body: Buffer.concat(chunks) };
    } catch (error) {
      if (init.signal?.aborted || attempt >= (limits.attempts ?? 1)) throw stalled.signal.aborted ? stalled.signal.reason : error;
    } finally { clearTimeout(timer); }
  }
}

/** 非 2xx 时抛 PeerError，带上对端的说明。 */
function check(peer: Peer, response: Exchange): void {
  if (response.status >= 200 && response.status < 300) return;
  let error: unknown;
  try { error = JSON.parse(response.body.toString('utf8')).error; } catch { /* 没有说明 */ }
  throw new PeerError(`工作机 ${peer.id} 返回 ${response.status}${typeof error === 'string' ? `：${error}` : ''}`, response.status);
}

/**
 * 请求另一台工作机的接口：带上它的机器 ID，非 2xx 时抛 PeerError，返回 JSON。
 * stallMs 按进度计时：等响应头、等下一段正文都不超过它，总时长不限，走境外中继的大页传得慢也能传完，对端没了才放弃。
 * 给了 attempts 时，卡住了换个请求重来，只给能重复的请求用。
 */
export async function peerJSON<T>(fetch: PeerFetch, peer: Peer, path: string,
  init: RequestInit & { json?: unknown } & Limits = {}): Promise<T> {
  const { json, stallMs, waitMs, attempts, ...rest } = init;
  const response = await exchange(fetch, peer, path, json === undefined ? rest : {
    ...rest, method: rest.method ?? 'POST', body: JSON.stringify(json),
    headers: { ...rest.headers as Record<string, string>, 'content-type': 'application/json' },
  }, { stallMs, waitMs, attempts });
  check(peer, response);
  try { return JSON.parse(response.body.toString('utf8')); } catch { return {} as T; }
}

/**
 * 按段取对端一份不会变的内容，接口要支持单段 Range（见 byte-range.ts）：先取第一段，从 Content-Range 知道整份大小，
 * 其余各段几路同时取，每段取齐了交给 write(位置, 内容)。第一段等响应头不超过 waitMs，对端可能要先把内容算出来；
 * stallMs 是两次收到数据之间算卡住的空档，默认 SEGMENT_STALL_MS。
 * 对端不认 Range（旧版）回 200 时，整份就在这个回应里。返回整份大小；对端的错误抛 PeerError。
 */
export async function peerDownload(fetch: PeerFetch, peer: Peer, path: string,
  write: (offset: number, bytes: Buffer) => void, options: { waitMs?: number; stallMs?: number; signal?: AbortSignal } = {}): Promise<number> {
  const range = async (start: number, end: number, waitMs?: number) => {
    const response = await exchange(fetch, peer, path, { headers: { Range: `bytes=${start}-${end}` }, signal: options.signal },
      { waitMs, stallMs: options.stallMs ?? SEGMENT_STALL_MS, attempts: SEGMENT_ATTEMPTS });
    check(peer, response);
    return response;
  };
  const first = await range(0, SEGMENT_BYTES - 1, options.waitMs);
  if (first.status !== 206) {
    write(0, first.body);
    return first.body.byteLength;
  }
  const total = Number(first.headers.get('content-range')?.split('/').at(-1));
  if (!Number.isSafeInteger(total) || first.body.byteLength !== Math.min(SEGMENT_BYTES, total)) throw new Error(`工作机 ${peer.id} 的分段回应无效`);
  write(0, first.body);
  const starts: number[] = [];
  for (let start = SEGMENT_BYTES; start < total; start += SEGMENT_BYTES) starts.push(start);
  await parallel(starts, SEGMENT_WORKERS, async (start) => {
    const end = Math.min(start + SEGMENT_BYTES, total) - 1;
    const part = await range(start, end);
    if (part.status !== 206 || part.body.byteLength !== end - start + 1) throw new Error(`工作机 ${peer.id} 的分段回应无效`);
    write(start, part.body);
  });
  return total;
}

/** 最多 limit 个同时跑；有一个失败就不再开新的，等跑着的都结束后抛出第一个错误。 */
export async function parallel<T>(items: T[], limit: number, run: (item: T) => Promise<void>): Promise<void> {
  let next = 0;
  let failure: { error: unknown } | undefined;
  const worker = async () => {
    while (!failure && next < items.length) {
      const item = items[next++]!;
      try { await run(item); } catch (error) { failure ??= { error }; }
    }
  };
  await Promise.all(Array.from({ length: Math.min(limit, items.length) }, worker));
  if (failure) throw failure.error;
}
