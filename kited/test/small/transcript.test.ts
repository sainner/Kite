import { afterEach, expect, test } from 'bun:test';
import { rmSync } from 'node:fs';
import { join } from 'node:path';
import { startDaemon, type Daemon } from '../../src/daemon.ts';
import { call, registerProject, startKited, type Kited } from '../harness.ts';
import { ManualModel, Seen } from '../harness-loop.ts';
import { makeTemp, newRepo } from '../util.ts';

type RecordView = { id: string; at: number; block: { type: string; [key: string]: unknown }; parent?: string; partial?: boolean };
type PendingView = { id: string; text: string; source: string; midTurn: boolean };
type WireEvent = {
  type: string;
  session: string;
  cursor: string;
  at: number;
  version?: number;
  records?: RecordView[];
  record?: RecordView;
  pending?: PendingView[];
  state?: unknown;
};

const roots: string[] = [];
let kited: Kited | undefined;
let daemon: Daemon | undefined;
afterEach(async () => {
  await daemon?.stop();
  daemon = undefined;
  await kited?.stop();
  kited = undefined;
  for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true });
});

async function connect(url: string, session: string) {
  const ctl = new AbortController();
  const response = await fetch(`${url}/events?session=${session}`, { signal: ctl.signal });
  expect(response.status).toBe(200);
  const events = new Seen<WireEvent>();
  const reading = (async () => {
    const reader = response.body!.pipeThrough(new TextDecoderStream()).getReader();
    let buffer = '';
    try {
      while (true) {
        const { value, done } = await reader.read();
        if (done) return;
        buffer += value;
        let end: number;
        while ((end = buffer.indexOf('\n\n')) >= 0) {
          const frame = buffer.slice(0, end);
          buffer = buffer.slice(end + 2);
          const data = frame.split('\n').filter((line) => line.startsWith('data: ')).map((line) => line.slice(6)).join('\n');
          if (data) events.add(JSON.parse(data) as WireEvent);
        }
      }
    } catch (error) {
      if (!ctl.signal.aborted) throw error;
    }
  })();
  return {
    events,
    async close() { ctl.abort(); await reading; },
  };
}

function apply(events: WireEvent[]) {
  let records = new Map<string, RecordView>();
  let pending: PendingView[] = [];
  for (const event of events) {
    if (event.type === 'history') {
      records = new Map(event.records!.map((record) => [record.id, record]));
      pending = event.pending!;
    } else if (event.type === 'record') records.set(event.record!.id, event.record!);
    else if (event.type === 'pending') pending = event.pending!;
  }
  return { records: [...records.values()], pending };
}

// Bun 的 HTTP 流、模型增量、journal 落盘及 SSE 重连交错时，完整条目必须替换原位置且 pending 交给 human。
test('SSE 重连以含 partial 的历史为基线，完整记录原位替换且排队输入只出现一次', async () => {
  const model = new ManualModel();
  kited = startKited(() => model);
  const kk = kited;
  const repo = newRepo(kk.root, 'project', { 'base.txt': '初始\n' });
  const project = await registerProject(kk, repo);
  const created = await kk.call('POST', '/sessions', { project: project.id, prompt: '开始' });
  expect(created.status).toBe(200);
  const id = created.body.id as string;
  const first = await model.call(1);
  const stream = await connect(kk.url, id);
  const baseline = await stream.events.wait((event) => event.type === 'history');
  expect(baseline).toMatchObject({ version: 1, session: id });

  await first.response.emit({ type: 'delta', itemId: 'answer-a', text: '半' });
  const partial = await stream.events.wait((event) => event.type === 'record' && event.record?.partial === true && event.record.block.text === '半');
  expect(partial.record?.block.type).toBe('text');
  await stream.close();

  const resumed = await connect(kk.url, id);
  const reconnected = await resumed.events.wait((event) => event.type === 'history');
  expect(reconnected.records?.find((record) => record.id === partial.record?.id)).toEqual(partial.record);

  const queued = await kk.call('POST', `/sessions/${id}/messages`, { id: 'queued-a', text: '接着做' });
  expect(queued.status).toBe(200);
  await resumed.events.wait((event) => event.type === 'pending' && event.pending?.some((entry) => entry.id === 'queued-a') === true);
  await first.response.emit({ type: 'item', item: { id: 'answer-a', raw: { type: 'message', content: [{ type: 'output_text', text: '完整' }] } } });
  const complete = await resumed.events.wait((event) => event.type === 'record' && event.record?.id === partial.record?.id && event.record?.partial !== true && event.record?.block.text === '完整');
  expect(complete.record?.block.type).toBe('text');
  first.response.complete();
  const second = await model.call(2);
  await resumed.events.wait((event) => event.type === 'record' && event.record?.block.type === 'human' && event.record.block.id === 'queued-a');
  await resumed.events.wait((event) => event.type === 'pending' && event.pending?.some((entry) => entry.id === 'queued-a') === false);

  const history = await kk.call('GET', `/sessions/${id}/history`);
  expect(history.status).toBe(200);
  expect(history.body).toMatchObject({ version: 1, session: id });
  const replayed = apply(resumed.events.values);
  expect(replayed.records).toEqual(history.body.records);
  expect(replayed.pending).toEqual(history.body.pending);
  expect(replayed.records.filter((record) => record.block.type === 'human' && record.block.id === 'queued-a')).toHaveLength(1);
  expect(replayed.records.filter((record) => record.id === partial.record?.id)).toHaveLength(1);
  second.response.complete();
  await resumed.close();
}, 1000);

// SQLite 和 native journal 在 daemon 关闭重开后共同重建视图；只读历史不能启动模型或更改记录 id。
test('重启后只读历史保持记录 id 和排队输入，重复发送及取消不唤醒模型', async () => {
  const root = makeTemp('transcript-');
  roots.push(root);
  const home = join(root, 'kite');
  const repo = newRepo(root, 'project', { 'base.txt': '初始\n' });
  const firstModel = new ManualModel();
  daemon = startDaemon({ home, port: 0, model: () => firstModel });
  const project = await call(daemon.url, 'POST', '/projects', { path: repo });
  expect(project.status).toBe(200);
  const created = await call(daemon.url, 'POST', '/sessions', { project: project.body.id, prompt: '保持挂起' });
  expect(created.status).toBe(200);
  const id = created.body.id as string;
  const active = await firstModel.call(1);
  const queued = await call(daemon.url, 'POST', `/sessions/${id}/messages`, { id: 'queued-after-restart', text: '恢复后继续' });
  expect(queued.status).toBe(200);
  const before = await call(daemon.url, 'GET', `/sessions/${id}/history`);
  expect(before.status).toBe(200);
  expect(before.body.pending).toContainEqual(expect.objectContaining({ id: 'queued-after-restart', text: '恢复后继续' }));
  await daemon.stop();
  daemon = undefined;
  expect(active.signal.aborted).toBe(true);

  const secondModel = new ManualModel();
  daemon = startDaemon({ home, port: 0, model: () => secondModel });
  const restored = await call(daemon.url, 'GET', `/sessions/${id}/history`);
  expect(restored.status).toBe(200);
  expect(restored.body.records.slice(0, before.body.records.length)).toEqual(before.body.records);
  expect(restored.body.pending).toEqual(before.body.pending);
  expect(secondModel.calls.values).toHaveLength(0);

  const duplicate = await call(daemon.url, 'POST', `/sessions/${id}/messages`, { id: 'queued-after-restart', text: '恢复后继续' });
  expect(duplicate.status).toBe(200);
  const afterDuplicate = await call(daemon.url, 'GET', `/sessions/${id}/history`);
  expect(afterDuplicate.body.pending.filter((entry: PendingView) => entry.id === 'queued-after-restart')).toHaveLength(1);
  const cancelled = await call(daemon.url, 'POST', `/sessions/${id}/messages/queued-after-restart/cancel`);
  expect(cancelled.status).toBe(200);
  const afterCancel = await call(daemon.url, 'GET', `/sessions/${id}/history`);
  expect(afterCancel.body.pending).toEqual([]);
  expect(secondModel.calls.values).toHaveLength(0);
}, 1000);
