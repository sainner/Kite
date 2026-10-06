/** 经 HTTP、CLI 驱动真实 Claude Code，验证 Kite 文件工具的 MCP 桥接与原生恢复。 */
import { afterEach, expect, setDefaultTimeout, test } from 'bun:test';
import { randomUUID } from 'node:crypto';
import { existsSync, symlinkSync } from 'node:fs';
import { join } from 'node:path';
import { startDaemon, type Daemon } from '../../src/daemon.ts';
import type { History } from '../../src/transcript/protocol.ts';
import { startCli } from '../cli.ts';
import type { Logged } from '../fake-api.ts';
import {
  api, call, createWorkspace, type Kited, listSnapshots, mark, registerCheckout, sendThreadMessage, startKited, waitRunner,
} from '../harness.ts';
import { commitAll, git, newRepo, read, until, useTemp, writeFiles } from '../util.ts';

setDefaultTimeout(3_000);

let k: Kited | undefined;
let restarted: Daemon | undefined;
afterEach(async () => {
  await restarted?.stop(); restarted = undefined;
  await k?.stop(); k = undefined;
});
const temp = useTemp();

const token = (name: string) => `${name}-${randomUUID().slice(0, 8)}`;
const readTool = 'mcp__kite__read';
const patchTool = 'mcp__kite__patch';
const shellTool = 'mcp__kite__shell';
const expectedTools = [readTool, patchTool, shellTool,
  ...['agent_start', 'agent_list', 'agent_send', 'agent_resume', 'agent_stop'].map((name) => `mcp__kite__${name}`)].sort();
const tools = (request: Logged): string[] => (request.body.tools ?? []).map((tool: { name: string }) => tool.name);
const resultFor = (request: Logged, id: string) => request.body.messages
  .flatMap((message: any) => Array.isArray(message.content) ? message.content : [])
  .find((block: any) => block.type === 'tool_result' && block.tool_use_id === id);
const resultText = (result: any): string => typeof result.content === 'string' ? result.content
  : result.content.filter((block: any) => block.type === 'text').map((block: any) => block.text).join('\n');
const resultValue = (result: any) => ({ call: result.tool_use_id, content: result.content, error: !!result.is_error });

async function readResult(id: string) {
  const request = await api.waitRequest((entry) => entry.main && !!resultFor(entry, id));
  return resultFor(request, id);
}

async function history(kited: Kited, threadId: string): Promise<History> {
  const response = await kited.call('GET', `/threads/${threadId}/history`);
  expect(response.status).toBe(200);
  return response.body;
}

/*
 * 上游行为：SDK MCP 工具在禁用原生工具时仍可调用，原生 resume 要重新接好进程内 MCP 并保留旧结果；
 * 宿主工具不能让默认工具、项目 skill 或 .mcp.json 重新出现。实际请求、回传和 HTTP 历史投影须一起验证。
 * skills: [] 只过滤模型上下文，init.skills 仍列出发现的技能（Claude Code 2.1.280 实测），所以断言实际请求。
 * .mcp.json 的命令一启动就留标记，避免工具列表为空却已经启动外部进程的假通过。
 */
test('Claude 新建与续接只开放 Kite 工具，按行读取经 MCP 返回并投影为 read 历史，项目工具不回流', async () => {
  k = startKited();
  const kk = k;
  const mcpStarted = join(kk.root, 'mcp-started');
  const skill = token('project-skill');
  const repo = newRepo(kk.root, 'proj', {
    'a.txt': '首行未选中\n第二行读取成功\n第三行恢复成功\n',
    '.claude/settings.local.json': JSON.stringify({ enableAllProjectMcpServers: true }),
    [`.claude/skills/${skill}/SKILL.md`]: `---\nname: ${skill}\ndescription: 项目测试技能\n---\n这是一条项目技能指令。\n`,
    '.mcp.json': JSON.stringify({ mcpServers: {
      projectProbe: { command: '/bin/sh', args: ['-c', 'printf started > "$1"', 'sh', mcpStarted] },
    } }),
  });
  const p = await registerCheckout(kk, repo);

  const a = token('首回合');
  const firstArgs = { path: 'a.txt', offset: 2, limit: 1 };
  const secondArgs = { path: 'a.txt', offset: 3, limit: 1 };
  const s = await createWorkspace(kk, p.checkout.id, `第一条 ${a}\nREAD ${JSON.stringify(firstArgs)}`);
  const req1 = await api.waitRequest((l) => l.main && l.lastUserText.includes(a));
  expect(tools(req1).sort()).toEqual(expectedTools);
  expect(JSON.stringify(req1.body)).not.toContain(skill);
  expect(JSON.stringify(req1.body)).not.toContain('这是一条项目技能指令。');
  expect(req1.toolUseIds).toHaveLength(1);
  const firstId = req1.toolUseIds[0]!;
  const firstResult = await readResult(firstId);
  expect(firstResult.is_error).toBeFalsy();
  expect(resultText(firstResult)).toMatch(/(?:^|\n)\s*2[^\n]*第二行读取成功/);
  expect(resultText(firstResult)).not.toMatch(/首行未选中|第三行恢复成功/);
  await waitRunner(kk, s.id, 'closed');
  expect((await history(kk, s.id)).records).toEqual(expect.arrayContaining([
    expect.objectContaining({ block: expect.objectContaining({ type: 'tool_use', id: firstId, name: 'read', input: firstArgs }) }),
    expect.objectContaining({ block: expect.objectContaining({ type: 'tool_result', call: firstId, status: 'success', output: resultText(firstResult) }) }),
  ]));
  expect(existsSync(mcpStarted)).toBe(false);

  const m = mark(kk);
  const b = token('续接');
  const sending = startCli(kk.url, 'send', s.id, `第二条 ${b}\nREAD ${JSON.stringify(secondArgs)}`);
  try {
    const req2 = await api.waitRequest((l) => l.main && l.lastUserText.includes(b));
    expect(JSON.stringify(req2.body.messages)).toContain(a);
    expect(tools(req2).sort()).toEqual(expectedTools);
    expect(resultValue(resultFor(req2, firstId))).toEqual(resultValue(firstResult));
    expect(JSON.stringify(req2.body)).not.toContain(skill);
    expect(JSON.stringify(req2.body)).not.toContain('这是一条项目技能指令。');
    expect(req2.toolUseIds).toHaveLength(1);
    const secondId = req2.toolUseIds[0]!;
    const secondResult = await readResult(secondId);
    expect(secondResult.is_error).toBeFalsy();
    expect(resultText(secondResult)).toMatch(/(?:^|\n)\s*3[^\n]*第三行恢复成功/);
    expect(resultText(secondResult)).not.toMatch(/首行未选中|第二行读取成功/);
    await waitRunner(kk, s.id, 'closed', m);
    expect(await sending.finished()).toMatchObject({ code: 0, stderr: '', stdout: expect.stringContaining('第三行恢复成功') });
    const resumed = await history(kk, s.id);
    expect(resumed.records.filter((record) => record.block.type === 'tool_use').map((record) => record.block)).toEqual([
      expect.objectContaining({ type: 'tool_use', id: firstId, name: 'read', input: firstArgs }),
      expect.objectContaining({ type: 'tool_use', id: secondId, name: 'read', input: secondArgs }),
    ]);
    expect(resumed.records).toEqual(expect.arrayContaining([
      expect.objectContaining({ block: expect.objectContaining({ type: 'tool_result', call: firstId, status: 'success', output: resultText(firstResult) }) }),
      expect.objectContaining({ block: expect.objectContaining({ type: 'tool_result', call: secondId, status: 'success', output: resultText(secondResult) }) }),
    ]));
  } finally {
    await sending.stop();
  }

  const inits = kk.events.flatMap((e) => e.type === 'sdk' && e.threadId === s.id && e.message.type === 'system' && e.message.subtype === 'init' ? [e.message] : []);
  expect(inits).toHaveLength(2);
  for (const init of inits) {
    expect(init.session_id).toBe(s.nativeId);
    expect([...init.tools].sort()).toEqual(expectedTools);
    expect(init.mcp_servers).toEqual([expect.objectContaining({ name: 'kite', status: 'connected' })]);
  }
  expect(existsSync(mcpStarted)).toBe(false);
});

/* MCP 处理器抛错要转成 tool_result.is_error，经原生会话记录投影成失败结果；错误后仍可恢复读取。 */
test('read 拒绝目录越界和符号链接逃逸，错误不泄露正文且之后仍可读取', async () => {
  k = startKited();
  const kk = k;
  const outside = temp();
  const externalSecret = token('外部机密');
  writeFiles(outside, { 'secret.txt': externalSecret });
  const repo = newRepo(kk.root, 'proj', { 'allowed.txt': '失败后仍能读取\n' });
  symlinkSync(outside, join(repo, 'escape'));
  commitAll(repo, '准备读取边界');
  const p = await registerCheckout(kk, repo);
  const marker = token('拒绝读取');
  const args = [
    { path: join(outside, 'secret.txt') },
    { path: 'escape/secret.txt' },
  ];
  const thread = await createWorkspace(kk, p.checkout.id, `${marker}\nREAD ${JSON.stringify(args)}`);
  const threadId = thread.id;
  const request = await api.waitRequest((entry) => entry.main && entry.lastUserText.includes(marker));
  expect(request.toolUseIds).toHaveLength(2);
  for (const id of request.toolUseIds) {
    const result = await readResult(id);
    expect(result.is_error).toBe(true);
    expect(resultText(result)).not.toBe('');
    expect(resultText(result)).not.toContain(externalSecret);
  }
  await waitRunner(kk, threadId, 'closed');
  const failed = await history(kk, threadId);
  expect(failed.records.filter((record) => record.block.type === 'tool_result').map((record) => record.block)).toEqual(
    expect.arrayContaining(request.toolUseIds.map((call) => expect.objectContaining({ type: 'tool_result', call, status: 'error' }))),
  );
  expect(JSON.stringify(failed)).not.toContain(externalSecret);

  const since = mark(kk);
  const resumed = token('读取恢复');
  await sendThreadMessage(kk, threadId, `${resumed}\nREAD {"path":"allowed.txt"}`);
  const next = await api.waitRequest((entry) => entry.main && entry.lastUserText.includes(resumed));
  const result = await readResult(next.toolUseIds[0]!);
  expect(result.is_error).toBeFalsy();
  expect(resultText(result)).toContain('失败后仍能读取');
  await waitRunner(kk, threadId, 'closed', since);
});

/*
 * 上游把 MCP structuredContent 转成模型可见的 JSON 文本；成功与局部失败的 diff 都必须经原生记录和显示投影保留。
 * 在假端点收到下一请求时同步记录已发生的快照事件，防止稍后读取快照列表掩盖 PostToolBatch 的时序回归。
 */
test('patch 的结果和快照先于下一模型请求，局部失败及服务重开后仍可查看各次原始 diff', async () => {
  k = startKited();
  const kk = k;
  const repo = newRepo(kk.root, 'proj', { 'original.txt': '修改前\n' });
  const p = await registerCheckout(kk, repo);
  const marker = token('修改文件');
  const hold = token('补丁后');
  const args = { operations: [
    { type: 'update_file', path: 'original.txt', diff: '@@\n-修改前\n+修改后' },
    { type: 'create_file', path: 'created.txt', diff: '+新建正文\n+' },
  ] };
  let snapshotsAtRequest: string[] = [];
  const received = api.waitRequest((entry) => {
    if (entry.hold !== hold) return false;
    snapshotsAtRequest = kk.events.flatMap((event) => event.type === 'workspace.snapshot' ? [event.commit] : []);
    return true;
  });
  const thread = await createWorkspace(kk, p.checkout.id, `${marker}\nPATCH ${JSON.stringify(args)}\nHOLD_RESULT ${hold}`);
  const initial = await api.waitRequest((entry) => entry.main && entry.lastUserText.includes(marker));
  expect(initial.toolUseIds).toHaveLength(1);
  const patchId = initial.toolUseIds[0]!;
  const next = await received;
  const result = resultFor(next, patchId);
  expect(result.is_error).toBeFalsy();
  const payload = JSON.parse(resultText(result)) as { output: string; diff: { id: string; paths: string[] } };
  expect(payload.output).not.toBe('');
  expect(payload.diff.paths).toEqual(['original.txt', 'created.txt']);
  expect(read(join(thread.workspace.cwd, 'original.txt'))).toBe('修改后\n');
  expect(read(join(thread.workspace.cwd, 'created.txt'))).toBe('新建正文\n');
  expect(read(join(repo, 'original.txt'))).toBe('修改前\n');
  expect(existsSync(join(repo, 'created.txt'))).toBe(false);

  const snapshot = (await listSnapshots(kk, thread.workspace.id)).find((value) => value.toolUseIds.includes(patchId));
  expect(snapshot).toBeDefined();
  expect(snapshotsAtRequest).toContain(snapshot!.commit);
  expect(git(repo, 'show', `${snapshot!.commit}:original.txt`)).toBe('修改后');
  expect(git(repo, 'show', `${snapshot!.commit}:created.txt`)).toBe('新建正文');
  const live = await history(kk, thread.id);
  const liveResult = live.records.flatMap((record) => record.block.type === 'tool_result' && record.block.call === patchId ? [record.block] : [])[0];
  expect(liveResult).toEqual({ type: 'tool_result', call: patchId, output: payload.output, status: 'success', diff: payload.diff });
  expect(live.records).toContainEqual(expect.objectContaining({
    block: expect.objectContaining({ type: 'tool_use', id: patchId, name: 'patch', input: args }),
  }));

  const openedFiles = await kk.call('POST', `/workspaces/${thread.workspace.id}/windows`, {
    id: randomUUID(), content: { kind: 'create', definitionId: 'kite.files' },
  });
  expect(openedFiles.status).toBe(200);
  const diffPath = `/workspaces/${thread.workspace.id}/operations/files.diff`;
  const diffArgs = { instanceId: openedFiles.body.target.instanceId as string, diffId: payload.diff.id };
  const expectedDiff = { id: payload.diff.id, files: [
    { path: 'original.txt', before: '修改前\n', after: '修改后\n' },
    { path: 'created.txt', before: null, after: '新建正文\n' },
  ] };
  expect(await kk.call('POST', diffPath, diffArgs)).toEqual({ status: 200, body: expectedDiff });
  api.release(hold);
  await waitRunner(kk, thread.id, 'closed');

  const since = mark(kk);
  const failedMarker = token('局部失败');
  // 预检时父子路径都不存在；第一项把父路径建成普通文件，第二项实际 mkdir 才失败。
  const invalid = { operations: [
    { type: 'create_file', path: 'partial.txt', diff: '+部分已完成\n+' },
    { type: 'create_file', path: 'partial.txt/child.txt', diff: '+不应写入\n+' },
  ] };
  await sendThreadMessage(kk, thread.id, `${failedMarker}\nPATCH ${JSON.stringify(invalid)}`);
  const resumed = await api.waitRequest((entry) => entry.main && entry.lastUserText.includes(failedMarker));
  expect(resultValue(resultFor(resumed, patchId))).toEqual(resultValue(result));
  expect(resumed.toolUseIds).toHaveLength(1);
  const failedId = resumed.toolUseIds[0]!;
  const failedResult = await readResult(failedId);
  expect(failedResult.is_error).toBe(true);
  const partial = JSON.parse(resultText(failedResult)) as typeof payload;
  expect(partial.output).not.toBe('');
  expect(partial.diff.paths).toEqual(['partial.txt']);
  expect(partial.diff.id).not.toBe(payload.diff.id);
  await waitRunner(kk, thread.id, 'closed', since);
  expect(read(join(thread.workspace.cwd, 'original.txt'))).toBe('修改后\n');
  expect(read(join(thread.workspace.cwd, 'partial.txt'))).toBe('部分已完成\n');
  expect(existsSync(join(thread.workspace.cwd, 'partial.txt/child.txt'))).toBe(false);
  const completed = await history(kk, thread.id);
  expect(completed.records).toContainEqual(expect.objectContaining({ block: liveResult }));
  expect(completed.records).toContainEqual(expect.objectContaining({
    block: { type: 'tool_result', call: failedId, output: partial.output, status: 'error', diff: partial.diff },
  }));
  const partialArgs = { ...diffArgs, diffId: partial.diff.id };
  const partialDiff = { id: partial.diff.id, files: [{ path: 'partial.txt', before: null, after: '部分已完成\n' }] };
  expect(await kk.call('POST', diffPath, partialArgs)).toEqual({ status: 200, body: partialDiff });

  await kk.daemon.stop();
  restarted = startDaemon({ home: kk.home, port: 0, lightTasks: false });
  const rebuilt = await call(restarted.url, 'GET', `/threads/${thread.id}/history`);
  expect(rebuilt.status).toBe(200);
  const toolBlocks = (value: History) => value.records.flatMap<History['records'][number]['block']>((record) => {
    const block = record.block;
    if (block.type === 'tool_use') return [{ type: block.type, id: block.id, name: block.name, input: block.input }];
    if (block.type === 'tool_result') return [block];
    return [];
  });
  expect(toolBlocks(rebuilt.body)).toEqual(toolBlocks(completed));
  expect(await call(restarted.url, 'POST', diffPath, diffArgs)).toEqual({ status: 200, body: expectedDiff });
  expect(await call(restarted.url, 'POST', diffPath, partialArgs)).toEqual({ status: 200, body: partialDiff });
});

/* Claude 的 MCP 取消信号必须跨 SDK 到达受管 shell；真实订阅曾在正常停止后误留 recovery，阻止后续继续。 */
test('Claude shell 保持工作区沙箱并流式输出，停止会等待命令和后代退出', async () => {
  k = startKited();
  const kk = k;
  const secret = join(kk.root, 'outside.txt');
  const marker = token('shell正在执行');
  writeFiles(kk.root, { 'outside.txt': '外部文件保持原样' });
  const childSource = 'process.on("SIGTERM", () => {}); setInterval(() => {}, 1000); console.log(process.pid);';
  const repo = newRepo(kk.root, 'proj', { 'probe.ts': [
    'import { readFileSync, writeFileSync } from "node:fs";',
    'process.on("SIGTERM", () => {});',
    `const external = ${JSON.stringify(secret)};`,
    'let outsideRead = false; let outsideWrite = false;',
    'try { readFileSync(external); outsideRead = true; } catch {}',
    'try { writeFileSync(external, "不应写入"); outsideWrite = true; } catch {}',
    `const child = Bun.spawn([process.execPath, "-e", ${JSON.stringify(childSource)}], { env: process.env, stdout: "pipe", stderr: "ignore" });`,
    'const reader = child.stdout.getReader();',
    'const { value } = await reader.read();',
    'const report = { parent: process.pid, child: Number(new TextDecoder().decode(value)), outsideRead, outsideWrite };',
    'writeFileSync("shell-ready.json", JSON.stringify(report));',
    `console.log(${JSON.stringify(marker)});`,
    'await child.exited;',
  ].join('\n') });
  const p = await registerCheckout(kk, repo);
  const quote = (value: string) => `'${value.replaceAll("'", "'\\''")}'`;
  const args = { description: '验证 Claude 命令沙箱及取消', command: `exec ${quote(process.execPath)} probe.ts` };
  const thread = await createWorkspace(kk, p.checkout.id, `SHELL ${JSON.stringify(args)}`);
  const request = await api.waitRequest((entry) => entry.main && entry.lastUserText.includes(args.description));
  expect(request.toolUseIds).toHaveLength(1);
  const callId = request.toolUseIds[0]!;
  let pids: number[] = [];
  const alive = (pid: number) => { try { process.kill(pid, 0); return true; } catch { return false; } };
  try {
    const readyPath = join(thread.workspace.cwd, 'shell-ready.json');
    const report = await until(() => {
      try { return JSON.parse(read(readyPath)) as { parent: number; child: number; outsideRead: boolean; outsideWrite: boolean }; }
      catch { return false; }
    }, '沙箱命令与子进程已就绪');
    pids = [report.parent, report.child];
    expect(report).toMatchObject({ outsideRead: false, outsideWrite: false });
    expect(read(secret)).toBe('外部文件保持原样');
    expect(pids.every(alive)).toBe(true);
    const streaming = await until(async () => {
      const view = await history(kk, thread.id);
      return view.records.find((record) => record.block.type === 'tool_use' && record.block.id === callId
        && record.block.name === 'shell' && record.block.output?.includes(marker));
    }, 'shell 输出在结束前到达 HTTP 历史');
    expect((await kk.call('POST', `/threads/${thread.id}/interrupt`, { id: randomUUID() })).status).toBe(200);
    await until(() => pids.every((pid) => !alive(pid)), 'shell 与后代进程都停止', 1_000);
    const stopped = await history(kk, thread.id);
    expect(stopped.state).toMatchObject({ phase: 'idle', busy: false, lastOutcome: { kind: 'interrupted' } });
    expect(stopped.state.recovery).toBeUndefined();
    const calls = stopped.records.filter((record) => record.block.type === 'tool_use' && record.block.id === callId);
    expect(calls).toHaveLength(1);
    expect(calls[0]!.id).toBe(streaming.id);
  } finally {
    for (const pid of pids) try { process.kill(pid, 'SIGKILL'); } catch { /* 测试失败时也收回自己的子进程。 */ }
  }
});
