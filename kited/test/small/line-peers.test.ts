import { expect, test } from 'bun:test';
import type { AccountMachine } from '../../src/account-data/directory.ts';
import { Peers } from '../../src/line/peers.ts';

type PeerResponse = { endpoint: string; machine: string | null };

// 目录读取、真实 HTTP 路由与机器身份配合：一批请求保持同轮地址，之后独立按 ID 调用仍能跟随地址变更。
test('批量调用复用本轮目录且保留目标机器身份，独立按 ID 调用读取最新地址', async () => {
  const endpoints = ['first', 'second'].map((endpoint) => Bun.serve({
    hostname: '127.0.0.1', port: 0,
    fetch: (request) => Response.json({ endpoint, machine: request.headers.get('X-Kite-Machine') }),
  }));
  try {
    let directoryReads = 0;
    const peers = new Peers({
      self: () => ({ id: 'machine-self', name: '本机' }),
      fetch: (address, path, init) => fetch(new URL(path, address), init),
      machines: async (): Promise<AccountMachine[]> => {
        const firstRead = ++directoryReads === 1;
        return [
          { id: 'machine-b', name: '工作机 B', online: true, address: endpoints[firstRead ? 0 : 1]!.url.origin },
          { id: 'machine-c', name: '工作机 C', online: true, address: endpoints[firstRead ? 1 : 0]!.url.origin },
        ];
      },
    });
    const machines = await peers.machines();
    const responses = await Promise.all(machines.filter((machine) => machine.id !== 'machine-self')
      .map((machine) => peers.call<PeerResponse>(machine, 'GET', '/summary')));
    expect(responses).toEqual([
      { endpoint: 'first', machine: 'machine-b' },
      { endpoint: 'second', machine: 'machine-c' },
    ]);
    expect(directoryReads).toBe(1);

    expect(await peers.call<PeerResponse>('machine-b', 'GET', '/summary')).toEqual({ endpoint: 'second', machine: 'machine-b' });
    expect(directoryReads).toBe(2);
  } finally {
    await Promise.all(endpoints.map((endpoint) => endpoint.stop(true)));
  }
}, 1000);
