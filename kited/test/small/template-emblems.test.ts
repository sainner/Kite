import { afterEach, expect, test } from 'bun:test';
import { defaultAgentModel } from '../../src/agents/models.ts';
import { checkEmblemExpression } from '../../src/emblem-expression.ts';
import type { ModelItem, ModelRequest } from '../../src/harness/types.ts';
import { contextRevision, type Role, type RoleSnapshot } from '../../src/roles.ts';
import type { EmblemDesign, EmblemStatus, TemplateEmblem } from '../../src/template-emblems.ts';
import { type Kited, mark, startKited } from '../harness.ts';
import { ManualModel } from '../harness-loop.ts';

type Entry = RoleSnapshot & EmblemStatus;

let kited: Kited | undefined;
afterEach(async () => {
  await kited?.stop();
  kited = undefined;
});

const generated: EmblemDesign = { expression: 'sin(x*0.4+t)*cos(y*0.4-t*0.7)', positive: 'M', negative: 'Y', form: 'circle' };
const regenerated: EmblemDesign = { expression: 'sin(r*0.5-t*1.3)*0.8', positive: 'B', negative: 'D', form: 'diamond' };
const handmade: EmblemDesign = { expression: 'cos(x*0.3-t)*sin(y*0.5+t*0.6)', positive: 'L', negative: 'B', form: 'star' };
// 算式本身可解析，但图案是空白，过不了 checkEmblemExpression。
const blank: EmblemDesign = { ...generated, expression: '0' };

function role(id: string, text: string, maxRequestsPerTurn = 50): Role {
  return {
    version: 1, id, title: '签名测试角色',
    context: {
      version: 2, id, title: '签名测试角色', scene: 'thread.create',
      blocks: [{ type: 'paragraph', id: 'rules', title: '规则', parts: [{ type: 'text', text }] }],
    },
    tools: { mode: 'deny', tools: [], required: [] }, model: { model: defaultAgentModel, reasoning: 'medium' }, maxRequestsPerTurn,
  };
}

/** 签名记下的是生成或手改时提示词的修订，不是整个角色的修订。 */
const promptRevision = (entry: { role: Role }) => contextRevision(entry.role);

const requestInput = (request: ModelRequest) =>
  request.history.flatMap((item) => item.type === 'input' ? [item.input.text] : []).join('\n');

async function reply(model: ManualModel, number: number, text: string) {
  const pending = await model.call(number);
  const item: ModelItem = { id: `emblem-${number}`, raw: { type: 'message', role: 'assistant', content: [{ type: 'output_text', text }] } };
  await pending.response.emit({ type: 'item', item });
  pending.response.complete();
  return pending;
}

async function entry(k: Kited, id: string): Promise<Entry> {
  const response = await k.call('GET', '/roles');
  expect(response.status).toBe(200);
  const found = (response.body.roles as Entry[]).find((value) => value.role.id === id);
  if (!found) throw new Error(`目录里没有角色 ${id}`);
  return found;
}

/** 每收到一条 roles.changed 就读一次目录，直到签名状态满足条件；收不到事件即超时失败。 */
async function settle(k: Kited, id: string, since: number, done: (value: Entry) => boolean): Promise<Entry> {
  let seen = since;
  while (true) {
    const event = await k.waitEvent((e) => e.type === 'roles.changed' && k.events.indexOf(e) >= seen, 900);
    seen = k.events.indexOf(event) + 1;
    const current = await entry(k, id);
    if (done(current)) return current;
  }
}

// 保存后的轻任务是异步串行的，重试要把上一次的校验结果带给模型，结果写回存储并通过目录事件流通知。
// 签名只随提示词过期：只改预算的保存不能让刚生成的签名过期或重新生成。
test('角色保存后后台生成签名，表达式不可用时带着错误重试，只改预算不重新生成，改提示词后两次都不可用记为失败', async () => {
  const model = new ManualModel();
  kited = startKited(undefined, { model: () => model });
  const k = kited;
  const problem = checkEmblemExpression(blank.expression);
  expect(problem).toBeString();

  const since = mark(k);
  const created = await k.call('POST', '/roles', { role: role('test.emblem', '审查改动并逐条报告风险。') });
  expect(created.status).toBe(200);
  const first = await reply(model, 1, JSON.stringify(blank));
  expect(first.request.instructions).toContain('JSON');
  expect(requestInput(first.request)).toContain('审查改动并逐条报告风险。');
  expect(requestInput(first.request)).not.toContain(problem!);
  const second = await reply(model, 2, JSON.stringify(generated));
  expect(requestInput(second.request)).toContain('审查改动并逐条报告风险。');
  expect(requestInput(second.request)).toContain(problem!);
  const ready = await settle(k, 'test.emblem', since, (value) => value.emblemState === 'ready');
  expect(ready.emblem).toEqual({ ...generated, source: 'generated', templateRevision: promptRevision(created.body) });
  expect(ready.emblemError).toBeUndefined();

  const budget = await k.call('PUT', '/roles/test.emblem', {
    expectedRevision: created.body.revision, role: role('test.emblem', '审查改动并逐条报告风险。', 9),
  });
  expect(budget.status).toBe(200);
  expect(budget.body).toMatchObject({ emblemState: 'ready', emblem: ready.emblem });
  expect(model.calls.values).toHaveLength(2);

  const editing = mark(k);
  const updated = await k.call('PUT', '/roles/test.emblem', {
    expectedRevision: budget.body.revision, role: role('test.emblem', '把需求写成分步计划。'),
  });
  expect(updated.status).toBe(200);
  const retry = await reply(model, 3, '先说明一下思路：这里没有 JSON');
  expect(requestInput(retry.request)).toContain('把需求写成分步计划。');
  const last = await reply(model, 4, '{"expression": ');
  expect(requestInput(last.request)).toContain('把需求写成分步计划。');
  const failed = await settle(k, 'test.emblem', editing, (value) => value.emblemState === 'failed');
  expect(failed.emblemError).toBeString();
  expect(model.calls.values).toHaveLength(4);
}, 1000);

// 生成在模型那里挂起时用户手改，run 写入前须再检查 manual；只有 force 才覆盖手改，角色再保存不触发生成。
test('生成途中手改的签名不被生成结果覆盖，角色再保存不重新生成，强制重新生成才覆盖', async () => {
  const model = new ManualModel();
  kited = startKited(undefined, { model: () => model });
  const k = kited;

  const created = await k.call('POST', '/roles', { role: role('test.manual', '写作时先列提纲。') });
  expect(created.status).toBe(200);
  const pending = await model.call(1);
  expect((await entry(k, 'test.manual')).emblemState).toBe('generating');
  const saved = await k.call('PUT', '/roles/test.manual/emblem', { emblem: handmade });
  expect(saved.status).toBe(200);
  const manual: TemplateEmblem = { ...handmade, source: 'manual', templateRevision: promptRevision(created.body) };
  expect(saved.body.emblem).toEqual(manual);

  const released = mark(k);
  await reply(model, 1, JSON.stringify(generated));
  expect(pending.signal.aborted).toBe(false);
  const afterRun = await settle(k, 'test.manual', released, (value) => value.emblemState !== 'generating');
  expect(afterRun.emblem).toEqual(manual);
  expect(afterRun.emblemState).toBe('ready');

  const updated = await k.call('PUT', '/roles/test.manual', {
    expectedRevision: created.body.revision, role: role('test.manual', '写作时先列提纲，再补例子。'),
  });
  expect(updated.status).toBe(200);
  const lazy = await k.call('POST', '/roles/test.manual/emblem/generate', { force: false });
  expect(lazy.status).toBe(200);
  expect((await entry(k, 'test.manual')).emblem).toEqual(manual);

  const forcing = mark(k);
  const forced = await k.call('POST', '/roles/test.manual/emblem/generate', { force: true });
  expect(forced.status).toBe(200);
  const next = await reply(model, 2, JSON.stringify(regenerated));
  expect(requestInput(next.request)).toContain('写作时先列提纲，再补例子。');
  const replaced = await settle(k, 'test.manual', forcing, (value) => value.emblemState === 'ready' && value.emblem?.source === 'generated');
  expect(replaced.emblem).toEqual({ ...regenerated, source: 'generated', templateRevision: promptRevision(updated.body) });
  expect(model.calls.values).toHaveLength(2);
}, 1000);
