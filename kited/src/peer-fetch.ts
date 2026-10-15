/** 访问另一台工作机的 kited：组网上经 kite-net 的本机 HTTP 代理，测试里同一进程的几台直接访问；由 Kite 统一决定。 */
export type PeerFetch = (address: string, path: string, init?: RequestInit) => Promise<Response>;

/** 一台在线的工作机：机器 ID 与组网上的访问地址。 */
export interface Peer { id: string; address: string }

/**
 * 请求另一台工作机的接口：带上它的机器 ID，非 2xx 时抛错并带上对端的说明，返回 JSON。
 * stallMs 按进度计时：等响应头、等下一段正文都不超过它，总时长不限，走境外中继的大页传得慢也能传完，对端没了才放弃。
 */
export async function peerJSON<T>(fetch: PeerFetch, peer: Peer, path: string,
  init: RequestInit & { json?: unknown; stallMs?: number } = {}): Promise<T> {
  const { json, stallMs, ...rest } = init;
  const stalled = new AbortController();
  let timer: ReturnType<typeof setTimeout> | undefined;
  const progress = () => {
    clearTimeout(timer);
    if (stallMs) timer = setTimeout(() => stalled.abort(new Error(`工作机 ${peer.id} 超过 ${Math.round(stallMs / 1000)} 秒没有响应`)), stallMs);
  };
  progress();
  try {
    const response = await fetch(peer.address, path, { ...rest, ...(json === undefined ? {} : { method: rest.method ?? 'POST', body: JSON.stringify(json) }),
      signal: rest.signal ? AbortSignal.any([rest.signal, stalled.signal]) : stalled.signal,
      headers: { ...rest.headers as Record<string, string>, 'X-Kite-Machine': peer.id, ...(json === undefined ? {} : { 'content-type': 'application/json' }) } });
    const chunks: Uint8Array[] = [];
    if (response.body) {
      const reader = response.body.getReader();
      const cancel = () => { void reader.cancel(stalled.signal.reason).catch(() => {}); };
      stalled.signal.addEventListener('abort', cancel, { once: true });
      try {
        for (;;) {
          progress();
          const { value, done } = await reader.read();
          if (stalled.signal.aborted) throw stalled.signal.reason;
          if (done) break;
          chunks.push(value);
        }
      } finally { stalled.signal.removeEventListener('abort', cancel); }
    }
    let data: T & { error?: unknown };
    try { data = JSON.parse(Buffer.concat(chunks).toString('utf8')); } catch { data = {} as T & { error?: unknown }; }
    if (!response.ok) throw new Error(`工作机 ${peer.id} 返回 ${response.status}${typeof data.error === 'string' ? `：${data.error}` : ''}`);
    return data;
  } catch (error) {
    throw stalled.signal.aborted ? stalled.signal.reason : error;
  } finally { clearTimeout(timer); }
}
