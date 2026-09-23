/**
 * 会话的检查工具背后的 src/check.ts：在会话工作树里跑 .kite/check，KITE_BASE 由 Kite 给，超时或被停下时停掉整个进程树。
 */
import { expect, test } from 'bun:test';
import { chmodSync, rmSync } from 'node:fs';
import { join } from 'node:path';
import { hasCheck, runCheck } from '../../src/check.ts';
import { ENV, git, gitWorktree, lexists, newDir, newRepo, read, until, useTemp, writeFiles } from '../util.ts';

const temp = useTemp();

const alive = (pid: number) => { try { process.kill(pid, 0); return true; } catch { return false; } };

/** 把可执行的检查脚本写进 dir/.kite/check。 */
function writeCheck(dir: string, script: string) {
  writeFiles(dir, { '.kite/check': script });
  chmodSync(join(dir, '.kite/check'), 0o755);
}

test('runCheck 在工作树里跑 .kite/check：KITE_BASE 是工作树 HEAD 和主文件夹 HEAD 的分叉点，环境带着 kited 的 process.env，all 时传 --all，退出码 0 才算通过，stdout 和 stderr 都进输出，不动工作树；主文件夹 HEAD 取不到时不传 KITE_BASE；hasCheck 只认有 .kite/check 的文件夹', async () => {
  const root = temp();
  const main = newDir(root, 'main', { 'a.txt': 'a\n' });
  writeCheck(main, [
    '#!/bin/sh',
    'echo "base=${KITE_BASE-(未设)}"',
    'echo "args=[$*]"',
    'echo "cwd=$(pwd -P)"',
    'echo "home=$HOME"',
    'echo "写到 stderr" >&2',
    '[ -e .fail ] && exit 3',
    'exit 0',
    '',
  ].join('\n'));
  // 检查脚本随第一个提交进仓库；从它分叉出会话工作树，之后主线和会话分支各提交一次；
  // 另建一个还没有提交的主文件夹。一个 shell 做完，少起进程
  const r = Bun.spawnSync(['sh', '-ec', [
    'git init -q -b main && git add -A && git commit -q -m init',
    'git worktree add -q -b kite/c1 ../wt',
    'git commit -q --allow-empty -m 主线前进',
    'echo 会话提交的 > ../wt/a.txt && git -C ../wt commit -q -am 会话的提交',
    'git init -q ../unborn',
    'git rev-parse HEAD~',
  ].join('\n')], { cwd: main, env: ENV(), stdout: 'pipe', stderr: 'pipe' });
  if (r.exitCode !== 0) throw new Error(`搭场景失败：${r.stderr.toString()}`);
  const fork = r.stdout.toString().trim();
  const wt = join(root, 'wt');
  const unborn = join(root, 'unborn');
  writeFiles(wt, { 'a.txt': '没提交的改动\n' });

  expect(hasCheck(wt)).toBe(true);
  expect(hasCheck(unborn)).toBe(false);

  const passed = await runCheck({ main, worktree: wt });
  expect(passed).toMatchObject({ ok: true, code: 0, all: false, base: fork });
  expect(passed.stopped).toBeUndefined();
  expect(passed.output).toContain(`base=${fork}\n`);
  expect(passed.output).toContain('args=[]');
  expect(passed.output).toContain(`cwd=${wt}\n`);
  // 隔离环境（test/setup.ts）里的 HOME，不是测试进程启动时的真实 HOME
  expect(passed.output).toContain(`home=${process.env.HOME}\n`);
  expect(passed.output).toContain('写到 stderr');
  // 没提交的改动原样留着，没被提交、暂存或收起
  expect(git(wt, 'status', '--porcelain')).toBe(' M a.txt');

  writeFiles(wt, { '.fail': '' });
  const failed = await runCheck({ main, worktree: wt, all: true });
  expect(failed).toMatchObject({ ok: false, code: 3, all: true, base: fork });
  expect(failed.output).toContain('args=[--all]');

  const noBase = await runCheck({ main: unborn, worktree: wt });
  expect(noBase.base).toBeNull();
  expect(noBase.output).toContain('base=(未设)');
});

test('runCheck 超时或 signal 触发时停掉检查命令和它起的子进程，stopped 分别为 timeout、aborted，code 为 null，不算通过', async () => {
  const root = temp();
  const main = newRepo(root, 'main', { 'a.txt': 'a\n' });
  const wt = gitWorktree(main, join(root, 'wt'), 'kite/c2');
  // sh 起一个后台子进程，记下自己和它的 pid，然后等它
  writeCheck(wt, '#!/bin/sh\nsleep 30 &\necho "$$ $!" > pids\nwait\n');
  const pidFile = join(wt, 'pids');
  const pids = () => {
    const m = lexists(pidFile) && /^(\d+) (\d+)\n$/.exec(read(pidFile));
    return m ? [Number(m[1]), Number(m[2])] : undefined;
  };
  const seen: number[] = [];

  try {
    const timedOut = await runCheck({ main, worktree: wt, timeoutMs: 300 });
    expect(timedOut).toMatchObject({ ok: false, code: null, stopped: 'timeout' });
    const first = pids();
    expect(first).toBeDefined();
    seen.push(...first!);
    await until(() => first!.every((p) => !alive(p)), '超时后检查命令和它的子进程都停掉', 500);

    rmSync(pidFile);
    const ac = new AbortController();
    const running = runCheck({ main, worktree: wt, signal: ac.signal });
    const second = await until(pids, '检查命令起了子进程', 500);
    seen.push(...second);
    ac.abort();
    const aborted = await running;
    expect(aborted).toMatchObject({ ok: false, code: null, stopped: 'aborted' });
    await until(() => second.every((p) => !alive(p)), '被停下后检查命令和它的子进程都停掉', 500);
  } finally {
    // 没停掉的留到这里清理，免得 sleep 挂 30 秒
    for (const p of seen) try { process.kill(p, 'SIGKILL'); } catch { /* 已经不在 */ }
  }
});
