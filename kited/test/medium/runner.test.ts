/**
 * Claude Code 进程的排队与打断，模型换成假端点。
 * 只 import runner.ts，不经 daemon。
 */
import { afterEach, expect, setDefaultTimeout, test } from 'bun:test';
import { randomUUID } from 'node:crypto';
import { Runner, type RunnerEvents, type RunnerState } from '../../src/claude/runner.ts';
import { api } from '../setup.ts';
import { until, useTemp } from '../util.ts';

setDefaultTimeout(3_000);

// 先关 Runner 再删临时目录：afterEach 按登记的先后执行
const runners: Runner[] = [];
const cleanups: Array<() => void | Promise<void>> = [];
afterEach(async () => {
  api.releaseAll();
  for (const r of runners.splice(0)) await r.shutdown();
  for (const cleanup of cleanups.splice(0)) await cleanup();
});
const temp = useTemp();

type Rec =
  | { kind: 'turnStart' }
  | { kind: 'turnEnd' }
  | { kind: 'idle' }
  | { kind: 'state'; state: RunnerState };

/** 起一个 Runner，记录回合与状态事件。 */
function startRunner(message: RunnerEvents['message'] = () => {}) {
  const log: Rec[] = [];
  const waiters: Array<{ pred: (r: Rec) => boolean; resolve: () => void }> = [];
  const push = (r: Rec) => {
    log.push(r);
    for (const w of [...waiters]) if (w.pred(r)) { waiters.splice(waiters.indexOf(w), 1); w.resolve(); }
  };
  const on: RunnerEvents = {
    message,
    async toolBatch() {},
    turnStart: () => push({ kind: 'turnStart' }),
    turnEnd: async () => push({ kind: 'turnEnd' }),
    idle: () => push({ kind: 'idle' }),
    state: (state) => push({ kind: 'state', state }),
  };
  const runner = new Runner({ cwd: temp(), nativeId: randomUUID(), title: '测试' }, on);
  runners.push(runner);
  return {
    runner,
    log,
    /** 当前事件数，配合 wait 的 since 只看之后的事件。 */
    mark: () => log.length,
    wait(pred: (r: Rec) => boolean, since = 0): Promise<void> {
      if (log.slice(since).some(pred)) return Promise.resolve();
      return new Promise((resolve) => { waiters.push({ pred, resolve }); });
    },
    states: (since = 0) => log.slice(since).flatMap((r) => (r.kind === 'state' ? [r.state] : [])),
  };
}

const tag = (name: string) => `${name}-${randomUUID().slice(0, 8)}`;
const closed = (r: Rec) => r.kind === 'state' && r.state === 'closed';

/* 回归一个 bug：回合开始前（进程刚从 closed 启动、正在 resume）的打断曾被忽略，回合照常跑完。
 * 上游 CLI 的请求合并与 beta 路由、SDK 的流式块转换须实际运行：短 thinking 更新及签名应保留。
 */
test('Claude 发送短思考更新配置并保留签名，支持生成中打断，续接前打断的消息不进入模型历史', async () => {
  const finalPrompt = `收尾 ${tag('收尾')}`;
  const thinking = { type: 'thinking', thinking: '先核对并发调用的交接，再检查返回结果。', signature: 'test-thinking-signature' };
  const sent: Array<{ thinking: unknown; beta: string | null }> = [];
  const received: unknown[] = [];
  const finalRequest = Promise.withResolvers<void>();
  let finalRequestAt = 0;
  const endpoint = Bun.serve({
    port: 0,
    async fetch(req) {
      const url = new URL(req.url);
      const text = await req.text();
      if (url.pathname.endsWith('/v1/messages')) {
        const body = JSON.parse(text);
        const lastUser = body.messages.findLast((message: { role: string }) => message.role === 'user');
        if (body.stream && JSON.stringify(lastUser).includes(finalPrompt)) {
          sent.push({ thinking: body.thinking, beta: req.headers.get('anthropic-beta') });
          finalRequestAt = mark();
          finalRequest.resolve();
          const events = [
            { type: 'message_start', message: { id: 'msg_thinking_update', type: 'message', role: 'assistant',
              model: body.model, content: [], stop_reason: null, stop_sequence: null, usage: { input_tokens: 10, output_tokens: 1 } } },
            { type: 'content_block_start', index: 0, content_block: { type: 'thinking', thinking: '', signature: '' } },
            { type: 'content_block_delta', index: 0, delta: { type: 'thinking_delta', thinking: thinking.thinking } },
            { type: 'content_block_delta', index: 0, delta: { type: 'signature_delta', signature: thinking.signature } },
            { type: 'content_block_stop', index: 0 },
            { type: 'content_block_start', index: 1, content_block: { type: 'text', text: '' } },
            { type: 'content_block_delta', index: 1, delta: { type: 'text_delta', text: '检查完成。' } },
            { type: 'content_block_stop', index: 1 },
            { type: 'message_delta', delta: { stop_reason: 'end_turn', stop_sequence: null }, usage: { output_tokens: 5 } },
            { type: 'message_stop' },
          ];
          return new Response(events.map((event) => `event: ${event.type}\ndata: ${JSON.stringify(event)}\n\n`).join(''),
            { headers: { 'content-type': 'text/event-stream' } });
        }
      }
      return fetch(new URL(url.pathname + url.search, api.url), {
        method: req.method, headers: req.headers, body: text || undefined, signal: req.signal,
      });
    },
  });
  const originalApi = process.env.ANTHROPIC_BASE_URL;
  process.env.ANTHROPIC_BASE_URL = `http://127.0.0.1:${endpoint.port}`;
  cleanups.push(async () => {
    process.env.ANTHROPIC_BASE_URL = originalApi;
    await endpoint.stop(true);
  });
  const { runner, wait, mark } = startRunner((message) => {
    if (message.type === 'assistant') received.push(...message.message.content.filter((block) => block.type === 'thinking'));
  });

  // 回合进行中：请求挂在假端点上，不打断就永远不结束
  const a = tag('生成中打断');
  runner.send({ text: `HOLD ${a} 很慢的回合`, human: true });
  await api.held(a);
  await runner.interrupt();
  await until(() => !runner.busy, 'busy 变 false', 2_000);
  // 被打断的消息会和下一条并进同一条用户消息，放行它，免得下一回合又被挂起
  api.release(a);

  // 正常跑完一回合，runner 关闭
  runner.send({ text: finalPrompt, human: true });
  await finalRequest.promise;
  await wait(closed, finalRequestAt);
  expect(sent).toHaveLength(1);
  expect(sent[0]!.thinking).toEqual({ type: 'adaptive', display: 'updates' });
  expect(sent[0]!.beta?.split(',').map((value) => value.trim())).toContain('thinking-display-updates-2026-08-18');
  expect(received).toEqual([thinking]);

  // runner 从 closed 刚启动、回合还没开始就打断
  const b = tag('续接前打断');
  runner.send({ text: `HOLD ${b} 不该发出去`, human: true });
  expect(runner.state).toBe('running');
  await runner.interrupt();
  await until(() => !runner.busy, 'busy 变 false', 2_000);
  const reached = () => api.log.filter((l) => JSON.stringify(l.body).includes(b)).map((l) => l.lastUserText);
  expect(reached()).toEqual([]);

  // 之后再发一条：它的请求到达时，被打断的那条如果发出去过，一定在它之前或在它的历史里
  const c = tag('打断后恢复');
  runner.send({ text: `之后 ${c}`, human: true });
  await api.waitRequest((l) => l.main && l.lastUserText.includes(c));
  expect(reached()).toEqual([]);
});
