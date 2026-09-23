/**
 * 接口契约的通用部分（不对应单条需求编号）：视图字段、错误格式、筛选、SSE 按会话过滤、中断。
 */
import { describe, expect, setDefaultTimeout, test } from 'bun:test';
import { symlinkSync } from 'node:fs';
import { join } from 'node:path';
import { getSession, mainReqs, newDir, pollUntil, register, send, startSession, useKited, waitIdle, waitRunThenClosed } from './util.ts';

setDefaultTimeout(60_000);

describe('接口契约', () => {
  const kited = useKited();

  test('SessionView 字段齐全、类型正确；按项目筛选会话', async () => {
    const k = kited();
    const pa = await register(k, newDir(k, 'apia', { 'a.txt': 'a\n' }));
    const pb = await register(k, newDir(k, 'apib', { 'a.txt': 'a\n' }));
    const r = await k.call('POST', '/sessions', { project: pa.id, prompt: '你好' });
    expect(r.status).toBe(200);
    const v = r.body;
    for (const f of ['id', 'projectId', 'title', 'worktree', 'branch', 'base', 'runtime', 'nativeId']) expect(typeof v[f]).toBe('string');
    expect(['preparing', 'prepare_failed', 'open', 'archived']).toContain(v.status);
    expect(['closed', 'running', 'closing']).toContain(v.runner);
    expect(typeof v.busy).toBe('boolean');
    expect(typeof v.createdAt).toBe('number');
    expect(v.projectId).toBe(pa.id);

    const { s: sb, t0 } = await startSession(k, pb.id, '你好');
    await waitIdle(k, sb.id, t0);
    const all = (await k.call('GET', '/sessions')).body as any[];
    expect(all.map((x) => x.id)).toEqual(expect.arrayContaining([v.id, sb.id]));
    const onlyA = (await k.call('GET', `/sessions?project=${pa.id}`)).body as any[];
    expect(onlyA.map((x) => x.id)).toEqual([v.id]);
    const projects = (await k.call('GET', '/projects')).body as any[];
    expect(projects.map((x) => x.id)).toEqual(expect.arrayContaining([pa.id, pb.id]));
  });

  test('不存在的会话 / 项目返回 4xx 和 {error}', async () => {
    const k = kited();
    const check = (r: { status: number; body: any }) => {
      expect(r.status).toBeGreaterThanOrEqual(400);
      expect(r.status).toBeLessThan(500);
      expect(typeof r.body.error).toBe('string');
    };
    check(await k.call('GET', '/sessions/no-such-session'));
    check(await k.call('POST', '/sessions/no-such-session/messages', { text: 'x' }));
    check(await k.call('GET', '/sessions/no-such-session/snapshots'));
    check(await k.call('POST', '/sessions', { project: 'no-such-project', prompt: 'x' }));
  });

  test('用符号链接别名登记已登记的文件夹，不产生第二个项目', async () => {
    const k = kited();
    const dir = newDir(k, 'aliased', { 'a.txt': 'a\n' });
    const p = await register(k, dir);
    const alias = join(k.root, 'alias-link');
    symlinkSync(dir, alias);
    const r = await k.call('POST', '/projects', { path: alias });
    if (r.status === 200) expect(r.body.id).toBe(p.id);
    else expect(r.status).toBeGreaterThanOrEqual(400);
    const list = (await k.call('GET', '/projects')).body as any[];
    const ids = new Set(list.filter((x) => x.path === dir || x.path === alias).map((x) => x.id));
    expect(ids.size).toBe(1);
  });

  test('GET /events?session=id 只推这个会话的事件', async () => {
    const k = kited();
    const p = await register(k, newDir(k, 'apiev', { 'a.txt': 'a\n' }));
    const { s: s1, t0: a0 } = await startSession(k, p.id, '会话一');
    const { s: s2, t0: b0 } = await startSession(k, p.id, '会话二');
    await waitIdle(k, s1.id, a0);
    await waitIdle(k, s2.id, b0);

    const ctl = new AbortController();
    const res = await fetch(`${k.url}/events?session=${s1.id}`, { signal: ctl.signal });
    const got: any[] = [];
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
            if (data) got.push(JSON.parse(data.slice(6)));
          }
        }
      } catch { /* 中止 */ }
    })();

    const m1 = await send(k, s1.id, 'RUN echo 1 > one.txt');
    const m2 = await send(k, s2.id, 'RUN echo 2 > two.txt');
    await waitIdle(k, s1.id, m1);
    await waitIdle(k, s2.id, m2);
    await pollUntil(() => got.some((e) => e.type === 'idle'), 5_000);
    ctl.abort();
    await reading;

    expect(got.length).toBeGreaterThan(0);
    expect(got.some((e) => e.type === 'snapshot')).toBe(true);
    for (const e of got) expect(e.session).toBe(s1.id);
  });

  test('中断：请求已在进行中时调 interrupt，回合很快结束', async () => {
    const k = kited();
    const p = await register(k, newDir(k, 'apiint', { 'a.txt': 'a\n' }));
    const { s, t0 } = await startSession(k, p.id, '开场');
    await waitRunThenClosed(k, s.id, t0);

    await send(k, s.id, 'SLOW 10 很慢的回合 标记INT1');
    expect(await pollUntil(() => mainReqs(k, '标记INT1')[0], 10_000)).toBeDefined();
    const started = Date.now();
    const r = await k.call('POST', `/sessions/${s.id}/interrupt`);
    expect(r.status).toBe(200);
    const done = await pollUntil(async () => !(await getSession(k, s.id)).busy, 6_000);
    expect(done).toBe(true);
    expect(Date.now() - started).toBeLessThan(8_000);
  });

  test('中断：刚发消息、进程还在启动时调 interrupt，也不会让这一回合照常跑完', async () => {
    const k = kited();
    const p = await register(k, newDir(k, 'apiint2', { 'a.txt': 'a\n' }));
    const { s, t0 } = await startSession(k, p.id, '开场');
    await waitRunThenClosed(k, s.id, t0);

    await send(k, s.id, 'SLOW 10 很慢的回合 标记INT2');
    const started = Date.now();
    const r = await k.call('POST', `/sessions/${s.id}/interrupt`);
    expect(r.status).toBeLessThan(500);
    const done = await pollUntil(async () => !(await getSession(k, s.id)).busy, 6_000);
    expect(done).toBe(true);
    expect(Date.now() - started).toBeLessThan(8_000);
  });
});
