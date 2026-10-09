import { afterEach, expect, spyOn, test } from 'bun:test';
import { Glob } from 'bun';
import { randomUUID } from 'node:crypto';
import { startDaemon, type Daemon } from '../../src/daemon.ts';
import type { ThreadContext } from '../../src/model.ts';
import { writeClaudeHistory } from '../claude-history.ts';
import { api, call, claudeModel, type Kited, openAgent, registerCheckout, sendThreadMessage, startKited } from '../harness.ts';
import { ManualModel } from '../harness-loop.ts';
import { newRepo, writeFiles } from '../util.ts';

let kited: Kited | undefined;
let reopened: Daemon | undefined;
let fetchSpy: ReturnType<typeof spyOn<typeof globalThis, 'fetch'>> | undefined;
afterEach(async () => {
  await reopened?.stop(); reopened = undefined;
  await kited?.stop(); kited = undefined;
  fetchSpy?.mockRestore(); fetchSpy = undefined;
});

// 默认模型工厂、隔离凭据与 HTTP SSE 传输联合验证；Claude 原生历史读取不能使标题转回 SDK 或污染会话。
test('Claude 与自研线程的默认标题均通过 ChatGPT HTTP 生成且不改变主历史', async () => {
  const main = new ManualModel();
  kited = startKited(() => main);
  const k = kited;
  const workspace = await registerCheckout(k, newRepo(k.root, 'project', { 'base.txt': '原始\n' }));
  const threads: ThreadContext[] = [];
  for (const model of [claudeModel, undefined]) {
    const id = await openAgent(k.call, workspace.workspace.id, model);
    const thread = (await k.call('GET', `/threads/${id}`)).body as ThreadContext;
    threads.push(thread);
  }
  const claude = threads[0]!;
  const harness = threads[1]!;
  await sendThreadMessage(k, harness.id, '自研线程需要订阅标题');
  (await main.call(1)).response.complete();
  await k.waitEvent((event) => event.type === 'idle' && event.threadId === harness.id);
  await k.daemon.stop();
  writeClaudeHistory(claude, [{ uuid: randomUUID(), at: Date.now(), role: 'user', text: 'Claude 线程需要订阅标题' }]);
  const token = `${Buffer.from('{}').toString('base64url')}.${Buffer.from(JSON.stringify({
    exp: Math.floor(Date.now() / 1000) + 3600,
  })).toString('base64url')}.test-signature`;
  writeFiles(k.home, { 'auth/chatgpt/auth.json': JSON.stringify({
    auth_mode: 'chatgpt', tokens: { access_token: token, account_id: 'title-test-account' },
  }) });

  const requests: Array<{ url: string; headers: Headers; body: { input: unknown; tools?: unknown[] } }> = [];
  const originalFetch = globalThis.fetch;
  const fakeFetch = Object.assign(async (...[input, init]: Parameters<typeof fetch>) => {
    const url = new URL(typeof input === 'string' ? input : input instanceof URL ? input.href : input.url);
    if (url.hostname === '127.0.0.1') return originalFetch(input, init);
    if (url.hostname !== 'chatgpt.com') throw new Error(`测试禁止访问外部地址：${url.origin}`);
    requests.push({ url: url.href, headers: new Headers(init?.headers), body: JSON.parse(String(init?.body)) });
    const item = { id: `title-${requests.length}`, type: 'message', role: 'assistant',
      content: [{ type: 'output_text', text: '订阅生成的标题' }] };
    const events = [
      { type: 'response.output_item.done', item },
      { type: 'response.completed', response: { id: `response-${requests.length}`, output: [item] } },
    ];
    return new Response(events.map((event) => `data: ${JSON.stringify(event)}\n\n`).join(''), {
      headers: { 'content-type': 'text/event-stream' },
    });
  }, { preconnect: originalFetch.preconnect });
  fetchSpy = spyOn(globalThis, 'fetch').mockImplementation(fakeFetch);
  reopened = startDaemon({ home: k.home, port: 0, lightTasks: {} });
  const files = () => [...new Glob('projects/**/*.jsonl').scanSync(process.env.CLAUDE_CONFIG_DIR!)].sort();
  const savedFiles = files();
  const before = api.log.length;
  for (const thread of threads) {
    const historyBefore = (await call(reopened.url, 'GET', `/threads/${thread.id}/history`)).body;
    const title = (await call(reopened.url, 'GET', `/threads/${thread.id}/title`)).body;
    const generated = await call(reopened.url, 'POST', `/threads/${thread.id}/title/regenerate`, {
      expectedRevision: title.revision,
    });
    expect(generated).toMatchObject({ status: 200, body: { title: '订阅生成的标题' } });
    const historyAfter = (await call(reopened.url, 'GET', `/threads/${thread.id}/history`)).body;
    expect(historyAfter.records).toEqual(historyBefore.records);
    expect(historyAfter.pending).toEqual(historyBefore.pending);
    expect(historyAfter.state).toEqual(historyBefore.state);
  }
  expect(requests).toHaveLength(2);
  for (const request of requests) {
    expect(request.url).toBe('https://chatgpt.com/backend-api/codex/responses');
    expect(request.headers.get('authorization')).toBe(`Bearer ${token}`);
    expect(request.body.tools ?? []).toEqual([]);
  }
  expect(JSON.stringify(requests[0]!.body.input)).toContain('Claude 线程需要订阅标题');
  expect(JSON.stringify(requests[1]!.body.input)).toContain('自研线程需要订阅标题');
  expect(api.log).toHaveLength(before);
  expect(files()).toEqual(savedFiles);
}, 1000);
