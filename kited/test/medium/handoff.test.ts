/**
 * 同一线程在自研 harness 与 Claude Code 之间来回切换：上下文翻译、重放与显示拼接。
 * Claude 一侧是真实 Claude Code 进程，模型换成假端点；harness 一侧用手动模型流。
 */
import { afterEach, expect, setDefaultTimeout, test } from 'bun:test';
import { randomUUID } from 'node:crypto';
import type { AgentDefinition } from '../../src/agents/definition.ts';
import type { ContextItem, ModelItem } from '../../src/harness/types.ts';
import type { History } from '../../src/transcript/protocol.ts';
import { after, api, type Kited, mark, registerCheckout, startKited } from '../harness.ts';
import { item, ManualModel } from '../harness-loop.ts';
import { newRepo } from '../util.ts';

setDefaultTimeout(3_000);
let kited: Kited | undefined;
afterEach(async () => {
  await kited?.stop(); kited = undefined;
});

const said = (id: string, text: string): ModelItem => ({
  id, raw: { type: 'message', role: 'assistant', content: [{ type: 'output_text', text }] },
});
const count = (haystack: string, needle: string) => haystack.split(needle).length - 1;
const inputIds = (history: ContextItem[]) => history.flatMap((entry) => entry.type === 'input' ? [entry.input.id] : []);

// 依赖上游：Claude Code（SDK 0.3.280 自带的 CLI 2.1.280）resume 时读取 Kite 追加到会话 jsonl 的合成条目，并按原样发给模型；
// 会话末尾追加的合成压缩分界（system/compact_boundary）使它丢弃分界之前的条目，并按最后一条 last-prompt 选择接续的叶子；
// 能力目录查询只做 SDK 初始化，不发模型请求。
// 配合：HTTP 配置、两份原生记录的增量交接、harness journal 重放与压缩、压缩后整体重组 Claude 会话、
// 显示投影拼接（去掉重组条目、按导入标记排序）与输入 id 去重，单看各部分都确认不了。
test('来回切换后端时双方都按顺序看到对方各段一次，harness 压缩后切到 Claude 只接续压缩后的上下文，能力目录跟随后端，显示不重复且旧输入 id 不再投递', async () => {
  const model = new ManualModel();
  kited = startKited(() => model);
  const k = kited;
  const workspace = await registerCheckout(k, newRepo(k.root, 'project', { 'base.txt': '基线文件正文\n' }));
  const opened = await k.call('POST', `/workspaces/${workspace.workspace.id}/windows`, {
    id: randomUUID(), content: { kind: 'create', definitionId: 'kite.agent.coding' },
  });
  expect(opened.status).toBe(200);
  const id = opened.body.target.instanceId as string;
  const configPath = `/instances/${id}/agent-config`;
  const capabilitiesPath = `/instances/${id}/agent-capabilities`;
  const initial = await k.call('GET', configPath);
  expect(initial.status).toBe(200);
  const harnessAgent = structuredClone(initial.body.instance.config.agent) as AgentDefinition;
  const claudeAgent: AgentDefinition = { ...harnessAgent, runtime: 'claude', model: { model: 'sonnet', reasoning: 'high' } };
  const harnessCapabilities = await k.call('GET', capabilitiesPath);
  expect(harnessCapabilities.status).toBe(200);
  const idle = (since: number) => k.waitEvent((e) => e.type === 'idle' && e.threadId === id && after(k, since)(e));
  const history = async () => {
    const result = await k.call('GET', `/threads/${id}/history`);
    expect(result.status).toBe(200);
    return result.body as History;
  };
  const switchTo = async (agent: AgentDefinition) => {
    const current = await k.call('GET', configPath);
    const switched = await k.call('PUT', configPath, { expectedRevision: current.body.revision, agent });
    expect(switched.status).toBe(200);
    expect((await history()).state.capabilities.switchRuntime).toBe(true);
  };

  // 第一段：harness 读一次文件再回复。
  let since = mark(k);
  expect((await k.call('POST', `/threads/${id}/messages`, { id: 'harness-1', text: '第一段由自研后端读取基线' })).status).toBe(200);
  const first = await model.call(1);
  await first.response.emit({ type: 'item', item: { ...item('harness-read', 'read'), call: { id: 'harness-read', name: 'read', arguments: { path: 'base.txt' } } } });
  first.response.complete();
  const second = await model.call(2);
  await second.response.emit({ type: 'item', item: said('harness-said', '自研后端读完了基线') });
  second.response.complete();
  await idle(since);

  // 第二段：Claude 先收到第一段，再自己读一次文件。
  const beforeClaude = api.log.length;
  await switchTo(claudeAgent);
  const claudeCapabilities = await k.call('GET', capabilitiesPath);
  expect(claudeCapabilities.status).toBe(200);
  expect(claudeCapabilities.body.models.map((entry: { title: string }) => entry.title.toLowerCase()).sort()).toEqual(['fable', 'opus', 'sonnet']);
  expect(api.log).toHaveLength(beforeClaude);
  since = mark(k);
  expect((await k.call('POST', `/threads/${id}/messages`, { id: 'claude-1', text: '第二段交给 Claude\nREAD {"path":"base.txt"}' })).status).toBe(200);
  const claudeFirst = await api.waitRequest((l) => l.main && l.lastUserText.includes('第二段交给 Claude'));
  const sent = JSON.stringify(claudeFirst.body.messages);
  expect(count(sent, '第一段由自研后端读取基线')).toBe(1);
  expect(count(sent, '自研后端读完了基线')).toBe(1);
  const messages = claudeFirst.body.messages as Array<{ role: string; content: any }>;
  const blocks = messages.flatMap((message) => Array.isArray(message.content) ? message.content : []);
  expect(blocks).toContainEqual(expect.objectContaining({ type: 'tool_use', id: 'harness-read', name: 'mcp__kite__read', input: { path: 'base.txt' } }));
  const harnessResult = blocks.find((block) => block.type === 'tool_result' && block.tool_use_id === 'harness-read');
  expect(JSON.stringify(harnessResult)).toContain('基线文件正文');
  await idle(since);
  const claudeRead = api.log.slice(beforeClaude).flatMap((l) => l.toolUseIds)[0]!;
  expect(claudeRead).toStartWith('toolu_');

  // 第三段：回到 harness。用 Claude 处理过的输入 id 重发一次，不应再交给模型。
  await switchTo(harnessAgent);
  expect((await k.call('GET', capabilitiesPath)).body).toEqual(harnessCapabilities.body);
  since = mark(k);
  await k.call('POST', `/threads/${id}/messages`, { id: 'claude-1', text: '第二段交给 Claude\nREAD {"path":"base.txt"}' });
  expect((await k.call('POST', `/threads/${id}/messages`, { id: 'harness-2', text: '第三段回到自研后端' })).status).toBe(200);
  const third = await model.call(3);
  const seen = third.request.history;
  expect(inputIds(seen)).toEqual(['harness-1', 'claude-1', 'harness-2']);
  expect(seen.filter((entry) => entry.type === 'output' && entry.item.call?.id === 'harness-read')).toHaveLength(1);
  expect(seen.filter((entry) => entry.type === 'output' && entry.item.id === 'harness-said')).toHaveLength(1);
  const claudeCalls = seen.filter((entry) => entry.type === 'output' && entry.item.call?.id === claudeRead);
  expect(claudeCalls).toHaveLength(1);
  expect(claudeCalls[0]).toMatchObject({ item: { call: { name: 'read', arguments: { path: 'base.txt' } } } });
  const claudeResults = seen.filter((entry) => entry.type === 'tool_result' && entry.callId === claudeRead);
  expect(claudeResults).toEqual([expect.objectContaining({ result: expect.objectContaining({ status: 'success', output: expect.stringContaining('基线文件正文') }) })]);
  // Claude 段里 UserPromptSubmit hook 注入的配置说明翻译为通知。
  expect(seen.some((entry) => entry.type === 'notification' && entry.text.includes('当前模型：sonnet'))).toBe(true);
  const order = (predicate: (entry: ContextItem) => boolean) => seen.findIndex(predicate);
  expect(order((entry) => entry.type === 'input' && entry.input.id === 'claude-1'))
    .toBeLessThan(order((entry) => entry.type === 'output' && entry.item.call?.id === claudeRead));
  expect(order((entry) => entry.type === 'tool_result' && entry.callId === claudeRead))
    .toBeLessThan(order((entry) => entry.type === 'input' && entry.input.id === 'harness-2'));
  await third.response.emit({ type: 'item', item: said('harness-said-2', '自研后端第三段的回复') });
  third.response.complete();
  await idle(since);
  const harnessNotices = seen.flatMap((entry) => entry.type === 'notification' && !entry.notification.kind.startsWith('claude.') ? [entry] : []);

  // 第四段：再切回 Claude，只多看到第三段；之前的内容各一次。
  await switchTo(claudeAgent);
  since = mark(k);
  expect((await k.call('POST', `/threads/${id}/messages`, { id: 'claude-2', text: '第四段再交给 Claude' })).status).toBe(200);
  const claudeAgain = await api.waitRequest((l) => l.main && l.lastUserText.includes('第四段再交给 Claude'));
  const resent = JSON.stringify(claudeAgain.body.messages);
  for (const text of ['第一段由自研后端读取基线', '自研后端读完了基线', '第二段交给 Claude', '第三段回到自研后端', '自研后端第三段的回复']) {
    expect(count(resent, text)).toBe(1);
  }
  expect(count(resent, '"harness-read"')).toBe(2);
  expect(count(resent, `"${claudeRead}"`)).toBe(2);
  // harness 段的通知以 hook 附加上下文的形式交给 Claude，正文只出现一次。
  expect(harnessNotices.length).toBeGreaterThan(0);
  for (const notice of harnessNotices) {
    const reminder = JSON.stringify(`<system-reminder>\nUserPromptSubmit hook additional context: ${notice.text}`).slice(1, -1);
    expect(count(resent, reminder)).toBe(1);
  }
  expect(resent.indexOf('第二段交给 Claude')).toBeLessThan(resent.indexOf('第三段回到自研后端'));
  expect(resent.indexOf('自研后端第三段的回复')).toBeLessThan(resent.indexOf('第四段再交给 Claude'));
  await idle(since);

  // 第五段：回到 harness 跑一轮，再把第三段压缩成摘要。压缩发生在上次交接之后，下次切到 Claude 要整体重组会话。
  await switchTo(harnessAgent);
  since = mark(k);
  expect((await k.call('POST', `/threads/${id}/messages`, { id: 'harness-3', text: '第五段回到自研后端' })).status).toBe(200);
  const fifth = await model.call(4);
  await fifth.response.emit({ type: 'item', item: said('harness-said-3', '自研后端第五段的回复') });
  fifth.response.complete();
  await idle(since);
  expect((await k.call('POST', `/threads/${id}/compactions`, { id: 'compact-third', from: 'harness-2', through: 'harness-2' })).status).toBe(200);
  // 第五次模型调用是摘要请求（不许调用工具），回一段摘要正文。
  const summarize = await model.call(5);
  expect(summarize.request.allowedTools).toEqual([]);
  await summarize.response.emit({ type: 'item', item: said('summary', '第三段的压缩摘要正文') });
  summarize.response.complete();
  const compacted = await k.waitEvent((e) => e.type === 'harness' && e.threadId === id
    && e.event.type === 'record' && e.event.record.type === 'context.compacted');
  await k.waitEvent((e) => e.type === 'idle' && e.threadId === id && k.events.indexOf(e) > k.events.indexOf(compacted));

  // 第六段：切到 Claude。Claude 只接续合成分界之后的历史：第三段换成摘要正文，
  // 其余各段（含更早从 Claude 导入的第二、四段）各一次，原条目和压缩请求都不再发给模型。
  await switchTo(claudeAgent);
  since = mark(k);
  expect((await k.call('POST', `/threads/${id}/messages`, { id: 'claude-3', text: '第六段在压缩后交给 Claude' })).status).toBe(200);
  const rebased = await api.waitRequest((l) => l.main && l.lastUserText.includes('第六段在压缩后交给 Claude'));
  const context = JSON.stringify(rebased.body.messages);
  for (const text of ['第一段由自研后端读取基线', '自研后端读完了基线', '第二段交给 Claude', '第三段的压缩摘要正文',
    '第五段回到自研后端', '自研后端第五段的回复', '第六段在压缩后交给 Claude']) {
    expect(count(context, text)).toBe(1);
  }
  // 第四段的输入和假端点对它的回显各一次。
  expect(count(context, '第四段再交给 Claude')).toBe(2);
  for (const text of ['第三段回到自研后端', '自研后端第三段的回复', '上下文即将压缩']) expect(count(context, text)).toBe(0);
  expect(count(context, '"harness-read"')).toBe(2);
  expect(count(context, `"${claudeRead}"`)).toBe(2);
  const at = (text: string) => context.indexOf(text);
  expect(at('第二段交给 Claude')).toBeLessThan(at('第三段的压缩摘要正文'));
  expect(at('第三段的压缩摘要正文')).toBeLessThan(at('第四段再交给 Claude'));
  expect(at('第四段再交给 Claude')).toBeLessThan(at('第五段回到自研后端'));
  expect(at('自研后端第五段的回复')).toBeLessThan(at('第六段在压缩后交给 Claude'));
  await idle(since);

  // 显示不受重组影响：两份原生记录的各段都在、按顺序、不重复，重组合成的条目和 Claude 的分界不出现。
  const final = await history();
  expect(final.state.capabilities.switchRuntime).toBe(true);
  const shown = final.records.flatMap(({ block }) => block.type === 'human' ? [`human:${block.id}`]
    : block.type === 'tool_use' ? [`tool_use:${block.id}`]
      : block.type === 'tool_result' ? [`tool_result:${block.call}`] : []);
  expect(shown).toEqual([
    'human:harness-1', 'tool_use:harness-read', 'tool_result:harness-read',
    'human:claude-1', `tool_use:${claudeRead}`, `tool_result:${claudeRead}`,
    'human:harness-2', 'human:claude-2', 'human:harness-3', 'human:claude-3',
  ]);
  const texts = final.records.flatMap(({ block }) => block.type === 'text' ? [block.text] : []);
  for (const text of ['自研后端读完了基线', '自研后端第三段的回复', '自研后端第五段的回复']) {
    expect(texts.filter((entry) => entry === text)).toHaveLength(1);
  }
  expect(texts.indexOf('自研后端读完了基线')).toBeLessThan(texts.indexOf('自研后端第三段的回复'));
  expect(texts.findIndex((text) => text.includes('第四段再交给 Claude'))).toBeLessThan(texts.indexOf('自研后端第五段的回复'));
  expect(texts.some((text) => text.includes('第三段的压缩摘要正文'))).toBe(false);
  expect(texts.at(-1)).toContain('第六段在压缩后交给 Claude');
  const compactions = final.records.flatMap(({ block }) => block.type === 'compacted' ? [block] : []);
  expect(compactions).toEqual([expect.objectContaining({ id: 'compact-third', text: '第三段的压缩摘要正文' })]);

  // 第七段：再回到 harness，只导入第六段；重组写入的条目不再导入一次。
  await switchTo(harnessAgent);
  since = mark(k);
  expect((await k.call('POST', `/threads/${id}/messages`, { id: 'harness-4', text: '第七段回到自研后端' })).status).toBe(200);
  const seventh = await model.call(6);
  const latest = seventh.request.history;
  expect(inputIds(latest)).toEqual(['harness-1', 'claude-1', 'claude-2', 'harness-3', 'claude-3', 'harness-4']);
  expect(latest.filter((entry) => entry.type === 'notification' && entry.notification.kind === 'context.summary')).toHaveLength(1);
  for (const output of ['harness-said', 'harness-said-3']) {
    expect(latest.filter((entry) => entry.type === 'output' && entry.item.id === output)).toHaveLength(1);
  }
  expect(latest.filter((entry) => entry.type === 'output' && entry.item.call?.id === claudeRead)).toHaveLength(1);
  expect(latest.filter((entry) => entry.type === 'output' && JSON.stringify(entry.item).includes('第六段在压缩后交给 Claude'))).toHaveLength(1);
  await seventh.response.emit({ type: 'item', item: said('harness-said-4', '自研后端第七段的回复') });
  seventh.response.complete();
  await idle(since);
});
