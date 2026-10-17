/**
 * 通用 monitor（docs/Monitor.md）：代理用 monitor_start 开的 kite.monitor 实例。本进程起 kited，模型换成 ManualModel，
 * 命令来源在代理的沙箱里真实运行。事件到唤醒的合批等待默认 1 秒，小测试的预算不够真等，起 kited 时缩短到 50 毫秒；
 * 同一来源 200 毫秒内的行合成一个事件不变。
 */
import { afterEach, expect, test } from 'bun:test';
import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import type { Input, Json, ModelItem, ModelRequest, ToolResult } from '../../src/harness/types.ts';
import { MONITOR_DAILY_WAKES, type MonitorEvent, monitorRuntimeState } from '../../src/monitor/monitors.ts';
import type { PluginInstance } from '../../src/model.ts';
import { folderWorkspace, type Kited, mark, startKited, waitIdle } from '../harness.ts';
import { diskRecords, item, ManualModel } from '../harness-loop.ts';
import { newDir, until } from '../util.ts';

let kited: Kited | undefined;
afterEach(async () => {
  await kited?.stop();
  kited = undefined;
});

const calledItem = (id: string, name: string, args: Json): ModelItem => ({ ...item(id, name), call: { id, name, arguments: args } });
const resultOf = (request: ModelRequest, callId: string): ToolResult | undefined => {
  const found = request.history.find((entry) => entry.type === 'tool_result' && entry.callId === callId);
  return found?.type === 'tool_result' ? found.result : undefined;
};
const outputOf = <T>(request: ModelRequest, callId: string): T => {
  const result = resultOf(request, callId);
  if (result?.status !== 'success') throw new Error(`${callId} 没有成功：${JSON.stringify(result)}`);
  return JSON.parse(result.output) as T;
};

/** 线程日志里收到的 Kite 来源输入（monitor 的唤醒）；线程还没跑过时没有日志。 */
function wakesOf(k: Kited, threadId: string): Input[] {
  const journal = join(k.home, 'sessions', threadId, 'journal.jsonl');
  if (!existsSync(journal)) return [];
  return diskRecords(journal).flatMap((record) => record.type === 'input.received' && record.input.source === 'kite' ? [record.input] : []);
}

/** 进程还在不在：信号 0 只检查，不发信号。 */
function alive(pid: number): boolean {
  try { process.kill(pid, 0); return true; } catch { return false; }
}

/** 一个工作区和其中的一个工作代理；代理已经开始第一回合，第一次模型请求挂着。 */
async function agentSetup() {
  const model = new ManualModel();
  const k = startKited(() => model, false, { monitorWakeDelayMs: 50 });
  kited = k;
  const registered = await folderWorkspace(k, newDir(k.root, 'project', { 'a.txt': 'a\n' }));
  const workspaceId = registered.workspace.id;
  const started = await k.call('POST', `/workspaces/${workspaceId}/operations/agent.start`, { operationId: 'agent' });
  expect(started.status).toBe(200);
  const agentId = started.body.instanceId as string;
  const sent = await k.call('POST', `/threads/${agentId}/messages`, { id: 'kickoff', text: '盯着构建' });
  expect(sent.status).toBe(200);
  const instance = (id: string): PluginInstance => {
    const found = k.daemon.kite.store.instance(id);
    if (!found) throw new Error(`没有实例 ${id}`);
    return found;
  };
  const events = (id: string): MonitorEvent[] => monitorRuntimeState(instance(id)).events;
  return { k, model, workspaceId, cwd: registered.workspace.cwd, agentId, instance, events, first: await model.call(1) };
}

/*
 * 几个部分的配合：命令在代理的沙箱里运行，标准输出经 200 毫秒合批成事件，退出记结束；事件稍等合成一条 Kite 来源的输入
 * 投给开它的代理，代理空闲时开始新回合。唤醒次数按天计，用完后新事件只记时间线、不再投递。
 * 依赖 sh 的行为：两次 printf 是两次写，中间 sleep 0.05 让它们分两次到达；第三行等测试放下闸门文件才输出，落在下一批。
 */
test('代理用 monitor_start 开的命令来源：200 毫秒内的几行合成一个事件、退出记结束，事件合成一条带标题与实例 ID 的输入唤醒代理；当天唤醒用完后新事件只进时间线并记一条说明；monitor_list 列得出，monitor_stop 后归档', async () => {
  const s = await agentSetup();
  expect(s.first.request.allowedTools).toEqual(expect.arrayContaining(['monitor_start', 'monitor_list', 'monitor_stop']));
  await s.first.response.emit({ type: 'item', item: calledItem('start', 'monitor_start', { title: '等构建', command:
    "printf '第一行\\n'; sleep 0.05; printf '第二行\\n'; while [ ! -e go ]; do sleep 0.02; done; printf '第三行\\n'; exit 3" }) });
  s.first.response.complete();
  const second = await s.model.call(2);
  const { instanceId } = outputOf<{ instanceId: string }>(second.request, 'start');
  let since = mark(s.k);
  second.response.complete();
  await waitIdle(s.k, s.agentId, since);

  // 前两行合成一个事件，稍等后唤醒：代理空闲，开始新回合，输入是 Kite 来源，正文带标题与实例 ID。
  const woke = await s.model.call(3);
  const wake = woke.request.history.flatMap((entry) => entry.type === 'input' ? [entry.input] : []).at(-1)!;
  expect(wake.source).toBe('kite');
  expect(wake.text).toContain('等构建');
  expect(wake.text).toContain(instanceId);
  expect(wake.text).toContain('第一行\n第二行');

  // 当天的唤醒用完（等这次投递落定再改，免得被投递的收尾覆盖）：第三行与命令退出只记进时间线，另记一条说明，不再投给代理。
  const runtime = await until(() => {
    const current = monitorRuntimeState(s.instance(instanceId));
    return current.pending === undefined && current.wakes !== undefined && current;
  }, '投递落定', 900);
  s.k.daemon.kite.store.setInstanceState(instanceId, { ...s.instance(instanceId).state,
    monitor: { ...runtime, wakes: { ...runtime.wakes!, count: MONITOR_DAILY_WAKES } } });
  writeFileSync(join(s.cwd, 'go'), '');
  await until(() => ['end', 'note'].every((kind) => s.events(instanceId).some((event) => event.kind === kind)), '命令退出记结束、用完唤醒次数记一条说明', 900);
  const timeline = s.events(instanceId);
  expect(timeline.map((event) => event.kind)).toEqual(['event', 'event', 'end', 'note']);
  expect(timeline.slice(0, 2).map((event) => event.text)).toEqual(['第一行\n第二行', '第三行']);
  expect(timeline[2]!.text).toContain('3');
  expect(wakesOf(s.k, s.agentId).map((input) => input.id)).toEqual([wake.id]);

  // 代理在这一回合里列出并停掉它：停掉即归档，时间线保留。
  await woke.response.emit({ type: 'item', item: calledItem('list', 'monitor_list', {}) });
  woke.response.complete();
  const listed = await s.model.call(4);
  const { monitors } = outputOf<{ monitors: Array<{ instanceId: string; title: string }> }>(listed.request, 'list');
  expect(monitors.map((monitor) => [monitor.instanceId, monitor.title])).toEqual([[instanceId, '等构建']]);
  await listed.response.emit({ type: 'item', item: calledItem('stop', 'monitor_stop', { instanceId }) });
  listed.response.complete();
  const stopped = await s.model.call(5);
  expect(resultOf(stopped.request, 'stop')?.status).toBe('success');
  expect(s.instance(instanceId).status).toBe('archived');
  expect(s.events(instanceId)).toEqual(timeline);
  since = mark(s.k);
  stopped.response.complete();
  await waitIdle(s.k, s.agentId, since);
}, 1000);

/*
 * 几个部分的配合：命令来源是常驻的子进程，工作区状态变化经事件总线触发核对，monitor 据工作区、对象代理与实例自己的状态
 * 停下或重新拉起进程；停下不算来源结束，重新拉起时时间线记一条。monitor_stop 与对象代理归档两条路径都要停掉进程。
 * 这里只改工作区状态字段并发出 workspace.changed，与交接、撤回改的是同一个字段、发的是同一个事件；真走一遍交接太慢。
 * 命令把 sh 的进程号（$$）写进工作区里的文件，exec sleep 沿用同一个进程号，测试据此确认进程在不在；不往标准输出写，
 * 时间线上只有 monitor 自己记的说明。
 */
test('工作区不再打开时停下 monitor 的命令且不算结束，回到打开后重新开始并在时间线上记一条；monitor_stop 停下进程并归档，对象代理归档时其余的 monitor 随之归档并停下', async () => {
  const s = await agentSetup();
  const command = (name: string) => `echo $$ > ${name}.pid; exec sleep 30`;
  await s.first.response.emit({ type: 'item', item: calledItem('start-a', 'monitor_start', { title: '甲', command: command('a') }) });
  await s.first.response.emit({ type: 'item', item: calledItem('start-b', 'monitor_start', { title: '乙', command: command('b') }) });
  s.first.response.complete();
  const second = await s.model.call(2);
  const a = outputOf<{ instanceId: string }>(second.request, 'start-a').instanceId;
  const b = outputOf<{ instanceId: string }>(second.request, 'start-b').instanceId;
  let since = mark(s.k);
  second.response.complete();
  await waitIdle(s.k, s.agentId, since);

  /** 命令写下的进程号；传入上一次的进程号时等它换成新的。 */
  const pid = (name: string, previous?: number) => until(() => {
    const file = join(s.cwd, `${name}.pid`);
    const value = existsSync(file) ? Number(readFileSync(file, 'utf8')) : 0;
    return value > 0 && value !== previous && value;
  }, `${name} 的命令拉起`, 900);
  const first = [await pid('a'), await pid('b')];
  expect(first.map(alive)).toEqual([true, true]);

  const status = (next: 'handing_off' | 'open') => {
    s.k.daemon.kite.store.setWorkspaceStatus(s.workspaceId, next);
    s.k.daemon.kite.bus.emit({ type: 'workspace.changed', workspaceId: s.workspaceId, status: next });
  };
  status('handing_off');
  await until(() => first.every((p) => !alive(p)), '工作区交接中时进程停下', 900);
  for (const id of [a, b]) {
    expect(monitorRuntimeState(s.instance(id)).ended).toEqual({});
    expect(s.events(id)).toEqual([]);
  }

  status('open');
  const again = [await pid('a', first[0]), await pid('b', first[1])];
  expect(again.map(alive)).toEqual([true, true]);
  for (const id of [a, b]) {
    const timeline = s.events(id);
    expect(timeline.map((event) => event.kind)).toEqual(['note']);
    expect(timeline[0]!.text).toContain('重新开始');
  }

  // 代理停掉甲：甲归档、进程停下，乙不受影响。
  const sent = await s.k.call('POST', `/threads/${s.agentId}/messages`, { id: 'stop-a', text: '甲不用盯了' });
  expect(sent.status).toBe(200);
  const third = await s.model.call(3);
  await third.response.emit({ type: 'item', item: calledItem('stop-a', 'monitor_stop', { instanceId: a }) });
  third.response.complete();
  const fourth = await s.model.call(4);
  expect(resultOf(fourth.request, 'stop-a')?.status).toBe('success');
  expect(s.instance(a).status).toBe('archived');
  await until(() => !alive(again[0]!), 'monitor_stop 后进程停下', 900);
  expect(alive(again[1]!)).toBe(true);
  since = mark(s.k);
  fourth.response.complete();
  await waitIdle(s.k, s.agentId, since);

  // 对象代理归档：乙随之归档，进程停下。
  expect((await s.k.call('POST', `/instances/${s.agentId}/archive`)).status).toBe(200);
  await until(() => s.instance(b).status === 'archived', '对象代理归档后 monitor 随之归档', 900);
  await until(() => !alive(again[1]!), '对象代理归档后进程停下', 900);
}, 1000);
