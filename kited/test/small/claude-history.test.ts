/**
 * Claude 的原生记录：重开时从原生历史恢复输入、时间与用量窗口；切换后端时思考块的删除收据在导入与同步之间保持有效。
 */
import { afterEach, expect, setSystemTime, test } from 'bun:test';
import { randomUUID } from 'node:crypto';
import { appendFileSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { saveClaudeControl, type ClaudeControl } from '../../src/claude/control.ts';
import { readClaudeMessages } from '../../src/claude/history.ts';
import { startDaemon, type Daemon } from '../../src/daemon.ts';
import { appendClaudeEntries, readClaudeEntries, type ClaudeEntry } from '../../src/handoff/claude-records.ts';
import { importClaude, syncToClaude } from '../../src/handoff/handoff.ts';
import type { ContextItem, JournalEvent, JournalRecord } from '../../src/harness/types.ts';
import type { ThreadContext } from '../../src/model.ts';
import type { History } from '../../src/transcript/protocol.ts';
import { api, call, claudeModel, type Kited, machine, openAgent, folderWorkspace, startKited } from '../harness.ts';
import { ManualModel } from '../harness-loop.ts';
import { newDir, useTemp } from '../util.ts';
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
  const workspace = await folderWorkspace(kited, newDir(kited.root, 'project', { 'base.txt': '原始\n' }));
  const id = await openAgent(kited.call, workspace.workspace.id, claudeModel);
  const thread = (await kited.call('GET', `/threads/${id}`)).body as ThreadContext;
  await kited.daemon.stop();
  return { k: kited, id, thread, directory: join(kited.home, 'sessions', id) };
}

// 真实回归：停止方（这里是带 X-Kite-Source 的 Line）带来的输入里有工作机还没收到、又不是它自己发的（Kite 的通知、别的代理的来信），
// 曾按来源留在被停线程的队列里，继续时交给了模型。工作机没收到的一律登记并退回（同自研后端），迟到的同 ID 发送只去重。
test('Claude 被 Line 停止时带来的未知通知和来信一律退回，迟到的同 ID 发送只去重', async () => {
  const { k, id } = await emptyThread();
  reopened = startDaemon({ home: k.home, port: 0, lightTasks: false });
  const requestCount = api.log.length;
  const notice = { id: 'unknown-notice', text: '整理文档 做完了', source: 'kite' as const };
  const letter = { id: 'unknown-letter', text: '别的代理的来信', source: 'agent' as const,
    from: { kind: 'agent' as const, instance: 'peer', title: '统筹' } };
  const byLine = await fetch(`${reopened.url}/threads/${id}/interrupt`, {
    method: 'POST',
    headers: {
      'content-type': 'application/json', 'X-Kite-Machine': (await machine(reopened.url)).id,
      'X-Kite-Source': JSON.stringify({ kind: 'line', machine: 'line-machine', instance: 'line-instance' }),
    },
    body: JSON.stringify({ id: 'stop-by-line', inputs: [notice, letter] }),
  });
  expect(byLine.status).toBe(200);
  expect(await byLine.json()).toEqual({ returned: [notice, letter] });
  expect(await reopened.kite.send(id, letter.text, letter.id, { source: 'agent', from: letter.from })).toEqual({ id: letter.id });
  const afterLineStop = (await call(reopened.url, 'GET', `/threads/${id}/history`)).body as History;
  expect(afterLineStop.pending).toEqual([]);
  expect(afterLineStop.state.waitingForResume).toBe(false);
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

// 原生 JSONL 和宿主控制文件分别恢复：不能把旧查询窗口配给历史中的更新用量，也不能用目录最大值补旧文件。
test('Claude 重开只把保存的窗口配给同一请求，旧控制文件和错配请求仅显示用量', async () => {
  const { k, id, thread, directory } = await emptyThread();
  const at = Date.now();
  writeClaudeHistory(thread, [
    { uuid: randomUUID(), at, role: 'user', text: '第一轮' },
    { uuid: randomUUID(), at: at + 1, role: 'assistant', text: '第一轮回答',
      measurement: { id: 'msg-first', model: 'claude-sonnet-5', usage: { input_tokens: 100 } } },
    { uuid: randomUUID(), at: at + 2, role: 'user', text: '最新一轮' },
    { uuid: randomUUID(), at: at + 3, role: 'assistant', text: '最新回答',
      measurement: { id: 'msg-latest', model: 'claude-sonnet-5',
        usage: { input_tokens: 2000, cache_read_input_tokens: 13, cache_creation_input_tokens: 17, output_tokens: 99 } } },
  ]);
  const control: Parameters<typeof saveClaudeControl>[1] = { inputs: [], stops: [], processes: [], through: 0, paused: false };
  const windows: Array<ClaudeControl['contextWindow']> = [undefined,
    { model: 'sonnet', tokens: 200_000, requestId: 'msg-first' },
    { model: 'sonnet', tokens: 200_000, requestId: 'msg-latest' }];
  const requests = api.log.length;
  for (const contextWindow of windows) {
    saveClaudeControl(directory, { ...control, contextWindow });
    reopened = startDaemon({ home: k.home, port: 0, lightTasks: false });
    const result = await call(reopened.url, 'GET', `/threads/${id}/history`);
    expect(result.status).toBe(200);
    const measurement = result.body.state.context as History['state']['context'];
    expect(measurement).toMatchObject({ requestId: 'msg-latest', inputTokens: 2030, measuredAt: at + 3 });
    expect(measurement?.windowTokens).toBe(contextWindow?.requestId === 'msg-latest' ? 200_000 : undefined);
    expect(await reopened.kite.threadState(id)).toEqual(result.body.state);
    await reopened.stop(); reopened = undefined;
  }
  expect(api.log).toHaveLength(requests);
}, 1000);

// ---- 思考块的删除收据（src/handoff）：直接调导入与同步，不起 kited ----

const temp = useTemp();
const first = { type: 'thinking', thinking: '第一段有效思考。', signature: 'thinking-first' };
const second = { type: 'thinking', thinking: '第二段待删除思考。', signature: 'thinking-second' };
const redacted = { type: 'redacted_thinking', data: 'thinking-redacted' };
const later = { type: 'thinking', thinking: '后续一轮思考。', signature: 'thinking-later' };
type Block = Record<string, string>;

async function fixture() {
  const root = temp();
  const cwd = newDir(root, 'work');
  const directory = newDir(root, 'journal');
  const nativeId = randomUUID();
  const firstMessageId = `msg_original_${randomUUID()}`;
  const read = () => readClaudeEntries(cwd, nativeId);
  const appendNative = async (values: ClaudeEntry[]) => {
    let parent = read().findLast((entry) => entry.uuid)?.uuid ?? null;
    const entries = values.map((value) => {
      const entry = { sessionId: nativeId, cwd, timestamp: new Date().toISOString(), isSidechain: false,
        ...value, uuid: randomUUID(), parentUuid: parent };
      parent = entry.uuid;
      return entry;
    });
    await appendClaudeEntries(cwd, nativeId, entries);
  };
  const turn = async (text: string, blocks: Block[], messageId = `msg_original_${randomUUID()}`) => appendNative([
    { type: 'user', origin: { kind: 'human' }, message: { role: 'user', content: text } },
    ...blocks.map((block) => ({ type: 'assistant', message: { id: messageId, role: 'assistant',
      model: 'claude-sonnet-5', content: [block], stop_reason: null, stop_sequence: null, usage: { input_tokens: 10, output_tokens: 5 } } })),
  ]);
  const records = () => readFileSync(join(directory, 'journal.jsonl'), 'utf8').split('\n').filter(Boolean)
    .map((line) => JSON.parse(line) as JournalRecord);
  const appendJournal = (event: JournalEvent) => appendFileSync(join(directory, 'journal.jsonl'), JSON.stringify({
    ...event, version: 1, seq: records().at(-1)!.seq + 1, at: Date.now(),
  }) + '\n');
  const compact = (text: string, id: string) => {
    const start = records().find((record) => record.type === 'context.imported'
      && record.items.some((item) => item.type === 'input' && item.input.text === text));
    expect(start).toBeDefined();
    const summary: ContextItem = { type: 'notification', notification: {
      id: `summary-${id}`, kind: 'context.summary', source: 'kite', authority: 'observation',
    }, text: '压缩摘要' };
    appendJournal({ type: 'context.compacted', id, range: { from: start!.seq }, automatic: false, items: [summary], summary: '压缩摘要' });
  };
  const sync = () => syncToClaude(directory, cwd, nativeId, 'sonnet');
  const imported = () => importClaude(directory, cwd, nativeId);
  const strip = (attachment: Record<string, unknown>) => appendNative([{ type: 'attachment', attachment: { type: 'thinking_stripped', ...attachment } }]);
  const active = () => {
    const entries = read();
    const boundary = entries.findLastIndex((entry) => entry.type === 'system' && entry.subtype === 'compact_boundary');
    expect(boundary).toBeGreaterThanOrEqual(0);
    return entries.slice(boundary + 1).flatMap((entry) => entry.type === 'assistant'
      ? (entry.message as { content: Block[] }).content : []);
  };
  const thoughts = () => active().filter((block) => block.type === 'thinking' || block.type === 'redacted_thinking')
    .map((block) => block.signature ?? block.data);
  await turn('第一轮', [first, { type: 'text', text: '两段思考之间的正文。' }, second, redacted, { type: 'text', text: '第一轮正文。' }], firstMessageId);
  await turn('第二轮', [later, { type: 'text', text: '第二轮正文。' }]);
  return { firstMessageId, imported, strip, compact, sync, thoughts, active, turn,
    revert: (id: string) => appendJournal({ type: 'context.compaction.reverted', id }) };
}

// 真实回归：CLI partial 收据曾令导入报错；其 thinkingIndex 跨同 message.id 的多行计数，正文不占索引。
test('partial 删除从同一消息第二个思考块起生效，压缩和撤销不复活已删除块', async () => {
  const f = await fixture();
  await f.strip({ scope: 'partial', from: { messageId: f.firstMessageId, thinkingIndex: 1 } });
  expect(() => f.imported()).not.toThrow();
  f.compact('第二轮', 'compact-second');
  await f.sync();
  expect(f.thoughts()).toEqual([first.signature]);
  expect(JSON.stringify(f.active())).toContain('两段思考之间的正文。');
  f.revert('compact-second');
  await f.sync();
  expect(f.thoughts()).toEqual([first.signature]);
  expect(JSON.stringify(f.active())).toContain('第二轮正文。');
}, 1000);

// 原生删块收据和重组后的新 message.id、journal 撤销共同决定有效集合；不能依靠原始旧块重新生成。
test('all 和旧消息 ID 的删除收据跨重组有效，重组后新思考在更晚位置压缩时仍保留', async () => {
  const f = await fixture();
  f.imported();
  f.compact('第二轮', 'compact-second');
  await f.sync();
  await f.strip({ scope: 'all' });
  expect(() => f.imported()).not.toThrow();
  f.revert('compact-second');
  await f.sync();
  expect(f.thoughts()).toEqual([]);

  const fresh = { type: 'thinking', thinking: '重组以后新生成的有效思考。', signature: 'thinking-after-rebase' };
  await f.turn('第三轮新生成', [fresh, { type: 'text', text: '第三轮新正文。' }]);
  await f.turn('第四轮稍后压缩', [{ type: 'text', text: '第四轮正文。' }]);
  f.imported();
  f.compact('第四轮稍后压缩', 'compact-fourth');
  await f.sync();
  expect(f.thoughts()).toEqual([fresh.signature]);

  // CLI 规定找不到旧 message.id 时按 all 清理；该 ID 来自首次重组前的原始记录。
  await f.strip({ scope: 'partial', from: { messageId: f.firstMessageId, thinkingIndex: 0 } });
  expect(() => f.imported()).not.toThrow();
  f.revert('compact-fourth');
  await f.sync();
  expect(f.thoughts()).toEqual([]);
  expect(JSON.stringify(f.active())).toContain('第三轮新正文。');
}, 1000);
