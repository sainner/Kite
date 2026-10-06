import { afterEach, expect, setSystemTime, test } from 'bun:test';
import { randomUUID } from 'node:crypto';
import { join } from 'node:path';
import { saveClaudeControl, type ClaudeControl } from '../../src/claude/control.ts';
import { readClaudeMessages } from '../../src/claude/history.ts';
import { startDaemon, type Daemon } from '../../src/daemon.ts';
import type { ThreadContext } from '../../src/model.ts';
import type { DisplayEnvelope, History } from '../../src/transcript/protocol.ts';
import { api, call, type Kited, registerCheckout, startKited } from '../harness.ts';
import { ManualModel, Seen } from '../harness-loop.ts';
import { newDir } from '../util.ts';
import { writeClaudeHistory } from '../claude-history.ts';

let kited: Kited | undefined;
let reopened: Daemon | undefined;
afterEach(async () => {
  setSystemTime();
  await reopened?.stop(); reopened = undefined;
  await kited?.stop(); kited = undefined;
});

async function emptyThread() {
  kited = startKited();
  const repo = newDir(kited.root, 'project');
  const workspace = await registerCheckout(kited, repo);
  const opened = await kited.call('POST', `/workspaces/${workspace.workspace.id}/windows`, {
    id: randomUUID(), content: { kind: 'create', definitionId: 'kite.agent.claude' },
  });
  expect(opened.status).toBe(200);
  const id = opened.body.target.instanceId as string;
  const thread = (await kited.call('GET', `/threads/${id}`)).body as ThreadContext;
  await kited.daemon.stop();
  return { k: kited, id, thread, directory: join(kited.home, 'sessions', id) };
}


const receipt = (id: string, at: number, delivered = false): ClaudeControl['inputs'][number] => ({
  input: { id, text: `正文 ${id}`, source: 'human' }, sdkId: randomUUID(), at,
  status: 'submitted', delivered, midTurn: true,
});

// 真实回归：重启后 submitted 曾被当成完成而丢失；并发读取原生历史后，恢复和撤回仍须更新同一视图。
test('Claude 恢复按原生记录确认已纳入输入，未知输入可撤回且停止重试跨重开退回原草稿', async () => {
  const { k, id, thread, directory } = await emptyThread();
  const at = Date.now();
  const accepted = receipt('native-accepted', at);
  const delivered = receipt('receipt-confirmed', at + 1, true);
  const cancelled = receipt('unknown-to-cancel', at + 2);
  const returned = receipt('unknown-to-return', at + 3);
  writeClaudeHistory(thread, [{ uuid: accepted.sdkId, at, role: 'user', text: accepted.input.text }]);
  saveClaudeControl(directory, {
    inputs: [accepted, delivered, cancelled, returned], stops: [], processes: [], through: 0, paused: false,
    recovery: { message: '宿主退出时输入是否纳入尚未确认' },
  });
  reopened = startDaemon({ home: k.home, port: 0, lightTasks: false });
  const requestCount = api.log.length;
  const [initial, concurrentHistory, concurrentState] = await Promise.all([
    reopened.kite.history(id), reopened.kite.history(id), reopened.kite.threadState(id),
  ]);
  expect(concurrentHistory).toEqual(initial);
  expect(concurrentState).toEqual(initial.state);
  expect(reopened.kite.historyNow(id)).toEqual(initial);
  expect(api.log).toHaveLength(requestCount);
  const updates = new Seen<DisplayEnvelope>();
  const unsubscribe = reopened.kite.events.subscribe((event) => 'threadId' in event && event.threadId === id,
    (event) => updates.add(event));
  expect((await call(reopened.url, 'POST', `/threads/${id}/recover`)).status).toBe(200);
  const ready = (await call(reopened.url, 'GET', `/threads/${id}/history`)).body as History;
  expect(ready.state).toMatchObject({ busy: false, waitingForResume: true });
  expect(ready.state.capabilities).toMatchObject({ send: false, resume: true, cancel: true });
  expect(ready.state.recovery).toBeUndefined();
  expect(ready.pending.map((input) => input.id)).toEqual([cancelled.input.id, returned.input.id]);
  expect(ready.records.filter((record) => record.block.type === 'human' && record.block.id === accepted.input.id)).toHaveLength(1);
  expect(ready.records.filter((record) => record.block.type === 'human' && record.block.id === delivered.input.id)).toHaveLength(1);
  expect((await call(reopened.url, 'POST', `/threads/${id}/messages`, { id: 'unrelated', text: '别的事情' })).status).toBe(409);
  expect((await call(reopened.url, 'POST', `/threads/${id}/messages/${cancelled.input.id}/cancel`)).status).toBe(200);
  const afterCancel = (await call(reopened.url, 'GET', `/threads/${id}/history`)).body as History;
  expect(afterCancel.pending.map((input) => input.id)).toEqual([returned.input.id]);
  const cancelledQueue = (event: DisplayEnvelope) => event.type === 'thread.pending'
    && event.pending.length === 1 && event.pending[0]?.id === returned.input.id;
  const update = await updates.wait(cancelledQueue);
  expect(update).toMatchObject({ type: 'thread.pending', pending: afterCancel.pending });
  expect(updates.values.filter(cancelledQueue)).toHaveLength(1);
  expect(reopened.kite.historyNow(id)).toEqual(afterCancel);
  expect(await reopened.kite.threadState(id)).toEqual(afterCancel.state);
  unsubscribe();
  await reopened.stop(); reopened = undefined;

  // 固定复现停止响应发出前宿主退出：收据只保存了客户端未确认输入，尚未完成队列核定。
  const clientInput = { id: 'client-unconfirmed', text: '客户端尚未确认', source: 'human' as const };
  const stop = { id: 'retry-incomplete-stop', inputs: [clientInput] };
  saveClaudeControl(directory, {
    inputs: [{ ...accepted, status: 'done' }, { ...delivered, status: 'done' }, { ...cancelled, status: 'cancelled' }, returned],
    stops: [{ id: stop.id, request: JSON.stringify(stop.inputs), returned: [clientInput], completed: false }],
    processes: [], through: 0, paused: true, recovery: { message: '停止尚未完成' },
  });
  reopened = startDaemon({ home: k.home, port: 0, lightTasks: false });
  expect((await call(reopened.url, 'POST', `/threads/${id}/recover`)).status).toBe(200);
  const stopped = await call(reopened.url, 'POST', `/threads/${id}/interrupt`, stop);
  expect(stopped).toEqual({ status: 200, body: { returned: [returned.input, clientInput] } });
  expect((await call(reopened.url, 'GET', `/threads/${id}/history`)).body.pending).toEqual([]);
  await reopened.stop(); reopened = startDaemon({ home: k.home, port: 0, lightTasks: false });
  expect(await call(reopened.url, 'POST', `/threads/${id}/interrupt`, stop)).toEqual(stopped);
  expect(api.log).toHaveLength(requestCount);
}, 1000);

// 真实回归：原生消息时间曾被线程创建时间覆盖，导致老线程的新对话全部被标题的近三天筛选丢弃。
test('Claude 重开保留每条原生时间，老线程的标题仍使用近三天的新对话', async () => {
  const now = Date.now();
  const old = now - 7 * 24 * 60 * 60 * 1000;
  setSystemTime(new Date(old));
  const { k, id, thread } = await emptyThread();
  const messages = [
    { uuid: randomUUID(), at: old, role: 'user' as const, text: '过期话题：旧项目背景' },
    { uuid: randomUUID(), at: old + 1, role: 'assistant' as const, text: '过期回复：旧项目完成' },
    { uuid: randomUUID(), at: now - 1000, role: 'user' as const, text: '近期话题：修复会话恢复' },
    { uuid: randomUUID(), at: now - 500, role: 'assistant' as const, text: '近期回复：待发送消息已经保留' },
  ];
  writeClaudeHistory(thread, messages);
  setSystemTime(new Date(now));
  expect((await readClaudeMessages(thread.nativeId, thread.workspace.cwd)).map((message) => ({ uuid: message.uuid, at: message.at })))
    .toEqual(messages.map(({ uuid, at }) => ({ uuid, at })));
  const titles = new ManualModel();
  reopened = startDaemon({ home: k.home, port: 0, lightTasks: { model: () => titles } });
  const history = (await call(reopened.url, 'GET', `/threads/${id}/history`)).body as History;
  expect(history.records.filter((record) => record.block.type === 'human' || record.block.type === 'text').map((record) => record.at))
    .toEqual(messages.map((message) => message.at));
  const title = (await call(reopened.url, 'GET', `/threads/${id}/title`)).body;
  const generating = call(reopened.url, 'POST', `/threads/${id}/title/regenerate`, { expectedRevision: title.revision });
  const pending = await Promise.race([titles.call(1), generating.then((result) => {
    throw new Error(`标题请求未调用模型：${JSON.stringify(result)}`);
  })]);
  const input = pending.request.history.flatMap((item) => item.type === 'input' ? [item.input.text] : []).join('\n');
  expect(input).toContain(messages[2]!.text);
  expect(input).toContain(messages[3]!.text);
  expect(input).not.toContain(messages[0]!.text);
  expect(input).not.toContain(messages[1]!.text);
  await pending.response.emit({ type: 'item', item: {
    id: 'title', raw: { type: 'message', role: 'assistant', content: [{ type: 'output_text', text: '修复会话恢复' }] },
  } });
  pending.response.complete();
  expect(await generating).toMatchObject({ status: 200, body: { title: '修复会话恢复' } });
}, 1000);
