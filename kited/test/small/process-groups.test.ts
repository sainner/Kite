import { afterEach, expect, test } from 'bun:test';
import { join } from 'node:path';
import {
  ownedProcessGroups, processGroupAlive, runCommand, stopProcessGroups, type BackgroundCommand,
} from '../../src/execution/command.ts';
import { deferred, Seen } from '../harness-loop.ts';
import { ENV, useTemp } from '../util.ts';

const temp = useTemp();
const started: BackgroundCommand[] = [];
// 失败时也别把进程留下：还在的整组 SIGKILL，等 runCommand 看到它结束。
afterEach(async () => {
  for (const command of started.splice(0)) {
    if (processGroupAlive(command.pid)) process.kill(-command.pid, 'SIGKILL');
    await command.done.catch(() => undefined);
  }
});

/**
 * 照 shell 工具的做法起一条一开始就转后台的命令（sh 带着一个后台的 sleep，同在一个进程组），等它输出 ready；
 * 返回的 pid 与 started 就是会话登记这个进程组时存下的。
 */
async function startGroup(): Promise<BackgroundCommand> {
  const root = temp('process-group-');
  const adopted = deferred<{ command: BackgroundCommand; heard: Seen<string> }>();
  const result = await runCommand('sleep 30 & echo ready; wait', 3000, new AbortController().signal, {
    cwd: root, logDir: join(root, 'logs'), env: ENV(),
    background: {
      immediately: true,
      adopt(command) {
        started.push(command);
        const heard = new Seen<string>();
        let text = command.output;
        heard.add(text);
        command.listen((chunk) => { text += chunk; heard.add(text); });
        adopted.resolve({ command, heard });
        return '已接管';
      },
    },
  });
  expect(result.status).toBe('success');
  const { command, heard } = await adopted.promise;
  await heard.wait((text) => text.includes('ready'));
  return command;
}

/*
 * 代码之外的东西：核对靠 ps -o pid=,lstart= 报的启动时刻（只到秒，格式随 locale、时区变）与 kited 起进程时记下的毫秒时刻对上，
 * 解析或换算错了，自己起的组也会被当成别人的，打开会话时停不掉上次留下的命令。依赖 macOS 的 ps 与进程组语义。
 */
test('登记的启动时刻对得上的命令进程组认作 Kite 起的，停下时整组都停掉、不再留在登记里', async () => {
  const command = await startGroup();
  const group = { pid: command.pid, started: command.started };
  expect(ownedProcessGroups([group])).toEqual([group]);
  expect(await stopProcessGroups([group])).toEqual([]);
  await command.done;
  expect(processGroupAlive(command.pid)).toBe(false);
}, 1000);

/*
 * 代码之外的东西：kited 崩溃后，登记里的组号可能已经给了别的进程，只能靠 ps 报的启动时刻认出来。
 * 依赖 macOS 的 ps 与进程组语义。
 */
test('组长还在、但启动时刻对不上（pid 被别的进程复用）的进程组不停，从返回的登记里去掉', async () => {
  const command = await startGroup();
  // 登记的是十分钟前起的那一组；眼下用着这个 pid 的是后来的进程。
  const reused = { pid: command.pid, started: command.started - 10 * 60_000 };
  expect(ownedProcessGroups([reused])).toEqual([]);
  expect(await stopProcessGroups([reused])).toEqual([]);
  expect(processGroupAlive(command.pid)).toBe(true);
}, 1000);
