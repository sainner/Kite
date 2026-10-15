/** 真实 HTTP 监听与组网代理的认证边界，不启动组网或模型进程。 */
import { expect, test } from 'bun:test';
import { rmSync } from 'node:fs';
import { join } from 'node:path';
import { startDaemon } from '../../src/daemon.ts';
import { serve } from '../../src/http.ts';
import { connect, machine, registerCheckout, startKited } from '../harness.ts';
import { makeTemp, newDir } from '../util.ts';

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
 * 组网里不是 kited 的设备（手机等，这里是 IPv6 回环上一个 /machine 404 的服务）都拒绝；本机监听不看来源（见 peer-git.test.ts）。
 */
test('远程监听上的账号同步和检出拉取只给目录里的工作机：来源不是组网对端或对端不是 kited 时 403，是工作机时放行', async () => {
  const a = startKited();
  const b = startKited();
  // 组网里的另一台设备没有跑 kited：/machine 读不到。记下被读了几次，确认来源 IP 确实对上了它。
  let probed = 0;
  const phone = Bun.serve({ hostname: '::1', port: 0, fetch: () => { probed++; return Response.json({ error: '不是 kited' }, { status: 404 }); } });
  let proxy: ReturnType<typeof serve> | undefined;
  try {
    const registered = await registerCheckout(a, newDir(a.root, 'notes', { 'a.txt': '一\n' }));
    proxy = serve(a.daemon.kite, { hostname: '127.0.0.1', port: 0, remote: true, proxyToken: 'fixture-secret' });
    const url = proxy.url.origin;
    const machineId = a.daemon.kite.store.machine.id;
    const pulls = [
      { method: 'GET', path: '/sync/changes?wait=0' },
      { method: 'GET', path: `/git/${registered.project.id}/info/refs?service=git-upload-pack` },
      { method: 'POST', path: `/git/${registered.project.id}/git-upload-pack` },
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
