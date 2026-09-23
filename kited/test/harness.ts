/**
 * 在本进程里起一个 kited（startDaemon），KITE_HOME 是临时目录；Claude Code 指向 setup.ts 起的假端点。
 * 另有 spawnKited：按路径起 kited 子进程，只给「kited 被 SIGKILL」那种测试用。
 */
import { rmSync } from 'node:fs';
import { join } from 'node:path';
import { startDaemon, type Daemon } from '../src/daemon.ts';
import type { Envelope } from '../src/events.ts';
import { api } from './setup.ts';
import { makeTemp } from './util.ts';

export { api };

export interface Kited {
  /** 这个 kited 的临时根目录：KITE_HOME 在 root/kite，项目文件夹建在 root 下。 */
  root: string;
  home: string;
  url: string;
  daemon: Daemon;
  /** 收到的事件（全部会话），按发生顺序。 */
  events: Envelope[];
  call(method: string, path: string, body?: unknown): Promise<{ status: number; body: any }>;
  /** 等满足条件的事件（已收到的也算）。 */
  waitEvent(pred: (e: Envelope) => boolean, timeoutMs?: number): Promise<Envelope>;
  /** 放行假端点上挂着的请求，停掉 kited，删掉临时目录。 */
  stop(): Promise<void>;
}

export async function call(url: string, method: string, path: string, body?: unknown): Promise<{ status: number; body: any }> {
  const r = await fetch(url + path, {
    method,
    headers: body === undefined ? {} : { 'content-type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  return { status: r.status, body: await r.json() };
}

export function startKited(): Kited {
  const root = makeTemp('kited-');
  const home = join(root, 'kite');
  const daemon = startDaemon({ home, port: 0 });
  const events: Envelope[] = [];
  const waiters: Array<{ pred: (e: Envelope) => boolean; resolve: (e: Envelope) => void }> = [];
  const unsubscribe = daemon.kite.bus.subscribe(undefined, (e) => {
    events.push(e);
    for (const w of [...waiters]) if (w.pred(e)) { waiters.splice(waiters.indexOf(w), 1); w.resolve(e); }
  });
  return {
    root, home, daemon, events,
    url: daemon.url,
    call: (method, path, body) => call(daemon.url, method, path, body),
    waitEvent(pred, timeoutMs = 10_000) {
      const hit = events.find(pred);
      if (hit) return Promise.resolve(hit);
      return new Promise((resolve, reject) => {
        const w = { pred, resolve: (e: Envelope) => { clearTimeout(t); resolve(e); } };
        const t = setTimeout(() => { waiters.splice(waiters.indexOf(w), 1); reject(new Error('等待事件超时')); }, timeoutMs);
        waiters.push(w);
      });
    },
    async stop() {
      api.releaseAll();
      unsubscribe();
      await daemon.stop();
      rmSync(root, { recursive: true, force: true });
    },
  };
}

// ---- 接口的常用组合 ----

export async function registerProject(k: Kited, path: string): Promise<any> {
  const r = await k.call('POST', '/projects', { path });
  if (r.status !== 200) throw new Error(`登记 ${path} 失败：${r.status} ${JSON.stringify(r.body)}`);
  return r.body;
}

/** 新建会话，立即返回视图（准备过程看事件）。 */
export async function createSession(k: Kited, project: string, prompt: string): Promise<any> {
  const r = await k.call('POST', '/sessions', { project, prompt });
  if (r.status !== 200) throw new Error(`建会话失败：${r.status} ${JSON.stringify(r.body)}`);
  return r.body;
}

export async function sendMessage(k: Kited, id: string, text: string): Promise<void> {
  const r = await k.call('POST', `/sessions/${id}/messages`, { text });
  if (r.status !== 200) throw new Error(`发消息失败：${r.status} ${JSON.stringify(r.body)}`);
}

export async function listSnapshots(k: Kited, id: string): Promise<Array<{ commit: string; at: number; label: string; toolUseIds: string[] }>> {
  const r = await k.call('GET', `/sessions/${id}/snapshots`);
  if (r.status !== 200) throw new Error(`取快照失败：${r.status} ${JSON.stringify(r.body)}`);
  return r.body;
}

/** 事件下标，配合 after 判断事件是否发生在某个动作之后。 */
export const mark = (k: Kited) => k.events.length;
export const after = (k: Kited, since: number) => (e: Envelope) => k.events.indexOf(e) >= since;

/** 等 since 之后这个会话的 runner 变为 state。 */
export function waitRunner(k: Kited, id: string, state: string, since = 0, timeoutMs?: number) {
  const isAfter = after(k, since);
  return k.waitEvent((e) => e.session === id && e.type === 'runner' && e.state === state && isAfter(e), timeoutMs);
}

// ---- kited 子进程 ----

export interface KitedProcess {
  url: string;
  pid: number;
  kill(signal: NodeJS.Signals): Promise<void>;
}

/** 按路径起 kited 子进程（bun src/main.ts），等它在标准输出报出地址。 */
export async function spawnKited(home: string): Promise<KitedProcess> {
  const main = join(import.meta.dir, '..', 'src', 'main.ts');
  const proc = Bun.spawn([process.execPath, main], {
    env: { ...(process.env as Record<string, string>), KITE_HOME: home, KITE_PORT: '0' },
    stdout: 'pipe',
    stderr: 'inherit',
  });
  const reader = proc.stdout.getReader();
  const decoder = new TextDecoder();
  let out = '';
  while (!out.includes('\n')) {
    const { value, done } = await reader.read();
    if (done) throw new Error(`kited 没有启动：${out}`);
    out += decoder.decode(value, { stream: true });
  }
  // 之后的输出照样读走，免得管道写满卡住 kited
  void (async () => { try { while (!(await reader.read()).done); } catch { /* 进程已退出 */ } })();
  const m = /http:\/\/127\.0\.0\.1:\d+/.exec(out.split('\n')[0]!);
  if (!m) throw new Error(`kited 第一行输出里没有地址：${out}`);
  return {
    url: m[0],
    pid: proc.pid,
    async kill(signal) { proc.kill(signal); await proc.exited; },
  };
}
