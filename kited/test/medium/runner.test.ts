/**
 * Claude Code 进程的开关（src/runner.ts 的 Runner），模型换成假端点：D2、D3、D5。
 * 只 import runner.ts，不经 daemon。
 */
import { afterEach, expect, setDefaultTimeout, test } from 'bun:test';
import { randomUUID } from 'node:crypto';
import { Runner, type RunnerEvents, type RunnerState } from '../../src/runner.ts';
import { api } from '../setup.ts';
import { until, useTemp } from '../util.ts';

setDefaultTimeout(20_000);

// 先关 Runner 再删临时目录：afterEach 按登记的先后执行
const runners: Runner[] = [];
afterEach(async () => {
  api.releaseAll();
  for (const r of runners.splice(0)) await r.shutdown();
});
const temp = useTemp();

type Rec =
  | { kind: 'message'; m: Parameters<RunnerEvents['message']>[0] }
  | { kind: 'toolBatch' }
  | { kind: 'turnStart'; prompt: string }
  | { kind: 'turnEnd' }
  | { kind: 'idle' }
  | { kind: 'state'; state: RunnerState; error?: string };

/** 起一个 Runner，记下它发出的全部事件。 */
function startRunner() {
  const log: Rec[] = [];
  const waiters: Array<{ pred: (r: Rec) => boolean; resolve: () => void }> = [];
  const push = (r: Rec) => {
    log.push(r);
    for (const w of [...waiters]) if (w.pred(r)) { waiters.splice(waiters.indexOf(w), 1); w.resolve(); }
  };
  const on: RunnerEvents = {
    message: (m) => push({ kind: 'message', m }),
    toolBatch: async () => push({ kind: 'toolBatch' }),
    turnStart: (prompt) => push({ kind: 'turnStart', prompt }),
    turnEnd: async () => push({ kind: 'turnEnd' }),
    idle: () => push({ kind: 'idle' }),
    state: (state, error) => push({ kind: 'state', state, error }),
  };
  const runner = new Runner({ cwd: temp(), nativeId: randomUUID(), title: '测试' }, on);
  runners.push(runner);
  return {
    runner,
    log,
    /** 当前事件数，配合 wait 的 since 只看之后的事件。 */
    mark: () => log.length,
    wait(pred: (r: Rec) => boolean, since = 0, timeoutMs = 10_000): Promise<void> {
      if (log.slice(since).some(pred)) return Promise.resolve();
      return new Promise((resolve, reject) => {
        const w = { pred, resolve: () => { clearTimeout(t); resolve(); } };
        const t = setTimeout(() => { waiters.splice(waiters.indexOf(w), 1); reject(new Error('等待 Runner 事件超时')); }, timeoutMs);
        waiters.push(w);
      });
    },
    states: (since = 0) => log.slice(since).flatMap((r) => (r.kind === 'state' ? [r.state] : [])),
  };
}

const tag = (name: string) => `${name}-${randomUUID().slice(0, 8)}`;
const history = (l: { body: any }) => JSON.stringify(l.body.messages);
const closed = (r: Rec) => r.kind === 'state' && r.state === 'closed';

test('回合结束时有后台任务，runner 不关；后台任务完成后 agent 自动开新回合（task-notification），这一回合结束后 runner 关闭', async () => {
  const { runner, wait, mark, states } = startRunner();
  const bg = tag('bg');
  runner.send({ text: `BG ${bg}`, human: true });

  // 第一回合（启动后台任务）结束
  await wait((r) => r.kind === 'idle');
  expect(runner.state).toBe('running');
  expect(states()).toEqual(['running']);

  const m = mark();
  const sent = Date.now();
  api.release(bg);
  await api.waitRequest((l) => l.main && l.at >= sent && l.lastUserText.includes('task-notification'));
  await wait(closed, m);
  expect(states()).toEqual(['running', 'closing', 'closed']);
  expect(runner.busy).toBe(false);
});

test('回合进行中又发来的消息不丢，最终到达 agent，runner 最后关闭', async () => {
  const { runner, wait, mark } = startRunner();
  const hold = tag('d3');
  const b = tag('插队一');
  const c = tag('插队二');
  runner.send({ text: `HOLD ${hold} 慢回合`, human: true });
  await api.held(hold);
  runner.send({ text: `插队消息 ${b}`, human: true });
  runner.send({ text: `又一条插队消息 ${c}`, human: true });
  api.release(hold);

  await api.waitRequest((l) => l.main && history(l).includes(b) && history(l).includes(c));
  const m = mark();
  await wait(closed, m);
  expect(runner.state).toBe('closed');
  expect(runner.busy).toBe(false);
});

/* 回归一个 bug：回合开始前（进程刚从 closed 启动、正在 resume）的打断曾被忽略，回合照常跑完。 */
test('打断：回合进行中打断，busy 很快变 false；刚发消息、回合还没开始就打断，这条消息不会到达模型，busy 变 false', async () => {
  const { runner, wait, mark } = startRunner();

  // 回合进行中：请求挂在假端点上，不打断就永远不结束
  const a = tag('d5a');
  runner.send({ text: `HOLD ${a} 很慢的回合`, human: true });
  await api.held(a);
  await runner.interrupt();
  await until(() => !runner.busy, 'busy 变 false', 2_000);
  // 被打断的消息会和下一条并进同一条用户消息，放行它，免得下一回合又被挂起
  api.release(a);

  // 正常跑完一回合，runner 关闭
  const m = mark();
  runner.send({ text: `收尾 ${tag('d5')}`, human: true });
  await wait(closed, m);

  // runner 从 closed 刚启动、回合还没开始就打断
  const b = tag('d5b');
  runner.send({ text: `HOLD ${b} 不该发出去`, human: true });
  expect(runner.state).toBe('running');
  await runner.interrupt();
  await until(() => !runner.busy, 'busy 变 false', 2_000);
  const reached = () => api.log.filter((l) => JSON.stringify(l.body).includes(b)).map((l) => l.lastUserText);
  expect(reached()).toEqual([]);

  // 之后再发一条：它的请求到达时，被打断的那条如果发出去过，一定在它之前或在它的历史里
  const c = tag('d5c');
  runner.send({ text: `之后 ${c}`, human: true });
  await api.waitRequest((l) => l.main && l.lastUserText.includes(c));
  expect(reached()).toEqual([]);
});
