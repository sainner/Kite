/**
 * 快照：需求 11–14。
 */
import { describe, expect, setDefaultTimeout, test } from 'bun:test';
import { join } from 'node:path';
import {
  git, gitOk, isSymlink, lexists, newDir, newRepo, read, register, send, snapshots, startSession, toolUseIdsSince,
  useKited, waitBusy, waitIdle, writeFiles,
} from './util.ts';

setDefaultTimeout(60_000);

describe('需求 11–13：快照的产生与存放', () => {
  const kited = useKited();

  test('会话开始时有「会话开始」快照，且是最早的一枚', async () => {
    const k = kited();
    const dir = newDir(k, 'snap11', { 'a.txt': 'a\n' });
    const p = await register(k, dir);
    const { s, t0 } = await startSession(k, p.id, 'RUN echo 1 > one.txt');
    await waitIdle(k, s.id, t0);
    const t1 = await send(k, s.id, 'RUN echo 2 > two.txt');
    await waitIdle(k, s.id, t1);

    const list = await snapshots(k, s.id);
    expect(list.length).toBeGreaterThanOrEqual(3);
    const last = list[list.length - 1]!;
    expect(last.label).toBe('会话开始');
    expect(list.filter((x) => x.label === '会话开始')).toHaveLength(1);
    // 新的在前：时间不增
    for (let i = 1; i < list.length; i++) expect(list[i]!.at).toBeLessThanOrEqual(list[i - 1]!.at);
    // 「会话开始」记录的是会话起点的内容
    expect(gitOk(dir, 'cat-file', '-e', `${last.commit}:a.txt`)).toBe(true);
    expect(gitOk(dir, 'cat-file', '-e', `${last.commit}:one.txt`)).toBe(false);
  });

  test('每批工具调用一枚快照：标签是开启回合的用户消息，toolUseIds 是这批调用；工作树没变不产生快照', async () => {
    const k = kited();
    const dir = newDir(k, 'snap12', { 'a.txt': 'a\n' });
    const p = await register(k, dir);

    // 单个调用
    const prompt = 'RUN echo 1 > f1.txt';
    const { s, t0 } = await startSession(k, p.id, prompt);
    await waitIdle(k, s.id, t0);
    let list = await snapshots(k, s.id);
    expect(list).toHaveLength(2);
    expect(list[0]!.label).toBe(prompt);
    const ids1 = toolUseIdsSince(k, s.id, t0);
    expect(ids1).toHaveLength(1);
    expect(list[0]!.toolUseIds).toEqual(ids1);
    expect(git(dir, 'show', `${list[0]!.commit}:f1.txt`)).toBe('1');

    // 并行两个调用：一枚快照、两个 id
    const par = 'PAR echo a > p1.txt ;; echo b > p2.txt';
    const t1 = await send(k, s.id, par);
    await waitIdle(k, s.id, t1);
    list = await snapshots(k, s.id);
    expect(list).toHaveLength(3);
    expect(list[0]!.label).toBe(par);
    const ids2 = toolUseIdsSince(k, s.id, t1);
    expect(ids2).toHaveLength(2);
    expect([...list[0]!.toolUseIds].sort()).toEqual([...ids2].sort());
    expect(git(dir, 'show', `${list[0]!.commit}:p1.txt`)).toBe('a');
    expect(git(dir, 'show', `${list[0]!.commit}:p2.txt`)).toBe('b');

    // 工具跑了但工作树没变：不产生快照
    const t2 = await send(k, s.id, 'RUN echo nothing-changed');
    await waitIdle(k, s.id, t2);
    await Bun.sleep(500);
    expect(await snapshots(k, s.id)).toHaveLength(3);

    // 纯对话回合也不产生快照
    const t3 = await send(k, s.id, '只是聊聊');
    await waitIdle(k, s.id, t3);
    await Bun.sleep(500);
    expect(await snapshots(k, s.id)).toHaveLength(3);
  });

  test('长消息开启的回合：快照标签仍是完整的用户消息，接口和事件一致', async () => {
    const k = kited();
    const dir = newDir(k, 'snap12long', { 'a.txt': 'a\n' });
    const p = await register(k, dir);
    const prompt = `RUN echo long > long.txt # ${'这是一条比较长的用户消息，'.repeat(8)}结尾`;
    const { s, t0 } = await startSession(k, p.id, prompt);
    await waitIdle(k, s.id, t0);
    const top = (await snapshots(k, s.id))[0]!;
    const ev = k.events.find((e) => e.session === s.id && e.type === 'snapshot' && e.commit === top.commit);
    expect(ev?.label).toBe(prompt);
    expect(top.label).toBe(prompt);
  });

  test('快照挂在 refs/kite/snapshots/<会话 id>，不建分支，不动主文件夹的 HEAD 和暂存区', async () => {
    const k = kited();
    const dir = newRepo(k, 'snap13', { 'a.txt': 'a\n' });
    writeFiles(dir, { 'staged.txt': 'staged\n', 'a.txt': 'a dirty\n' });
    git(dir, 'add', 'staged.txt');
    const p = await register(k, dir);
    const before = {
      head: git(dir, 'rev-parse', 'HEAD'),
      sym: git(dir, 'symbolic-ref', 'HEAD'),
      status: git(dir, 'status', '--porcelain'),
      cached: git(dir, 'diff', '--cached'),
      index: git(dir, 'ls-files', '--stage'),
    };

    const { s, t0 } = await startSession(k, p.id, 'RUN echo 1 > f1.txt');
    await waitIdle(k, s.id, t0);
    const t1 = await send(k, s.id, 'RUN echo 2 > f2.txt && echo x > a.txt');
    await waitIdle(k, s.id, t1);

    const list = await snapshots(k, s.id);
    expect(list.length).toBeGreaterThanOrEqual(3);
    const ref = `refs/kite/snapshots/${s.id}`;
    expect(gitOk(dir, 'rev-parse', '--verify', '--quiet', ref)).toBe(true);
    expect(git(dir, 'rev-parse', ref)).toBe(list[0]!.commit);
    for (const snap of list) expect(gitOk(dir, 'merge-base', '--is-ancestor', snap.commit, ref)).toBe(true);

    // 回归：快照曾挂在 refs/kite/<id>，和会话分支 kite/<id> 短名相同，git 会把分支名解析成快照
    expect(git(dir, 'rev-parse', s.branch)).toBe(git(dir, 'rev-parse', `refs/heads/${s.branch}`));

    // 分支只有原来的 main 和会话分支
    const heads = git(dir, 'for-each-ref', '--format=%(refname)', 'refs/heads').split('\n').sort();
    expect(heads).toEqual(['refs/heads/main', `refs/heads/${s.branch}`].sort());

    expect(git(dir, 'rev-parse', 'HEAD')).toBe(before.head);
    expect(git(dir, 'symbolic-ref', 'HEAD')).toBe(before.sym);
    expect(git(dir, 'status', '--porcelain')).toBe(before.status);
    expect(git(dir, 'diff', '--cached')).toBe(before.cached);
    expect(git(dir, 'ls-files', '--stage')).toBe(before.index);
  });
});

describe('需求 14：回退', () => {
  const kited = useKited();

  test('回退到某枚快照：删改的回来、新建的删掉、被忽略的不动；回退可撤销', async () => {
    const k = kited();
    const dir = newDir(k, 'restore', {
      'keep.txt': 'v0\n',
      'del.txt': 'to be deleted\n',
      'ren.txt': 'to be renamed\n',
      'dir/inner.txt': 'inner\n',
      '.worktreeinclude': '.env\n',
      '.claude/settings.json': JSON.stringify({ worktree: { symlinkDirectories: ['node_modules'] } }),
      '.env': 'SECRET=1\n',
      'node_modules/pkg/index.js': 'index\n',
    });
    const p = await register(k, dir);
    const { s, t0 } = await startSession(k, p.id, 'RUN echo v1 > keep.txt');
    await waitIdle(k, s.id, t0);
    const wt = s.worktree;
    expect(read(join(wt, '.env'))).toBe('SECRET=1\n');
    expect(isSymlink(join(wt, 'node_modules'))).toBe(true);
    const s1 = (await snapshots(k, s.id))[0]!;
    expect(s1.label).toBe('RUN echo v1 > keep.txt');

    const t1 = await send(k, s.id,
      'RUN rm del.txt && mv ren.txt renamed.txt && rm -r dir && echo new > created.txt && mkdir -p newdir/deep && echo nd > newdir/deep/f.txt && echo v2 > keep.txt && echo SECRET=2 > .env && echo loc > .env.local && echo added > node_modules/pkg/added.js');
    await waitIdle(k, s.id, t1);
    expect((await snapshots(k, s.id))[0]!.commit).not.toBe(s1.commit);

    // 用前缀回退
    const r = await k.call('POST', `/sessions/${s.id}/restore`, { commit: s1.commit.slice(0, 8) });
    expect(r.status).toBe(200);

    expect(read(join(wt, 'keep.txt'))).toBe('v1\n');
    expect(read(join(wt, 'del.txt'))).toBe('to be deleted\n');
    expect(read(join(wt, 'ren.txt'))).toBe('to be renamed\n');
    expect(read(join(wt, 'dir/inner.txt'))).toBe('inner\n');
    expect(lexists(join(wt, 'renamed.txt'))).toBe(false);
    expect(lexists(join(wt, 'created.txt'))).toBe(false);
    expect(lexists(join(wt, 'newdir/deep/f.txt'))).toBe(false);
    // 被忽略的不动
    expect(read(join(wt, '.env'))).toBe('SECRET=2\n');
    expect(read(join(wt, '.env.local'))).toBe('loc\n');
    expect(isSymlink(join(wt, 'node_modules'))).toBe(true);
    expect(read(join(dir, 'node_modules/pkg/index.js'))).toBe('index\n');
    expect(read(join(dir, 'node_modules/pkg/added.js'))).toBe('added\n');

    // 回退可撤销：回退之后，快照里仍有一枚记着回退前的状态
    const after = await snapshots(k, s.id);
    const undo = after.find((x) => gitOk(dir, 'cat-file', '-e', `${x.commit}:created.txt`));
    expect(undo).toBeDefined();
    const r2 = await k.call('POST', `/sessions/${s.id}/restore`, { commit: undo!.commit });
    expect(r2.status).toBe(200);
    expect(read(join(wt, 'keep.txt'))).toBe('v2\n');
    expect(read(join(wt, 'created.txt'))).toBe('new\n');
    expect(read(join(wt, 'newdir/deep/f.txt'))).toBe('nd\n');
    expect(read(join(wt, 'renamed.txt'))).toBe('to be renamed\n');
    expect(lexists(join(wt, 'del.txt'))).toBe(false);
    expect(lexists(join(wt, 'ren.txt'))).toBe(false);
    expect(lexists(join(wt, 'dir'))).toBe(false);
    expect(read(join(wt, '.env'))).toBe('SECRET=2\n');
    expect(isSymlink(join(wt, 'node_modules'))).toBe(true);
  });

  test('回退前工作树有快照之外的改动：自动存一枚「回退前自动保存」，能回退回来', async () => {
    const k = kited();
    const dir = newDir(k, 'restore-auto', { 'keep.txt': 'v0\n' });
    const p = await register(k, dir);
    const { s, t0 } = await startSession(k, p.id, 'RUN echo v1 > keep.txt');
    await waitIdle(k, s.id, t0);
    const wt = s.worktree;
    const s1 = (await snapshots(k, s.id))[0]!;

    // 不经过 agent 直接改工作树（比如人在编辑器里改的），这些改动还没进任何快照
    writeFiles(wt, { 'keep.txt': 'hand edit\n', 'manual.txt': 'manual\n' });

    const r = await k.call('POST', `/sessions/${s.id}/restore`, { commit: s1.commit });
    expect(r.status).toBe(200);
    expect(read(join(wt, 'keep.txt'))).toBe('v1\n');
    expect(lexists(join(wt, 'manual.txt'))).toBe(false);

    const auto = (await snapshots(k, s.id)).find((x) => x.label === '回退前自动保存');
    expect(auto).toBeDefined();
    expect(git(dir, 'show', `${auto!.commit}:manual.txt`)).toBe('manual');

    const r2 = await k.call('POST', `/sessions/${s.id}/restore`, { commit: auto!.commit });
    expect(r2.status).toBe(200);
    expect(read(join(wt, 'keep.txt'))).toBe('hand edit\n');
    expect(read(join(wt, 'manual.txt'))).toBe('manual\n');
  });

  test('不属于这个会话的 commit 返回 404', async () => {
    const k = kited();
    const dir = newDir(k, 'restore404', { 'a.txt': 'a\n' });
    const p = await register(k, dir);
    const a = await startSession(k, p.id, 'RUN echo a > a2.txt');
    const b = await startSession(k, p.id, 'RUN echo b > b2.txt');
    await waitIdle(k, a.s.id, a.t0);
    await waitIdle(k, b.s.id, b.t0);
    const other = (await snapshots(k, b.s.id))[0]!;

    const r = await k.call('POST', `/sessions/${a.s.id}/restore`, { commit: other.commit });
    expect(r.status).toBe(404);
    expect(typeof r.body.error).toBe('string');
    // 工作树没被动
    expect(read(join(a.s.worktree, 'a2.txt'))).toBe('a\n');
    expect(lexists(join(a.s.worktree, 'b2.txt'))).toBe(false);

    const bad = await k.call('POST', `/sessions/${a.s.id}/restore`, { commit: 'deadbeefdeadbeef' });
    expect(bad.status).toBeGreaterThanOrEqual(400);
    expect(bad.status).toBeLessThan(500);
  });

  test('agent 正在工作时回退被拒绝（409）', async () => {
    const k = kited();
    const dir = newDir(k, 'restore409', { 'a.txt': 'a\n' });
    const p = await register(k, dir);
    const { s, t0 } = await startSession(k, p.id, 'RUN echo 1 > f.txt');
    await waitIdle(k, s.id, t0);
    const first = (await snapshots(k, s.id)).at(-1)!;

    const t1 = await send(k, s.id, 'SLOW 4 慢慢想');
    await waitBusy(k, s.id);
    const r = await k.call('POST', `/sessions/${s.id}/restore`, { commit: first.commit });
    expect(r.status).toBe(409);
    expect(typeof r.body.error).toBe('string');
    await waitIdle(k, s.id, t1);
    expect(read(join(s.worktree, 'f.txt'))).toBe('1\n');
  });
});
