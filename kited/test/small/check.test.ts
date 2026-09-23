/**
 * 会话的检查工具背后的 src/check.ts：超时或被停下时停掉检查命令的整个进程树。
 */
import { expect, test } from 'bun:test';
import { chmodSync, rmSync } from 'node:fs';
import { join } from 'node:path';
import { runCheck } from '../../src/check.ts';
import { ENV, lexists, read, until, useTemp, writeFiles } from '../util.ts';

const temp = useTemp();

const alive = (pid: number) => { try { process.kill(pid, 0); return true; } catch { return false; } };

/*
 * 依赖的运行时行为：检查命令常是 sh 包一层再起子进程，只停最外层的话，子进程被 1 号进程收养、继续跑
 * （本机实测：SIGTERM 杀掉 sh 后，它的后台 sleep 的父进程变成 1，还活着）；非交互 sh 的后台任务忽略 SIGINT。
 * 停得干不干净取决于这些，看代码确认不了。
 */
test('runCheck 超时或 signal 触发时停掉检查命令和它起的子进程，stopped 分别为 timeout、aborted，code 为 null，不算通过', async () => {
  // 这里只看怎么停，用不着 git：普通文件夹既当主文件夹又当工作树（取不到 HEAD，不传 KITE_BASE）
  const wt = temp();
  const main = wt;
  // sh 起一个后台子进程，记下自己和它的 pid，然后等它。sleep 的秒数带一个随机小数，凭它在进程表里认出这个子进程
  const sleep = `sleep 30.${Math.floor(Math.random() * 1e6)}`;
  writeFiles(wt, { '.kite/check': `#!/bin/sh\n${sleep} &\necho "$$ $!" > pids\nwait\n` });
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
    // 在进程表里认得出活着的子进程，上面超时那一段的检查才不是空的
    expect(sleeping()).toBe(true);
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
