/** 受管网络通道的本机接口与 kite-net 子进程的交接；kite-net 换成记录自身环境的假程序。 */
import { expect, test } from 'bun:test';
import { chmodSync, existsSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { startDaemon } from '../../src/daemon.ts';
import type { NetworkChannel } from '../../src/network.ts';
import { call, machine } from '../harness.ts';
import { makeTemp, until } from '../util.ts';

const PUBLIC_KEY = 'Q'.repeat(43) + '=';

/**
 * 假 kite-net：带 key 参数时像真程序一样只往标准输出写一行 {"publicKey": ...}；
 * 否则作为组网节点运行，往 log 追加一行「pid、KITE_NET_CHANNEL 是否存在、它的值」，报 Running 后常驻。
 * exec 换成 sleep 保持同一个 pid，kited 停进程时的信号直接落在它身上。
 */
function fakeKiteNet(dir: string, log: string): string {
  const path = join(dir, 'kite-net');
  writeFileSync(path, [
    '#!/bin/sh',
    'if [ "$1" = key ]; then',
    `  printf '{"publicKey":"%s"}\\n' '${PUBLIC_KEY}'`,
    '  exit 0',
    'fi',
    `printf '%s\\t%s\\t%s\\n' "$$" "\${KITE_NET_CHANNEL+set}" "\${KITE_NET_CHANNEL-}" >> '${log}'`,
    `echo '{"state":"Running"}'`,
    'exec /bin/sleep 30',
    '',
  ].join('\n'));
  chmodSync(path, 0o755);
  return path;
}

interface Start { pid: number; channel?: unknown }

/** 假 kite-net 每次启动记下的一行；写到一半的行不算。 */
function starts(log: string): Start[] {
  if (!existsSync(log)) return [];
  return readFileSync(log, 'utf8').split('\n').slice(0, -1).map((line) => {
    const [pid, set, value] = line.split('\t');
    return { pid: Number(pid), ...(set === 'set' ? { channel: JSON.parse(value!) } : {}) };
  });
}

const alive = (pid: number) => { try { process.kill(pid, 0); return true; } catch { return false; } };

// kited 与 kite-net 跨进程交接：改通道要先停掉旧进程再起新进程，配置只经新进程的环境变量 KITE_NET_CHANNEL 传过去；
// 无效配置被拒时旧进程不能被动。依赖 sh 的 ${VAR+set} 区分环境变量未设置与设为空。
test('设置受管网络通道后组网节点换成带 KITE_NET_CHANNEL 的新进程，无效配置被拒且不重启，清除后新进程不带它', async () => {
  const root = makeTemp('kite-channel-');
  const log = join(root, 'starts.log');
  const daemon = startDaemon({ home: join(root, 'kite'), port: 0, lightTasks: false, networkBinary: fakeKiteNet(root, log) });
  try {
    const machineId = (await machine(daemon.url)).id;
    const request = (method: string, path: string, body?: unknown) => call(daemon.url, method, path, body, machineId);

    expect((await request('GET', '/network/channel')).body).toEqual({ channel: null });
    const joined = await request('PUT', '/network', { enabled: true });
    expect(joined.status).toBe(200);
    const [first] = await until(() => starts(log).length === 1 && starts(log), '组网节点启动');
    expect(first!.channel).toBeUndefined();

    const valid = { endpoint: '192.168.31.1:51830', routerKey: 'R'.repeat(43) + '=', address4: '10.77.0.2/32', address6: 'fd00:77::2/128' };
    const configured: NetworkChannel = { endpoint: '192.168.31.1:51830', routerKey: 'R'.repeat(43) + '=', address4: '10.77.0.2', address6: 'fd00:77::2' };
    expect((await request('PUT', '/network/channel', valid)).status).toBe(200);
    expect(alive(first!.pid)).toBe(false);
    const second = (await until(() => starts(log).length === 2 && starts(log), '设置通道后组网节点重启'))[1]!;
    expect(second.channel).toEqual(configured);
    expect((await request('GET', '/network/channel')).body).toEqual({ channel: configured });

    for (const invalid of [
      { ...valid, endpoint: 'router.lan:51830' },
      { ...valid, routerKey: 'ab'.repeat(32) },
      { ...valid, address4: '10.77.0.256' },
      { ...valid, address6: 'fd00:77::zz' },
    ]) {
      expect((await request('PUT', '/network/channel', invalid)).status).toBe(400);
    }
    expect((await request('GET', '/network/channel')).body).toEqual({ channel: configured });
    expect(alive(second.pid)).toBe(true);

    expect((await request('DELETE', '/network/channel')).status).toBe(200);
    expect(alive(second.pid)).toBe(false);
    const all = await until(() => starts(log).length >= 3 && starts(log), '清除通道后组网节点重启');
    // 无效配置若触发过重启，这里会多出一次启动。
    expect(all).toHaveLength(3);
    expect(all[2]!.channel).toBeUndefined();
    expect((await request('GET', '/network/channel')).body).toEqual({ channel: null });

    expect((await request('GET', '/network/channel/key')).body).toEqual({ publicKey: PUBLIC_KEY });
  } finally {
    try { await daemon.stop(); }
    finally { rmSync(root, { recursive: true, force: true }); }
  }
});
