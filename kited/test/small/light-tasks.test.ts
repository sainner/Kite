import { afterEach, expect, test } from 'bun:test';
import { LightTasks } from '../../src/light-tasks.ts';
import type { JsonObject, ModelItem } from '../../src/harness/types.ts';
import { ManualModel, Seen } from '../harness-loop.ts';

let tasks: LightTasks | undefined;
afterEach(async () => { await tasks?.close(); tasks = undefined; });

const textItem = (id: string, text: string): ModelItem => ({
  id, raw: { type: 'message', role: 'assistant', content: [{ type: 'output_text', text }] },
});

// 受控模型流、串行队列和关闭信号交接：断流不能当成功，关闭不能留下排队请求。
test('轻任务断流后继续串行队列，只交付完整最终文字，关闭同时取消在途和排队请求', async () => {
  const model = new ManualModel();
  const results = new Seen<{ purpose: string; durationMs: number; usage?: JsonObject; error?: string }>();
  tasks = new LightTasks({ model: () => model, onResult: (result) => results.add(result) });
  const generate = (purpose: string) => tasks!.generateText({ purpose, instructions: '生成短文本', input: purpose });

  const broken = generate('断流').catch((error: unknown) => error);
  const complete = generate('完整');
  const first = await model.call(1);
  expect(model.calls.values).toHaveLength(1);
  await first.response.emit({ type: 'item', item: textItem('unfinished', '未确认文字') });
  first.response.finish();
  expect(await broken).toBeInstanceOf(Error);

  const second = await model.call(2);
  expect(second.request.tools).toEqual([]);
  await second.response.emit({ type: 'delta', text: '临时增量', field: 'text' });
  await second.response.emit({ type: 'item', item: {
    id: 'reasoning', raw: { type: 'reasoning', summary: [{ type: 'summary_text', text: '内部思考' }] },
  } });
  await second.response.emit({ type: 'item', item: textItem('final', '最终文字') });
  const usage = { input_tokens: 11, output_tokens: 3 };
  void second.response.emit({ type: 'completed', responseId: 'finished', usage });
  second.response.finish();
  expect(await complete).toEqual({ text: '最终文字', usage });
  expect(await results.wait((result) => result.purpose === '完整')).toMatchObject({ usage });
  expect(results.values.find((result) => result.purpose === '断流')?.error).toEqual(expect.any(String));

  const active = generate('在途').catch((error: unknown) => error);
  const queued = generate('排队').catch((error: unknown) => error);
  const third = await model.call(3);
  expect(model.calls.values).toHaveLength(3);
  await tasks.close();
  expect(third.signal.aborted).toBe(true);
  expect(await active).toBeInstanceOf(Error);
  expect(await queued).toBeInstanceOf(Error);
  expect(model.calls.values).toHaveLength(3);
}, 1000);
