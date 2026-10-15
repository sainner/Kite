/**
 * Line 所在的 kited 调用同一用户的其他工作机：从工作机目录（account-data/directory.ts）找组网地址，按 Kite 给的方式访问（组网上经 kite-net 的本机代理）；本机走本机监听。
 * 请求带 X-Kite-Machine 防止连错机器，带 X-Kite-Source 声明「代理 Line」；对端只记录来源，授权在 Line 所在机器检查。
 */
import { KiteError } from '../errors.ts';
import type { AccountMachine } from '../account-data/directory.ts';
import type { InputVia } from '../harness/types.ts';
import type { PeerFetch } from '../peer-fetch.ts';

export interface PeerOptions {
  /** 本机身份与本机监听地址（服务起来后才有）。 */
  self(): { id: string; name: string; url?: string };
  /** 工作机目录；测试里换成同一进程里几台 kited 的本机地址。 */
  machines(): Promise<AccountMachine[]>;
  /** 访问别的工作机。 */
  fetch: PeerFetch;
}

export class PeerError extends KiteError {
  constructor(message: string, status: number, readonly body: Record<string, unknown> = {}) { super(message, status); }
}

export class Peers {
  constructor(private options: PeerOptions) {}

  /** 全部工作机，本机排在最前；目录读不到时只有本机。 */
  async machines(): Promise<AccountMachine[]> {
    const self = this.options.self();
    let listed: AccountMachine[] = [];
    try { listed = await this.options.machines(); }
    catch (error) { console.error(`[Line] 读取工作机目录失败：${(error as Error).message}`); }
    return [{ id: self.id, name: self.name, online: true, ...(self.url ? { address: self.url } : {}) },
      ...listed.filter((machine) => machine.id !== self.id)];
  }

  /**
   * 调用一台工作机的 HTTP 接口；传 ID 时现查目录，批量读取可传同轮目录里的工作机。
   * 非 2xx 抛 PeerError，带对端的状态码与正文。timeoutMs 默认 30 秒。
   * signal 是调用方回合的停止：停下只是不再等，请求可能已经送到，对端照样做完。
   */
  async call<T = any>(target: string | AccountMachine, method: string, path: string,
    options: { body?: unknown; via?: InputVia; timeoutMs?: number; signal?: AbortSignal } = {}): Promise<T> {
    const machineId = typeof target === 'string' ? target : target.id;
    const self = this.options.self();
    let base: string | undefined;
    if (machineId === self.id) base = self.url;
    else {
      const machine = typeof target === 'string' ? (await this.machines()).find((entry) => entry.id === machineId) : target;
      if (!machine) throw new KiteError(`工作机目录里没有这台工作机：${machineId}`, 404);
      base = machine.address;
    }
    if (!base) throw new KiteError('这台工作机还没有组网地址，可能不在线', 409);
    const init: RequestInit = {
      method,
      headers: { 'X-Kite-Machine': machineId, ...(options.via ? { 'X-Kite-Source': JSON.stringify(options.via) } : {}),
        ...(options.body === undefined ? {} : { 'content-type': 'application/json' }) },
      body: options.body === undefined ? undefined : JSON.stringify(options.body),
      signal: AbortSignal.any([AbortSignal.timeout(options.timeoutMs ?? 30_000), ...(options.signal ? [options.signal] : [])]),
    };
    let response: Response;
    try {
      response = machineId === self.id ? await fetch(new URL(path, base), init) : await this.options.fetch(base, path, init);
    } catch (error) {
      if (error instanceof KiteError) throw error;
      if (options.signal?.aborted) throw new KiteError(`已停止，不再等工作机 ${machineId} 的结果；请求可能已经送到`);
      throw new KiteError(`连不上工作机 ${machineId}：${(error as Error).message}`, 502);
    }
    const data = await response.json().catch(() => ({})) as Record<string, unknown>;
    if (!response.ok) throw new PeerError(typeof data.error === 'string' ? data.error : `工作机返回 ${response.status}`, response.status, data);
    return data as T;
  }
}
