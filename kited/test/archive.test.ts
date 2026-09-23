/**
 * 归档：需求 25–26。
 */
import { describe, expect, setDefaultTimeout, test } from 'bun:test';
import { existsSync } from 'node:fs';
import { join } from 'node:path';
import { getSession, git, gitOk, newDir, read, register, send, snapshots, startSession, useKited, waitIdle } from './util.ts';

setDefaultTimeout(60_000);

const archive = (k: any, id: string, body: unknown = {}) =>
  k.call('POST', `/sessions/${id}/archive`, body) as Promise<{ status: number; body: any }>;

describe('需求 25：归档前检查未采纳的改动', () => {
  const kited = useKited();

  test('有没合回主线的改动：不带 force 拒绝（409），带 force 成功', async () => {
    const k = kited();
    const dir = newDir(k, 'ar25a', { 'a.txt': 'a\n' });
    const p = await register(k, dir);
    const { s, t0 } = await startSession(k, p.id, 'RUN echo x > x.txt');
    await waitIdle(k, s.id, t0);

    const r = await archive(k, s.id);
    expect(r.status).toBe(409);
    expect(typeof r.body.error).toBe('string');
    const v = await getSession(k, s.id);
    expect(v.status).toBe('open');
    expect(existsSync(s.worktree)).toBe(true);

    const r2 = await archive(k, s.id, { force: true });
    expect(r2.status).toBe(200);
    expect((await getSession(k, s.id)).status).toBe('archived');
    // 强制归档不把改动带进主文件夹
    expect(existsSync(join(dir, 'x.txt'))).toBe(false);
  });

  test('agent 在工作树里提交了、工作树干净但没合回主线：不带 force 仍被拒绝', async () => {
    const k = kited();
    const dir = newDir(k, 'ar25d', { 'a.txt': 'a\n' });
    const p = await register(k, dir);
    const { s, t0 } = await startSession(k, p.id,
      'RUN echo z > z.txt && git add -A && git -c user.name=a -c user.email=a@b commit -q -m z');
    await waitIdle(k, s.id, t0);
    expect(git(s.worktree, 'status', '--porcelain')).toBe('');
    expect(git(s.worktree, 'rev-parse', 'HEAD')).not.toBe(s.base);

    const r = await archive(k, s.id);
    expect(r.status).toBe(409);
    expect((await getSession(k, s.id)).status).toBe('open');
  });

  test('已完全采纳的会话不带 force 也能归档', async () => {
    const k = kited();
    const dir = newDir(k, 'ar25b', { 'a.txt': 'a\n' });
    const p = await register(k, dir);
    const { s, t0 } = await startSession(k, p.id, 'RUN echo y > y.txt');
    await waitIdle(k, s.id, t0);
    const ad = await k.call('POST', `/sessions/${s.id}/adopt`);
    expect(ad.body.status).toBe('adopted');

    const r = await archive(k, s.id);
    expect(r.status).toBe(200);
    expect((await getSession(k, s.id)).status).toBe('archived');
    expect(read(join(dir, 'y.txt'))).toBe('y\n');
  });

  test('采纳之后又有新改动：不带 force 仍被拒绝', async () => {
    const k = kited();
    const dir = newDir(k, 'ar25c', { 'a.txt': 'a\n' });
    const p = await register(k, dir);
    const { s, t0 } = await startSession(k, p.id, 'RUN echo 1 > one.txt');
    await waitIdle(k, s.id, t0);
    expect((await k.call('POST', `/sessions/${s.id}/adopt`)).body.status).toBe('adopted');
    const t1 = await send(k, s.id, 'RUN echo 2 > two.txt');
    await waitIdle(k, s.id, t1);

    const r = await archive(k, s.id);
    expect(r.status).toBe(409);
    expect((await getSession(k, s.id)).status).toBe('open');
  });
});

describe('需求 26：归档之后', () => {
  const kited = useKited();

  test('工作树和会话分支被删，refs/kite/snapshots/<id> 和快照还在，发消息被拒绝（409）', async () => {
    const k = kited();
    const dir = newDir(k, 'ar26', { 'a.txt': 'a\n' });
    const p = await register(k, dir);
    const { s, t0 } = await startSession(k, p.id, 'RUN echo x > x.txt');
    await waitIdle(k, s.id, t0);
    const t1 = await send(k, s.id, 'RUN echo y > y.txt');
    await waitIdle(k, s.id, t1);
    const before = await snapshots(k, s.id);
    expect(before.length).toBeGreaterThanOrEqual(3);

    const r = await k.call('POST', `/sessions/${s.id}/archive`, { force: true });
    expect(r.status).toBe(200);
    expect((await getSession(k, s.id)).status).toBe('archived');

    expect(existsSync(s.worktree)).toBe(false);
    expect(gitOk(dir, 'rev-parse', '--verify', '--quiet', `refs/heads/${s.branch}`)).toBe(false);
    expect(git(dir, 'worktree', 'list', '--porcelain')).not.toContain(s.worktree);
    const ref = `refs/kite/snapshots/${s.id}`;
    expect(gitOk(dir, 'rev-parse', '--verify', '--quiet', ref)).toBe(true);
    for (const snap of before) expect(gitOk(dir, 'merge-base', '--is-ancestor', snap.commit, ref)).toBe(true);

    const after = await snapshots(k, s.id);
    expect(after.map((x) => x.commit)).toEqual(before.map((x) => x.commit));
    expect(git(dir, 'show', `${after[0]!.commit}:y.txt`)).toBe('y');

    const m = await k.call('POST', `/sessions/${s.id}/messages`, { text: '还在吗' });
    expect(m.status).toBe(409);
    expect(typeof m.body.error).toBe('string');
    // 主文件夹不受影响
    expect(git(dir, 'status', '--porcelain')).toBe('');
  });
});
