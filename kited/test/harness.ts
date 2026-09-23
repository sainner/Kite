/**
 * 测试用：在隔离环境里起一个 kited 子进程，Claude Code 指向假端点。
 * 隔离 HOME、CLAUDE_CONFIG_DIR 和 KITE_HOME，不读用户的设置，不耗额度。
 */
import { mkdirSync, mkdtempSync, realpathSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { startFakeApi } from './fake-api.ts';

const MAIN = join(import.meta.dir, '..', 'src', 'main.ts');

export interface Kited {
  root: string;
  url: string;
  env: Record<string, string>;
  api: ReturnType<typeof startFakeApi>;
  call(method: string, path: string, body?: unknown): Promise<{ status: number; body: any }>;
  /** 收集到的事件（全部会话）。 */
  events: any[];
  /** 等到满足条件的事件（已收到的也算）。 */
  waitEvent(pred: (e: any) => boolean, timeoutMs?: number): Promise<any>;
  restart(signal?: NodeJS.Signals): Promise<void>;
  stop(): Promise<void>;
}

/** extraEnv 追加或覆盖 kited 的环境变量。 */
export async function startKited(extraEnv: Record<string, string> = {}): Promise<Kited> {
  const root = realpathSync(mkdtempSync(join(tmpdir(), 'kited-test-')));
  const api = startFakeApi();
  for (const d of ['home', 'claude', 'kite']) mkdirSync(join(root, d));
  const env: Record<string, string> = {
    PATH: `${process.execPath.replace(/\/bun$/, '')}:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin`,
    HOME: join(root, 'home'),
    TMPDIR: process.env.TMPDIR ?? '/tmp',
    LANG: 'en_US.UTF-8',
    USER: process.env.USER ?? 'u',
    SHELL: '/bin/zsh',
    CLAUDE_CONFIG_DIR: join(root, 'claude'),
    ANTHROPIC_BASE_URL: `http://127.0.0.1:${api.port}`,
    ANTHROPIC_API_KEY: 'sk-ant-fake',
    CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC: '1',
    KITE_HOME: join(root, 'kite'),
    KITE_PORT: '0',
    ...extraEnv,
  };

  let proc: ReturnType<typeof Bun.spawn>;
  let url = '';
  const events: any[] = [];
  const waiters: Array<{ pred: (e: any) => boolean; resolve: (e: any) => void }> = [];
  let abort: AbortController;

  async function launch() {
    proc = Bun.spawn([process.execPath, MAIN], { env, stdout: 'pipe', stderr: 'inherit' });
    const reader = (proc.stdout as ReadableStream<Uint8Array>).getReader();
    const decoder = new TextDecoder();
    let out = '';
    while (!/http:\/\/127\.0\.0\.1:\d+/.test(out)) {
      const { value, done } = await reader.read();
      if (done) throw new Error(`kited 没有启动：${out}`);
      out += decoder.decode(value, { stream: true });
    }
    url = /http:\/\/127\.0\.0\.1:\d+/.exec(out)![0];
    abort = new AbortController();
    const res = await fetch(`${url}/events`, { signal: abort.signal });
    void (async () => {
      const r = res.body!.pipeThrough(new TextDecoderStream()).getReader();
      let buf = '';
      try {
        while (true) {
          const { value, done } = await r.read();
          if (done) return;
          buf += value;
          let i: number;
          while ((i = buf.indexOf('\n\n')) >= 0) {
            const data = buf.slice(0, i).split('\n').find((l) => l.startsWith('data: '));
            buf = buf.slice(i + 2);
            if (!data) continue;
            const e = JSON.parse(data.slice(6));
            events.push(e);
            for (const w of [...waiters]) if (w.pred(e)) { waiters.splice(waiters.indexOf(w), 1); w.resolve(e); }
          }
        }
      } catch { /* 连接被中止 */ }
    })();
  }
  await launch();

  const k: Kited = {
    root, env, api, events,
    get url() { return url; },
    async call(method, path, body) {
      const r = await fetch(url + path, {
        method,
        headers: body === undefined ? {} : { 'content-type': 'application/json' },
        body: body === undefined ? undefined : JSON.stringify(body),
      });
      return { status: r.status, body: await r.json() };
    },
    waitEvent(pred, timeoutMs = 60_000) {
      const hit = events.find(pred);
      if (hit) return Promise.resolve(hit);
      return new Promise((resolve, reject) => {
        const t = setTimeout(() => reject(new Error('等待事件超时')), timeoutMs);
        waiters.push({ pred, resolve: (e) => { clearTimeout(t); resolve(e); } });
      });
    },
    async restart(signal = 'SIGTERM') {
      abort.abort();
      proc.kill(signal);
      await proc.exited;
      await launch();
    },
    /** 停掉 kited 和假端点，删掉临时目录；设了 KITE_TEST_KEEP 就保留现场。 */
    async stop() {
      abort.abort();
      proc.kill('SIGTERM');
      await proc.exited;
      api.stop();
      if (!process.env.KITE_TEST_KEEP) rmSync(root, { recursive: true, force: true });
    },
  };
  return k;
}
