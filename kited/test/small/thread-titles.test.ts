import { afterEach, expect, setSystemTime, test } from 'bun:test';
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
  setSystemTime();
  await restarted?.stop();
  restarted = undefined;
  await kited?.stop();
  kited = undefined;
});

const textItem = (id: string, text: string): ModelItem => ({
  id, raw: { type: 'message', role: 'assistant', content: [{ type: 'output_text', text }] },
});

async function automaticThread(main: ManualModel, titles: ManualModel) {
  kited = startKited(() => main, { model: () => titles });
  const repo = newRepo(kited.root, 'project', { 'base.txt': '原始\n' });
  const project = await registerCheckout(kited, repo);
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
  expect(response.body.definition).toEqual(definition);
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

// HTTP 和 SQLite 同时保存规则与材料；统一 revision 防止半份覆盖，后台请求冻结本次文本并隔离主 journal。
test('标题规则和材料共用保存版本，冲突不写入半份模板且在途请求保留旧文本', async () => {
  const main = new ManualModel();
  const titles = new ManualModel();
  const { k, thread } = await automaticThread(main, titles);
  const initial = await title(k, thread.id);
  expect(initial).toMatchObject({ mode: 'auto', generatedAt: null, through: null });
  const savedFirst = await saveTitleTemplate(k, '版本一');
  const first = await main.call(1);
  await first.response.emit({ type: 'item', item: textItem('main-answer', '标题同步已经修复') });
  first.response.complete();
  await k.waitEvent((event) => event.type === 'idle' && event.threadId === thread.id);
  const background = await titles.call(1);
  expect(background.request.tools).toEqual([]);
  expect(background.request.instructions).toContain('标题规则版本一');
  expect(background.request.instructions).toContain(JSON.stringify(initial.title));
  expect(titleInput(background.request)).toContain('标题材料版本一');
  expect(titleInput(background.request)).toContain(JSON.stringify(initial.title));
  expect(titleInput(background.request)).toContain('修复工作区标题同步');
  expect(titleInput(background.request)).toContain('标题同步已经修复');
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
  expect(before.body.state.busy).toBe(false);
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
  expect(titleInput(latest.request)).toContain('标题同步已经修复');
  await latest.response.emit({ type: 'item', item: textItem('title-2', '更新模板生成的标题') });
  latest.response.complete();
  expect(await regenerating).toMatchObject({ status: 200, body: { title: '更新模板生成的标题' } });

  await sendThreadMessage(k, thread.id, '继续检查');
  const second = await main.call(2);
  expect(second.request.history).toContainEqual({ type: 'output', item: textItem('main-answer', '标题同步已经修复') });
  expect(JSON.stringify(second.request.history)).not.toContain('title-1');
  expect(JSON.stringify(second.request.history)).not.toContain('title-2');
  second.response.complete();
  await k.daemon.kite.titles!.refresh(thread.id);
  expect(titles.calls.values).toHaveLength(2);
}, 1000);

// 标题请求挂起时，HTTP 改名、切回自动及重生受理会推进 revision，与旧响应和串行队列交错。
test('手动改名与重生使在途旧标题失效，合并刷新只提交重生版本的结果', async () => {
  const main = new ManualModel();
  const titles = new ManualModel();
  const { k, thread } = await automaticThread(main, titles);
  (await main.call(1)).response.complete();
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
}, 1000);

// HTTP 等模型结果、工作区锁与主回合并行；断流失败和即时重试还会跨过持久标题的游标与模式。
test('显式重生等待完整标题且不阻塞主会话，失败保留原题并能立即在手动模式重试', async () => {
  const main = new ManualModel();
  const titles = new ManualModel();
  const { k, thread } = await automaticThread(main, titles);
  (await main.call(1)).response.complete();
  const original = await finishTitle(k, titles, 1, thread.id, '原标题');

  let returned = false;
  const regenerating = k.call('POST', `/threads/${thread.id}/title/regenerate`, {
    expectedRevision: original.revision,
  }).then((result) => { returned = true; return result; });
  const pending = await titles.call(2);
  const accepted = await title(k, thread.id);
  expect(accepted).toMatchObject({
    title: original.title, mode: original.mode, generatedAt: original.generatedAt, through: original.through,
  });
  expect(accepted.revision).not.toBe(original.revision);
  await sendThreadMessage(k, thread.id, '标题还在生成时继续工作');
  const active = await main.call(2);
  expect(returned).toBe(false);
  expect((await k.call('GET', `/threads/${thread.id}/history`)).body.state.busy).toBe(true);

  await pending.response.emit({ type: 'item', item: textItem('explicit-title', '重新生成的标题') });
  pending.response.complete();
  const generated = await regenerating;
  expect(generated.status).toBe(200);
  expect(generated.body).toMatchObject({
    title: '重新生成的标题', mode: 'auto', generatedAt: expect.any(Number), through: original.through,
  });
  expect(await title(k, thread.id)).toEqual(generated.body);

  const manual = await k.call('PUT', `/threads/${thread.id}/title`, {
    expectedRevision: generated.body.revision, mode: 'manual', title: '手动保留标题',
  });
  expect(manual.status).toBe(200);
  const failing = k.call('POST', `/threads/${thread.id}/title/regenerate`, {
    expectedRevision: manual.body.revision,
  });
  const broken = await titles.call(3);
  await broken.response.emit({ type: 'item', item: textItem('unfinished-title', '未完成的标题不得保存') });
  broken.response.finish();
  const failure = await failing;
  expect(failure.status).toBeGreaterThanOrEqual(500);
  const retained = await title(k, thread.id);
  expect(retained).toMatchObject({
    title: manual.body.title, mode: 'manual', generatedAt: manual.body.generatedAt, through: manual.body.through,
  });
  expect(retained.revision).not.toBe(manual.body.revision);

  const retrying = k.call('POST', `/threads/${thread.id}/title/regenerate`, {
    expectedRevision: retained.revision,
  });
  const retry = await titles.call(4);
  await retry.response.emit({ type: 'item', item: textItem('manual-title', '手动模式的新标题') });
  retry.response.complete();
  const retried = await retrying;
  expect(retried.status).toBe(200);
  expect(retried.body).toMatchObject({ title: '手动模式的新标题', mode: 'manual' });
  expect(await title(k, thread.id)).toEqual(retried.body);
  const since = mark(k);
  active.response.complete();
  await k.waitEvent((event) => event.type === 'idle' && event.threadId === thread.id && after(k, since)(event));
  await k.daemon.kite.titles!.refresh(thread.id);
  expect(titles.calls.values).toHaveLength(4);
}, 1000);

// SQLite 中标题游标与规则、材料的同一份定义跨重启；六小时后请求使用完整保存版本并参与关闭收口。
test('重启保留标题模板和生成间隔，新消息触发保存的模板，关闭取消挂起标题', async () => {
  const firstMain = new ManualModel();
  const firstTitles = new ManualModel();
  const { k, thread } = await automaticThread(firstMain, firstTitles);
  (await firstMain.call(1)).response.complete();
  const saved = await finishTitle(k, firstTitles, 1, thread.id, '持久标题');
  const savedTemplate = await saveTitleTemplate(k, '持久版本');
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
  expect((await call(restarted.url, 'POST', `/threads/${thread.id}/messages`, { text: '六小时内继续' })).status).toBe(200);
  (await main.call(1)).response.complete();
  await events.wait((event) => event.type === 'idle' && event.threadId === thread.id);
  await restarted.kite.titles!.refresh(thread.id);
  expect(titles.calls.values).toHaveLength(0);
  expect((await call(restarted.url, 'GET', `/threads/${thread.id}/title`)).body).toEqual(saved);

  setSystemTime(new Date(saved.generatedAt! + 6 * 60 * 60 * 1000 + 1));
  const since = events.values.length;
  expect((await call(restarted.url, 'POST', `/threads/${thread.id}/messages`, { text: '六小时后继续' })).status).toBe(200);
  (await main.call(2)).response.complete();
  const pending = await titles.call(1);
  expect(pending.request.instructions).toContain('标题规则持久版本');
  expect(pending.request.instructions).toContain(JSON.stringify(saved.title));
  expect(titleInput(pending.request)).toContain('标题材料持久版本');
  expect(titleInput(pending.request)).toContain('六小时后继续');
  await events.wait((event) => event.type === 'idle' && event.threadId === thread.id && events.values.indexOf(event) >= since);
  const journalPath = join(k.home, 'sessions', thread.id, 'journal.jsonl');
  const beforeStop = diskRecords(journalPath);
  await restarted.stop();
  restarted = undefined;
  expect(pending.signal.aborted).toBe(true);
  expect(diskRecords(journalPath)).toEqual(beforeStop);
}, 1000);
