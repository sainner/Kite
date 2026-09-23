/**
 * 会话的检查工具背后的 src/check.ts：超时或被停下时停掉检查命令的整个进程树；同一个进程里的检查排队，一次只跑一个。
 */
import { expect, test } from 'bun:test';
import { chmodSync, mkdirSync, rmSync, symlinkSync } from 'node:fs';
import { join } from 'node:path';
import { runCheck } from '../../src/check.ts';
import { ENV, lexists, read, until, useTemp, writeFiles } from '../util.ts';

const temp = useTemp();

const alive = (pid: number) => { try { process.kill(pid, 0); return true; } catch { return false; } };

/*
 * 依赖的运行时行为：检查命令常是 sh 包一层再起子进程，只停最外层的话，子进程被 1 号进程收养、继续跑
 * （本机实测：SIGTERM 杀掉 sh 后，它的后台 sleep 的父进程变成 1，还活着）；非交互 sh 的后台任务忽略 SIGINT。
 * 停得干不干净取决于这些，看代码确认不了。
 *
 * 脚本内容要固定，随机的东西放进文件由脚本读出来：macOS 上内容没见过的可执行文件第一次执行约多 260 毫秒
 * （本机实测；内容执行过的新文件约 50 毫秒，同一个文件再执行约 10 毫秒）。脚本里带随机内容的话，
 * 每次都要多付这一笔，检查命令起得晚，300 毫秒的超时可能在它记下 pid 之前就到了。
 */
test('runCheck 超时或 signal 触发时停掉检查命令和它起的子进程，stopped 分别为 timeout、aborted，code 为 null，不算通过', async () => {
  // 这里只看怎么停，用不着 git：普通文件夹既当主文件夹又当工作树（取不到 HEAD，不传 KITE_BASE）
  const wt = temp();
  const main = wt;
  // sh 起一个后台子进程，记下自己和它的 pid，然后等它。sleep 的秒数带一个随机小数（从文件 secs 读），
  // 凭它在进程表里认出这个子进程
  const secs = `30.${Math.floor(Math.random() * 1e6)}`;
  const sleep = `sleep ${secs}`;
  writeFiles(wt, {
    secs: `${secs}\n`,
    '.kite/check': '#!/bin/sh\nread s < secs\nsleep "$s" &\necho "$$ $!" > pids\nwait\n',
  });
  chmodSync(join(wt, '.kite/check'), 0o755);
  const pidFile = join(wt, 'pids');
  const pids = () => {
    const m = lexists(pidFile) && /^(\d+) (\d+)\n$/.exec(read(pidFile));
    return m ? [Number(m[1]), Number(m[2])] : undefined;
  };
  const sleeping = () => Bun.spawnSync(['pgrep', '-f', sleep], { env: ENV(), stdout: 'ignore' }).exitCode === 0;
  const seen: number[] = [];

  try {
    const timedOut = await runCheck({ main, worktree: wt, timeoutMs: 300 });
    expect(timedOut).toMatchObject({ ok: false, code: null, stopped: 'timeout' });
    // 超时的时机由 runCheck 定：机器忙时检查命令可能还没记下 pid 就被停了，所以后台 sleep 按参数在进程表里找
    const first = pids() ?? [];
    seen.push(...first);
    await until(() => !sleeping() && first.every((p) => !alive(p)), '超时后检查命令和它的子进程都停掉', 2_000);

    rmSync(pidFile, { force: true });
    const ac = new AbortController();
    const running = runCheck({ main, worktree: wt, signal: ac.signal });
    const second = await until(pids, '检查命令起了子进程', 2_000);
    seen.push(...second);
    // 在进程表里认得出活着的子进程，上面超时那一段的检查才不是空的。
    // 要等：`sleep … &` 先 fork 再 exec，sh 写 pids 时子进程的命令行可能还是 sh
    await until(sleeping, '进程表里认得出子进程', 2_000);
    ac.abort();
    const aborted = await running;
    expect(aborted).toMatchObject({ ok: false, code: null, stopped: 'aborted' });
    await until(() => second.every((p) => !alive(p)), '被停下后检查命令和它的子进程都停掉', 2_000);
  } finally {
    // 没停掉的留到这里清理，免得 sleep 挂 30 秒
    for (const p of seen) try { process.kill(p, 'SIGKILL'); } catch { /* 已经不在 */ }
    Bun.spawnSync(['pkill', '-KILL', '-f', sleep], { env: ENV() });
  }
});

/*
 * 并发和时序：几次 runCheck 同时发起时怎么排队、排队时被停下怎么收场，看代码确认不了。
 * 第一个的检查命令停在放行文件上，放行之前后面的都在排队，第二个就在这时被停下。
 */
test('runCheck 同时发起几次时按发起顺序一个跑完再跑下一个；排队时被 signal 停下的立即返回 aborted、检查命令从没启动，排在它后面的照常按顺序跑', async () => {
  const root = temp();
  const log = join(root, 'log');
  const lines = () => (lexists(log) ? read(log).split('\n').filter(Boolean) : []);
  // 检查命令进出时往同一个日志里记一行，名字取工作树的文件夹名；a 等放行文件，最多 3 秒。
  // 各个工作树的 .kite/check 都链到同一个内容固定的脚本：macOS 头一回执行一个新文件要做一次检查，
  // 内容没见过时约 0.26 秒，每个工作树各写一份就要各付一次
  const script = join(root, 'check.sh');
  writeFiles(root, {
    'check.sh': [
      '#!/bin/sh',
      'd=$(pwd -P); n=${d##*/}',
      'echo "start $n" >> ../log',
      'if [ "$n" = a ]; then i=0; while [ ! -e ../go ] && [ $i -lt 300 ]; do sleep 0.01; i=$((i+1)); done; fi',
      'echo "end $n" >> ../log',
      '',
    ].join('\n'),
  });
  chmodSync(script, 0o755);
  // 每次调用一个文件夹，既当主文件夹又当工作树：排队不分工作树
  const folder = (name: string) => {
    const dir = join(root, name);
    mkdirSync(join(dir, '.kite'), { recursive: true });
    symlinkSync(script, join(dir, '.kite/check'));
    return dir;
  };
  const [a, b, c, d] = [folder('a'), folder('b'), folder('c'), folder('d')];

  const ac = new AbortController();
  const runs = [
    runCheck({ main: a, worktree: a }),
    runCheck({ main: b, worktree: b, signal: ac.signal }),
    runCheck({ main: c, worktree: c }),
    runCheck({ main: d, worktree: d }),
  ];
  try {
    await until(() => lines().includes('start a'), 'a 的检查命令开始', 2_000);
    ac.abort();
    const rb = await runs[1]!;
    expect(rb).toMatchObject({ ok: false, code: null, stopped: 'aborted' });
    // b 返回时 a 还停在放行文件上：b 没等 a 跑完；c、d 也还没开始
    expect(lines()).toEqual(['start a']);

    writeFiles(root, { go: '' });
    const [ra, , rc, rd] = await Promise.all(runs);
    // 运行时间不重叠、按发起顺序，b 从没启动
    expect(lines()).toEqual(['start a', 'end a', 'start c', 'end c', 'start d', 'end d']);
    expect([ra!.ok, rc!.ok, rd!.ok]).toEqual([true, true, true]);
    expect(rc!.waited).toBeGreaterThan(0);
  } finally {
    // 失败时也放行 a、等全部收场，免得队列卡着
    writeFiles(root, { go: '' });
    await Promise.allSettled(runs);
  }
});
