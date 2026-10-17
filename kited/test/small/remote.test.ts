/**
 * 真实 HTTP 监听与组网代理的认证边界，不启动组网或模型进程；
 * 以及受管网络通道的本机接口与 kite-net 子进程的交接，kite-net 换成记录自身环境的假程序。
 */
import { expect, test } from 'bun:test';
import { chmodSync, existsSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { startDaemon } from '../../src/daemon.ts';
import { serve } from '../../src/http.ts';
import type { NetworkChannel } from '../../src/network.ts';
import { addProject, call, connect, machine, startKited } from '../harness.ts';
import { makeTemp, newDir, until } from '../util.ts';

function start() {
  const root = makeTemp('kite-remote-');
  const daemon = startDaemon({ home: join(root, 'kite'), port: 0, lightTasks: false });
  return {
    daemon,
    async stop() {
      try { await daemon.stop(); }
      finally { rmSync(root, { recursive: true, force: true }); }
    },
  };
}

function remote(url: string, path: string, opts: {
  method?: string; token?: string; proxyToken?: string; machineId?: string; signal?: AbortSignal;
} = {}) {
  const headers: Record<string, string> = {};
  if (opts.token) headers.authorization = `Bearer ${opts.token}`;
  if (opts.proxyToken) headers['X-Kite-Network'] = opts.proxyToken;
  if (opts.machineId) headers['X-Kite-Machine'] = opts.machineId;
  return fetch(url + path, { method: opts.method ?? 'GET', headers, signal: opts.signal });
}

// startDaemon 必须把运行时生成的代理凭据接入真实远程监听；客户端 bearer 与伪造网络头不能穿透它。
test('真实远程监听拒绝外部 bearer 和伪造网络凭据', async () => {
  const k = start();
  try {
    const d = k.daemon;
    const machineId = (await machine(d.url)).id;
    for (const credentials of [
      {}, { token: 'external-account-session' },
      { proxyToken: 'fixture-secret' },
      { token: 'external-account-session', proxyToken: 'fixture-secret' },
    ]) {
      for (const path of ['/machine', '/events']) {
        expect((await remote(d.remoteUrl, path, { ...credentials, machineId })).status).toBe(401);
      }
    }
  } finally { await k.stop(); }
}, 1_000);

// 已验证的代理和机器身份检查、仅本机管理路由、SSE 订阅共用 HTTP 路由，认证成功不能绕过其余边界。
test('受信代理仍需正确机器身份且不能管理组网，目录事件流可读并可取消', async () => {
  const k = start();
  let proxy: ReturnType<typeof serve> | undefined;
  const controller = new AbortController();
  try {
    const d = k.daemon;
    const machineId = (await machine(d.url)).id;
    proxy = serve(d.kite, { hostname: '127.0.0.1', port: 0, remote: true, proxyToken: 'fixture-secret' });
    const url = proxy.url.origin;
    expect((await remote(url, '/machine', { token: 'fixture-secret' })).status).toBe(401);
    expect((await remote(url, '/machine', { proxyToken: 'wrong-secret' })).status).toBe(401);
    const verified = await remote(url, '/machine', { proxyToken: 'fixture-secret' });
    expect(verified.status).toBe(200);
    expect((await verified.json() as { id: string }).id).toBe(machineId);

    expect((await remote(url, '/events', { proxyToken: 'fixture-secret' })).status).toBe(400);
    expect((await remote(url, '/events', { proxyToken: 'fixture-secret', machineId: 'wrong-machine' })).status).toBe(409);
    for (const method of ['GET', 'PUT']) {
      expect((await remote(url, '/network', { method, proxyToken: 'fixture-secret', machineId })).status).toBe(404);
    }
    const events = await remote(url, '/events', { proxyToken: 'fixture-secret', machineId, signal: controller.signal });
    expect(events.status).toBe(200);
    const reader = events.body!.pipeThrough(new TextDecoderStream()).getReader();
    try {
      let first = '';
      while (!first.includes('\n\n')) {
        const next = await reader.read();
        if (next.done) throw new Error('收到目录快照前事件流已结束');
        first += next.value;
      }
      expect(first).toContain('catalog.snapshot');
      await reader.cancel();
      expect((await reader.read()).done).toBe(true);
    } finally { reader.releaseLock(); }
  } finally {
    controller.abort();
    try { await proxy?.stop(true); }
    finally { await k.stop(); }
  }
}, 1_000);

/*
 * 几个部分的配合：组网来的拉取（账号级数据的 /sync/changes，没有远程的项目的 /git/:project）只给目录里的工作机，
 * 按 kite-net 给的来源 IP（X-Kite-Peer）找组网对端，再读它的 /machine 确认是 kited。不在组网对端里的地址、
 * 组网里不是 kited 的设备（手机等，这里是 IPv6 回环上一个 /machine 404 的服务）都拒绝；本机监听不看来源（见 projects.test.ts 里没有远程的项目一段）。
 */
test('远程监听上的账号同步和检出拉取只给目录里的工作机：来源不是组网对端或对端不是 kited 时 403，是工作机时放行', async () => {
  const a = startKited();
  const b = startKited();
  // 组网里的另一台设备没有跑 kited：/machine 读不到。记下被读了几次，确认来源 IP 确实对上了它。
  let probed = 0;
  const phone = Bun.serve({ hostname: '::1', port: 0, fetch: () => { probed++; return Response.json({ error: '不是 kited' }, { status: 404 }); } });
  let proxy: ReturnType<typeof serve> | undefined;
  try {
    const registered = await addProject(a, { path: newDir(a.root, 'notes', { 'a.txt': '一\n' }) });
    proxy = serve(a.daemon.kite, { hostname: '127.0.0.1', port: 0, remote: true, proxyToken: 'fixture-secret' });
    const url = proxy.url.origin;
    const machineId = a.daemon.kite.store.machine.id;
    const pulls = [
      { method: 'GET', path: '/sync/changes?wait=0' },
      { method: 'GET', path: `/git/${registered.id}/info/refs?service=git-upload-pack` },
      { method: 'POST', path: `/git/${registered.id}/git-upload-pack` },
    ];
    const from = (peer: string, requests = pulls) => Promise.all(requests.map(async ({ method, path }) => {
      const response = await fetch(url + path, { method,
        headers: { 'X-Kite-Network': 'fixture-secret', 'X-Kite-Machine': machineId, 'X-Kite-Peer': peer } });
      await response.arrayBuffer();
      return response.status;
    }));

    a.candidates.push({ address: `http://[::1]:${phone.port}`, online: true });
    expect(await from('100.64.0.9')).toEqual([403, 403, 403]);
    expect(probed).toBe(0);
    expect(await from('::1')).toEqual([403, 403, 403]);
    expect(probed).toBeGreaterThan(0);

    await connect(a, b);
    expect(await from('127.0.0.1', pulls.slice(0, 2))).toEqual([200, 200]);
  } finally {
    await proxy?.stop(true);
    await phone.stop(true);
    await b.stop();
    await a.stop();
  }
}, 1_000);

// ---- 受管网络通道 ----

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
