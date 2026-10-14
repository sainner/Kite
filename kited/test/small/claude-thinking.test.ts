import { expect, test } from 'bun:test';
import { randomUUID } from 'node:crypto';
import { appendFileSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { appendClaudeEntries, readClaudeEntries, type ClaudeEntry } from '../../src/handoff/claude-records.ts';
import { importClaude, syncToClaude } from '../../src/handoff/handoff.ts';
import type { ContextItem, JournalEvent, JournalRecord } from '../../src/harness/types.ts';
import { newDir, useTemp } from '../util.ts';

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
