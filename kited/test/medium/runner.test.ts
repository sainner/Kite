/**
 * Claude Code 进程的排队与打断，模型换成假端点。
 * 只 import runner.ts，不经 daemon。
 */
import { afterEach, expect, setDefaultTimeout, test } from 'bun:test';
import { randomUUID } from 'node:crypto';
import { Runner, type RunnerEvents, type RunnerState } from '../../src/claude/runner.ts';
import { api } from '../setup.ts';
import { until, useTemp } from '../util.ts';

setDefaultTimeout(3_000);

// 先关 Runner 再删临时目录：afterEach 按登记的先后执行
const runners: Runner[] = [];
afterEach(async () => {
  api.releaseAll();
  for (const r of runners.splice(0)) await r.shutdown();
});
const temp = useTemp();

type Rec =
  | { kind: 'turnStart' }
  | { kind: 'turnEnd' }
  | { kind: 'idle' }
  | { kind: 'state'; state: RunnerState };

/** 起一个 Runner，记录回合与状态事件。 */
function startRunner() {
  const log: Rec[] = [];
  const waiters: Array<{ pred: (r: Rec) => boolean; resolve: () => void }> = [];
  const push = (r: Rec) => {
    log.push(r);
    for (const w of [...waiters]) if (w.pred(r)) { waiters.splice(waiters.indexOf(w), 1); w.resolve(); }
  };
  const on: RunnerEvents = {
    message() {},
    async toolBatch() {},
    turnStart: () => push({ kind: 'turnStart' }),
    turnEnd: async () => push({ kind: 'turnEnd' }),
    idle: () => push({ kind: 'idle' }),
    state: (state) => push({ kind: 'state', state }),
  };
  const runner = new Runner({ cwd: temp(), nativeId: randomUUID(), title: '测试' }, on);
  runners.push(runner);
  return {
    runner,
    log,
    /** 当前事件数，配合 wait 的 since 只看之后的事件。 */
    mark: () => log.length,
    wait(pred: (r: Rec) => boolean, since = 0): Promise<void> {
      if (log.slice(since).some(pred)) return Promise.resolve();
      return new Promise((resolve) => { waiters.push({ pred, resolve }); });
    },
    states: (since = 0) => log.slice(since).flatMap((r) => (r.kind === 'state' ? [r.state] : [])),
  };
}

const tag = (name: string) => `${name}-${randomUUID().slice(0, 8)}`;
const closed = (r: Rec) => r.kind === 'state' && r.state === 'closed';

/* 回归一个 bug：回合开始前（进程刚从 closed 启动、正在 resume）的打断曾被忽略，回合照常跑完。 */
test('Claude 支持生成中打断，续接前打断的消息不进入模型历史', async () => {
  const { runner, wait, mark } = startRunner();

  // 回合进行中：请求挂在假端点上，不打断就永远不结束
  const a = tag('生成中打断');
  runner.send({ text: `HOLD ${a} 很慢的回合`, human: true });
  await api.held(a);
  await runner.interrupt();
  await until(() => !runner.busy, 'busy 变 false', 2_000);
  // 被打断的消息会和下一条并进同一条用户消息，放行它，免得下一回合又被挂起
  api.release(a);

  // 正常跑完一回合，runner 关闭
  const m = mark();
  runner.send({ text: `收尾 ${tag('收尾')}`, human: true });
  await wait(closed, m);

  // runner 从 closed 刚启动、回合还没开始就打断
  const b = tag('续接前打断');
  runner.send({ text: `HOLD ${b} 不该发出去`, human: true });
  expect(runner.state).toBe('running');
  await runner.interrupt();
  await until(() => !runner.busy, 'busy 变 false', 2_000);
  const reached = () => api.log.filter((l) => JSON.stringify(l.body).includes(b)).map((l) => l.lastUserText);
  expect(reached()).toEqual([]);

  // 之后再发一条：它的请求到达时，被打断的那条如果发出去过，一定在它之前或在它的历史里
  const c = tag('打断后恢复');
  runner.send({ text: `之后 ${c}`, human: true });
  await api.waitRequest((l) => l.main && l.lastUserText.includes(c));
  expect(reached()).toEqual([]);
});
