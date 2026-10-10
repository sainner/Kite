/** 真实 HTTP 监听与组网代理的认证边界，不启动组网或模型进程。 */
import { expect, test } from 'bun:test';
import { rmSync } from 'node:fs';
import { join } from 'node:path';
import { startDaemon } from '../../src/daemon.ts';
import { serve } from '../../src/http.ts';
import { machine } from '../harness.ts';
import { makeTemp } from '../util.ts';

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
