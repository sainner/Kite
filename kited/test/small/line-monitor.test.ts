/**
 * Line 的 monitor 路由中与时间有关的状态流转（docs/Line与工作区流转.md「Line 的收件箱、代处理与托管」「monitor 的事件路由」）：
 * 直接调 route、collect、attend 这几个纯函数，传入时刻，不真的等。一轮 monitor 就是先 route 再 collect。
 * 汇总的形状照 B 上真实的 GET /summary：在等提问的线程 phase 为 running、busy 为真并带 waiting；结束回合后 phase 为 idle、带 settledAt。
 */
import { expect, test } from 'bun:test';
import type { AccountMachine } from '../../src/account-data/directory.ts';
import type { MachineSummary } from '../../src/kite.ts';
import { attend, collect, DAILY_WAKES, monitorState, type MonitorState, route } from '../../src/line/monitor.ts';
import type { Waiting } from '../../src/waiting.ts';

type ThreadSummary = MachineSummary['workspaces'][number]['threads'][number];

const SECOND = 1_000;
const MINUTE = 60 * SECOND;
const HOUR = 60 * MINUTE;
/** 本机时区的上午九点：每日预算按本机时区的日子计。 */
const t0 = new Date(2026, 9, 15, 9, 0, 0).getTime();

const machineB: AccountMachine = { id: 'machine-b', name: '工作机 B', online: true, address: 'http://machine-b.invalid' };

const question = (id: string, since: number): Waiting => ({ id, since, kind: 'question', questions: [{
  question: `问题 ${id}`, multiSelect: false,
  options: [{ label: '甲', description: '选甲' }, { label: '乙', description: '选乙' }],
}] });
/** 别人发起、正卡在一个提问上的线程。 */
const asking = (thread: string, waiting: string, since: number): ThreadSummary => ({
  id: thread, title: `线程 ${thread}`, role: 'kite.work', phase: 'running', busy: true, waitingForResume: false, waiting: question(waiting, since),
});
/** Line 发起的工作：还在跑，或已结束回合。 */
const lineWork = (thread: string, settledAt?: number): ThreadSummary => settledAt === undefined
  ? { id: thread, title: `线程 ${thread}`, role: 'kite.work', phase: 'running', busy: true, waitingForResume: false, byLine: true }
  : { id: thread, title: `线程 ${thread}`, role: 'kite.work', phase: 'idle', busy: false, waitingForResume: false, lastOutcome: 'completed', settledAt, byLine: true };

const fresh = (): MonitorState => monitorState({ state: {} });

/** 一轮 monitor：B 的汇总里是这些线程。 */
function round(state: MonitorState, threads: ThreadSummary[], now: number, focused = false) {
  const summary: MachineSummary = { machine: { id: machineB.id, name: machineB.name }, workspaces: [{
    id: 'workspace-b', epoch: 1, status: 'open', name: 'work', project: { id: 'project-b', name: '项目 B' }, threads,
  }] };
  const notes = route(state, { line: 'line-thread', machines: [machineB], summaries: new Map([[machineB.id, summary]]), focused, now });
  return collect(state, now, focused, notes);
}

/*
 * 几个时间条件的组合：托管攒批与时段结束、各项各自的超时、跨日的唤醒预算与预算外的去向、离开与回来的时长和事项进来的时刻。
 */
test(`时段托管攒够 15 秒合并唤醒且到点结束，超时托管逐项到点交出；每天自动唤醒 ${DAILY_WAKES} 次用满后托管的提问交回用户、Line 发起的工作结果只进收件箱，次日重计；离开够 30 分钟且期间有新事项，回来才排简报`, () => {
  // 按时段托管：新进的提问先攒着，攒够 15 秒把期间进来的合成一次唤醒；时段到点后新进的不再交给 Line。
  const period = fresh();
  period.delegation = { until: t0 + 2 * HOUR };
  const one = asking('t1', 'w1', t0);
  const two = asking('t2', 'w2', t0 + 5 * SECOND);
  expect(round(period, [one], t0)).toBeUndefined();
  expect(period.items['waiting:w1']?.delegated?.by).toBe('period');
  expect(round(period, [one, two], t0 + 5 * SECOND)).toBeUndefined();
  expect(round(period, [one, two], t0 + 10 * SECOND)).toBeUndefined();
  expect(round(period, [one, two], t0 + 20 * SECOND)?.delegated.map((item) => item.id)).toEqual(['waiting:w1', 'waiting:w2']);
  expect(round(period, [one, two], t0 + 40 * SECOND)).toBeUndefined();
  // 时段已过：新进的提问留给用户。
  const late = asking('t3', 'w3', t0 + 2 * HOUR + MINUTE);
  expect(round(period, [late], t0 + 2 * HOUR + MINUTE)).toBeUndefined();
  expect(round(period, [late], t0 + 2 * HOUR + 2 * MINUTE)).toBeUndefined();
  expect(period.items['waiting:w3']?.delegated).toBeUndefined();

  // 超时托管：每一项按各自进收件箱的时刻计时，到点只交这一项。
  const timeout = fresh();
  timeout.delegation = { timeoutMinutes: 15 };
  const early = asking('t1', 'w1', t0);
  const later = asking('t2', 'w2', t0 + 10 * MINUTE);
  expect(round(timeout, [early], t0)).toBeUndefined();
  expect(round(timeout, [early, later], t0 + 10 * MINUTE)).toBeUndefined();
  expect(round(timeout, [early, later], t0 + 14 * MINUTE)).toBeUndefined();
  expect(round(timeout, [early, later], t0 + 15 * MINUTE + SECOND)?.delegated.map((item) => [item.id, item.delegated?.by]))
    .toEqual([['waiting:w1', 'timeout']]);
  expect(timeout.items['waiting:w2']?.delegated).toBeUndefined();
  expect(round(timeout, [early, later], t0 + 25 * MINUTE + SECOND)?.delegated.map((item) => item.id)).toEqual(['waiting:w2']);

  // 每日唤醒预算：用满后托管中新进的提问交回用户并写明原因，Line 发起的工作结果也只进收件箱；第二天重新计。
  const budget = fresh();
  budget.delegation = { until: t0 + 36 * HOUR };
  for (let i = 0; i < DAILY_WAKES; i++) {
    const at = t0 + i * MINUTE;
    const thread = asking(`t${i}`, `w${i}`, at);
    expect(round(budget, [thread], at)).toBeUndefined();
    expect(round(budget, [thread], at + 20 * SECOND)?.delegated.map((item) => item.id)).toEqual([`waiting:w${i}`]);
  }

  const over = t0 + DAILY_WAKES * MINUTE;
  const extra = asking('t-extra', 'w-extra', over);
  expect(round(budget, [extra], over)).toBeUndefined();
  expect(round(budget, [extra], over + 20 * SECOND)).toBeUndefined();
  const left = budget.items['waiting:w-extra']!;
  expect([left.left, left.delegated]).toEqual([true, undefined]);
  expect(left.note).toBeTruthy();

  expect(round(budget, [extra, lineWork('t-line')], over + MINUTE)).toBeUndefined();
  expect(round(budget, [extra, lineWork('t-line', over + 90 * SECOND)], over + 2 * MINUTE)).toBeUndefined();
  expect(Object.values(budget.items).filter((item) => item.thread?.id === 't-line')).toHaveLength(1);

  const tomorrow = t0 + 24 * HOUR;
  const next = asking('t-next', 'w-next', tomorrow);
  expect(round(budget, [next], tomorrow)).toBeUndefined();
  expect(round(budget, [next], tomorrow + 20 * SECOND)?.delegated.map((item) => item.id)).toEqual(['waiting:w-next']);

  // 简报：关注设备变空记下离开时刻，回来时离开够 30 分钟、且收件箱里有离开期间进来的事项，才排一次简报。
  const away = fresh();
  const old = asking('t1', 'w1', t0);
  expect(round(away, [old], t0, true)).toBeUndefined();

  attend(away, false, t0 + MINUTE);
  const fresher = asking('t2', 'w2', t0 + 2 * MINUTE);
  expect(round(away, [old, fresher], t0 + 2 * MINUTE)).toBeUndefined();
  attend(away, true, t0 + 20 * MINUTE);
  expect(collect(away, t0 + 20 * MINUTE, true, [])).toBeUndefined();

  const t1 = t0 + HOUR;
  attend(away, false, t1);
  expect(round(away, [old, fresher], t1 + MINUTE)).toBeUndefined();
  attend(away, true, t1 + 40 * MINUTE);
  expect(collect(away, t1 + 40 * MINUTE, true, [])).toBeUndefined();

  const t2 = t0 + 2 * HOUR;
  attend(away, false, t2);
  const newest = asking('t3', 'w3', t2 + 5 * MINUTE);
  expect(round(away, [old, fresher, newest], t2 + 5 * MINUTE)).toBeUndefined();
  attend(away, true, t2 + 31 * MINUTE);
  const back = collect(away, t2 + 31 * MINUTE, true, []);
  expect(back?.briefing?.since).toBe(t2);
  expect(back?.briefing?.items.map((item) => item.id)).toContain('waiting:w3');
  expect(collect(away, t2 + 32 * MINUTE, true, [])).toBeUndefined();
});
