/**
 * Line 所在的 kited 调用同账号的工作机：从账号目录找组网地址，经 kite-net 的本机 HTTP 代理过去；本机走本机监听。
 * 请求带 X-Kite-Machine 防止连错机器，带 X-Kite-Source 声明「代理 Line」；对端只记录来源，授权在 Line 所在机器检查。
 */
import { KiteError } from '../errors.ts';
import type { AccountClient, AccountMachine } from '../account-client.ts';
import type { InputVia } from '../harness/types.ts';

export interface PeerOptions {
  /** 本机身份与本机监听地址（服务起来后才有）。 */
  self(): { id: string; name: string; url?: string };
  account: AccountClient;
  /** kite-net 的本机 HTTP 代理端口；组网没开时没有。 */
  proxyPort(): number | undefined;
  /** 测试里替换目录与地址：同一进程里的几台 kited 直接互相访问。 */
  directory?(): Promise<AccountMachine[]>;
}

export class PeerError extends KiteError {
  constructor(message: string, status: number, readonly body: Record<string, unknown> = {}) { super(message, status); }
}

export class Peers {
  constructor(private options: PeerOptions) {}

  /** 账号下的全部工作机，本机排在最前；目录读不到时只有本机。 */
  async machines(): Promise<AccountMachine[]> {
    const self = this.options.self();
    let listed: AccountMachine[] = [];
    try { listed = await (this.options.directory?.() ?? this.options.account.machines()); }
    catch (error) { console.error(`[Line] 读取账号目录失败：${(error as Error).message}`); }
    return [{ id: self.id, name: self.name, online: true, ...(self.url ? { address: self.url } : {}) },
      ...listed.filter((machine) => machine.id !== self.id)];
  }

  /**
   * 调用一台工作机的 HTTP 接口；非 2xx 抛 PeerError，带对端的状态码与正文。timeoutMs 默认 30 秒。
   * signal 是调用方回合的停止：停下只是不再等，请求可能已经送到，对端照样做完。
   */
  async call<T = any>(machineId: string, method: string, path: string,
    options: { body?: unknown; via?: InputVia; timeoutMs?: number; signal?: AbortSignal } = {}): Promise<T> {
    const self = this.options.self();
    let base: string | undefined;
    let proxy: string | undefined;
    if (machineId === self.id) base = self.url;
    else {
      const machine = (await this.machines()).find((entry) => entry.id === machineId);
      if (!machine) throw new KiteError(`账号目录里没有这台工作机：${machineId}`, 404);
      base = machine.address;
      if (!this.options.directory) {
        const port = this.options.proxyPort();
        if (!port) throw new KiteError('这台工作机没有开启组网，连不到其他工作机', 409);
        proxy = `http://127.0.0.1:${port}`;
      }
    }
    if (!base) throw new KiteError('这台工作机还没有组网地址，可能不在线', 409);
    let response: Response;
    try {
      response = await fetch(new URL(path, base), {
        method, ...(proxy ? { proxy } : {}),
        headers: { 'X-Kite-Machine': machineId, ...(options.via ? { 'X-Kite-Source': JSON.stringify(options.via) } : {}),
          ...(options.body === undefined ? {} : { 'content-type': 'application/json' }) },
        body: options.body === undefined ? undefined : JSON.stringify(options.body),
        signal: AbortSignal.any([AbortSignal.timeout(options.timeoutMs ?? 30_000), ...(options.signal ? [options.signal] : [])]),
      });
    } catch (error) {
      if (options.signal?.aborted) throw new KiteError(`已停止，不再等工作机 ${machineId} 的结果；请求可能已经送到`);
      throw new KiteError(`连不上工作机 ${machineId}：${(error as Error).message}`, 502);
    }
    const data = await response.json().catch(() => ({})) as Record<string, unknown>;
    if (!response.ok) throw new PeerError(typeof data.error === 'string' ? data.error : `工作机返回 ${response.status}`, response.status, data);
    return data as T;
  }
}
