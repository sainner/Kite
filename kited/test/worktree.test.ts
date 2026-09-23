/**
 * 会话与工作树：需求 5–10。
 */
import { describe, expect, setDefaultTimeout, test } from 'bun:test';
import { chmodSync, existsSync, mkdirSync, realpathSync, symlinkSync } from 'node:fs';
import { join, relative, isAbsolute } from 'node:path';
import {
  commitAll, eventsSince, getSession, git, isSymlink, lexists, listTree, mainReqs, newDir, newRepo, read,
  register, send, startSession, useKited, waitIdle, writeFiles,
} from './util.ts';

setDefaultTimeout(60_000);

const outside = (child: string, parent: string) => {
  const r = relative(parent, child);
  return r.startsWith('..') || isAbsolute(r);
};

describe('需求 5：工作树位置与会话分支', () => {
  const kited = useKited();

  test('工作树在项目文件夹外，分支 kite/<id>，起点是主文件夹当时的 HEAD', async () => {
    const k = kited();
    const dir = newRepo(k, 'wt5', { 'a.txt': 'a\n' });
    // 主文件夹停在另一个分支、比初始提交多一个提交，确认起点取的是「当时的 HEAD」
    git(dir, 'checkout', '-q', '-b', 'dev');
    writeFiles(dir, { 'b.txt': 'b\n' });
    const head = commitAll(dir, 'second');
    const p = await register(k, dir);

    const { s } = await startSession(k, p.id, '你好');
    expect(s.projectId).toBe(p.id);
    expect(s.branch).toBe(`kite/${s.id}`);
    expect(s.base).toBe(head);
    expect(outside(s.worktree, dir)).toBe(true);

    // 工作树真实存在，是同一个仓库的工作树，检出在会话分支、起点就是 base
    expect(existsSync(s.worktree)).toBe(true);
    expect(realpathSync(git(s.worktree, 'rev-parse', '--path-format=absolute', '--git-common-dir'))).toBe(realpathSync(join(dir, '.git')));
    expect(git(s.worktree, 'symbolic-ref', 'HEAD')).toBe(`refs/heads/${s.branch}`);
    expect(git(s.worktree, 'rev-parse', 'HEAD')).toBe(head);
    expect(git(dir, 'rev-parse', `refs/heads/${s.branch}`)).toBe(head);
    expect(read(join(s.worktree, 'b.txt'))).toBe('b\n');

    // 主文件夹仍在原分支
    expect(git(dir, 'symbolic-ref', 'HEAD')).toBe('refs/heads/dev');
    expect(git(dir, 'rev-parse', 'HEAD')).toBe(head);
  });
});

describe('需求 6：.worktreeinclude', () => {
  const kited = useKited();

  test('复制匹配且被忽略的文件；未被忽略的保持检出版本；符号链接不复制', async () => {
    const k = kited();
    const dir = newRepo(k, 'wt6', {
      '.gitignore': '.env\nsecrets/\n*.local\n*.log\n',
      '.worktreeinclude': '.env\nsecrets/\n*.local\ntracked.txt\n',
      'tracked.txt': 'committed\n',
      'a.txt': 'a\n',
    });
    // 主文件夹里的被忽略文件
    writeFiles(dir, {
      '.env': 'SECRET=1\n',
      'secrets/key.txt': 'key\n',
      'secrets/deep/more.txt': 'more\n',
      'config.local': 'local\n',
      'debug.log': 'not included\n',
    });
    writeFiles(k.root, { 'outside-target.txt': 'target\n' });
    symlinkSync(join(k.root, 'outside-target.txt'), join(dir, 'link.local'));
    symlinkSync(join(k.root, 'outside-target.txt'), join(dir, 'secrets', 'link.txt'));
    mkdirSync(join(k.root, 'outside-dir'));
    writeFiles(k.root, { 'outside-dir/inside.txt': 'inside\n' });
    symlinkSync(join(k.root, 'outside-dir'), join(dir, 'secrets', 'linkdir'));
    // 已跟踪文件在主文件夹里有未提交修改：它不该被复制过去
    writeFiles(dir, { 'tracked.txt': 'dirty in main\n' });

    const p = await register(k, dir);
    expect(p.commits).toBe('user');
    const { s } = await startSession(k, p.id, '你好');
    const wt = s.worktree;

    expect(read(join(wt, '.env'))).toBe('SECRET=1\n');
    expect(read(join(wt, 'secrets/key.txt'))).toBe('key\n');
    expect(read(join(wt, 'secrets/deep/more.txt'))).toBe('more\n');
    expect(read(join(wt, 'config.local'))).toBe('local\n');
    // 被忽略但不在 .worktreeinclude 里
    expect(lexists(join(wt, 'debug.log'))).toBe(false);
    // 符号链接不复制
    expect(lexists(join(wt, 'link.local'))).toBe(false);
    expect(lexists(join(wt, 'secrets/link.txt'))).toBe(false);
    expect(lexists(join(wt, 'secrets/linkdir'))).toBe(false);
    // 匹配但未被忽略：就是检出里的版本
    expect(read(join(wt, 'tracked.txt'))).toBe('committed\n');
    expect(git(wt, 'status', '--porcelain')).toBe('');
  });
});

describe('需求 6：.worktreeinclude 的匹配语法', () => {
  const kited = useKited();

  test('按 .gitignore 语法匹配：不带斜杠的模式匹配任意层级，带前导斜杠的只匹配根', async () => {
    const k = kited();
    const dir = newRepo(k, 'wt6b', {
      '.gitignore': '.env\n*.secret\n',
      '.worktreeinclude': '.env\n/root.secret\n',
      'a.txt': 'a\n',
    });
    writeFiles(dir, {
      '.env': 'root\n',
      'app/.env': 'nested\n',
      'root.secret': 'r\n',
      'app/root.secret': 'nested secret\n',
    });
    const p = await register(k, dir);
    const { s } = await startSession(k, p.id, '你好');
    const wt = s.worktree;
    expect(read(join(wt, '.env'))).toBe('root\n');
    expect(read(join(wt, 'app/.env'))).toBe('nested\n');
    expect(read(join(wt, 'root.secret'))).toBe('r\n');
    expect(lexists(join(wt, 'app/root.secret'))).toBe(false);
  });
});

describe('需求 7：worktree.symlinkDirectories', () => {
  const kited = useKited();

  test('列出的已存在目录在工作树里是指向主文件夹的软链接；不存在、绝对路径、含 .. 的跳过', async () => {
    const k = kited();
    const absDir = join(k.root, 'abs-target');
    mkdirSync(absDir);
    writeFiles(absDir, { 'x.txt': 'x\n' });
    const dir = newRepo(k, 'wt7', {
      '.gitignore': 'node_modules/\ndata/\ncache/\n',
      '.claude/settings.json': JSON.stringify({
        worktree: {
          symlinkDirectories: ['node_modules', 'data/big', 'missing', absDir, '../sibling', 'x/../cache'],
        },
      }),
      'a.txt': 'a\n',
    });
    writeFiles(dir, {
      'node_modules/pkg/index.js': '1\n',
      'data/big/blob.bin': 'blob\n',
      'cache/c.txt': 'c\n',
    });
    // 项目旁边的同级目录（'../sibling' 指向的地方）
    const sibling = join(dir, '..', 'sibling');
    mkdirSync(sibling);
    const p = await register(k, dir);
    const { s } = await startSession(k, p.id, '你好');
    const wt = s.worktree;

    expect(isSymlink(join(wt, 'node_modules'))).toBe(true);
    expect(realpathSync(join(wt, 'node_modules'))).toBe(realpathSync(join(dir, 'node_modules')));
    expect(read(join(wt, 'node_modules/pkg/index.js'))).toBe('1\n');

    expect(isSymlink(join(wt, 'data/big'))).toBe(true);
    expect(realpathSync(join(wt, 'data/big'))).toBe(realpathSync(join(dir, 'data/big')));

    // 不存在的跳过
    expect(lexists(join(wt, 'missing'))).toBe(false);
    // 绝对路径跳过：工作树里不出现，原目录也没被动
    expect(lexists(join(wt, absDir))).toBe(false);
    expect(isSymlink(absDir)).toBe(false);
    expect(read(join(absDir, 'x.txt'))).toBe('x\n');
    // 含 .. 的跳过
    expect(lexists(join(wt, '..', 'sibling'))).toBe(false);
    expect(lexists(join(wt, 'cache'))).toBe(false);
    expect(lexists(join(wt, 'x'))).toBe(false);
  });
});

describe('需求 8：.kite/setup', () => {
  const kited = useKited();

  test('agent 启动前在工作树里执行一次，KITE_MAIN_DIR 是主文件夹，输出进 setup 事件', async () => {
    const k = kited();
    const dir = newRepo(k, 'wt8', {
      '.gitignore': '.setup-count\n',
      '.kite/setup': [
        '#!/bin/sh',
        'echo "cwd=$(pwd -P)"',
        'echo "main=$KITE_MAIN_DIR"',
        'echo "to-stderr" >&2',
        'echo ran >> .setup-count',
        'echo marker-content > .setup-marker',
        'exit 0',
        '',
      ].join('\n'),
      'a.txt': 'a\n',
    });
    chmodSync(join(dir, '.kite/setup'), 0o755);
    commitAll(dir, 'exec bit');
    const p = await register(k, dir);

    const token = '标记S8';
    const { s, t0 } = await startSession(k, p.id, `RUN cat .setup-marker > seen.txt # ${token}`);
    const setup = await k.waitEvent((e) => e.session === s.id && e.type === 'setup');
    expect(setup.exit).toBe(0);
    expect(setup.log).toContain(`cwd=${realpathSync(s.worktree)}`);
    expect(setup.log).toContain(`main=${dir}`);
    expect(setup.log).toContain('to-stderr');

    await waitIdle(k, s.id, t0);
    // agent 启动时 setup 已经跑完：它读得到 setup 写的文件
    expect(read(join(s.worktree, 'seen.txt'))).toBe('marker-content\n');
    // 时间上：setup 事件在第一个带这条消息的请求之前
    const firstReq = mainReqs(k, token)[0];
    expect(firstReq).toBeDefined();
    expect(setup.at).toBeLessThanOrEqual(firstReq!.at);

    // 再来一个回合（中间进程可能关闭再续接），setup 仍只跑过一次
    const t1 = await send(k, s.id, '第二条');
    await waitIdle(k, s.id, t1);
    expect(read(join(s.worktree, '.setup-count'))).toBe('ran\n');
    expect(eventsSince(k, s.id, 0, 'setup')).toHaveLength(1);
  });

  test('setup 退出码非 0：会话 prepare_failed，agent 收不到第一条消息', async () => {
    const k = kited();
    const dir = newRepo(k, 'wt8fail', {
      '.kite/setup': '#!/bin/sh\necho "装依赖失败"\necho "err-line" >&2\nexit 3\n',
      'a.txt': 'a\n',
    });
    chmodSync(join(dir, '.kite/setup'), 0o755);
    commitAll(dir, 'exec bit');
    const p = await register(k, dir);

    const token = '标记S8F';
    const r = await k.call('POST', '/sessions', { project: p.id, prompt: `你好 ${token}` });
    expect(r.status).toBe(200);
    const id = r.body.id;
    const setup = await k.waitEvent((e) => e.session === id && e.type === 'setup');
    expect(setup.exit).toBe(3);
    expect(setup.log).toContain('装依赖失败');
    expect(setup.log).toContain('err-line');
    await k.waitEvent((e) => e.session === id && e.type === 'status' && e.status === 'prepare_failed');
    expect((await getSession(k, id)).status).toBe('prepare_failed');

    await Bun.sleep(2000);
    expect(k.api.log.filter((l) => JSON.stringify(l.body).includes(token))).toHaveLength(0);
    expect(eventsSince(k, id, 0, 'sdk')).toHaveLength(0);
  });

  test('没有 .kite/setup 时 setup 事件的 exit 为 null', async () => {
    const k = kited();
    const dir = newRepo(k, 'wt8none', { 'a.txt': 'a\n' });
    const p = await register(k, dir);
    const { s } = await startSession(k, p.id, '你好');
    const setup = await k.waitEvent((e) => e.session === s.id && e.type === 'setup');
    expect(setup.exit).toBeNull();
  });
});

describe('需求 9：改动只在工作树', () => {
  const kited = useKited();

  test('user 项目：agent 改文件、暂存、提交，主文件夹的文件、HEAD、分支、暂存区都不变', async () => {
    const k = kited();
    const dir = newRepo(k, 'wt9', { 'a.txt': 'a\n', 'b.txt': 'b\n' });
    // 主文件夹里有用户自己的暂存和未暂存改动
    writeFiles(dir, { 'staged.txt': 'staged\n', 'b.txt': 'b dirty\n' });
    git(dir, 'add', 'staged.txt');
    const p = await register(k, dir);
    const before = {
      head: git(dir, 'rev-parse', 'HEAD'),
      branch: git(dir, 'symbolic-ref', 'HEAD'),
      status: git(dir, 'status', '--porcelain'),
      cached: git(dir, 'diff', '--cached'),
      diff: git(dir, 'diff'),
      tree: listTree(dir),
    };

    const { s, t0 } = await startSession(k, p.id,
      'RUN echo changed > a.txt && echo new > new.txt && rm b.txt && git add -A && git -c user.name=a -c user.email=a@b commit -q -m agent');
    await waitIdle(k, s.id, t0);
    const t1 = await send(k, s.id, 'RUN echo again > a.txt && echo more > more.txt && git add more.txt');
    await waitIdle(k, s.id, t1);

    // 改动确实发生在工作树
    expect(read(join(s.worktree, 'a.txt'))).toBe('again\n');
    expect(existsSync(join(s.worktree, 'new.txt'))).toBe(true);

    expect(git(dir, 'rev-parse', 'HEAD')).toBe(before.head);
    expect(git(dir, 'symbolic-ref', 'HEAD')).toBe(before.branch);
    expect(git(dir, 'status', '--porcelain')).toBe(before.status);
    expect(git(dir, 'diff', '--cached')).toBe(before.cached);
    expect(git(dir, 'diff')).toBe(before.diff);
    expect(listTree(dir)).toEqual(before.tree);
  });

  test('kite 项目：agent 的改动不出现在主文件夹', async () => {
    const k = kited();
    const dir = newDir(k, 'wt9kite', { 'a.txt': 'a\n' });
    const p = await register(k, dir);
    const before = {
      head: git(dir, 'rev-parse', 'HEAD'),
      branch: git(dir, 'symbolic-ref', 'HEAD'),
      tree: listTree(dir),
    };
    const { s, t0 } = await startSession(k, p.id, 'RUN echo changed > a.txt && echo new > new.txt');
    await waitIdle(k, s.id, t0);
    expect(read(join(s.worktree, 'a.txt'))).toBe('changed\n');
    expect(git(dir, 'rev-parse', 'HEAD')).toBe(before.head);
    expect(git(dir, 'symbolic-ref', 'HEAD')).toBe(before.branch);
    expect(git(dir, 'status', '--porcelain')).toBe('');
    expect(listTree(dir)).toEqual(before.tree);
  });
});

describe('需求 10：同一个原生会话', () => {
  const kited = useKited();

  test('第一条和之后的消息都进同一个原生会话，历史里有之前的内容', async () => {
    const k = kited();
    const dir = newDir(k, 'wt10', { 'a.txt': 'a\n' });
    const p = await register(k, dir);
    const { s, t0 } = await startSession(k, p.id, '第一条 标记A10');
    expect(typeof s.nativeId).toBe('string');
    expect(s.nativeId.length).toBeGreaterThan(0);
    await waitIdle(k, s.id, t0);

    const t1 = await send(k, s.id, '第二条 标记B10');
    await waitIdle(k, s.id, t1);
    const t2 = await send(k, s.id, '第三条 标记C10');
    await waitIdle(k, s.id, t2);

    expect((await getSession(k, s.id)).nativeId).toBe(s.nativeId);
    // SDK 报告的原生会话 id 始终是这一个
    const inits = eventsSince(k, s.id, 0, 'sdk').filter((e) => e.message.type === 'system' && e.message.subtype === 'init');
    expect(inits.length).toBeGreaterThan(0);
    for (const e of inits) expect(e.message.session_id).toBe(s.nativeId);

    const second = mainReqs(k, '标记B10')[0];
    expect(second).toBeDefined();
    expect(JSON.stringify(second!.body.messages)).toContain('标记A10');
    const third = mainReqs(k, '标记C10')[0];
    expect(third).toBeDefined();
    const hist = JSON.stringify(third!.body.messages);
    expect(hist).toContain('标记A10');
    expect(hist).toContain('标记B10');
  });
});
