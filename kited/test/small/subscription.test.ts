import { expect, test } from 'bun:test';
import { existsSync, mkdirSync, readFileSync, readdirSync, statSync, symlinkSync, watch, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { readSubscriptionCredentials } from '../../src/harness/auth.ts';
import { ChatGPTModel } from '../../src/harness/chatgpt.ts';
import { assembleContext, restoreContext } from '../../src/harness/context/assembler.ts';
import { contextUpdateContext } from '../../src/harness/context/notifications.ts';
import { projectContext } from '../../src/harness/context/project.ts';
import type { ContextSource } from '../../src/harness/context/types.ts';
import { localTools } from '../../src/execution/local-tools.ts';
import { openThreadHost } from '../../src/harness/thread-host.ts';
import type { Json, JsonObject, ModelEvent, ModelRequest, ThreadNotification, Tool, ToolResult } from '../../src/harness/types.ts';
import {
  aborted, deferred, diskRecords, input, item, ManualModel, Seen, success, tool, useHarness,
} from '../harness-loop.ts';
import { ENV } from '../util.ts';

const h = useHarness();
const credentials = async () => ({ accessToken: 'test-access-token', accountId: 'test-account' });
const request: ModelRequest = {
  id: 'request', turnId: 'turn', cwd: '/tmp', instructions: '测试指令', history: [], tools: [],
};

/** 每字节拆分 UTF-8，且使用 CRLF 和多行 data；不依赖 HTTP 实现恰好如何分块。 */
function sse() {
  let controller!: ReadableStreamDefaultController<Uint8Array>;
  const pulled = deferred();
  let cancelled = false;
  const body = new ReadableStream<Uint8Array>({
    start(value) { controller = value; },
    pull() { pulled.resolve(); },
    cancel() { cancelled = true; },
  });
  const push = (text: string) => {
    for (const byte of new TextEncoder().encode(text)) controller.enqueue(new Uint8Array([byte]));
  };
  return {
    body, pulled: pulled.promise, get cancelled() { return cancelled; },
    event(value: unknown) {
      push(JSON.stringify(value, null, 2).split('\n').map((line) => `data: ${line}\r\n`).join('') + '\r\n');
    },
    text: push,
    close() { controller.close(); },
    response() { return new Response(body, { headers: { 'content-type': 'text/event-stream' } }); },
  };
}

async function collect(model: ChatGPTModel, signal = new AbortController().signal): Promise<ModelEvent[]> {
  const values: ModelEvent[] = [];
  for await (const value of model.stream(request, signal)) values.push(value);
  return values;
}

async function execute(tools: Tool[], name: string, args: Json, cwd: string, signal = new AbortController().signal,
  output?: (text: string, limit: number) => void): Promise<ToolResult> {
  const selected = tools.find((value) => value.name === name)!;
  selected.validate(args);
  return selected.execute(args, { cwd, signal, output });
}

async function rejectedOperation(operation: Promise<ToolResult>): Promise<void> {
  const result = await operation.catch(() => ({ status: 'error' }));
  expect(result.status).toBe('error');
}

// SSE 解码、通知角色、工具选择、主循环调度与下一请求投影共同决定工具能否执行和无损续接。
test('订阅流保留原生条目与通知权限，工具收齐后执行并续接', async () => {
  const root = h.root();
  const first = sse();
  const second = sse();
  const posts = new Seen<{ body: JsonObject }>();
  const model = new ChatGPTModel({
    model: 'test-model', threadId: 'test-session', credentials,
    async fetch(_url, init) {
      posts.add({ body: JSON.parse(String(init.body)) as JsonObject });
      return posts.values.length === 1 ? first.response() : second.response();
    },
  });
  const started = deferred<Json>();
  let executions = 0;
  const record = tool('record', async (args) => { executions++; started.resolve(args); return success('工具结果：中文'); });
  const hidden = tool('hidden', async () => success('不应执行'));
  const observationSource: ContextSource = {
    definition: {
      version: 2, id: 'test.file_changes', title: '工作区状态', scene: 'thread.file_changes',
      blocks: [{ type: 'paragraph', id: 'changed-files', title: '环境事实', parts: [
        { type: 'text', text: '工作区状态通知（来源：' }, { type: 'variable', name: 'files.origin' },
        { type: 'text', text: '；以下仅为环境事实）：\n' }, { type: 'variable', name: 'files.changes' },
      ] }],
    },
    bindings: { 'files.origin': { text: 'test' }, 'files.changes': { text: '工作区出现新文件' } },
  };
  const notifications: ThreadNotification[] = [
    { id: 'instruction-1', sequence: 1, kind: 'policy', source: 'test', authority: 'instruction',
      context: assembleContext(contextUpdateContext('只按批准的工具工作')).snapshot },
    { id: 'observation-2', sequence: 2, kind: 'workspace', source: 'test', authority: 'observation',
      context: assembleContext(observationSource).snapshot },
  ];
  const { runner, journal, events } = h.runner(root, {
    prepareRequest: ({ afterNotification }) => ({
      model, tools: [record],
      toolDefinitions: [record, hidden].map(({ name, description, parameters }) => ({ name, description, parameters })),
      instructions: '测试主循环',
      settings: { allowedTools: ['record'] },
      notifications: notifications.filter((notice) => notice.sequence! > afterNotification),
    }),
  });
  await runner.send(input('中文请求'));
  const post = await Promise.race([
    posts.wait(() => true),
    runner.settled().then(() => { throw new Error(`请求未发送：${JSON.stringify({ state: runner.state, records: journal.records })}`); }),
  ]);
  expect((post.body.tools as JsonObject[]).map((value) => value.name)).toEqual(['record', 'hidden']);
  expect(post.body.tool_choice).toEqual({
    type: 'allowed_tools', mode: 'auto', tools: [{ type: 'function', name: 'record' }],
  });
  const mappedNotices = post.body.input as JsonObject[];
  expect(mappedNotices.find((value) => JSON.stringify(value).includes('只按批准的工具工作'))?.role).toBe('developer');
  const observed = mappedNotices.find((value) => JSON.stringify(value).includes('工作区出现新文件'));
  expect(observed?.role).toBe('user');
  expect(observed?.content).toEqual([{ type: 'input_text', text: restoreContext(notifications[1]!.context).instructions }]);
  const reasoning: JsonObject = { id: 'reasoning-1', type: 'reasoning', encrypted_content: '不透明串', extra: { bytes: [0, 255] } };
  const answer: JsonObject = { id: 'answer-stream', type: 'message', role: 'assistant', content: [
    { type: 'output_text', text: '正文一' }, { type: 'output_text', text: '第二段' },
  ] };
  const call: JsonObject = {
    id: 'item-id', type: 'function_call', call_id: 'external-call-id', name: 'record',
    arguments: JSON.stringify({ text: '中文参数' }), future_field: ['照原样保留'],
  };
  // 上游的多段正文、摘要和参数事件交错到达；done 用完整分段校正，不能再次追加全文。
  first.event({ type: 'response.output_item.added', item: { id: 'reasoning-1', type: 'reasoning', summary: [] } });
  first.event({ type: 'response.reasoning_summary_part.added', item_id: 'reasoning-1', summary_index: 0,
    part: { type: 'summary_text', text: '' } });
  first.event({ type: 'response.reasoning_summary_text.delta', item_id: 'reasoning-1', summary_index: 0, delta: '思考' });
  first.event({ type: 'response.output_item.added', item: { id: answer.id, type: 'message', role: 'assistant', content: [] } });
  first.event({ type: 'response.output_text.delta', item_id: answer.id, content_index: 0, delta: '正' });
  first.event({ type: 'response.output_text.delta', item_id: answer.id, content_index: 0, delta: '文' });
  first.event({ type: 'response.output_text.done', item_id: answer.id, content_index: 0, text: '正文一' });
  first.event({ type: 'response.output_text.delta', item_id: answer.id, content_index: 1, delta: '第二' });
  first.event({ type: 'response.reasoning_summary_text.done', item_id: 'reasoning-1', summary_index: 0, text: '思考完成' });
  first.event({ type: 'response.output_text.done', item_id: answer.id, content_index: 1, text: '第二段' });
  await events.wait((event) => event.type === 'delta' && event.itemId === answer.id
    && event.field === 'text' && event.part === 1 && event.replace === true && event.text === '第二段');
  expect(events.values.filter((event) => event.type === 'item.started').map((event) => event.itemId)).toEqual(['reasoning-1', 'answer-stream']);
  expect(events.values.some((event) => event.type === 'delta' && event.itemId === 'reasoning-1'
    && event.field === 'thinking' && event.replace === true && event.text === '思考完成')).toBe(true);
  first.event({ type: 'response.output_item.done', item: reasoning });
  first.event({ type: 'response.output_item.done', item: answer });
  first.event({ type: 'response.output_item.added', item: { ...call, arguments: '' } });
  first.event({ type: 'response.function_call_arguments.delta', item_id: call.id, delta: '{"text":"中' });
  await events.wait((event) => event.type === 'delta' && event.itemId === call.id && event.field === 'arguments'
    && event.text === '{"text":"中');
  expect(executions).toBe(0);
  first.event({ type: 'response.function_call_arguments.delta', item_id: call.id, delta: '文参数"}' });
  first.event({ type: 'response.function_call_arguments.done', item_id: call.id, arguments: call.arguments });
  first.event({ type: 'response.output_text.delta', delta: '中文增量' });
  await events.wait((event) => event.type === 'delta' && event.text === '中文增量');
  expect(executions).toBe(0);
  first.event({ type: 'response.output_item.done', item: call });
  expect(await started.promise).toEqual({ text: '中文参数' });
  expect(journal.records.some((record) => record.type === 'request.completed')).toBe(false);
  const fallback: JsonObject = { id: 'only-completed', type: 'message', role: 'assistant', content: [{ type: 'output_text', text: '完成', annotations: [] }], future: '保留' };
  first.event({ type: 'response.completed', response: { id: 'response-1', status: 'completed', output: [reasoning, answer, call, fallback] } });
  first.close();
  const next = await posts.wait((value) => value !== post);
  expect(next.body.tools).toEqual(post.body.tools);
  expect(next.body.tool_choice).toEqual(post.body.tool_choice);
  expect((next.body.input as JsonObject[]).filter((value) => JSON.stringify(value).includes('只按批准的工具工作'))).toHaveLength(1);
  expect((next.body.input as JsonObject[]).filter((value) => JSON.stringify(value).includes('工作区出现新文件'))).toHaveLength(1);
  expect(next.body.input).toContainEqual(reasoning);
  expect(next.body.input).toContainEqual(answer);
  expect(next.body.input).toContainEqual(call);
  expect(next.body.input).toContainEqual(fallback);
  expect(next.body.input).toContainEqual({ type: 'function_call_output', call_id: 'external-call-id', output: '工具结果：中文' });
  const outputItems = journal.records.filter((record) => record.type === 'model.item');
  expect(outputItems.map((record) => record.item.raw)).toEqual([reasoning, answer, call, fallback]);
  expect(executions).toBe(1);
  second.event({ type: 'response.completed', response: { id: 'response-2', status: 'completed', output: [] } });
  second.close();
  await runner.settled();
  expect(runner.state.lastOutcome).toEqual({ kind: 'completed' });
}, 1000);

// ReadableStream 的 EOF、cancel 和 AbortSignal 是运行时交接：已有文字不能掩盖失败，也不能重试副作用。
test('订阅流失败不重试，取消释放等待中的 reader', async () => {
  const failures: Array<(stream: ReturnType<typeof sse>) => void> = [
    (stream) => stream.event({ type: 'response.failed', response: { error: { message: '测试失败' } } }),
    (stream) => stream.event({ type: 'response.incomplete', response: { id: 'incomplete', incomplete_details: { reason: 'max_output_tokens' } } }),
    (stream) => stream.close(),
    (stream) => stream.text('data: [DONE]\r\n\r\n'),
    (stream) => stream.text('data: {坏 JSON}\r\n\r\n'),
    (stream) => stream.event({ type: 'response.output_item.done', item: { id: 'bad', type: 'function_call', call_id: 'bad-call', name: 'write', arguments: '{' } }),
  ];
  for (const fail of failures) {
    const stream = sse();
    let requests = 0;
    const model = new ChatGPTModel({
      model: 'test', threadId: 'failure', credentials,
      async fetch() { requests++; return stream.response(); },
    });
    stream.event({ type: 'response.output_text.delta', delta: '有文字也没成功' });
    fail(stream);
    await expect(collect(model)).rejects.toThrow();
    expect(requests).toBe(1);
    expect(stream.body.locked).toBe(false);
  }
  const stream = sse();
  const controller = new AbortController();
  const fetching = deferred();
  let requests = 0;
  const model = new ChatGPTModel({
    model: 'test', threadId: 'cancel', credentials,
    async fetch() { requests++; fetching.resolve(); return stream.response(); },
  });
  const collecting = collect(model, controller.signal);
  await fetching.promise;
  await stream.pulled;
  controller.abort();
  await expect(collecting).rejects.toThrow();
  expect(requests).toBe(1);
  expect(stream.cancelled).toBe(true);
  expect(stream.body.locked).toBe(false);
}, 1000);

// 真实缓存文件会被上游替换；重复读取、文件元数据和异常消息一起验证不会缓存旧令牌或回写凭据。
test('订阅凭据重新只读加载，异常不泄露令牌', async () => {
  const root = h.root();
  const path = join(root, 'auth.json');
  const token = (name: string, exp = Math.floor(Date.now() / 1000) + 3600) =>
    `${Buffer.from('{}').toString('base64url')}.${Buffer.from(JSON.stringify({ exp, name })).toString('base64url')}.test-secret-signature`;
  const first = token('第一次');
  const second = token('第二次');
  const save = (accessToken: string) => writeFileSync(path, JSON.stringify({ auth_mode: 'chatgpt', tokens: { access_token: accessToken, account_id: 'account', refresh_token: '刷新秘密' } }));
  save(first);
  const before = statSync(path);
  const original = readFileSync(path, 'utf8');
  expect(await readSubscriptionCredentials(path)).toEqual({ accessToken: first, accountId: 'account' });
  expect(readFileSync(path, 'utf8')).toBe(original);
  expect(statSync(path).mtimeMs).toBe(before.mtimeMs);
  save(second);
  expect(await readSubscriptionCredentials(path)).toEqual({ accessToken: second, accountId: 'account' });
  for (const invalid of [
    JSON.stringify({ auth_mode: 'apikey', OPENAI_API_KEY: '不许泄露的API秘密' }),
    JSON.stringify({ auth_mode: 'chatgpt', tokens: { access_token: token('过期', 1), account_id: 'account', refresh_token: '刷新秘密' } }),
    '{"access_token":"不许泄露的坏文件秘密"',
  ]) {
    writeFileSync(path, invalid);
    const failure = await readSubscriptionCredentials(path).then(() => undefined, (error: unknown) => error);
    expect(failure).toBeInstanceOf(Error);
    expect(String(failure)).not.toMatch(/刷新秘密|不许泄露|test-secret-signature/);
    expect(readFileSync(path, 'utf8')).toBe(invalid);
  }
  expect(readdirSync(root)).toEqual(['auth.json']);
}, 1000);

// 上游补丁定位与文件版本提示、真实符号链接解析的交接需实际运行，失败不能改动文件。
test('文件补丁保留外部修改并提示版本变化，拒绝不匹配补丁及路径逃逸', async () => {
  const root = h.root();
  const cwd = join(root, 'work');
  const outside = join(root, 'work-neighbor');
  mkdirSync(cwd);
  mkdirSync(outside);
  writeFileSync(join(outside, 'secret.txt'), '外部内容');
  symlinkSync(outside, join(cwd, 'escape'));
  const tools = localTools({ cwd, logDir: join(root, 'logs'), env: ENV() });
  expect((await execute(tools, 'patch', { operations: [{ type: 'create_file', path: 'note.txt', diff: '+甲\n+乙\n+丙\n+' }] }, cwd)).status).toBe('success');
  expect((await execute(tools, 'read', { path: 'note.txt' }, cwd)).status).toBe('success');
  writeFileSync(join(cwd, 'note.txt'), '甲由外部修改\n乙\n丙\n');
  const patched = await execute(tools, 'patch', { operations: [{ type: 'update_file', path: 'note.txt', diff: '@@\n-乙\n+丁\n 丙' }] }, cwd);
  expect(patched.status).toBe('success');
  expect(patched.output).toContain('提示');
  expect(readFileSync(join(cwd, 'note.txt'), 'utf8')).toBe('甲由外部修改\n丁\n丙\n');
  const next = await execute(tools, 'patch', { operations: [{ type: 'update_file', path: 'note.txt', diff: '@@\n-丁\n+戊\n 丙' }] }, cwd);
  expect(next.status).toBe('success');
  expect(next.output).not.toContain('提示');
  writeFileSync(join(cwd, 'note.txt'), '甲由外部修改\n目标也由外部修改\n丙\n');
  await rejectedOperation(execute(tools, 'patch', { operations: [{ type: 'update_file', path: 'note.txt', diff: '@@\n-戊\n+不应写入\n 丙' }] }, cwd));
  expect(readFileSync(join(cwd, 'note.txt'), 'utf8')).toBe('甲由外部修改\n目标也由外部修改\n丙\n');
  for (const path of ['../work-neighbor/secret.txt', join(outside, 'secret.txt'), 'escape/secret.txt']) {
    await rejectedOperation(execute(tools, 'read', { path }, cwd));
    await rejectedOperation(execute(tools, 'patch', { operations: [{ type: 'update_file', path, diff: '@@\n-外部内容\n+不应改动' }] }, cwd));
    await rejectedOperation(execute(tools, 'patch', { operations: [{ type: 'delete_file', path }] }, cwd));
  }
  await rejectedOperation(execute(tools, 'patch', { operations: [{ type: 'create_file', path: 'escape/new.txt', diff: '+不应创建' }] }, cwd));
  expect(readFileSync(join(outside, 'secret.txt'), 'utf8')).toBe('外部内容');
  expect(readdirSync(outside)).toEqual(['secret.txt']);
}, 1000);

// Bun spawn 的环境快照和操作系统进程组行为须实际运行：取消要等忽略 TERM 的后代也停下。
test('命令继承显式环境并输出完整日志，取消等待整组退出', async () => {
  const root = h.root();
  const logDir = join(root, 'logs');
  const processes = new Seen<{ pid: number; active: boolean }>();
  const output = new Seen<{ text: string; limit: number }>();
  const tools = localTools({
    cwd: root, logDir, env: { ...ENV(), KITE_SUBSCRIPTION_TEST_ENV: '仅由显式env传入' }, outputLimit: 64,
    onProcess(pid, active) { processes.add({ pid, active }); },
  });
  const quote = (value: string) => `'${value.replaceAll("'", "'\\''")}'`;
  const longOutput = '完整输出'.repeat(120);
  const command = `${quote(process.execPath)} -e ${quote('process.stdout.write(process.env.KITE_SUBSCRIPTION_TEST_ENV + "\\n" + ' + JSON.stringify(longOutput) + '); process.stderr.write("错误流也保存");')}`;
  const observe = (text: string, limit: number) => output.add({ text, limit });
  const result = await execute(tools, 'shell', { description: '检查命令环境和日志', command }, root, undefined, observe);
  expect(result.status).toBe('success');
  const logs = readdirSync(logDir).map((name) => join(logDir, name));
  const contents = logs.map((path) => readFileSync(path, 'utf8')).join('');
  expect(contents).toContain('仅由显式env传入');
  expect(contents).toContain(longOutput);
  expect(contents).toContain('错误流也保存');
  expect(result.output).not.toContain(longOutput);
  expect(logs.some((path) => result.output.includes(path))).toBe(true);
  expect(output.values.map((part) => part.text).join('')).toContain(longOutput);
  expect(output.values.every((part) => part.limit === 64)).toBe(true);
  expect(processes.values.filter((value) => value.active)).toHaveLength(1);
  expect(processes.values.at(-1)?.active).toBe(false);

  // shell 的 UTF-8 解码、日志落盘和输出回调跨进程交接；第一段到达时命令仍在运行。
  const fixture = join(root, 'stream-output.ts');
  writeFileSync(fixture, [
    'import { writeSync } from "node:fs";',
    'const hold = setInterval(() => {}, 1000);',
    'const write = (bytes: Uint8Array) => {',
    '  let offset = 0;',
    '  while (offset < bytes.length) offset += writeSync(1, bytes, offset, bytes.length - offset);',
    '};',
    'process.on("SIGUSR1", () => {',
    '  write(Buffer.concat([Buffer.from("中文").subarray(1), Buffer.from("完成")]));',
    '  clearInterval(hold);',
    '});',
    'write(Buffer.concat([Buffer.from(`PID:${process.pid}\\n先到\\n`), Buffer.from("中文").subarray(0, 1)]));',
  ].join('\n'));
  const outputStart = output.values.length;
  let finished = false;
  const streaming = execute(tools, 'shell', { description: '检查流式中文输出',
    command: `exec ${quote(process.execPath)} ${quote(fixture)}` }, root, undefined, observe).finally(() => { finished = true; });
  await output.wait((part) => output.values.indexOf(part) >= outputStart && part.text.includes('先到'));
  expect(finished).toBe(false);
  expect(readdirSync(logDir).some((name) => readFileSync(join(logDir, name), 'utf8').includes('先到'))).toBe(true);
  const fixturePid = /PID:(\d+)/.exec(output.values.slice(outputStart).map((part) => part.text).join(''));
  expect(fixturePid).not.toBeNull();
  process.kill(Number(fixturePid![1]), 'SIGUSR1');
  expect((await streaming).status).toBe('success');
  expect(output.values.slice(outputStart).map((part) => part.text).join('')).toContain('先到\n中文完成');

  const before = processes.values.length;
  const preCancelled = new AbortController();
  preCancelled.abort();
  await rejectedOperation(execute(tools, 'shell', { description: '检查预先取消的命令', command: 'touch forbidden-start' }, root, preCancelled.signal));
  expect(existsSync(join(root, 'forbidden-start'))).toBe(false);
  expect(processes.values).toHaveLength(before);

  const marker = join(root, 'descendants.json');
  const processFixture = join(root, 'hold-processes.ts');
  const childSource = 'process.on("SIGTERM", () => {}); setInterval(() => {}, 1000); console.log(process.pid);';
  writeFileSync(processFixture, [
    'import { writeFileSync } from "node:fs";',
    'process.on("SIGTERM", () => {});',
    `const child = Bun.spawn([process.execPath, "-e", ${JSON.stringify(childSource)}], { env: process.env, stdout: "pipe", stderr: "ignore" });`,
    'const reader = child.stdout.getReader();',
    'const { value } = await reader.read();',
    `writeFileSync(${JSON.stringify(marker)}, JSON.stringify({ parent: process.pid, child: Number(new TextDecoder().decode(value)) }));`,
    'await child.exited;',
  ].join('\n'));
  const ready = deferred();
  const watcher = watch(root, () => { if (existsSync(marker)) ready.resolve(); });
  const controller = new AbortController();
  let pids: number[] = [];
  try {
    const execution = execute(tools, 'shell', { description: '检查进程组取消', command: `${quote(process.execPath)} ${quote(processFixture)}` }, root, controller.signal);
    await ready.promise;
    const written = JSON.parse(readFileSync(marker, 'utf8')) as { parent: number; child: number };
    pids = [written.parent, written.child];
    for (const pid of pids) expect(() => process.kill(pid, 0)).not.toThrow();
    const group = processes.values.filter((value) => value.active).at(-1)!.pid;
    controller.abort();
    expect((await execution).status).toBe('error');
    expect(() => process.kill(-group, 0)).toThrow();
    for (const pid of pids) expect(() => process.kill(pid, 0)).toThrow();
    expect(processes.values.at(-1)).toEqual({ pid: group, active: false });
  } finally {
    watcher.close();
    controller.abort();
    for (const pid of pids) { try { process.kill(pid, 'SIGKILL'); } catch { /* 已停止。 */ } }
  }
}, 1000);

// 磁盘独占锁、主循环取消与重新打开交接：旧请求的材料快照仍可读，新请求须重新读取磁盘。
test('终端线程关闭等工具停止，重开保留历史并更新项目材料', async () => {
  const root = h.root();
  const cwd = join(root, 'project');
  const threadDir = join(root, 'thread');
  mkdirSync(join(cwd, '.kite', 'memory'), { recursive: true });
  writeFileSync(join(cwd, 'AGENTS.md'), '项目专属指令：保留这句话');
  writeFileSync(join(cwd, '.kite', 'memory', 'MEMORY.md'), '长期记忆：保留这条索引');
  const model = new ManualModel();
  let currentModel = model;
  const started = deferred<AbortSignal>();
  const stopped = h.gate(success('停止前的结果'));
  const options = {
    cwd, threadDir, env: ENV(),
    prepareRequest: () => ({
      model: currentModel,
      instructions: projectContext(cwd),
      tools: [tool('hold', async (_args, { signal }) => { started.resolve(signal); await aborted(signal); return stopped.promise; })],
      settings: { model: { model: 'test', reasoning: 'high' } },
    }),
  };
  const opened = await openThreadHost(options);
  try {
    await expect(openThreadHost(options)).rejects.toThrow();
    await opened.runner.send(input('保留输入'));
    const first = await model.call(1);
    expect(first.request.instructions).toContain('项目专属指令：保留这句话');
    expect(first.request.instructions).toContain('长期记忆：保留这条索引');
    await first.response.emit({ type: 'item', item: item('held-call', 'hold') });
    const signal = await started.promise;
    let closed = false;
    const closing = opened.close().then(() => { closed = true; });
    await aborted(signal);
    expect(closed).toBe(false);
    await expect(openThreadHost(options)).rejects.toThrow();
    stopped.resolve(success('停止前的结果'));
    await closing;
    const journalPath = join(threadDir, readdirSync(threadDir).find((name) => name.endsWith('.jsonl'))!);
    const oldSnapshot = diskRecords(journalPath).find((record) => record.type === 'context.prepared');
    if (oldSnapshot?.type !== 'context.prepared') throw new Error('缺少旧项目材料快照');
    expect(restoreContext(oldSnapshot.snapshot).instructions).toBe(first.request.instructions);
    writeFileSync(join(cwd, 'AGENTS.md'), '项目专属指令：换成新规则');
    writeFileSync(join(cwd, '.kite', 'memory', 'MEMORY.md'), '长期记忆：换成新索引');
    const elsewhere = join(root, 'elsewhere');
    mkdirSync(elsewhere);
    await expect(openThreadHost({ ...options, cwd: elsewhere })).rejects.toThrow();
    const nextModel = new ManualModel();
    currentModel = nextModel;
    const reopened = await openThreadHost(options);
    try {
      await reopened.runner.send(input('重开输入'));
      const next = await nextModel.call(1);
      expect(next.request.instructions).toBe(first.request.instructions);
      const updates = next.request.history.filter((entry) => entry.type === 'notification');
      expect(updates).toHaveLength(1);
      expect(updates[0]!.text).toContain('项目专属指令：换成新规则');
      expect(updates[0]!.text).toContain('长期记忆：换成新索引');
      const records = diskRecords(journalPath);
      const snapshots = records.filter((record) => record.type === 'context.prepared');
      const starts = records.filter((record) => record.type === 'request.started');
      const delivered = starts[1]!.notifications?.[0];
      if (!delivered) throw new Error('缺少已投递项目材料快照');
      const { context, ...metadata } = delivered;
      expect(updates[0]!.notification).toEqual(metadata);
      expect(updates[0]!.text).toBe(restoreContext(context).instructions);
      expect(snapshots).toHaveLength(2);
      expect(starts[0]!.contextId).toBe(oldSnapshot.snapshot.id);
      expect(starts[1]!.contextId).toBe(snapshots[1]!.snapshot.id);
      expect(snapshots[0]!.snapshot).toEqual(oldSnapshot.snapshot);
      expect(updates[0]!.text).toContain(restoreContext(snapshots[1]!.snapshot).instructions);
      expect(next.request.history).toContainEqual({ type: 'input', input: input('保留输入') });
      expect(next.request.history).toContainEqual({ type: 'output', item: item('held-call', 'hold') });
      expect(next.request.history).toContainEqual({ type: 'tool_result', callId: 'held-call', result: success('停止前的结果') });
      next.response.complete();
      await reopened.runner.settled();
    } finally {
      await reopened.close();
    }
  } finally {
    stopped.resolve(success('停止前的结果'));
    await opened.close();
  }
}, 1000);
