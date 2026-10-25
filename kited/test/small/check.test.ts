/**
 * 会话的检查工具背后的 src/check.ts：同一个进程里的检查排队，一次只跑一个。
 */
import { expect, test } from 'bun:test';
import { chmodSync, mkdirSync, symlinkSync } from 'node:fs';
import { join } from 'node:path';
import { runCheck } from '../../src/check.ts';
import { commandEnvironment, workspacePolicy } from '../../src/execution/sandbox.ts';
import { lexists, read, until, useTemp, writeFiles } from '../util.ts';

const temp = useTemp();

/*
 * 并发和时序：几次 runCheck 同时发起时怎么排队、排队时被停下怎么收场，看代码确认不了；每次检查还要真起一次沙箱。
 * 第一个的检查命令停在放行文件上，放行之前后面的都在排队，第二个就在这时被停下。
 */
test('并发检查按顺序串行，排队时取消立即返回且后续检查照常运行', async () => {
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
  // 每次调用一个文件夹，既当主文件夹又当工作树（取不到 HEAD，不传 KITE_BASE）：排队不分工作树
  const folder = (name: string) => {
    const dir = join(root, name);
    mkdirSync(join(dir, '.kite'), { recursive: true });
    symlinkSync(script, join(dir, '.kite/check'));
    return dir;
  };
  const [a, b, c, d] = [folder('a'), folder('b'), folder('c'), folder('d')];
  // 脚本读写工作树外的 ../log、../go，沙箱按整个临时目录放行
  const env = commandEnvironment(process.env);
  const policy = workspacePolicy(root, env);
  const logs = join(root, 'logs');
  const check = (dir: string, signal = new AbortController().signal) =>
    runCheck(false, signal, { main: dir, logs, command: { cwd: dir, env, policy } });

  const ac = new AbortController();
  const runs = [check(a), check(b, ac.signal), check(c), check(d)];
  try {
    await until(() => lines().includes('start a'), 'a 的检查命令开始', 2_000);
    ac.abort();
    const rb = await runs[1]!;
    expect(rb.status).toBe('not_executed');
    // b 返回时 a 还停在放行文件上：b 没等 a 跑完；c、d 也还没开始
    expect(lines()).toEqual(['start a']);

    writeFiles(root, { go: '' });
    const [ra, , rc, rd] = await Promise.all(runs);
    // 运行时间不重叠、按发起顺序，b 从没启动
    expect(lines()).toEqual(['start a', 'end a', 'start c', 'end c', 'start d', 'end d']);
    expect([ra!.status, rc!.status, rd!.status]).toEqual(['success', 'success', 'success']);
  } finally {
    // 失败时也放行 a、等全部收场，免得队列卡着
    writeFiles(root, { go: '' });
    await Promise.allSettled(runs);
  }
});
