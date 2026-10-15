/**
 * 账号级数据在工作机之间的同步：每台工作机向目录里每台在线的工作机拉增量，按对方的序号续传；没有新变化时请求挂着等，
 * 对方一有变化就返回。收到的变化写进本机后也会被第三台工作机拉走，所以不必两两都直接连通。
 * 同步要按「可能一直走境外中继」设计：增量、可续传、不阻塞当前操作。
 */
import { peerJSON, type Peer, type PeerFetch } from '../peer-fetch.ts';
import type { Directory } from './directory.ts';
import type { AccountData, Changes } from './store.ts';

/** 对方没有新变化时最多等这么久再返回；要短于 HTTP 服务的空闲超时。 */
export const WAIT_SECONDS = 25;
const RETRY_MIN_MS = 1_000;
const RETRY_MAX_MS = 60_000;

export class Replication {
  private loops = new Map<string, { address: string; abort: AbortController; done: Promise<void> }>();
  private closed = false;

  constructor(private deps: {
    data: AccountData;
    directory: Directory;
    fetch: PeerFetch;
  }) {}

  /** 按目录调整：在线的工作机各有一条拉取，离线、移除或换了地址的停掉。 */
  sync(): void {
    if (this.closed) return;
    const wanted = new Map(this.deps.directory.online().map((machine) => [machine.id, machine]));
    for (const [id, loop] of this.loops) {
      if (wanted.get(id)?.address !== loop.address) { loop.abort.abort(); this.loops.delete(id); }
    }
    for (const machine of wanted.values()) if (!this.loops.has(machine.id)) this.start(machine);
  }

  async close(): Promise<void> {
    this.closed = true;
    const loops = [...this.loops.values()];
    this.loops.clear();
    for (const loop of loops) loop.abort.abort();
    await Promise.all(loops.map((loop) => loop.done));
  }

  private start(machine: Peer): void {
    const abort = new AbortController();
    const done = this.pull(machine, abort.signal).finally(() => {
      if (this.loops.get(machine.id)?.abort === abort) this.loops.delete(machine.id);
    });
    this.loops.set(machine.id, { address: machine.address, abort, done });
  }

  private async pull(machine: Peer, signal: AbortSignal): Promise<void> {
    let delay = RETRY_MIN_MS;
    while (!signal.aborted) {
      const cursor = this.deps.data.cursor(machine.id);
      const query = new URLSearchParams({ since: String(cursor?.seq ?? 0), wait: String(WAIT_SECONDS), ...(cursor ? { epoch: cursor.epoch } : {}) });
      try {
        const page = await peerJSON<Changes>(this.deps.fetch, machine, `/sync/changes?${query}`, { signal, stallMs: (WAIT_SECONDS + 30) * 1000 });
        await this.deps.data.apply(machine.id, page);
        delay = RETRY_MIN_MS;
      } catch (error) {
        if (signal.aborted) return;
        // 断线期间按退避重试，只在每轮断线的第一次记日志。
        if (delay === RETRY_MIN_MS) console.warn(`[账号数据同步] ${machine.id}：${(error as Error).message}`);
        await new Promise((resolve) => {
          const timer = setTimeout(resolve, delay);
          signal.addEventListener('abort', () => { clearTimeout(timer); resolve(undefined); }, { once: true });
        });
        delay = Math.min(delay * 2, RETRY_MAX_MS);
      }
    }
  }
}

/** 对端拉取的处理：epoch 对得上且没有新变化时等到有变化或超时。 */
export async function changesSince(data: AccountData, params: URLSearchParams, signal: AbortSignal): Promise<Changes> {
  const epoch = params.get('epoch') ?? undefined;
  const since = Math.max(0, Math.floor(Number(params.get('since') ?? 0)) || 0);
  const wait = Math.min(Math.max(Number(params.get('wait') ?? 0) || 0, 0), WAIT_SECONDS);
  if (wait > 0 && epoch === data.epoch) await data.wait(since, wait * 1000, signal);
  return data.changes(epoch, since);
}
