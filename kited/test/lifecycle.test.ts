/**
 * 进程生命周期：需求 15–18。
 */
import { describe, expect, setDefaultTimeout, test } from 'bun:test';
import { chmodSync } from 'node:fs';
import { join } from 'node:path';
import {
  commitAll, eventsSince, getSession, mainReqs, newDir, newRepo, pollUntil, register, send, startSession, useKited,
  waitClosed, waitIdle, waitRunThenClosed,
} from './util.ts';

setDefaultTimeout(60_000);

describe('需求 15–17：进程随回合开关', () => {
  const kited = useKited();

  test('回合结束且没有后台任务时进程关闭；再发消息自动续接，历史还在', async () => {
    const k = kited();
    const p = await register(k, newDir(k, 'l15', { 'a.txt': 'a\n' }));
    const { s, t0 } = await startSession(k, p.id, '第一条 标记L15A');
    await waitRunThenClosed(k, s.id, t0);
    let v = await getSession(k, s.id);
    expect(v.runner).toBe('closed');
    expect(v.busy).toBe(false);

    const t1 = await send(k, s.id, '第二条 标记L15B');
    await waitRunThenClosed(k, s.id, t1);
    v = await getSession(k, s.id);
    expect(v.runner).toBe('closed');
    expect(v.busy).toBe(false);
    expect(v.nativeId).toBe(s.nativeId);

    const req = mainReqs(k, '标记L15B')[0];
    expect(req).toBeDefined();
    expect(JSON.stringify(req!.body.messages)).toContain('标记L15A');
    const init = eventsSince(k, s.id, t1, 'sdk').find((e) => e.message.type === 'system' && e.message.subtype === 'init');
    expect(init?.message.session_id).toBe(s.nativeId);
  });

  test('回合结束时有后台任务则不关进程；后台任务完成后自动开新回合，结束后关闭', async () => {
    const k = kited();
    const p = await register(k, newDir(k, 'l16', { 'a.txt': 'a\n' }));
    const { s, t0 } = await startSession(k, p.id, 'BG 2');
    // 第一回合（启动后台任务）结束
    await k.waitEvent((e) => e.session === s.id && e.type === 'sdk' && e.message.type === 'result');

    const notif = await pollUntil(
      () => k.api.log.find((l) => l.main && l.at >= t0.t && l.lastUserText.includes('task-notification')), 20_000);
    // 通知回合开始前，进程不该进入关闭
    const early = eventsSince(k, s.id, t0, 'runner').filter((e) => e.state !== 'running' && (!notif || e.at < notif.at));
    expect(early).toEqual([]);
    expect(notif).toBeDefined();

    await waitClosed(k, s.id, notif!.at);
    const v = await getSession(k, s.id);
    expect(v.runner).toBe('closed');
    expect(v.busy).toBe(false);
  });

  test('回合进行中又发来的消息不丢，最终被处理，进程最后关闭', async () => {
    const k = kited();
    const p = await register(k, newDir(k, 'l17', { 'a.txt': 'a\n' }));
    const { s, t0 } = await startSession(k, p.id, '开场');
    await waitIdle(k, s.id, t0);

    const t1 = await send(k, s.id, 'SLOW 3 慢回合 标记L17A');
    const slow = await pollUntil(() => mainReqs(k, '标记L17A')[0], 10_000);
    expect(slow).toBeDefined();
    await send(k, s.id, '插队消息 标记L17B');
    await send(k, s.id, '又一条插队消息 标记L17C');

    // 两条都被 agent 处理：出现在某次请求的最后一条用户消息里
    const got = await pollUntil(() => {
      const b = mainReqs(k, '标记L17B')[0];
      const c = mainReqs(k, '标记L17C')[0];
      return b && c && (b.at >= c.at ? b : c);
    }, 30_000);
    expect(mainReqs(k, '标记L17B').length).toBeGreaterThan(0);
    expect(mainReqs(k, '标记L17C').length).toBeGreaterThan(0);
    expect(got).toBeDefined();
    expect(JSON.stringify(got!.body.messages)).toContain('标记L17A');
    // 慢回合结束时还有新消息，这时不算 idle
    expect(eventsSince(k, s.id, t1, 'idle').filter((e) => e.at < got!.at)).toEqual([]);

    await waitClosed(k, s.id, got!.at);
    const v = await getSession(k, s.id);
    expect(v.runner).toBe('closed');
    expect(v.busy).toBe(false);
  });
});

describe('需求 18：kited 被 SIGKILL 后重启', () => {
  const kited = useKited();

  test('进程已关闭时被杀：重启后发消息能续接，历史还在', async () => {
    const k = kited();
    const p = await register(k, newDir(k, 'l18a', { 'a.txt': 'a\n' }));
    const { s, t0 } = await startSession(k, p.id, '第一条 标记L18A');
    await waitRunThenClosed(k, s.id, t0);

    await k.restart('SIGKILL');
    const v = await getSession(k, s.id);
    expect(v.status).toBe('open');
    expect(v.nativeId).toBe(s.nativeId);

    const t1 = await send(k, s.id, '第二条 标记L18B');
    await waitIdle(k, s.id, t1);
    const req = mainReqs(k, '标记L18B')[0];
    expect(req).toBeDefined();
    expect(JSON.stringify(req!.body.messages)).toContain('标记L18A');
    expect((await getSession(k, s.id)).nativeId).toBe(s.nativeId);
  });

  test('回合进行中被杀：重启后发消息能续接，历史还在', async () => {
    const k = kited();
    const p = await register(k, newDir(k, 'l18b', { 'a.txt': 'a\n' }));
    const { s, t0 } = await startSession(k, p.id, '开场 标记L18C');
    await waitIdle(k, s.id, t0);
    await send(k, s.id, 'SLOW 3 标记L18D');
    expect(await pollUntil(() => mainReqs(k, '标记L18D')[0], 10_000)).toBeDefined();

    await k.restart('SIGKILL');
    // 等被杀前那个 agent 进程的慢请求自然结束，避免两个进程同时写同一份会话记录
    await Bun.sleep(4000);

    const t2 = await send(k, s.id, '续接 标记L18E');
    await waitIdle(k, s.id, t2);
    const req = mainReqs(k, '标记L18E')[0];
    expect(req).toBeDefined();
    const hist = JSON.stringify(req!.body.messages);
    expect(hist).toContain('标记L18C');
    expect(hist).toContain('标记L18D');
    const v = await getSession(k, s.id);
    expect(v.nativeId).toBe(s.nativeId);
    expect(v.busy).toBe(false);
  });

  test('重启时仍在 preparing 的会话变为 prepare_failed', async () => {
    const k = kited();
    const dir = newRepo(k, 'l18prep', { '.kite/setup': '#!/bin/sh\nsleep 20\n', 'a.txt': 'a\n' });
    chmodSync(join(dir, '.kite/setup'), 0o755);
    commitAll(dir, 'exec bit');
    const p = await register(k, dir);

    const r = await k.call('POST', '/sessions', { project: p.id, prompt: '你好 标记L18P' });
    expect(r.status).toBe(200);
    const id = r.body.id;
    await Bun.sleep(500);
    expect((await getSession(k, id)).status).toBe('preparing');

    await k.restart('SIGKILL');
    const failed = await pollUntil(async () => (await getSession(k, id)).status === 'prepare_failed', 5_000);
    expect((await getSession(k, id)).status).toBe('prepare_failed');
    expect(failed).toBe(true);
    await Bun.sleep(1000);
    expect(k.api.log.filter((l) => JSON.stringify(l.body).includes('标记L18P'))).toHaveLength(0);
  });
});
