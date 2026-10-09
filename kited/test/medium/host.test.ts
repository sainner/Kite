/** Claude 原生流、宿主输入收据和 HTTP 操作控制一起验证，模型仅连接假端点。 */
import { afterEach, expect, setDefaultTimeout, spyOn, test } from 'bun:test';
import { randomUUID } from 'node:crypto';
import { join } from 'node:path';
import { readClaudeControl } from '../../src/claude/control.ts';
import { Runner } from '../../src/claude/runner.ts';
import { startDaemon, type Daemon } from '../../src/daemon.ts';
import type { History } from '../../src/transcript/protocol.ts';
import { api, call, claudeModel, type Kited, mark, openAgent, registerCheckout, startKited, waitRunner } from '../harness.ts';
import { deferred } from '../harness-loop.ts';
import { newRepo, transcript, until, writeFiles } from '../util.ts';

setDefaultTimeout(3_000);
let k: Kited | undefined;
let reopened: Daemon | undefined;
let restoreQuery: (() => void) | undefined;
let releaseQuery: (() => void) | undefined;
afterEach(async () => {
  api.releaseAll();
  releaseQuery?.(); releaseQuery = undefined;
  await reopened?.stop(); reopened = undefined;
  await k?.stop(); k = undefined;
  restoreQuery?.(); restoreQuery = undefined;
});

const tag = (name: string) => `${name}-${randomUUID().slice(0, 8)}`;

/*
 * 首请求挂起时发送的插话必须经 stdin 折入同一 CLI 的工具后请求，不能等 result 后再起回合。
 * 非 UUID 客户端输入要经过宿主映射到原生 SDK；取消以 SDK 收据为准，增量与最终事件仍归并成同一记录。
 * 工具配置、真实 MCP 的 callId/turnId、工具后通知与输入停止收据跨进程交接，类型或单独小测试不能确认。
 */
test('Claude 插话经 stdin 纳入同轮工具后请求，稳定输入、取消停止收据和流式历史跨重开保持，停止后的迟到窗口查询不能覆盖重开状态或启动排队与压缩', async () => {
  k = startKited();
  const kk = k;
  const querying = deferred();
  const delayedWindow = deferred<Awaited<ReturnType<Runner['contextUsage']>>>();
  releaseQuery = () => delayedWindow.resolve(undefined);
  const query = spyOn(Runner.prototype, 'contextUsage').mockImplementationOnce(() => {
    querying.resolve(); return delayedWindow.promise;
  });
  restoreQuery = () => query.mockRestore();
  const streamingTag = tag('流式工具结果');
  const oldRule = tag('最初项目规则');
  const updatedRule = tag('运行中项目规则更新');
  const repo = newRepo(kk.root, 'project', { 'a.txt': `${streamingTag}\n`, 'AGENTS.md': oldRule });
  const p = await registerCheckout(kk, repo);
  const id = await openAgent(kk.call, p.workspace.id, claudeModel);
  const getHistory = async () => (await kk.call('GET', `/threads/${id}/history`)).body as History;
  const sdkMessages = () => kk.events.flatMap((event) => event.type === 'sdk' && event.threadId === id ? [event.message as any] : []);
  const isLifecycle = (message: any, uuid: string, state: string) => message.type === 'command_lifecycle'
    && message.command_uuid === uuid && message.state === state;
  const waitLifecycle = (uuid: string, state: string) => kk.waitEvent((event) => event.type === 'sdk'
    && event.threadId === id && isLifecycle(event.message, uuid, state));
  const submitQueued = async (input: { id: string; text: string }) => {
    const since = mark(kk);
    expect((await kk.call('POST', `/threads/${id}/messages`, input)).status).toBe(200);
    const received = await kk.waitEvent((event) => kk.events.indexOf(event) >= since && event.type === 'sdk'
      && event.threadId === id && (event.message as any).type === 'command_lifecycle' && (event.message as any).state === 'queued');
    if (received.type !== 'sdk') throw new Error('缺少 SDK 排队确认');
    return (received.message as any).command_uuid as string;
  };
  const firstHold = tag('首个工具请求');
  const first = { id: 'client-input-without-uuid', text: `HOLD ${firstHold}\nREAD {"path":"a.txt"}\nSTREAM_RESULT ${streamingTag}` };
  const firstReply = await kk.call('POST', `/threads/${id}/messages`, first);
  expect(firstReply.status).toBe(200);
  expect(await kk.call('POST', `/threads/${id}/messages`, first)).toEqual(firstReply);
  const firstRequest = await api.held(firstHold);
  expect(firstRequest.toolUseIds).toHaveLength(1);
  expect(JSON.stringify(firstRequest.body)).toContain(oldRule);
  writeFiles(repo, { 'AGENTS.md': updatedRule });
  const cancelled = { id: 'cancel-in-sdk-queue', text: tag('取消消息') };
  const cancelledUuid = await submitQueued(cancelled);
  expect((await getHistory()).pending.map((input) => input.id)).toContain(cancelled.id);
  expect((await kk.call('POST', `/threads/${id}/messages/${cancelled.id}/cancel`)).status).toBe(200);
  await waitLifecycle(cancelledUuid, 'cancelled');
  expect((await getHistory()).pending).toEqual([]);
  const interjections = [
    { id: 'mid-turn-first', text: tag('第一条插话') },
    { id: 'mid-turn-second', text: tag('第二条插话') },
  ];
  const nativeIds: string[] = [];
  for (const input of interjections) nativeIds.push(await submitQueued(input));
  expect((await kk.call('POST', `/threads/${id}/messages`, interjections[0])).status).toBe(200);
  api.release(firstHold);
  const folded = await api.held(streamingTag);
  const modelMessages = JSON.stringify(folded.body.messages);
  expect(folded.body.system).toEqual(firstRequest.body.system);
  expect(modelMessages).toContain(updatedRule);
  expect(JSON.stringify(firstRequest.body)).not.toContain(updatedRule);
  for (const input of interjections) expect(modelMessages.split(input.text)).toHaveLength(2);
  expect(modelMessages).not.toContain(cancelled.text);
  expect(sdkMessages().filter((message) => message.type === 'result')).toHaveLength(0);
  expect(sdkMessages().filter((message) => message.type === 'system' && message.subtype === 'init')).toHaveLength(1);
  const streaming = await until(async () => (await getHistory()).records.find((record) => record.block.type === 'text'
    && record.block.text.includes(streamingTag) && record.generation === 'streaming'), '工具后回复增量已到达历史');
  expect((await kk.call('POST', `/threads/${id}/messages/${interjections[0]!.id}/cancel`)).status).toBe(409);
  api.release(streamingTag);
  await querying.promise;
  // 上游回合已完成而控制查询未返回；这时停止必须能退回排队输入，迟到查询留到宿主重开后才放行。
  const queuedAtQuery = { id: 'queued-during-context-query', text: tag('查询时排队'), source: 'human' as const };
  expect((await kk.call('POST', `/threads/${id}/messages`, queuedAtQuery)).status).toBe(200);
  const queryStop = mark(kk);
  expect(await kk.call('POST', `/threads/${id}/interrupt`, { id: 'stop-context-query' }))
    .toEqual({ status: 200, body: { returned: [queuedAtQuery] } });
  await waitRunner(kk, id, 'closed', queryStop);
  const complete = await getHistory();
  const texts = complete.records.filter((record) => record.block.type === 'text' && record.block.text.includes(streamingTag));
  expect(texts).toHaveLength(1);
  expect(texts[0]!.id).toBe(streaming.id);
  expect(texts[0]!.generation).toBe('complete');
  expect(complete.records.filter((record) => record.block.type === 'human' && record.block.id === first.id)).toHaveLength(1);
  expect(complete.records.flatMap((record) => record.block.type === 'human' ? [record.block.id] : []).sort())
    .toEqual([first.id, ...interjections.map((input) => input.id)].sort());
  for (const [index, input] of interjections.entries()) {
    expect(complete.records.filter((record) => record.block.type === 'human' && record.block.id === input.id)).toHaveLength(1);
    const replay = sdkMessages().filter((message) => message.type === 'user' && message.isReplay && message.uuid === nativeIds[index]);
    expect(replay).toHaveLength(1);
    expect(replay[0].origin).toEqual({ kind: 'human' });
    expect(replay[0].message.content).toBe(input.text);
    expect(sdkMessages().filter((message) => isLifecycle(message, nativeIds[index]!, 'queued'))).toHaveLength(1);
  }
  expect(api.log.some((entry) => JSON.stringify(entry.body).includes(cancelled.text))).toBe(false);

  const config = await kk.call('GET', `/instances/${id}/agent-config`);
  expect(config.status).toBe(200);
  const contextRule = tag('续接新上下文');
  const agent = config.body.instance.config.agent;
  const changed = await kk.call('PUT', `/instances/${id}/agent-config`, {
    expectedRevision: config.body.revision,
    agent: { ...agent, tools: ['agent_start', 'agent_list'], context: {
      ...agent.context, blocks: [...agent.context.blocks, {
        type: 'paragraph', id: 'resumed-context', title: '续接上下文', parts: [{ type: 'text', text: contextRule }],
      }],
    } },
  });
  expect(changed.status).toBe(200);
  const grants = await kk.call('GET', `/instances/${id}/operation-grants`);
  expect((await kk.call('PUT', `/instances/${id}/operation-grants`, {
    expectedRevision: grants.body.revision, grants: [{ operation: 'agent.start', roleIds: ['kite.work'] }],
  })).status).toBe(200);
  const opTag = tag('创建空会话');
  const hold = tag('操作结果');
  const operation = { id: 'operation-client-input', text: `${opTag}\nAGENT_START {"role":"kite.work","presentation":"background"}\nHOLD_RESULT ${hold}` };
  expect((await kk.call('POST', `/threads/${id}/messages`, operation)).status).toBe(200);
  const request = await api.waitRequest((entry) => entry.main && entry.lastUserText.includes(opTag));
  expect(request.body.tools.map((tool: { name: string }) => tool.name)).toEqual(['mcp__kite__agent_start']);
  expect(JSON.stringify(request.body)).toContain(contextRule);
  expect(request.toolUseIds).toHaveLength(1);
  const callId = request.toolUseIds[0]!;
  const afterTool = await api.held(hold);
  const toolResult = afterTool.body.messages.flatMap((message: any) => Array.isArray(message.content) ? message.content : [])
    .find((block: any) => block.type === 'tool_result' && block.tool_use_id === callId);
  expect(toolResult.is_error).toBeFalsy();
  const nativeResult = JSON.parse(typeof toolResult.content === 'string' ? toolResult.content
    : toolResult.content.filter((block: any) => block.type === 'text').map((block: any) => block.text).join('\n'));
  expect(nativeResult.status).toBe('success');
  const catalog = await kk.call('GET', '/workspaces');
  const children = catalog.body.flatMap((entry: any) => entry.instances).filter((instance: any) => instance.origin?.callId === callId);
  expect(children).toHaveLength(1);
  expect(JSON.parse(nativeResult.output).instanceId).toBe(children[0].id);
  expect(children[0].origin.turnId).toMatch(/^[0-9a-f-]{36}$/i);
  expect(typeof children[0].origin.operationId).toBe('string');
  expect(children[0].origin).toMatchObject({ instanceId: id, callId });
  expect((await kk.call('POST', `/threads/${id}/messages`, operation)).status).toBe(200);

  const queued = { id: 'return-queued-input', text: tag('停止退回'), source: 'human' as const };
  const unconfirmed = { id: 'return-unconfirmed', text: tag('未确认输入'), source: 'human' as const };
  const returnedUuid = await submitQueued(queued);
  const stop = { id: 'stable-stop-id', inputs: [unconfirmed] };
  const stopping = mark(kk);
  const stopped = await kk.call('POST', `/threads/${id}/interrupt`, stop);
  expect(stopped).toEqual({ status: 200, body: { returned: [queued, unconfirmed] } });
  await waitLifecycle(returnedUuid, 'cancelled');
  api.release(hold);
  // 手动停止结束常驻进程。
  await waitRunner(kk, id, 'closed', stopping);
  expect((await getHistory()).pending).toEqual([]);
  expect(api.log.some((entry) => JSON.stringify(entry.body).includes(queued.text))).toBe(false);

  await kk.daemon.stop();
  reopened = startDaemon({ home: kk.home, port: 0, lightTasks: false });
  expect(await call(reopened.url, 'POST', `/threads/${id}/interrupt`, stop)).toEqual(stopped);
  expect((await call(reopened.url, 'POST', `/threads/${id}/messages`, operation)).status).toBe(200);
  const beforeLate = await call(reopened.url, 'GET', `/threads/${id}/history`);
  const controlDirectory = join(kk.home, 'sessions', id);
  const beforeControl = readClaudeControl(controlDirectory);
  const beforeRequests = api.log.length;
  delayedWindow.resolve({ tokens: 999_999, window: 1000 });
  await delayedWindow.promise;
  const restored = await call(reopened.url, 'GET', `/threads/${id}/history`);
  expect(restored.body.state).toEqual(beforeLate.body.state);
  expect(readClaudeControl(controlDirectory)).toEqual(beforeControl);
  expect(api.log).toHaveLength(beforeRequests);
  expect(api.log.some((entry) => entry.main && entry.lastUserText.includes(queuedAtQuery.text))).toBe(false);
  expect(restored.body.pending).toEqual([]);
  expect(restored.body.state.phase).toBe('idle');
  const humanIds = [first.id, ...interjections.map((input) => input.id), operation.id];
  expect(restored.body.records.flatMap((record: any) => record.block.type === 'human' && !humanIds.includes(record.block.id)
    ? [record.block] : [])).toEqual([]);
  const thread = (await call(reopened.url, 'GET', `/threads/${id}`)).body;
  const native = transcript(thread.nativeId);
  for (const input of [first, ...interjections, operation]) {
    expect(restored.body.records.filter((record: any) => record.block.type === 'human' && record.block.id === input.id)).toHaveLength(1);
  }
  // 原生中途插话保存为 attachment；有独立 user/assistant 行的消息必须用各自原生时间。
  for (const input of [first, operation]) {
    const record = restored.body.records.find((record: any) => record.block.type === 'human' && record.block.id === input.id);
    const original = native.find((entry) => entry.type === 'user' && (typeof entry.message.content === 'string'
      ? entry.message.content : entry.message.content.filter((block: any) => block.type === 'text').map((block: any) => block.text).join('\n')) === input.text);
    expect(original).toBeDefined();
    expect(record.at).toBe(Date.parse(original.timestamp));
  }
  const nativeReply = native.find((entry) => entry.type === 'assistant'
    && entry.message.content.some((block: any) => block.type === 'text' && block.text.includes(streamingTag)));
  expect(nativeReply).toBeDefined();
  expect(restored.body.records.find((record: any) => record.block.type === 'text' && record.block.text.includes(streamingTag)).at)
    .toBe(Date.parse(nativeReply.timestamp));
  expect(restored.body.records.find((record: any) => record.block.type === 'tool_result' && record.block.call === callId)?.block)
    .toEqual({ type: 'tool_result', call: callId, status: 'success', output: nativeResult.output });
  const finalCatalog = await call(reopened.url, 'GET', '/workspaces');
  expect(finalCatalog.body.flatMap((entry: any) => entry.instances).filter((instance: any) => instance.origin?.callId === callId)).toHaveLength(1);
});
