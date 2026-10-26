import { afterEach, expect, test } from 'bun:test';
import { readdirSync } from 'node:fs';
import { join } from 'node:path';
import type { ContextTemplate } from '../../src/context-templates.ts';
import { startDaemon, type Daemon } from '../../src/daemon.ts';
import type { ContextDefinition } from '../../src/harness/context/types.ts';
import type { ModelItem, ModelRequest } from '../../src/harness/types.ts';
import type { ThreadTitle } from '../../src/store.ts';
import { titleTemplate } from '../../src/thread-titles.ts';
import { addProject, after, call, createWorkspace, type Kited, mark, sendThreadMessage, startKited } from '../harness.ts';
import { diskRecords, ManualModel } from '../harness-loop.ts';
import { newDir } from '../util.ts';

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

async function automaticThread(main: ManualModel, titles: ManualModel, prepare?: (k: Kited) => Promise<void>) {
  kited = startKited(() => main, { model: () => titles });
  const project = await addProject(kited, { path: newDir(kited.root, 'project', { 'base.txt': '原始\n' }) });
  await prepare?.(kited);
  const thread = await createWorkspace(kited, project.id, '修复工作区标题同步', 'harness');
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
      { type: 'text', text: `标题规则${version}；当前标题：` }, { type: 'variable', name: 'title.current' },
    ] }],
    input: [{ type: 'paragraph', id: 'title-input', title: '标题材料', parts: [
      { type: 'text', text: `标题材料${inputVersion}；当前标题：` }, { type: 'variable', name: 'title.current' },
      { type: 'text', text: '\n近期正文：' }, { type: 'variable', name: 'title.messages' },
    ] }],
  };
  const response = await k.call('PUT', `/context-templates/${titleTemplate.id}`, {
    expectedRevision: original.revision, definition, model: original.model,
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
    expectedRevision: savedFirst.revision, definition: staleDefinition, model: savedFirst.model,
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

// SQLite 保存的标题和模板跨重启。
test('重启保留标题与模板', async () => {
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
  expect((await call(restarted.url, 'GET', `/threads/${thread.id}/title`)).body).toEqual(saved);
  const directory = await call(restarted.url, 'GET', '/context-templates');
  expect(directory.status).toBe(200);
  expect((directory.body.templates as ContextTemplate[]).filter((template) => template.definition.scene === 'thread.title'))
    .toEqual([savedTemplate]);
}, 1000);
