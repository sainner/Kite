import { expect, test } from 'bun:test';
import { existsSync, mkdirSync, readFileSync, readdirSync, statSync, symlinkSync, watch, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { readSubscriptionCredentials } from '../../src/harness/auth.ts';
import { ChatGPTModel } from '../../src/harness/chatgpt.ts';
import { restoreContext } from '../../src/harness/context/assembler.ts';
import { localTools } from '../../src/harness/local-tools.ts';
import { openTerminalSession } from '../../src/harness/terminal-session.ts';
import type { Json, JsonObject, ModelEvent, ModelRequest, Tool, ToolResult } from '../../src/harness/types.ts';
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

async function execute(tools: Tool[], name: string, args: Json, cwd: string, signal = new AbortController().signal): Promise<ToolResult> {
  const selected = tools.find((value) => value.name === name)!;
  selected.validate(args);
  return selected.execute(args, { cwd, signal });
}

async function rejectedOperation(operation: Promise<ToolResult>): Promise<void> {
  const result = await operation.catch(() => ({ status: 'error' }));
  expect(result.status).toBe('error');
}

// SSE 解码、完整调用通知、主循环调度与下一请求投影共同决定工具能否执行和无损续接。
test('订阅字节流完整保存原生条目，调用参数收齐才执行并按 call_id 回传结果', async () => {
  const root = h.root();
  const first = sse();
  const second = sse();
  const posts = new Seen<{ url: string; init: RequestInit; body: JsonObject }>();
  const model = new ChatGPTModel({
    model: 'test-model', sessionId: 'test-session', credentials,
    async fetch(url, init) {
      posts.add({ url, init, body: JSON.parse(String(init.body)) as JsonObject });
      return posts.values.length === 1 ? first.response() : second.response();
    },
  });
  const started = deferred<Json>();
  let executions = 0;
  const { session, journal, events } = h.session(root, {
    model, tools: [tool('record', async (args) => { executions++; started.resolve(args); return success('工具结果：中文'); })],
  });
  await session.send(input('中文请求'));
  const post = await posts.wait(() => true);
  expect(post.url).toBe('https://chatgpt.com/backend-api/codex/responses');
  expect(post.init.method).toBe('POST');
  const headers = new Headers(post.init.headers);
  expect(headers.get('Authorization')).toBe('Bearer test-access-token');
  expect(headers.get('ChatGPT-Account-Id')).toBe('test-account');
  expect(post.body).toMatchObject({ store: false, stream: true, include: ['reasoning.encrypted_content'] });
  const reasoning: JsonObject = { id: 'reasoning-1', type: 'reasoning', encrypted_content: '不透明串', extra: { bytes: [0, 255] } };
  const call: JsonObject = {
    id: 'item-id', type: 'function_call', call_id: 'external-call-id', name: 'record',
    arguments: JSON.stringify({ text: '中文参数' }), future_field: ['照原样保留'],
  };
  first.event({ type: 'response.output_item.done', item: reasoning });
  first.event({ type: 'response.output_item.added', item: { ...call, arguments: '' } });
  first.event({ type: 'response.function_call_arguments.delta', item_id: call.id, delta: '{"text":"中' });
  first.event({ type: 'response.output_text.delta', delta: '中文增量' });
  await events.wait((event) => event.type === 'delta' && event.text === '中文增量');
  expect(executions).toBe(0);
  first.event({ type: 'response.output_item.done', item: call });
  expect(await started.promise).toEqual({ text: '中文参数' });
  expect(journal.records.some((record) => record.type === 'request.completed')).toBe(false);
  const fallback: JsonObject = { id: 'only-completed', type: 'message', role: 'assistant', content: [{ type: 'output_text', text: '完成', annotations: [] }], future: '保留' };
  first.event({ type: 'response.completed', response: { id: 'response-1', status: 'completed', output: [reasoning, call, fallback] } });
  first.close();
  const next = await posts.wait((value) => value !== post);
  expect(next.body.input).toContainEqual(reasoning);
  expect(next.body.input).toContainEqual(call);
  expect(next.body.input).toContainEqual(fallback);
  expect(next.body.input).toContainEqual({ type: 'function_call_output', call_id: 'external-call-id', output: '工具结果：中文' });
  const outputItems = journal.records.filter((record) => record.type === 'model.item');
  expect(outputItems.map((record) => record.item.raw)).toEqual([reasoning, call, fallback]);
  expect(executions).toBe(1);
  second.event({ type: 'response.completed', response: { id: 'response-2', status: 'completed', output: [] } });
  second.close();
  await session.settled();
  expect(session.state.lastOutcome).toEqual({ kind: 'completed' });
}, 1000);

// ReadableStream 的 EOF、cancel 和 AbortSignal 是运行时交接：已有文字不能掩盖失败，也不能重试副作用。
test('订阅失败与提前断流不会完成或重试，取消会释放正在等待的流 reader', async () => {
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
      model: 'test', sessionId: 'failure', credentials,
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
    model: 'test', sessionId: 'cancel', credentials,
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
test('订阅缓存每次重新只读加载，拒绝 API key、过期和损坏且错误不泄露令牌', async () => {
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
  const read = await execute(tools, 'read', { path: 'note.txt', offset: 2, limit: 1 }, cwd);
  expect(read.status).toBe('success');
  expect(read.output).toContain('乙');
  expect(read.output).not.toMatch(/甲|丙/);
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
test('命令使用显式环境并保存完整日志，取消等整组退出而预先取消不启动', async () => {
  const root = h.root();
  const logDir = join(root, 'logs');
  const processes = new Seen<{ pid: number; active: boolean }>();
  const tools = localTools({
    cwd: root, logDir, env: { ...ENV(), KITE_SUBSCRIPTION_TEST_ENV: '仅由显式env传入' }, outputLimit: 64,
    onProcess(pid, active) { processes.add({ pid, active }); },
  });
  const quote = (value: string) => `'${value.replaceAll("'", "'\\''")}'`;
  const longOutput = '完整输出'.repeat(120);
  const command = `${quote(process.execPath)} -e ${quote('process.stdout.write(process.env.KITE_SUBSCRIPTION_TEST_ENV + "\\n" + ' + JSON.stringify(longOutput) + '); process.stderr.write("错误流也保存");')}`;
  const result = await execute(tools, 'shell', { command }, root);
  expect(result.status).toBe('success');
  const logs = readdirSync(logDir).map((name) => join(logDir, name));
  const contents = logs.map((path) => readFileSync(path, 'utf8')).join('');
  expect(contents).toContain('仅由显式env传入');
  expect(contents).toContain(longOutput);
  expect(contents).toContain('错误流也保存');
  expect(result.output).not.toContain(longOutput);
  expect(logs.some((path) => result.output.includes(path))).toBe(true);
  expect(processes.values.filter((value) => value.active)).toHaveLength(1);
  expect(processes.values.at(-1)?.active).toBe(false);

  const before = processes.values.length;
  const preCancelled = new AbortController();
  preCancelled.abort();
  await rejectedOperation(execute(tools, 'shell', { command: 'touch forbidden-start' }, root, preCancelled.signal));
  expect(existsSync(join(root, 'forbidden-start'))).toBe(false);
  expect(processes.values).toHaveLength(before);

  const marker = join(root, 'descendants.json');
  const fixture = join(root, 'hold-processes.ts');
  const childSource = 'process.on("SIGTERM", () => {}); Bun.serve({ port: 0, fetch() { return new Response("等待取消"); } }); console.log(process.pid);';
  writeFileSync(fixture, [
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
    const execution = execute(tools, 'shell', { command: `${quote(process.execPath)} ${quote(fixture)}` }, root, controller.signal);
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
test('终端会话关闭等待执行停止，重开保留旧快照和历史并读取新项目材料', async () => {
  const root = h.root();
  const cwd = join(root, 'project');
  const sessionDir = join(root, 'session');
  mkdirSync(join(cwd, '.kite', 'memory'), { recursive: true });
  writeFileSync(join(cwd, 'AGENTS.md'), '项目专属指令：保留这句话');
  writeFileSync(join(cwd, '.kite', 'memory', 'MEMORY.md'), '长期记忆：保留这条索引');
  const model = new ManualModel();
  const started = deferred<AbortSignal>();
  const stopped = h.gate(success('停止前的结果'));
  const options = {
    cwd, sessionDir, model, env: ENV(), modelConfig: { model: 'test', reasoning: 'high' },
    tools: [tool('hold', async (_args, { signal }) => { started.resolve(signal); await aborted(signal); return stopped.promise; })],
  };
  const opened = await openTerminalSession(options);
  try {
    await expect(openTerminalSession(options)).rejects.toThrow();
    const metadata = JSON.parse(readFileSync(join(sessionDir, 'metadata.json'), 'utf8'));
    expect(metadata).toMatchObject({ cwd, modelConfig: options.modelConfig });
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
    await expect(openTerminalSession(options)).rejects.toThrow();
    stopped.resolve(success('停止前的结果'));
    await closing;
    const journalPath = join(sessionDir, readdirSync(sessionDir).find((name) => name.endsWith('.jsonl'))!);
    const oldSnapshot = diskRecords(journalPath).find((record) => record.type === 'context.prepared');
    expect(oldSnapshot?.type).toBe('context.prepared');
    if (oldSnapshot?.type !== 'context.prepared') throw new Error('缺少旧项目材料快照');
    expect(restoreContext(oldSnapshot.snapshot).instructions).toBe(first.request.instructions);
    writeFileSync(join(cwd, 'AGENTS.md'), '项目专属指令：换成新规则');
    writeFileSync(join(cwd, '.kite', 'memory', 'MEMORY.md'), '长期记忆：换成新索引');
    const elsewhere = join(root, 'elsewhere');
    mkdirSync(elsewhere);
    await expect(openTerminalSession({ ...options, cwd: elsewhere })).rejects.toThrow();
    const nextModel = new ManualModel();
    const reopened = await openTerminalSession({ ...options, model: nextModel });
    try {
      await reopened.runner.send(input('重开输入'));
      const next = await nextModel.call(1);
      expect(next.request.cwd).toBe(cwd);
      expect(next.request.instructions).toContain('项目专属指令：换成新规则');
      expect(next.request.instructions).toContain('长期记忆：换成新索引');
      expect(next.request.instructions).not.toContain('项目专属指令：保留这句话');
      const records = diskRecords(journalPath);
      const snapshots = records.filter((record) => record.type === 'context.prepared');
      const starts = records.filter((record) => record.type === 'request.started');
      expect(snapshots).toHaveLength(2);
      expect(starts[0]!.contextId).toBe(oldSnapshot.snapshot.id);
      expect(starts[1]!.contextId).toBe(snapshots[1]!.snapshot.id);
      expect(snapshots[0]!.snapshot).toEqual(oldSnapshot.snapshot);
      expect(next.request.instructions).toBe(restoreContext(snapshots[1]!.snapshot).instructions);
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
