import { afterEach, expect, test } from 'bun:test';
import { readdirSync } from 'node:fs';
import { join } from 'node:path';
import type { ContextTemplate } from '../../src/context-templates.ts';
import { startDaemon, type Daemon } from '../../src/daemon.ts';
import type { Envelope } from '../../src/events.ts';
import type { ContextDefinition } from '../../src/harness/context/types.ts';
import type { ModelItem, ModelRequest } from '../../src/harness/types.ts';
import type { ThreadTitle } from '../../src/store.ts';
import { titleTemplate } from '../../src/thread-titles.ts';
import { after, call, createWorkspace, type Kited, mark, registerCheckout, sendThreadMessage, startKited } from '../harness.ts';
import { diskRecords, ManualModel, Seen } from '../harness-loop.ts';
import { newRepo } from '../util.ts';

let kited: Kited | undefined;
let restarted: Daemon | undefined;
afterEach(async () => {
  await restarted?.stop();
  restarted = undefined;
  await kited?.stop();
  kited = undefined;
});

const textItem = (id: string, text: string): ModelItem => ({
  id, raw: { type: 'message', role: 'assistant', content: [{ type: 'output_text', text }] },
});

async function automaticThread(main: ManualModel, titles: ManualModel,
  prepare?: (k: Kited) => Promise<void>, results?: Seen<{ error?: string }>) {
  kited = startKited(() => main, { model: () => titles, onResult: (result) => results?.add(result) });
  const repo = newRepo(kited.root, 'project', { 'base.txt': '原始\n' });
  const project = await registerCheckout(kited, repo);
  await prepare?.(kited);
  const thread = await createWorkspace(kited, project.checkout.id, '修复工作区标题同步', 'harness');
  return { k: kited, thread };
}

async function title(k: Kited, id: string): Promise<ThreadTitle> {
  const response = await k.call('GET', `/threads/${id}/title`);
  expect(response.status).toBe(200);
  return response.body as ThreadTitle;
}

async function saveTitleTemplate(k: Kited, version: string, inputVersion = version): Promise<ContextTemplate> {
  const directory = await k.call('GET', '/context-templates');
  expect(directory.status).toBe(200);
  const original = (directory.body.templates as ContextTemplate[]).find((template) => template.definition.id === titleTemplate.id);
  if (!original) throw new Error(`缺少标题模板 ${titleTemplate.id}`);
  const definition: ContextDefinition = {
    ...original.definition,
    blocks: [{ type: 'paragraph', id: 'title-rules', title: '命名规则', parts: [
      { type: 'text', text: `标题规则${version}；当前标题：` }, { type: 'variable', name: 'thread.title' },
    ] }],
    input: [{ type: 'paragraph', id: 'title-input', title: '标题材料', parts: [
      { type: 'text', text: `标题材料${inputVersion}；当前标题：` }, { type: 'variable', name: 'thread.title' },
      { type: 'text', text: '\n近期正文：' }, { type: 'variable', name: 'thread.messages' },
    ] }],
  };
  const response = await k.call('PUT', `/context-templates/${titleTemplate.id}`, {
    expectedRevision: original.revision, definition,
  });
  expect(response.status).toBe(200);
  return response.body as ContextTemplate;
}

const titleInput = (request: ModelRequest) =>
  request.history.flatMap((item) => item.type === 'input' ? [item.input.text] : []).join('\n');

async function finishTitle(k: Kited, model: ManualModel, number: number, id: string, text: string) {
  const pending = await model.call(number);
  const since = mark(k);
  await pending.response.emit({ type: 'item', item: textItem(`title-${number}`, text) });
  pending.response.complete();
  await k.waitEvent((event) => event.type === 'thread.changed' && event.threadId === id && after(k, since)(event));
  await k.daemon.kite.titles!.refresh(id);
  return title(k, id);
}

// 首条 HTTP 输入、挂起的主模型和标题请求并行；SQLite 模板 revision 与在途快照、主 journal 交叉验证。
test('首条输入立即生成标题，模板原子保存且在途快照与主历史隔离', async () => {
  const main = new ManualModel();
  const titles = new ManualModel();
  let savedFirst!: ContextTemplate;
  const { k, thread } = await automaticThread(main, titles, async (k) => {
    savedFirst = await saveTitleTemplate(k, '版本一');
  });
  const initial = await title(k, thread.id);
  const first = await main.call(1);
  const background = await titles.call(1);
  expect((await k.call('GET', `/threads/${thread.id}/history`)).body.state.busy).toBe(true);
  expect(background.request.instructions).toContain('标题规则版本一');
  expect(background.request.instructions).toContain(JSON.stringify(initial.title));
  expect(titleInput(background.request)).toContain('标题材料版本一');
  expect(titleInput(background.request)).toContain(JSON.stringify(initial.title));
  expect(titleInput(background.request)).toContain('修复工作区标题同步');
  const inFlight = structuredClone(background.request);
  const materialUpdated = await saveTitleTemplate(k, '版本一', '版本二');
  expect(materialUpdated.revision).not.toBe(savedFirst.revision);
  expect(materialUpdated.definition.blocks).toEqual(savedFirst.definition.blocks);
  const staleDefinition: ContextDefinition = {
    ...savedFirst.definition,
    blocks: [{ type: 'paragraph', id: 'stale-rules', title: '过期规则', parts: [{ type: 'text', text: '过期命名规则' }] }],
    input: [{ type: 'paragraph', id: 'stale-input', title: '过期材料', parts: [{ type: 'text', text: '过期标题材料' }] }],
  };
  expect((await k.call('PUT', `/context-templates/${titleTemplate.id}`, {
    expectedRevision: savedFirst.revision, definition: staleDefinition,
  })).status).toBe(409);
  const afterConflict = await k.call('GET', '/context-templates');
  expect(afterConflict.status).toBe(200);
  expect((afterConflict.body.templates as ContextTemplate[]).find((template) => template.definition.id === titleTemplate.id))
    .toEqual(materialUpdated);
  const rulesUpdated = await saveTitleTemplate(k, '版本二');
  expect(rulesUpdated.revision).not.toBe(materialUpdated.revision);
  expect(rulesUpdated.definition.input).toEqual(materialUpdated.definition.input);
  expect(background.request).toEqual(inFlight);
  const before = await k.call('GET', `/threads/${thread.id}/history`);
  expect(before.body.state.busy).toBe(true);
  const journalPath = join(k.home, 'sessions', thread.id, 'journal.jsonl');
  const journalBefore = diskRecords(journalPath);

  const generated = await finishTitle(k, titles, 1, thread.id, '修复标题同步');
  expect(generated).toMatchObject({
    title: '修复标题同步', mode: 'auto', generatedAt: expect.any(Number), through: expect.any(String),
  });
  expect(generated.revision).not.toBe(initial.revision);
  expect((await k.call('GET', `/threads/${thread.id}`)).body.title).toBe('修复标题同步');
  const historyAfter = await k.call('GET', `/threads/${thread.id}/history`);
  expect(historyAfter.body.records).toEqual(before.body.records);
  expect(historyAfter.body.pending).toEqual(before.body.pending);
  expect(historyAfter.body.state).toEqual(before.body.state);
  expect(diskRecords(journalPath)).toEqual(journalBefore);
  expect(readdirSync(join(k.home, 'sessions'))).toEqual([thread.id]);

  const mainAnswer = '标题同步已经修复。' + '诊断细节。'.repeat(400) + '完整正文结尾';
  await first.response.emit({ type: 'item', item: textItem('main-answer', mainAnswer) });
  first.response.complete();
  await k.waitEvent((event) => event.type === 'idle' && event.threadId === thread.id);
  await k.daemon.kite.titles!.refresh(thread.id);
  expect(titles.calls.values).toHaveLength(1);
  expect(await title(k, thread.id)).toEqual(generated);

  const regenerating = k.call('POST', `/threads/${thread.id}/title/regenerate`, {
    expectedRevision: generated.revision,
  });
  const latest = await titles.call(2);
  expect(latest.request.instructions).toContain('标题规则版本二');
  expect(latest.request.instructions).not.toContain('标题规则版本一');
  expect(latest.request.instructions).toContain(JSON.stringify(generated.title));
  expect(titleInput(latest.request)).toContain('标题材料版本二');
  expect(titleInput(latest.request)).not.toContain('标题材料版本一');
  expect(titleInput(latest.request)).toContain(JSON.stringify(generated.title));
  expect(titleInput(latest.request)).toContain(mainAnswer.slice(-1600));
  await latest.response.emit({ type: 'item', item: textItem('title-2', '更新模板生成的标题') });
  latest.response.complete();
  expect(await regenerating).toMatchObject({ status: 200, body: { title: '更新模板生成的标题' } });

  await sendThreadMessage(k, thread.id, '继续检查');
  const second = await main.call(2);
  expect(second.request.history).toContainEqual({ type: 'output', item: textItem('main-answer', mainAnswer) });
  expect(JSON.stringify(second.request.history)).not.toContain('title-1');
  expect(JSON.stringify(second.request.history)).not.toContain('title-2');
  const continued = await titles.call(3);
  expect(titleInput(continued.request)).toContain('继续检查');
  expect(titleInput(continued.request)).toContain(mainAnswer.slice(-1600));
  await finishTitle(k, titles, 3, thread.id, '更新模板生成的标题');
  const beforeIdle = mark(k);
  second.response.complete();
  await k.waitEvent((event) => event.type === 'idle' && event.threadId === thread.id && after(k, beforeIdle)(event));
  await k.daemon.kite.titles!.refresh(thread.id);
  expect(titles.calls.values).toHaveLength(3);
}, 1000);

// 标题请求挂起时，HTTP 改名、切回自动及重生受理会推进 revision，与旧响应和串行队列交错。
test('改名与重生使旧标题失效，合并刷新只提交最新结果', async () => {
  const main = new ManualModel();
  const titles = new ManualModel();
  const { k, thread } = await automaticThread(main, titles);
  await main.call(1);
  const old = await titles.call(1);
  const initial = await title(k, thread.id);
  const manualMark = mark(k);
  const manual = await k.call('PUT', `/threads/${thread.id}/title`, {
    expectedRevision: initial.revision, mode: 'manual', title: '手动指定标题',
  });
  expect(manual.status).toBe(200);
  expect(manual.body).toMatchObject({ title: '手动指定标题', mode: 'manual' });
  expect(manual.body.revision).not.toBe(initial.revision);
  await k.waitEvent((event) => event.type === 'thread.changed' && event.threadId === thread.id && after(k, manualMark)(event));
  const conflict = await k.call('PUT', `/threads/${thread.id}/title`, {
    expectedRevision: initial.revision, mode: 'manual', title: '过期客户端标题',
  });
  expect(conflict.status).toBe(409);
  const automatic = await k.call('PUT', `/threads/${thread.id}/title`, {
    expectedRevision: manual.body.revision, mode: 'auto',
  });
  expect(automatic.status).toBe(200);
  expect(automatic.body.mode).toBe('auto');
  expect(automatic.body.revision).not.toBe(manual.body.revision);
  const refreshed = k.daemon.kite.titles!.refresh(thread.id);
  const regenerateMark = mark(k);
  const regenerating = k.call('POST', `/threads/${thread.id}/title/regenerate`, {
    expectedRevision: automatic.body.revision,
  });
  await k.waitEvent((event) => event.type === 'thread.changed' && event.threadId === thread.id && after(k, regenerateMark)(event));
  const reserved = await title(k, thread.id);
  expect(reserved.revision).not.toBe(automatic.body.revision);
  expect(titles.calls.values).toHaveLength(1);
  await old.response.emit({ type: 'item', item: textItem('stale-title', '旧请求不得覆盖') });
  old.response.complete();

  await titles.call(2);
  const whileFresh = await title(k, thread.id);
  expect(whileFresh.revision).toBe(reserved.revision);
  expect(whileFresh.title).not.toBe('旧请求不得覆盖');
  const fresh = await finishTitle(k, titles, 2, thread.id, '新版本标题');
  await refreshed;
  expect(await regenerating).toEqual({ status: 200, body: fresh });
  expect(fresh).toMatchObject({ title: '新版本标题', mode: 'auto' });
  expect(titles.calls.values).toHaveLength(2);

  const manuallyNamed = await k.call('PUT', `/threads/${thread.id}/title`, {
    expectedRevision: fresh.revision, mode: 'manual', title: '手动保留标题',
  });
  expect(manuallyNamed.status).toBe(200);
  await sendThreadMessage(k, thread.id, '手动命名后继续工作');
  await k.daemon.kite.titles!.refresh(thread.id);
  expect(titles.calls.values).toHaveLength(2);
  const failing = k.call('POST', `/threads/${thread.id}/title/regenerate`, {
    expectedRevision: manuallyNamed.body.revision,
  });
  const broken = await titles.call(3);
  await broken.response.emit({ type: 'item', item: textItem('unfinished-title', '未完成的标题不得保存') });
  broken.response.finish();
  expect((await failing).status).toBeGreaterThanOrEqual(500);
  const retained = await title(k, thread.id);
  expect(retained).toMatchObject({
    title: manuallyNamed.body.title, mode: 'manual', generatedAt: manuallyNamed.body.generatedAt,
    through: manuallyNamed.body.through,
  });
  const retrying = k.call('POST', `/threads/${thread.id}/title/regenerate`, {
    expectedRevision: retained.revision,
  });
  const retry = await titles.call(4);
  await retry.response.emit({ type: 'item', item: textItem('manual-title', '手动模式的新标题') });
  retry.response.complete();
  expect(await retrying).toMatchObject({ status: 200, body: { title: '手动模式的新标题', mode: 'manual' } });
}, 1000);

// 主模型保持挂起，HTTP 接受的插话仍在 pending；标题断流与合并队列交错，回复不得推进输入游标。
test('pending 插话立即检查标题，断流保留原题且合并检查与下一条输入均不丢失', async () => {
  const main = new ManualModel();
  const titles = new ManualModel();
  const results = new Seen<{ error?: string }>();
  const { k, thread } = await automaticThread(main, titles, undefined, results);
  const first = await main.call(1);
  const original = await finishTitle(k, titles, 1, thread.id, '原标题');

  const regenerating = k.call('POST', `/threads/${thread.id}/title/regenerate`, {
    expectedRevision: original.revision,
  });
  const pending = await titles.call(2);
  const reserved = await title(k, thread.id);
  expect(reserved.title).toBe(original.title);
  expect(reserved.revision).not.toBe(original.revision);
  await sendThreadMessage(k, thread.id, '增加标题同步检查');
  const history = (await k.call('GET', `/threads/${thread.id}/history`)).body;
  expect(history.state.busy).toBe(true);
  expect(JSON.stringify(history.pending)).toContain('增加标题同步检查');
  await sendThreadMessage(k, thread.id, '再增加模板持久化检查');
  await sendThreadMessage(k, thread.id, '同时检查取消行为');
  expect(main.calls.values).toHaveLength(1);
  expect(titles.calls.values).toHaveLength(2);
  await pending.response.emit({ type: 'item', item: textItem('unfinished-title', '未完成的标题不得保存') });
  pending.response.finish();

  const merged = await titles.call(3);
  expect(await title(k, thread.id)).toEqual(reserved);
  const material = titleInput(merged.request);
  for (const text of ['修复工作区标题同步', '增加标题同步检查', '再增加模板持久化检查', '同时检查取消行为']) {
    expect(material).toContain(text);
  }
  expect(material.split('同时检查取消行为')).toHaveLength(2);
  const updated = await finishTitle(k, titles, 3, thread.id, '同步、持久化与取消');
  expect((await regenerating).status).toBeGreaterThanOrEqual(500);
  expect(updated.through).not.toBe(original.through);
  expect(titles.calls.values).toHaveLength(3);

  await sendThreadMessage(k, thread.id, '增加故障恢复检查');
  const failing = await titles.call(4);
  const beforeFailure = results.values.length;
  failing.response.finish();
  await results.wait((result) => results.values.indexOf(result) >= beforeFailure && Boolean(result.error));
  expect(await title(k, thread.id)).toEqual(updated);
  await sendThreadMessage(k, thread.id, '故障后继续检查恢复');
  const recovered = await titles.call(5);
  expect(titleInput(recovered.request)).toContain('增加故障恢复检查');
  expect(titleInput(recovered.request)).toContain('故障后继续检查恢复');
  const latest = await finishTitle(k, titles, 5, thread.id, '同步、持久化与取消');
  expect(latest.through).not.toBe(updated.through);

  await first.response.emit({ type: 'item', item: textItem('main-answer', '已经完成首轮工作') });
  first.response.complete();
  const continuation = await main.call(2);
  expect(JSON.stringify(continuation.request.history)).toContain('故障后继续检查恢复');
  const beforeIdle = mark(k);
  await continuation.response.emit({ type: 'item', item: textItem('main-latest', '已经完成所有新增检查') });
  continuation.response.complete();
  await k.waitEvent((event) => event.type === 'idle' && event.threadId === thread.id && after(k, beforeIdle)(event));
  await k.daemon.kite.titles!.refresh(thread.id);
  expect(titles.calls.values).toHaveLength(5);
  expect(await title(k, thread.id)).toEqual(latest);
}, 1000);

// SQLite 保存的模板和输入游标跨重启；重开后的新输入不受时间限制，关闭须取消独立标题请求。
test('重启保留标题与模板，新输入立即检查且关闭取消在途标题', async () => {
  const firstMain = new ManualModel();
  const firstTitles = new ManualModel();
  const { k, thread } = await automaticThread(firstMain, firstTitles);
  const first = await firstMain.call(1);
  const saved = await finishTitle(k, firstTitles, 1, thread.id, '持久标题');
  const savedTemplate = await saveTitleTemplate(k, '持久版本');
  await first.response.emit({ type: 'item', item: textItem('saved-answer', '重启前的完整答复') });
  first.response.complete();
  await k.waitEvent((event) => event.type === 'idle' && event.threadId === thread.id);
  await k.daemon.stop();

  const main = new ManualModel();
  const titles = new ManualModel();
  restarted = startDaemon({ home: k.home, port: 0, model: () => main, lightTasks: { model: () => titles } });
  const events = new Seen<Envelope>();
  restarted.kite.bus.subscribe(undefined, (event) => events.add(event));
  expect((await call(restarted.url, 'GET', `/threads/${thread.id}/title`)).body).toEqual(saved);
  const directory = await call(restarted.url, 'GET', '/context-templates');
  expect(directory.status).toBe(200);
  expect((directory.body.templates as ContextTemplate[]).filter((template) => template.definition.scene === 'thread.title'))
    .toEqual([savedTemplate]);
  expect((await call(restarted.url, 'POST', `/threads/${thread.id}/messages`, { text: '重启后立即继续' })).status).toBe(200);
  const active = await main.call(1);
  const pending = await titles.call(1);
  expect((await call(restarted.url, 'GET', `/threads/${thread.id}/history`)).body.state.busy).toBe(true);
  expect(pending.request.instructions).toContain('标题规则持久版本');
  expect(pending.request.instructions).toContain(JSON.stringify(saved.title));
  expect(titleInput(pending.request)).toContain('标题材料持久版本');
  expect(titleInput(pending.request)).toContain('重启前的完整答复');
  expect(titleInput(pending.request)).toContain('重启后立即继续');
  active.response.complete();
  await events.wait((event) => event.type === 'idle' && event.threadId === thread.id);
  const journalPath = join(k.home, 'sessions', thread.id, 'journal.jsonl');
  const beforeStop = diskRecords(journalPath);
  await restarted.stop();
  restarted = undefined;
  expect(pending.signal.aborted).toBe(true);
  expect(titles.calls.values).toHaveLength(1);
  expect(diskRecords(journalPath)).toEqual(beforeStop);
}, 1000);
