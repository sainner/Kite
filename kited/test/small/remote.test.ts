/**
 * 远程设备配对与认证：本进程里起带远程监听的 kited，经两个 HTTP 监听驱动，不启动 Claude Code。
 */
import { afterEach, expect, test } from 'bun:test';
import { join } from 'node:path';
import { startDaemon, type Daemon } from '../../src/daemon.ts';
import { call, machine } from '../harness.ts';
import { useTemp } from '../util.ts';

const temp = useTemp();
let daemon: Daemon | undefined;
afterEach(async () => { await daemon?.stop(); daemon = undefined; });

function start(): Daemon {
  daemon = startDaemon({ home: join(temp(), 'kite'), port: 0, lightTasks: false });
  return daemon;
}

/** 请求远程监听；token 省略时不带 Authorization，machineId 省略时不带 X-Kite-Machine。 */
function remote(d: Daemon, method: string, path: string, opts: { token?: string; machineId?: string; body?: unknown; signal?: AbortSignal } = {}) {
  const headers: Record<string, string> = {};
  if (opts.token) headers.authorization = `Bearer ${opts.token}`;
  if (opts.machineId) headers['X-Kite-Machine'] = opts.machineId;
  if (opts.body !== undefined) headers['content-type'] = 'application/json';
  return fetch(d.remoteUrl! + path, {
    method, headers, signal: opts.signal, body: opts.body === undefined ? undefined : JSON.stringify(opts.body),
  });
}

/** 本机生成配对码，远程用它换取令牌。 */
async function pair(d: Daemon, name: string, transform = (code: string) => code) {
  const created = await call(d.url, 'POST', '/pairings');
  expect(created.status).toBe(200);
  const res = await remote(d, 'POST', '/pair', { body: { code: transform(created.body.code), name } });
  return { pairing: created.body as { code: string; expiresAt: number; address: string }, res };
}

/*
 * 两个 Bun.serve 监听共用一套路由：本机管理设备的接口和远程配对接口只能各在一边出现，
 * 远程除配对外一律要令牌（含 /machine 与 SSE），配对码换过一次就作废。
 */
test('远程监听未带令牌一律 401，设备管理与配对接口互不跨监听，配对码不分大小写和短横线且只能用一次', async () => {
  const d = start();
  expect(d.remoteUrl).toBeDefined();
  const machineId = (await machine(d.url)).id;

  expect((await remote(d, 'GET', '/machine')).status).toBe(401);
  expect((await remote(d, 'GET', '/events', { machineId })).status).toBe(401);
  expect((await remote(d, 'GET', '/machine', { token: 'not-a-token' })).status).toBe(401);
  expect((await fetch(`${d.url}/pair`, {
    method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ code: 'AAAA-BBBB', name: '本机' }),
  })).status).toBe(404);

  const { pairing, res } = await pair(d, '我的 iPhone', (code) => code.toLowerCase().replace('-', ''));
  // 不用 toMatchObject 加 expect.any：Bun（1.3.14、1.4.2 实测）会把非对称匹配器写回被比较的对象。
  expect([typeof pairing.code, typeof pairing.expiresAt]).toEqual(['string', 'number']);
  // 组网未开启时没有可告诉远程设备的地址。
  expect(pairing.address).toBeNull();
  expect(res.status).toBe(200);
  const paired = await res.json() as { machine: { id: string }; device: { id: string; name: string }; token: string };
  expect(paired.machine.id).toBe(machineId);
  expect(paired.device.name).toBe('我的 iPhone');

  const reused = await remote(d, 'POST', '/pair', { body: { code: pairing.code, name: '另一台' } });
  expect(reused.status).toBe(401);

  const token = paired.token;
  const machineRes = await remote(d, 'GET', '/machine', { token });
  expect(machineRes.status).toBe(200);
  expect((await machineRes.json() as { id: string }).id).toBe(machineId);
  const ctl = new AbortController();
  try {
    const events = await remote(d, 'GET', '/events', { token, machineId, signal: ctl.signal });
    expect(events.status).toBe(200);
  } finally { ctl.abort(); }

  for (const [method, path] of [['POST', '/pairings'], ['GET', '/devices'], ['DELETE', `/devices/${paired.device.id}`]] as const) {
    expect({ path, status: (await remote(d, method, path, { token, machineId })).status }).toEqual({ path, status: 404 });
  }
  const listed = await call(d.url, 'GET', '/devices');
  expect(listed.status).toBe(200);
  expect(JSON.stringify(listed.body)).toContain(paired.device.id);
});

/* 撤销要跨到另一监听上已建立的 ReadableStream：Devices.watch 登记的关闭须让客户端读到结束，而不是等下一次请求。 */
test('撤销设备后它已建立的远程事件流立即结束，此后令牌失效', async () => {
  const d = start();
  const machineId = (await machine(d.url)).id;
  const { res } = await pair(d, '要撤销的设备');
  expect(res.status).toBe(200);
  const { device, token } = await res.json() as { device: { id: string }; token: string };

  const ctl = new AbortController();
  try {
    const events = await remote(d, 'GET', '/events', { token, machineId, signal: ctl.signal });
    expect(events.status).toBe(200);
    const reader = events.body!.pipeThrough(new TextDecoderStream()).getReader();
    let buf = '';
    while (!buf.includes('\n\n')) {
      const { value, done } = await reader.read();
      if (done) throw new Error('撤销前事件流就结束了');
      buf += value;
    }
    expect(buf).toContain('catalog.snapshot');

    expect((await call(d.url, 'DELETE', `/devices/${device.id}`)).status).toBe(200);
    while (true) {
      const { done } = await reader.read();
      if (done) break;
    }
  } finally { ctl.abort(); }

  expect((await remote(d, 'GET', '/machine', { token })).status).toBe(401);
  expect((await remote(d, 'GET', '/events', { token, machineId })).status).toBe(401);
  const listed = await call(d.url, 'GET', '/devices');
  expect(JSON.stringify(listed.body)).not.toContain(device.id);
});
