/**
 * Claude 线程上的上下文压缩：常驻进程先退出，Claude 内容导入 journal 后按 harness 规则压缩或撤销，
 * 摘要在不落盘的分叉上生成，再重组 Claude 会话，下一回合从重组后的会话恢复。
 * Claude 一侧是真实 Claude Code 进程，模型换成假端点。
 */
import { afterEach, expect, setDefaultTimeout, spyOn, test } from 'bun:test';
import { randomUUID } from 'node:crypto';
import { readdirSync } from 'node:fs';
import { join } from 'node:path';
import { readClaudeControl } from '../../src/claude/control.ts';
import { Runner } from '../../src/claude/runner.ts';
import type { Envelope } from '../../src/events.ts';
import type { ThreadContext } from '../../src/model.ts';
import type { DisplayBlock, DisplayEnvelope, History } from '../../src/transcript/protocol.ts';
import { api, type Kited, mark, registerCheckout, startKited, waitIdle } from '../harness.ts';
import { deferred, Seen } from '../harness-loop.ts';
import { ENV, newRepo, transcript } from '../util.ts';

setDefaultTimeout(3_000);
let k: Kited | undefined;
let restoreQuery: (() => void) | undefined;
let releaseQuery: (() => void) | undefined;
afterEach(async () => {
  releaseQuery?.(); releaseQuery = undefined;
  await k?.stop(); k = undefined;
  restoreQuery?.(); restoreQuery = undefined;
});

const tag = (name: string) => `${name}-${randomUUID().slice(0, 8)}`;
const count = (haystack: string, needle: string) => haystack.split(needle).length - 1;
const json = (value: unknown) => JSON.stringify(value);
/** CLI 合并相邻的用户消息时把字符串正文改成文本块；比较正文时按块比较。 */
const blocks = (content: unknown) => typeof content === 'string' ? [{ type: 'text', text: content }] : content as unknown[];
/** 这个原生会话的 Claude Code 进程。依赖 SDK 起 CLI 时把原生会话 id 放在命令行参数里（新建 --session-id，续接 --resume）。 */
const sessionProcesses = (nativeId: string) => Bun.spawnSync(['pgrep', '-f', nativeId], { env: ENV(), stdout: 'pipe' })
  .stdout.toString().split('\n').filter(Boolean).map(Number);

/*
 * 依赖上游（SDK 0.3.280 自带的 CLI 2.1.280）：resume + forkSession + persistSession:false 的摘要分叉看到与主会话相同的
 * system、工具声明与 messages 前缀，且不在会话目录留下文件；CLI 加载重组后的会话时只取合成分界之后的链、
 * 按 last-prompt 接续，拷贝条目换了 message.id 所以不与原条目合并；助手回复的 usage 分 input、cache 写、cache 读三项报出；
 * getContextUsage 报出 CLI 自己认定的窗口（可能小于模型目录），CLI 在本地按这个窗口拦截超长上下文
 * （关闭原生压缩时不发请求，直接报 Prompt is too long），所以自动压缩要按它算阈值，分叉才发得出摘要请求。
 * 配合：常驻进程退出与重启、Claude 内容导入 journal、journal 上的压缩与撤销、会话重组、显示投影，
 * 以及控制查询先完成、再保存窗口并推送、最后决定自动压缩的时序，单看各部分都确认不了。
 */
test('Claude 线程压缩中间两轮：摘要在不落盘的分叉上按主会话的上下文生成，期间消息排队，之后范围换成摘要、前后各轮逐字节不变，显示能折叠；撤销后恢复原历史；每回合等待动态窗口查询，同模型失败保留窗口，用量达新窗口的 85% 后自动压缩全部历史', async () => {
  k = startKited();
  const kk = k;
  const query = spyOn(Runner.prototype, 'contextUsage');
  restoreQuery = () => query.mockRestore();
  query.mockResolvedValueOnce(undefined);
  const repo = newRepo(kk.root, 'project', { 'a.txt': '压缩测试文件第一行\n压缩测试文件第二行\n' });
  const workspace = await registerCheckout(kk, repo);
  const opened = await kk.call('POST', `/workspaces/${workspace.workspace.id}/windows`, {
    id: randomUUID(), content: { kind: 'create', definitionId: 'kite.agent.claude' },
  });
  expect(opened.status).toBe(200);
  const id = opened.body.target.instanceId as string;
  const updates = new Seen<DisplayEnvelope>();
  kk.daemon.kite.events.subscribe((event) => 'threadId' in event && event.threadId === id, (event) => updates.add(event));
  const thread = (await kk.call('GET', `/threads/${id}`)).body as ThreadContext;
  const configuredModel = (await kk.call('GET', `/instances/${id}/agent-config`)).body.instance.config.agent.model.model as string;
  const history = async () => {
    const result = await kk.call('GET', `/threads/${id}/history`);
    expect(result.status).toBe(200);
    return result.body as History;
  };
  const measured = async (window: number | undefined) => {
    const current = (await history()).state.context;
    expect(current?.inputTokens).toBe(10);
    expect(current?.windowTokens).toBe(window);
    const last = transcript(thread.nativeId).filter((entry) => entry.type === 'assistant').at(-1);
    expect(current?.requestId).toBe(last.message.id);
    if (window !== undefined) {
      expect(readClaudeControl(join(kk.home, 'sessions', id)).contextWindow).toEqual({
        model: configuredModel, tokens: window, requestId: current!.requestId,
      });
      await updates.wait((event) => event.type === 'thread.state'
        && event.state.context?.requestId === current!.requestId && event.state.context.windowTokens === window);
    }
    return current;
  };
  const record = (envelope: Envelope, type: string, compaction?: string) => envelope.type === 'harness' && envelope.threadId === id
    && envelope.event.type === 'record' && envelope.event.record.type === type
    && (compaction === undefined || (envelope.event.record as { id?: string }).id === compaction);
  const idleAfter = (event: Envelope) => kk.waitEvent((e) => e.type === 'idle' && e.threadId === id && kk.events.indexOf(e) > kk.events.indexOf(event));
  /** 发一条输入、等回合结束，返回这一轮的主循环请求。 */
  const round = async (inputId: string, text: string) => {
    const since = mark(kk);
    const start = api.log.length;
    expect((await kk.call('POST', `/threads/${id}/messages`, { id: inputId, text })).status).toBe(200);
    await api.waitRequest((l) => l.main && l.lastUserText.includes(text));
    await waitIdle(kk, id, since);
    return api.log.slice(start).filter((l) => l.main);
  };

  const texts = {
    r1: `第一轮 ${tag('甲')}\nREAD {"path":"a.txt"}`,
    r2: `第二轮 ${tag('乙')}`,
    r3: `第三轮 ${tag('丙')}`,
    r4: `第四轮 ${tag('丁')}\nREAD {"path":"a.txt"}`,
    r5: `第五轮 ${tag('戊')}`,
  };
  const first = await round('r1', texts.r1);
  expect(first.flatMap((l) => l.toolUseIds)).toHaveLength(1);
  await measured(undefined);
  await round('r2', texts.r2);
  const initialWindow = (await history()).state.context?.windowTokens;
  expect(initialWindow).toBe(200_000);
  await measured(initialWindow);
  query.mockResolvedValueOnce(undefined);
  await round('r3', texts.r3);
  await measured(initialWindow);
  const fourth = await round('r4', texts.r4);
  const fourthCall = fourth.flatMap((l) => l.toolUseIds)[0]!;
  expect(fourthCall).toStartWith('toolu_');
  const mainRequest = fourth.at(-1)!;
  const resident = sessionProcesses(thread.nativeId);
  expect(resident).toHaveLength(1);
  expect((await history()).state.capabilities.compact).toBe(true);

  // 手动压缩第二、三轮。摘要请求挂起，观察压缩期间的状态与排队。
  api.holdNext('claude-summary', (l) => l.main && l.lastUserText.includes(texts.r2) && l.lastUserText.includes(texts.r3));
  const compacting = mark(kk);
  expect((await kk.call('POST', `/threads/${id}/compactions`, { id: 'c1', from: 'r2', through: 'r3' })).status).toBe(200);
  const summary = await api.held('claude-summary');
  // 常驻进程已经退出，摘要由另起的分叉进程请求。
  expect(sessionProcesses(thread.nativeId)).not.toContain(resident[0]);
  // 分叉与主会话的模型、思考设置、system、工具声明和历史前缀逐字节一致，最后一条用户消息是写明两端的摘要指令。
  for (const key of ['model', 'thinking', 'output_config']) expect(json(summary.body[key])).toBe(json(mainRequest.body[key]));
  expect(json(summary.body.system)).toBe(json(mainRequest.body.system));
  expect(json(summary.body.tools)).toBe(json(mainRequest.body.tools));
  const reference = summary.body.messages as Array<{ role: string; content: unknown }>;
  const mainMessages = mainRequest.body.messages as Array<{ role: string; content: unknown }>;
  expect(json(reference.slice(0, mainMessages.length - 1))).toBe(json(mainMessages.slice(0, -1)));
  expect(reference.at(-1)!.role).toBe('user');
  expect(summary.lastUserText).toContain(texts.r2);
  expect(summary.lastUserText).toContain(texts.r3);
  const busy = await history();
  expect(busy.state).toMatchObject({ busy: true, compacting: true, capabilities: { compact: false } });
  // 压缩期间发来的消息排队，不启动回合。
  expect((await kk.call('POST', `/threads/${id}/messages`, { id: 'r5', text: texts.r5 })).status).toBe(200);
  expect((await history()).pending.map((input) => input.id)).toEqual(['r5']);
  api.release('claude-summary');
  const compacted = await kk.waitEvent((e) => record(e, 'context.compacted', 'c1') && kk.events.indexOf(e) >= compacting);
  const fifth = await api.waitRequest((l) => l.main && l.lastUserText.includes(texts.r5));
  await idleAfter(compacted);

  // 分叉不落盘：会话目录只有主会话，指令不进原生记录。
  const sessions = join(process.env.CLAUDE_CONFIG_DIR!, 'projects', thread.workspace.cwd.replace(/[^a-zA-Z0-9]/g, '-'));
  expect(readdirSync(sessions).filter((name) => name.endsWith('.jsonl'))).toEqual([`${thread.nativeId}.jsonl`]);
  expect(json(transcript(thread.nativeId))).not.toContain(json(summary.lastUserText).slice(1, 40));

  // 排队的消息在重组后的会话上执行：第一轮原样在前，第二、三轮换成摘要（与第四轮的用户消息合并成一条），
  // 第四轮其余条目原样，没有重复，范围内的原文不再发给模型。
  const display = await history();
  const block = display.records.find((entry) => entry.id === 'compaction:c1')?.block as Extract<DisplayBlock, { type: 'compacted' }>;
  expect(block).toMatchObject({ type: 'compacted', id: 'c1', automatic: false });
  expect(block.reverted).toBeFalsy();
  // 摘要正文是分叉的回复：假端点回显指令末尾 60 字。
  expect(block.text).toBe(`echo: ${summary.lastUserText.slice(-60)}`.trim());
  const after = fifth.body.messages as Array<{ role: string; content: unknown }>;
  const at = after.findIndex((message) => json(message.content).includes(json(block.text).slice(1, -1)));
  const fourthAt = reference.findIndex((message) => message.role === 'user' && json(message.content).includes(json(texts.r4).slice(1, -1)));
  expect(at).toBeGreaterThan(0);
  expect(json(after.slice(0, at))).toBe(json(reference.slice(0, at)));
  expect(json(reference[at]!.content)).toContain(json(texts.r2).slice(1, -1));
  expect(json(blocks(after[at]!.content).slice(1))).toBe(json(blocks(reference[fourthAt]!.content)));
  expect(json(after.slice(at + 1, -1))).toBe(json(reference.slice(fourthAt + 1, -1)));
  expect(json(blocks(after.at(-1)!.content).map((part: any) => part.text))).toBe(json([texts.r5]));
  const sent = json(after);
  expect(count(sent, json(block.text).slice(1, -1))).toBe(1);
  for (const text of [texts.r2, texts.r3]) expect(sent).not.toContain(json(text).slice(1, -1));
  expect(count(sent, `"tool_use_id":"${fourthCall}"`)).toBe(1);

  // 显示：原有记录各一次，压缩块按输入的显示记录指向第二轮开头到第三轮末尾，追加在压缩发生时的位置。
  const ids = display.records.map((entry) => entry.id);
  expect(display.records.flatMap((entry) => entry.block.type === 'human' ? [entry.block.id] : [])).toEqual(['r1', 'r2', 'r3', 'r4', 'r5']);
  expect(display.records.filter((entry) => entry.block.type === 'tool_use' && entry.block.id === fourthCall)).toHaveLength(1);
  expect(block.from).toBe('input:r2');
  expect(block.through).toBe(ids[ids.indexOf('input:r4') - 1]);
  expect(ids.indexOf('compaction:c1')).toBeLessThan(ids.indexOf('input:r5'));
  expect(ids.indexOf('compaction:c1')).toBeGreaterThan(ids.indexOf('input:r4'));
  expect(display.state.capabilities.compact).toBe(true);

  // 与已有压缩部分重叠的范围在 HTTP 返回前拒绝，历史不变。
  expect((await kk.call('POST', `/threads/${id}/compactions`, { id: 'c2', from: 'r3', through: 'r4' })).status).toBe(409);
  const rejected = await history();
  expect(rejected.records.filter((entry) => entry.block.type === 'compacted')).toHaveLength(1);
  expect(rejected.state.compacting).toBeFalsy();

  // 撤销后再一轮：恢复压缩前的原历史，第五轮接在后面，摘要不再出现，各条目不重复。
  const reverting = mark(kk);
  expect((await kk.call('DELETE', `/threads/${id}/compactions/c1`)).status).toBe(200);
  await kk.waitEvent((e) => record(e, 'context.compaction.reverted', 'c1') && kk.events.indexOf(e) >= reverting);
  query.mockResolvedValueOnce({ tokens: 10, window: 300_000 });
  const sixth = (await round('r6', `第六轮 ${tag('己')}`))[0]!;
  await measured(300_000);
  const restored = sixth.body.messages as Array<{ role: string; content: unknown }>;
  expect(json(restored.slice(0, reference.length - 1))).toBe(json(reference.slice(0, -1)));
  expect(restored.slice(reference.length - 1).map((message) => message.role)).toEqual(['user', 'assistant', 'user']);
  expect(json(blocks(restored[reference.length - 1]!.content))).toBe(json(blocks(texts.r5)));
  const resent = json(restored);
  expect(resent).not.toContain(json(block.text).slice(1, -1));
  expect(count(resent, json(`echo: ${texts.r5}`).slice(1, -1))).toBe(1);
  expect(count(resent, `"tool_use_id":"${fourthCall}"`)).toBe(1);

  // 回合收口时窗口从 30 万变为 20 万，必须等查询后才决定压缩；沿用旧窗口会漏压缩。
  // CLI 在约 17.7 万输入以上拒绝摘要分叉，这里用 17.3 万并分到三类输入用量。
  const querying = deferred();
  const window = deferred<Awaited<ReturnType<Runner['contextUsage']>>>();
  releaseQuery = () => window.resolve(undefined);
  query.mockImplementationOnce(() => { querying.resolve(); return window.promise; });
  const share = Math.ceil(173_000 / 3);
  const seventhText = `第七轮 ${tag('庚')}\nUSAGE ${json({ input_tokens: share, cache_creation_input_tokens: share, cache_read_input_tokens: share })}`;
  const seventhAt = api.log.length;
  const seventhMark = mark(kk);
  expect((await kk.call('POST', `/threads/${id}/messages`, { id: 'r7', text: seventhText })).status).toBe(200);
  const seventh = await api.waitRequest((l) => l.main && l.lastUserText.includes(seventhText));

  await querying.promise;
  expect((await history()).state.context?.windowTokens).toBeUndefined();
  expect(kk.events.slice(seventhMark).some((event) => record(event, 'context.compacted')
    || (event.type === 'idle' && event.threadId === id))).toBe(false);
  expect(api.log.slice(seventhAt).filter((entry) => entry.main)).toEqual([seventh]);
  window.resolve({ tokens: share * 3, window: 200_000 });

  // 自动压缩：回合结束后在分叉上摘要全部历史，显示块从会话第一条记录起。失败时会报错并暂停，这里直接报出错误。
  const automatic = await kk.waitEvent((e) => kk.events.indexOf(e) >= seventhMark
    && (record(e, 'context.compacted') || (e.type === 'error' && e.threadId === id)));
  expect(automatic.type === 'error' ? automatic.message : 'compacted').toBe('compacted');
  const autoSummary = api.log.slice(seventhAt).filter((l) => l.main && l !== seventh);
  expect(autoSummary).toHaveLength(1);
  const latest = seventh.body.messages as unknown[];
  expect(json((autoSummary[0]!.body.messages as unknown[]).slice(0, latest.length - 1))).toBe(json(latest.slice(0, -1)));
  expect(json(autoSummary[0]!.body.tools)).toBe(json(mainRequest.body.tools));
  await kk.waitEvent((e) => e.type === 'claude.control' && e.threadId === id && kk.events.indexOf(e) > kk.events.indexOf(automatic)
    && !e.state.compacting);
  const final = await history();
  const autoBlock = final.records.find((entry) => entry.block.type === 'compacted' && entry.block.automatic)?.block;
  expect(autoBlock).toMatchObject({ type: 'compacted', automatic: true, from: final.records[0]!.id });
  expect(final.records.find((entry) => entry.id === 'compaction:c1')?.block).toMatchObject({ reverted: true });
  expect(final.state).toMatchObject({ waitingForResume: false, capabilities: { compact: true } });
  expect(final.state.compacting).toBeFalsy();
});
