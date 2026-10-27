/**
 * 回退到一条人发消息之前（POST /threads/:id/rewind），自研 harness 后端：对话从 journal 上回退、文件按工具调用 id 找快照还原、
 * 显示投影整份重建、压缩按范围保留或作废，下一回合接在留下的历史后面。
 */
import { afterEach, expect, test } from 'bun:test';
import { existsSync } from 'node:fs';
import { join } from 'node:path';
import type { RewindResult } from '../../src/kite.ts';
import type { ContextItem, Json, ModelItem, ModelRequest } from '../../src/harness/types.ts';
import type { DisplayRecord, History } from '../../src/transcript/protocol.ts';
import { folderWorkspace, type Kited, mark, openAgent, startKited, waitIdle } from '../harness.ts';
import { item, ManualModel } from '../harness-loop.ts';
import { connectSse } from '../sse.ts';
import { git, gitOk, newDir, read } from '../util.ts';

let kited: Kited | undefined;
const streams: Array<{ close(): Promise<void> }> = [];
afterEach(async () => {
  await Promise.allSettled(streams.splice(0).map((stream) => stream.close()));
  await kited?.stop();
  kited = undefined;
});

const said = (id: string, text: string): ModelItem => ({
  id, raw: { type: 'message', role: 'assistant', content: [{ type: 'output_text', text }] },
});
const patch = (id: string, operations: Json[]): ModelItem => ({ ...item(id, 'patch'), call: { id, name: 'patch', arguments: { operations } } });
const humans = (records: DisplayRecord[]) => records.flatMap(({ block }) => block.type === 'human' ? [block.id] : []);
const summaries = (history: ContextItem[]) => history.flatMap((entry) => entry.type === 'notification'
  && entry.notification.kind === 'context.summary' ? [entry.text] : []);

// 几部分的配合：runner 在 journal 上回退并作废覆盖回退点的压缩、kite 用回退掉的工具调用 id 在快照链上找还原点、
// 显示投影整份重建并经线程流推出、下一回合的上下文按回退后的 journal 组装；单看每一部分都确认不了合起来对不对。
test('回退到第二轮：预览不动任何东西；回退后文件回到第二轮处理前、对话与显示去掉第二轮起的内容，回退点之前的压缩保留、覆盖回退点的压缩作废，第四轮接在第一轮的摘要之后', async () => {
  const model = new ManualModel();
  kited = startKited(() => model);
  const kk = kited;
  const workspace = await folderWorkspace(kk, newDir(kk.root, 'project', { 'a.txt': '原始\n' }));
  const id = await openAgent(kk.call, workspace.workspace.id);
  const thread = (await kk.call('GET', `/threads/${id}`)).body as { workspace: { cwd: string }; checkout: { path: string } };
  const cwd = thread.workspace.cwd;
  const history = async () => (await kk.call('GET', `/threads/${id}/history`)).body as History;

  let calls = 0;
  /** 发一条人消息，按顺序回各次模型请求（每次一批条目），等回合结束；返回各次请求。 */
  const round = async (inputId: string, steps: ModelItem[][]) => {
    const since = mark(kk);
    expect((await kk.call('POST', `/threads/${id}/messages`, { id: inputId, text: `输入 ${inputId}` })).status).toBe(200);
    const requests: ModelRequest[] = [];
    for (const step of steps) {
      const call = await model.call(++calls);
      requests.push(call.request);
      for (const entry of step) await call.response.emit({ type: 'item', item: entry });
      call.response.complete();
    }
    await waitIdle(kk, id, since);
    return requests;
  };
  /** 手动压缩一段，摘要请求回 text，等压缩记下且线程回到空闲。 */
  const compact = async (compaction: string, from: string, through: string, text: string) => {
    expect((await kk.call('POST', `/threads/${id}/compactions`, { id: compaction, from, through })).status).toBe(200);
    const summary = await model.call(++calls);
    expect(summary.request.allowedTools).toEqual([]);
    await summary.response.emit({ type: 'item', item: said(`summary-${compaction}`, text) });
    summary.response.complete();
    const compacted = await kk.waitEvent((e) => e.type === 'harness' && e.threadId === id && e.event.type === 'record'
      && e.event.record.type === 'context.compacted' && e.event.record.id === compaction);
    await kk.waitEvent((e) => e.type === 'harness' && e.threadId === id && e.event.type === 'state'
      && e.event.state.phase === 'idle' && !e.event.state.busy && kk.events.indexOf(e) > kk.events.indexOf(compacted));
  };

  await round('r1', [[patch('patch-r1', [{ type: 'update_file', path: 'a.txt', diff: '@@\n-原始\n+第一轮' }])],
    [said('said-r1', '第一轮回复')]]);
  // 第二轮分两批工具：先改 a.txt，再新建 b.txt；还原点要按最早含这一轮调用的快照找。
  await round('r2', [[patch('patch-r2-a', [{ type: 'update_file', path: 'a.txt', diff: '@@\n-第一轮\n+第二轮' }])],
    [patch('patch-r2-b', [{ type: 'create_file', path: 'b.txt', diff: '+第二轮新建\n+' }])],
    [said('said-r2', '第二轮回复')]]);
  await round('r3', [[said('said-r3', '第三轮回复')]]);
  expect(read(join(cwd, 'a.txt'))).toBe('第二轮\n');
  expect(read(join(cwd, 'b.txt'))).toBe('第二轮新建\n');
  // c1 完全在回退点之前（在回退点之后才做）；c2 覆盖回退点。
  await compact('c1', 'r1', 'r1', '第一轮摘要');
  await compact('c2', 'r2', 'r3', '第二三轮摘要');

  const stream = await connectSse<{ type: string; records?: DisplayRecord[] }>(`${kk.url}/events?thread=${id}`, kk.daemon.kite.store.machine.id);
  streams.push(stream);
  await stream.events.wait((event) => event.type === 'thread.history');
  const before = await history();
  expect(humans(before.records)).toEqual(['r1', 'r2', 'r3']);

  // 预览：给出还原点，其他代理为空，文件、显示和模型调用都不动。
  const preview = await kk.call('POST', `/threads/${id}/rewind`, { input: 'r2', conversation: true, files: true, preview: true });
  expect(preview.status).toBe(200);
  const target = (preview.body as RewindResult).files;
  expect(target?.others).toEqual([]);
  expect(git(thread.checkout.path, 'show', `${target!.snapshot}:a.txt`)).toBe('第一轮');
  expect(gitOk(thread.checkout.path, 'cat-file', '-e', `${target!.snapshot}:b.txt`)).toBe(false);
  expect(read(join(cwd, 'a.txt'))).toBe('第二轮\n');
  expect(read(join(cwd, 'b.txt'))).toBe('第二轮新建\n');
  expect((await history()).records).toEqual(before.records);

  const streamed = stream.events.values.length;
  const rewound = await kk.call('POST', `/threads/${id}/rewind`, { input: 'r2', conversation: true, files: true });
  expect(rewound.status).toBe(200);
  expect((rewound.body as RewindResult).files).toEqual({ snapshot: target!.snapshot, others: [] });
  expect(read(join(cwd, 'a.txt'))).toBe('第一轮\n');
  expect(existsSync(join(cwd, 'b.txt'))).toBe(false);

  // 显示：第一轮与它的压缩块留着，第二轮起的消息、回复和工具记录都没了；线程流整份替换。
  const replaced = await stream.events.wait((event) => stream.events.values.indexOf(event) >= streamed && event.type === 'thread.history');
  const after = await history();
  for (const records of [replaced.records!, after.records]) {
    expect(humans(records)).toEqual(['r1']);
    const kept = records.find((record) => record.id === 'compaction:c1')?.block;
    expect(kept).toMatchObject({ type: 'compacted', text: '第一轮摘要' });
    expect(kept).not.toHaveProperty('reverted', true);
    const blocks = JSON.stringify(records.map((record) => record.block));
    expect(blocks).toContain('patch-r1');
    expect(blocks).toContain('第一轮回复');
    for (const gone of ['patch-r2-a', 'patch-r2-b', '第二轮回复', '第三轮回复']) expect(blocks).not.toContain(gone);
  }

  // 第四轮：上下文是第一轮的摘要接第四轮，第二三轮的正文、工具调用和它们的摘要都不在。
  const [fourth] = await round('r4', [[said('said-r4', '第四轮回复')]]);
  const context = fourth!.history;
  expect(context.at(-1)).toEqual({ type: 'input', input: expect.objectContaining({ id: 'r4' }) });
  expect(context.flatMap((entry) => entry.type === 'input' ? [entry.input.id] : [])).toEqual(['r4']);
  expect(summaries(context)).toEqual([expect.stringContaining('第一轮摘要')]);
  const sent = JSON.stringify(context);
  for (const gone of ['输入 r2', '输入 r3', 'patch-r2-a', 'patch-r2-b', '第二轮回复', '第三轮回复', '第二三轮摘要']) {
    expect(sent).not.toContain(gone);
  }
  expect(humans((await history()).records)).toEqual(['r1', 'r4']);
}, 1000);
