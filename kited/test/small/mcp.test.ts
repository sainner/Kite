import { afterEach, expect, test } from 'bun:test';
import { rmSync } from 'node:fs';
import { TOOL_SEARCH } from '../../src/harness/tool-search.ts';
import type { Json, ModelItem, ModelRequest } from '../../src/harness/types.ts';
import { McpServers } from '../../src/mcp/servers.ts';
import { mcpToolName } from '../../src/mcp/tools.ts';
import { echoReply, failReply, mcpEchoServer } from '../fixtures/mcp-echo-server.ts';
import { folderWorkspace, mark, startKited, waitIdle, type Kited } from '../harness.ts';
import { item, ManualModel } from '../harness-loop.ts';
import { makeTemp, newDir } from '../util.ts';

const roots: string[] = [];
const registries: McpServers[] = [];
let kited: Kited | undefined;
afterEach(async () => {
  await kited?.stop();
  kited = undefined;
  await Promise.all(registries.splice(0).map((registry) => registry.close()));
  for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true });
});

const fixture = (mode: 'modern' | 'legacy') => ({ command: process.execPath, args: ['run', mcpEchoServer, mode] });

/*
 * 上游 SDK（@modelcontextprotocol/client 与 server 2.3.1）的行为：客户端按 2026-07-28 版开场，serveStdio 的服务据此用新版无状态协议；
 * 只会旧版 initialize 握手的服务（手接 StdioServerTransport），客户端退回 2025-11-25。
 * 服务连上之后注册工具会发 tools list_changed，客户端的 listChanged 回调重新取目录（SDK 带防抖），McpServers 的目录随之更新。
 * 工具结果的 isError 由 SDK 原样交回，包成 Tool 后 status 为 error。
 */
test('新版服务协商到 2026-07-28、旧版服务退回 2025-11-25，两种都能列出并调用工具，isError 记为 error，服务后加的工具随 list_changed 进目录', async () => {
  const root = makeTemp('mcp-');
  roots.push(root);
  let notify = () => {};
  const registry = new McpServers(root, () => notify());
  registries.push(registry);
  await registry.save('modern', fixture('modern'));
  await registry.save('legacy', fixture('legacy'));
  await registry.ensure(['modern', 'legacy']);

  const status = Object.fromEntries(registry.list().map((entry) => [entry.name, entry.status]));
  expect(status.modern).toMatchObject({ phase: 'connected', protocol: '2026-07-28' });
  expect(status.legacy).toMatchObject({ phase: 'connected', protocol: '2025-11-25' });

  const signal = new AbortController().signal;
  for (const server of ['modern', 'legacy']) {
    const tools = new Map(registry.tools([server]).map((tool) => [tool.name, tool]));
    expect([...tools.keys()].sort()).toEqual(['echo', 'fail', 'grow'].map((name) => mcpToolName(server, name)).sort());
    const echoed = await tools.get(mcpToolName(server, 'echo'))!.execute({ text: server }, { cwd: root, signal });
    expect(echoed.status).toBe('success');
    expect(echoed.output).toBe(echoReply(server));
    const failed = await tools.get(mcpToolName(server, 'fail'))!.execute({}, { cwd: root, signal });
    expect(failed.status).toBe('error');
    expect(failed.output).toContain(failReply);
  }

  const late = mcpToolName('modern', 'late');
  const listed = () => registry.tools(['modern']).some((tool) => tool.name === late);
  expect(listed()).toBe(false);
  // 不按时间等：每次 McpServers 报变化时看目录里有没有 late。
  const refreshed = new Promise<void>((resolve) => { notify = () => { if (listed()) resolve(); }; });
  const grown = await registry.tools(['modern']).find((tool) => tool.name === mcpToolName('modern', 'grow'))!
    .execute({}, { cwd: root, signal });
  expect(grown.status).toBe('success');
  await refreshed;
}, 1000);

const called = (id: string, name: string, args: Json): ModelItem => ({ ...item(id, name), call: { id, name, arguments: args } });
function resultOf(request: ModelRequest, callId: string) {
  const entry = request.history.find((value) => value.type === 'tool_result' && value.callId === callId);
  if (entry?.type !== 'tool_result') throw new Error(`没有工具结果：${callId}`);
  return entry.result;
}
/** 这次请求里生效的基础上下文：首次请求定下 instructions，之后正文变了在历史里追加整份更新（context.updated）。 */
const baseContext = (request: ModelRequest) => request.history
  .flatMap((entry) => entry.type === 'notification' && entry.notification.kind === 'context.updated' ? [entry.text] : [])
  .at(-1) ?? request.instructions;

/*
 * 几个部分的配合：HTTP 登记的服务与建代理时打开的服务经 openRunner 连上，公共变量 mcp.servers 进默认角色的基础上下文，
 * 服务的工具作为按需加载的工具交给自研 harness，tool_search 按服务名加载后下一次请求放行、调用经共用连接到真实 stdio 服务；
 * 回合进行中关掉实例的服务，下一次请求起工具不再可执行，基础上下文追加的更新里没有这个服务。
 */
test('代理打开的 MCP 服务列在基础上下文里，tool_search 按服务名加载后能调用；运行中关掉后下一次请求调用被拒、上下文更新里没有这个服务', async () => {
  const model = new ManualModel();
  kited = startKited(() => model);
  const k = kited;
  const saved = await k.call('PUT', '/mcp/servers/echo', {
    command: process.execPath, args: ['run', mcpEchoServer, 'modern'], description: '回显测试服务',
  });
  expect(saved.status).toBe(200);
  const { workspace } = await folderWorkspace(k, newDir(k.root, 'project', { 'base.txt': '原始\n' }));
  const created = await k.call('POST', `/workspaces/${workspace.id}/threads`, { prompt: '用 echo 服务回显', mcp: ['echo'] });
  expect(created.status).toBe(200);
  const id = created.body.id as string;
  const echo = mcpToolName('echo', 'echo');
  const listed = /^- echo\b.*回显测试服务/m;

  const first = await model.call(1);
  expect(first.request.instructions).toMatch(listed);
  expect(first.request.allowedTools).not.toContain(echo);
  await first.response.emit({ type: 'item', item: called('search', TOOL_SEARCH, { groups: ['echo'] }) });
  first.response.complete();

  const second = await model.call(2);
  const search = resultOf(second.request, 'search');
  expect(search.status).toBe('success');
  expect(search.tools?.map((tool) => tool.name)).toContain(echo);
  expect(second.request.allowedTools).toContain(echo);
  await second.response.emit({ type: 'item', item: called('echo-1', echo, { text: '你好' }) });
  second.response.complete();

  const third = await model.call(3);
  expect(resultOf(third.request, 'echo-1')).toMatchObject({ status: 'success', output: echoReply('你好') });
  const revoked = await k.call('PUT', `/instances/${id}/mcp`, { servers: [] });
  expect(revoked.status).toBe(200);
  const since = mark(k);
  third.response.complete();
  await waitIdle(k, id, since);

  expect((await k.call('POST', `/threads/${id}/messages`, { text: '再回显一次' })).status).toBe(200);
  const fourth = await model.call(4);
  expect(fourth.request.allowedTools).not.toContain(echo);
  expect(baseContext(fourth.request)).not.toMatch(listed);
  await fourth.response.emit({ type: 'item', item: called('echo-2', echo, { text: '撤权后' }) });
  fourth.response.complete();

  const fifth = await model.call(5);
  const denied = resultOf(fifth.request, 'echo-2');
  expect(denied.status).not.toBe('success');
  expect(denied.output).not.toContain(echoReply('撤权后'));
  const done = mark(k);
  fifth.response.complete();
  await waitIdle(k, id, done);
}, 1000);
