/**
 * 经 HTTP 驱动本进程里的 kited，只走不起 Claude Code 的路径：D8、D10。
 */
import { afterEach, expect, test } from 'bun:test';
import { randomUUID } from 'node:crypto';
import { chmodSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import type { Envelope } from '../../src/events.ts';
import { api, createSession, getSession, type Kited, registerProject, startKited } from '../harness.ts';
import { commitAll, newRepo } from '../util.ts';

let k: Kited | undefined;
afterEach(async () => { await k?.stop(); k = undefined; });

/** 带 .kite/setup 的已有仓库；script 是脚本正文（不含 #!）。 */
function repoWithSetup(parent: string, name: string, script: string): string {
  const dir = newRepo(parent, name, { '.kite/setup': `#!/bin/sh\n${script}`, 'a.txt': 'a\n' });
  chmodSync(join(dir, '.kite/setup'), 0o755);
  commitAll(dir, '可执行');
  return dir;
}

test('.kite/setup 退出码非 0：会话变为 prepare_failed，setup 事件带退出码和日志，agent 从没收到第一条消息', async () => {
  k = startKited();
  const kk = k;
  const repo = repoWithSetup(kk.root, 'proj', 'echo "装依赖失败"\necho "err-line" >&2\nexit 3\n');
  const p = await registerProject(kk, repo);
  const token = `标记D8-${randomUUID()}`;
  const s = await createSession(kk, p.id, `你好 ${token}`);

  const setup = await kk.waitEvent((e) => e.session === s.id && e.type === 'setup');
  if (setup.type !== 'setup') throw new Error('不是 setup 事件');
  expect(setup.exit).toBe(3);
  expect(setup.log).toContain('装依赖失败');
  expect(setup.log).toContain('err-line');
  await kk.waitEvent((e) => e.session === s.id && e.type === 'status' && e.status === 'prepare_failed');
  const v = await getSession(kk, s.id);
  expect(v.status).toBe('prepare_failed');
  expect(v.runner).toBe('closed');
  expect(kk.events.filter((e) => e.session === s.id && (e.type === 'runner' || e.type === 'sdk'))).toEqual([]);
  expect(api.log.some((l) => JSON.stringify(l.body).includes(token))).toBe(false);
});

test('HTTP：不存在的会话和项目返回 4xx 和 {error}；GET /events?session=<id> 只推这个会话的事件', async () => {
  k = startKited();
  const kk = k;
  for (const [method, path, body] of [
    ['GET', '/sessions/no-such-session'],
    ['POST', '/sessions/no-such-session/messages', { text: 'x' }],
    ['GET', '/sessions/no-such-session/snapshots'],
    ['POST', '/sessions/no-such-session/adopt'],
    ['POST', '/sessions', { project: 'no-such-project', prompt: 'x' }],
  ] as const) {
    const r = await kk.call(method, path, body);
    expect([path, r.status >= 400 && r.status < 500, typeof r.body.error]).toEqual([path, true, 'string']);
  }

  // 两个会话的 setup 都等着各自的放行文件（工作树旁边的 <工作树>.go），放行后失败退出；不起 Claude Code
  const repo = repoWithSetup(kk.root, 'proj', 'i=0; while [ ! -e "$(pwd -P).go" ] && [ $i -lt 500 ]; do sleep 0.01; i=$((i+1)); done\nexit 1\n');
  const p = await registerProject(kk, repo);
  const a = await createSession(kk, p.id, '会话 A');
  const b = await createSession(kk, p.id, '会话 B');

  const ctl = new AbortController();
  const res = await fetch(`${kk.url}/events?session=${a.id}`, { signal: ctl.signal });
  const got: Envelope[] = [];
  let sawEnd!: () => void;
  const ended = new Promise<void>((r) => (sawEnd = r));
  const reading = (async () => {
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
          const e = JSON.parse(data.slice(6)) as Envelope;
          got.push(e);
          if (e.type === 'status' && e.status === 'prepare_failed') sawEnd();
        }
      }
    } catch { /* 中止 */ }
  })();

  // 先让 B 跑完，再让 A 跑完：A 的最后一个事件到达时，B 的事件如果会漏进来也早就到了
  writeFileSync(`${b.worktree}.go`, '');
  await kk.waitEvent((e) => e.session === b.id && e.type === 'status' && e.status === 'prepare_failed');
  writeFileSync(`${a.worktree}.go`, '');
  await ended;
  ctl.abort();
  await reading;

  expect(got.some((e) => e.type === 'setup')).toBe(true);
  expect(got.map((e) => e.session)).toEqual(got.map(() => a.id));
});
