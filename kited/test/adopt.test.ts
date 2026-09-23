/**
 * 采纳：需求 19–24。
 */
import { describe, expect, setDefaultTimeout, test } from 'bun:test';
import { join } from 'node:path';
import {
  commitAll, getSession, git, gitOk, lexists, mainReqs, mark, newDir, newRepo, read, register, send, startSession,
  useKited, waitBusy, waitIdle, writeFiles,
} from './util.ts';

setDefaultTimeout(60_000);

const adopt = (k: any, id: string) => k.call('POST', `/sessions/${id}/adopt`) as Promise<{ status: number; body: any }>;

describe('需求 19–20：无冲突采纳', () => {
  const kited = useKited();

  test('主线没动：主文件夹快进到会话分支，文件出现、主文件夹干净；会话仍可继续、再次采纳', async () => {
    const k = kited();
    const dir = newDir(k, 'ad19', { 'a.txt': 'a\n', '.env': 'MAIN\n' });
    const p = await register(k, dir);
    const branchRef = git(dir, 'symbolic-ref', 'HEAD');
    const h0 = git(dir, 'rev-parse', 'HEAD');

    const { s, t0 } = await startSession(k, p.id, 'RUN echo feature > feat.txt && echo a2 > a.txt && echo SESSION > .env && echo x > out.pdf');
    await waitIdle(k, s.id, t0);
    const r = await adopt(k, s.id);
    expect(r.status).toBe(200);
    expect(r.body.status).toBe('adopted');
    expect(typeof r.body.commit).toBe('string');

    expect(git(dir, 'rev-parse', 'HEAD')).toBe(r.body.commit);
    expect(git(dir, 'symbolic-ref', 'HEAD')).toBe(branchRef);
    expect(git(dir, 'rev-parse', `refs/heads/${s.branch}`)).toBe(r.body.commit);
    expect(gitOk(dir, 'merge-base', '--is-ancestor', h0, 'HEAD')).toBe(true);
    expect(read(join(dir, 'feat.txt'))).toBe('feature\n');
    expect(read(join(dir, 'a.txt'))).toBe('a2\n');
    expect(git(dir, 'status', '--porcelain')).toBe('');
    expect((await getSession(k, s.id)).status).toBe('open');
    // 工作树里被忽略的文件不随采纳进主线
    expect(gitOk(dir, 'cat-file', '-e', 'HEAD:.env')).toBe(false);
    expect(gitOk(dir, 'cat-file', '-e', 'HEAD:out.pdf')).toBe(false);
    expect(read(join(dir, '.env'))).toBe('MAIN\n');
    expect(lexists(join(dir, 'out.pdf'))).toBe(false);

    // 继续对话，再次采纳
    const t1 = await send(k, s.id, 'RUN echo more > feat2.txt');
    await waitIdle(k, s.id, t1);
    const r2 = await adopt(k, s.id);
    expect(r2.status).toBe(200);
    expect(r2.body.status).toBe('adopted');
    expect(git(dir, 'rev-parse', 'HEAD')).toBe(r2.body.commit);
    expect(gitOk(dir, 'merge-base', '--is-ancestor', r.body.commit, 'HEAD')).toBe(true);
    expect(read(join(dir, 'feat2.txt'))).toBe('more\n');
    expect(read(join(dir, 'feat.txt'))).toBe('feature\n');
    expect(git(dir, 'status', '--porcelain')).toBe('');
    expect((await getSession(k, s.id)).status).toBe('open');
  });

  test('主线有不冲突的新提交：采纳后双方改动都在，主文件夹 HEAD 等于工作树 HEAD', async () => {
    const k = kited();
    const dir = newRepo(k, 'ad20', { 'a.txt': 'a\n', 'b.txt': 'b\n' });
    const p = await register(k, dir);
    const { s, t0 } = await startSession(k, p.id, 'RUN echo session > s.txt && echo a-session > a.txt');
    await waitIdle(k, s.id, t0);

    // 会话期间主线有了新提交
    writeFiles(dir, { 'm.txt': 'main\n', 'b.txt': 'b-main\n' });
    const mainCommit = commitAll(dir, 'main moves');

    const r = await adopt(k, s.id);
    expect(r.status).toBe(200);
    expect(r.body.status).toBe('adopted');
    expect(read(join(dir, 's.txt'))).toBe('session\n');
    expect(read(join(dir, 'a.txt'))).toBe('a-session\n');
    expect(read(join(dir, 'm.txt'))).toBe('main\n');
    expect(read(join(dir, 'b.txt'))).toBe('b-main\n');
    expect(git(dir, 'rev-parse', 'HEAD')).toBe(git(s.worktree, 'rev-parse', 'HEAD'));
    expect(git(dir, 'rev-parse', 'HEAD')).toBe(r.body.commit);
    expect(gitOk(dir, 'merge-base', '--is-ancestor', mainCommit, 'HEAD')).toBe(true);
    expect(git(dir, 'status', '--porcelain')).toBe('');
    // 工作树也有双方的改动
    expect(read(join(s.worktree, 'm.txt'))).toBe('main\n');
  });
});

describe('需求 19：路径含空格和中文', () => {
  const kited = useKited();

  test('项目路径含空格和中文：登记、会话、快照、采纳都正常', async () => {
    const k = kited();
    const dir = newDir(k, '我的 论文 (草稿)', { '第一章.md': '# 一\n' });
    const p = await register(k, dir);
    expect(p.commits).toBe('kite');
    expect(p.id).toMatch(/^[\x20-\x7e]+$/);
    const { s, t0 } = await startSession(k, p.id, 'RUN echo 二 > "第二章.md"');
    await waitIdle(k, s.id, t0);
    const r = await adopt(k, s.id);
    expect(r.status).toBe(200);
    expect(r.body.status).toBe('adopted');
    expect(read(join(dir, '第二章.md'))).toBe('二\n');
    expect(git(dir, 'status', '--porcelain')).toBe('');
  });
});

describe('需求 21：冲突', () => {
  const kited = useKited();

  test('冲突时返回冲突文件、主文件夹不进入冲突状态；agent 收到说明并解决后自动重试采纳', async () => {
    const k = kited();
    const dir = newDir(k, 'ad21', { 'c.txt': 'base\n', 'd.txt': 'base-d\n', 'other.txt': 'o\n' });
    const p = await register(k, dir);
    const { s, t0 } = await startSession(k, p.id, 'RUN echo session > c.txt && echo session-d > d.txt && echo session-o > other.txt');
    await waitIdle(k, s.id, t0);

    writeFiles(dir, { 'c.txt': 'main\n', 'd.txt': 'main-d\n', 'm.txt': 'm\n' });
    const mainCommit = commitAll(dir, 'main edits c and d');

    const m = mark(k);
    const r = await adopt(k, s.id);
    expect(r.status).toBe(200);
    expect(r.body.status).toBe('conflict');
    expect([...r.body.files].sort()).toEqual(['c.txt', 'd.txt']);

    // 主文件夹不进入冲突状态
    expect(git(dir, 'status', '--porcelain')).toBe('');
    expect(gitOk(dir, 'rev-parse', '-q', '--verify', 'MERGE_HEAD')).toBe(false);
    expect(git(dir, 'rev-parse', 'HEAD')).toBe(mainCommit);
    expect(read(join(dir, 'c.txt'))).toBe('main\n');

    // agent 这一轮结束后自动重试，成功时发 adopt 事件
    const ev = await k.waitEvent((e) => e.session === s.id && e.type === 'adopt' && e.result?.status === 'adopted' && k.events.indexOf(e) >= m.i);
    // agent 收到了说明冲突的消息
    const note = mainReqs(k, '冲突').filter((l) => l.at >= m.t);
    expect(note.length).toBeGreaterThan(0);

    expect(git(dir, 'rev-parse', 'HEAD')).toBe(ev.result.commit);
    expect(git(dir, 'rev-parse', 'HEAD')).toBe(git(s.worktree, 'rev-parse', 'HEAD'));
    expect(gitOk(dir, 'merge-base', '--is-ancestor', mainCommit, 'HEAD')).toBe(true);
    // agent 按会话一侧解决；不冲突的双方改动都在
    expect(read(join(dir, 'c.txt'))).toBe('session\n');
    expect(read(join(dir, 'd.txt'))).toBe('session-d\n');
    expect(read(join(dir, 'other.txt'))).toBe('session-o\n');
    expect(read(join(dir, 'm.txt'))).toBe('m\n');
    expect(git(dir, 'status', '--porcelain')).toBe('');
    expect(gitOk(dir, 'rev-parse', '-q', '--verify', 'MERGE_HEAD')).toBe(false);
  });
});

describe('需求 22–23：主文件夹里的未提交改动', () => {
  const kited = useKited();

  test('kite 项目：新建会话时主文件夹的未提交改动先存成提交，会话从它开始', async () => {
    const k = kited();
    const dir = newDir(k, 'ad22a', { 'u.txt': 'u0\n' });
    const p = await register(k, dir);
    expect(p.commits).toBe('kite');
    const h0 = git(dir, 'rev-parse', 'HEAD');
    writeFiles(dir, { 'u.txt': 'u-dirty\n', 'new.txt': 'new\n', 'scan.pdf': '%PDF', '.env': 'S=1\n' });

    const { s } = await startSession(k, p.id, '你好');
    expect(s.base).not.toBe(h0);
    expect(gitOk(dir, 'merge-base', '--is-ancestor', h0, s.base)).toBe(true);
    expect(git(dir, 'show', `${s.base}:u.txt`)).toBe('u-dirty');
    expect(git(dir, 'show', `${s.base}:new.txt`)).toBe('new');
    // 被 .gitignore 忽略的文件不进这个提交，仍留在主文件夹
    expect(gitOk(dir, 'cat-file', '-e', `${s.base}:scan.pdf`)).toBe(false);
    expect(gitOk(dir, 'cat-file', '-e', `${s.base}:.env`)).toBe(false);
    expect(read(join(dir, 'scan.pdf'))).toBe('%PDF');
    expect(git(dir, 'rev-parse', 'HEAD')).toBe(s.base);
    expect(git(dir, 'status', '--porcelain')).toBe('');
    expect(read(join(s.worktree, 'u.txt'))).toBe('u-dirty\n');
    expect(read(join(s.worktree, 'new.txt'))).toBe('new\n');
  });

  test('kite 项目：采纳时主文件夹的未提交改动先存成提交，采纳后两边都在、主文件夹干净', async () => {
    const k = kited();
    const dir = newDir(k, 'ad22b', { 'a.txt': 'a\n', 'gone.txt': 'g\n' });
    const p = await register(k, dir);
    const { s, t0 } = await startSession(k, p.id, 'RUN echo session > s.txt');
    await waitIdle(k, s.id, t0);

    // 用户直接在主文件夹里改，不提交
    writeFiles(dir, { 'a.txt': 'a-user\n', 'user.txt': 'user\n' });
    Bun.spawnSync(['rm', join(dir, 'gone.txt')]);

    const r = await adopt(k, s.id);
    expect(r.status).toBe(200);
    expect(r.body.status).toBe('adopted');
    expect(git(dir, 'rev-parse', 'HEAD')).toBe(r.body.commit);
    expect(read(join(dir, 's.txt'))).toBe('session\n');
    expect(read(join(dir, 'a.txt'))).toBe('a-user\n');
    expect(read(join(dir, 'user.txt'))).toBe('user\n');
    expect(lexists(join(dir, 'gone.txt'))).toBe(false);
    expect(git(dir, 'status', '--porcelain')).toBe('');
    // 用户的改动进了提交
    expect(git(dir, 'show', 'HEAD:user.txt')).toBe('user');
    expect(git(dir, 'show', 'HEAD:a.txt')).toBe('a-user');
    expect(gitOk(dir, 'cat-file', '-e', 'HEAD:gone.txt')).toBe(false);
  });

  test('user 项目：采纳后主文件夹里无关的未提交改动仍未提交、内容不变', async () => {
    const k = kited();
    const dir = newRepo(k, 'ad23', { 'notes.txt': 'notes0\n', 'a.txt': 'a\n' });
    const p = await register(k, dir);
    expect(p.commits).toBe('user');
    const { s, t0 } = await startSession(k, p.id, 'RUN echo session > s.txt && echo a-session > a.txt');
    await waitIdle(k, s.id, t0);

    // 用户在主文件夹里的无关改动：改了已跟踪文件、新建未跟踪文件、暂存了一个新文件
    writeFiles(dir, { 'notes.txt': 'notes-dirty\n', 'scratch.txt': 'scratch\n', 'staged.txt': 'staged\n' });
    git(dir, 'add', 'staged.txt');
    const h0 = git(dir, 'rev-parse', 'HEAD');

    const r = await adopt(k, s.id);
    expect(r.status).toBe(200);
    expect(r.body.status).toBe('adopted');
    expect(git(dir, 'rev-parse', 'HEAD')).toBe(r.body.commit);
    expect(r.body.commit).not.toBe(h0);
    expect(read(join(dir, 's.txt'))).toBe('session\n');
    expect(read(join(dir, 'a.txt'))).toBe('a-session\n');

    // 无关改动：内容不变
    expect(read(join(dir, 'notes.txt'))).toBe('notes-dirty\n');
    expect(read(join(dir, 'scratch.txt'))).toBe('scratch\n');
    expect(read(join(dir, 'staged.txt'))).toBe('staged\n');
    // 仍未提交：不在 HEAD 里（或还是原内容），状态里还看得到
    expect(git(dir, 'show', 'HEAD:notes.txt')).toBe('notes0');
    expect(gitOk(dir, 'cat-file', '-e', 'HEAD:scratch.txt')).toBe(false);
    expect(gitOk(dir, 'cat-file', '-e', 'HEAD:staged.txt')).toBe(false);
    const status = git(dir, 'status', '--porcelain').split('\n');
    expect(status.some((l) => l.endsWith(' notes.txt') && l.slice(0, 2).includes('M'))).toBe(true);
    expect(status).toContain('?? scratch.txt');
    expect(status.some((l) => l.endsWith(' staged.txt'))).toBe(true);
    // 会话的文件已经提交，不在未提交状态里
    expect(status.some((l) => l.endsWith(' s.txt') || l.endsWith(' a.txt'))).toBe(false);
  });
});

describe('需求 21–23 组合：未提交改动遇上冲突或主线前进', () => {
  const kited = useKited();

  test('kite 项目：主文件夹未提交的改动和会话冲突——先存成提交，返回冲突，主文件夹干净；agent 解决后采纳成功', async () => {
    const k = kited();
    const dir = newDir(k, 'ad22c', { 'c.txt': 'base\n' });
    const p = await register(k, dir);
    const { s, t0 } = await startSession(k, p.id, 'RUN echo session > c.txt');
    await waitIdle(k, s.id, t0);

    writeFiles(dir, { 'c.txt': 'user-dirty\n' });
    const m = mark(k);
    const r = await adopt(k, s.id);
    expect(r.status).toBe(200);
    expect(r.body.status).toBe('conflict');
    expect(r.body.files).toEqual(['c.txt']);
    // 用户的改动已存成提交，主文件夹不进入冲突状态
    expect(git(dir, 'status', '--porcelain')).toBe('');
    expect(gitOk(dir, 'rev-parse', '-q', '--verify', 'MERGE_HEAD')).toBe(false);
    expect(read(join(dir, 'c.txt'))).toBe('user-dirty\n');
    expect(git(dir, 'show', 'HEAD:c.txt')).toBe('user-dirty');
    const userCommit = git(dir, 'rev-parse', 'HEAD');

    const ev = await k.waitEvent((e) => e.session === s.id && e.type === 'adopt' && e.result?.status === 'adopted' && k.events.indexOf(e) >= m.i);
    expect(git(dir, 'rev-parse', 'HEAD')).toBe(ev.result.commit);
    expect(gitOk(dir, 'merge-base', '--is-ancestor', userCommit, 'HEAD')).toBe(true);
    expect(read(join(dir, 'c.txt'))).toBe('session\n');
    expect(git(dir, 'status', '--porcelain')).toBe('');
  });

  test('user 项目：主线有新提交、同时有无关的未提交改动——采纳后双方改动都在，无关改动仍未提交', async () => {
    const k = kited();
    const dir = newRepo(k, 'ad23b', { 'notes.txt': 'notes0\n', 'a.txt': 'a\n' });
    const p = await register(k, dir);
    const { s, t0 } = await startSession(k, p.id, 'RUN echo session > s.txt');
    await waitIdle(k, s.id, t0);

    writeFiles(dir, { 'm.txt': 'main\n' });
    const mainCommit = commitAll(dir, 'main moves');
    writeFiles(dir, { 'notes.txt': 'notes-dirty\n', 'scratch.txt': 'scratch\n' });

    const r = await adopt(k, s.id);
    expect(r.status).toBe(200);
    expect(r.body.status).toBe('adopted');
    expect(git(dir, 'rev-parse', 'HEAD')).toBe(r.body.commit);
    expect(gitOk(dir, 'merge-base', '--is-ancestor', mainCommit, 'HEAD')).toBe(true);
    expect(read(join(dir, 's.txt'))).toBe('session\n');
    expect(read(join(dir, 'm.txt'))).toBe('main\n');
    expect(read(join(dir, 'notes.txt'))).toBe('notes-dirty\n');
    expect(read(join(dir, 'scratch.txt'))).toBe('scratch\n');
    expect(git(dir, 'show', 'HEAD:notes.txt')).toBe('notes0');
    expect(gitOk(dir, 'cat-file', '-e', 'HEAD:scratch.txt')).toBe(false);
    const status = git(dir, 'status', '--porcelain').split('\n');
    expect(status.some((l) => l.endsWith(' notes.txt'))).toBe(true);
    expect(status).toContain('?? scratch.txt');
  });
});

describe('需求 24：工作中不能采纳', () => {
  const kited = useKited();

  test('agent 正在工作时采纳被拒绝（409）', async () => {
    const k = kited();
    const dir = newDir(k, 'ad24', { 'a.txt': 'a\n' });
    const p = await register(k, dir);
    const { s, t0 } = await startSession(k, p.id, 'RUN echo 1 > f.txt');
    await waitIdle(k, s.id, t0);
    const h0 = git(dir, 'rev-parse', 'HEAD');

    const t1 = await send(k, s.id, 'SLOW 4 慢慢想');
    await waitBusy(k, s.id);
    const r = await adopt(k, s.id);
    expect(r.status).toBe(409);
    expect(typeof r.body.error).toBe('string');
    expect(git(dir, 'rev-parse', 'HEAD')).toBe(h0);
    expect(lexists(join(dir, 'f.txt'))).toBe(false);
    await waitIdle(k, s.id, t1);
  });
});
