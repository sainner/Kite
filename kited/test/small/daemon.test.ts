/**
 * 经 HTTP 驱动本进程里的 kited，只走不起 Claude Code 的路径：D10。
 */
import { afterEach, expect, test } from 'bun:test';
import { chmodSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import type { Envelope } from '../../src/events.ts';
import { createSession, type Kited, registerProject, startKited } from '../harness.ts';
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

/* 依赖 Bun 的流式响应把事件即时推给客户端（连接开着时就到，不攒到关闭），看代码确认不了。 */
test('GET /events?session=<id> 在连接开着时就把这个会话的事件推过来，不推别的会话的', async () => {
  k = startKited();
  const kk = k;
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
