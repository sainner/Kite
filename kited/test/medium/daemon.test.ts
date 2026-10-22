/** 经 HTTP 驱动真实 Claude Code，验证 Kite 文件工具的 MCP 桥接与原生恢复。 */
import { afterEach, expect, setDefaultTimeout, spyOn, test } from 'bun:test';
import { randomUUID } from 'node:crypto';
import { existsSync, symlinkSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { Runner } from '../../src/claude/runner.ts';
import { defaultAgentModel } from '../../src/agents/models.ts';
import { startDaemon, type Daemon } from '../../src/daemon.ts';
import type { History } from '../../src/transcript/protocol.ts';
import type { Logged } from '../fake-api.ts';
import { bunPluginSource } from '../fixtures/bun-plugin-source.ts';
import {
  addProject, api, call, createWorkspace, type Kited, listSnapshots, mark, sendThreadMessage, startKited, waitIdle,
} from '../harness.ts';
import { commitAll, ENV, git, newRepo, read, transcript, until, useTemp, writeFiles } from '../util.ts';

setDefaultTimeout(3_000);

let k: Kited | undefined;
let restarted: Daemon | undefined;
let restoreQuery: (() => void) | undefined;
afterEach(async () => {
  await restarted?.stop(); restarted = undefined;
  await k?.stop(); k = undefined;
  restoreQuery?.(); restoreQuery = undefined;
});
const temp = useTemp();

const token = (name: string) => `${name}-${randomUUID().slice(0, 8)}`;
/** Kite 自己的工具，Claude 里用裸名（不带 MCP 前缀），全部常驻。 */
const expectedTools = ['read', 'patch', 'shell', 'credentials', 'question', 'agent_start', 'agent_list', 'agent_send', 'agent_resume',
  'agent_stop', 'agent_merge', 'monitor_start', 'monitor_list', 'monitor_stop', 'terminal_run', 'terminal_list', 'terminal_read', 'terminal_stop',
  'preview_open', 'preview_action', 'preview_inspect', 'preview_list', 'preview_close'].sort();
const tools = (request: Logged): string[] => (request.body.tools ?? []).map((tool: { name: string }) => tool.name);
const resultFor = (request: Logged, id: string) => request.body.messages
  .flatMap((message: any) => Array.isArray(message.content) ? message.content : [])
  .find((block: any) => block.type === 'tool_result' && block.tool_use_id === id);
const resultText = (result: any): string => typeof result.content === 'string' ? result.content
  : result.content.filter((block: any) => block.type === 'text').map((block: any) => block.text).join('\n');
const resultValue = (result: any) => ({ call: result.tool_use_id, content: result.content, error: !!result.is_error });

/** 在 dir 里把 Bun 插件夹具打成单文件（同 test/small/bun-plugin.test.ts），插件宿主只收打好的字节串。 */
async function pluginBundle(dir: string): Promise<string> {
  const entry = join(dir, 'plugin.ts');
  symlinkSync(join(import.meta.dir, '..', '..', 'node_modules'), join(dir, 'node_modules'));
  writeFileSync(entry, bunPluginSource);
  const built = await Bun.build({ entrypoints: [entry], target: 'bun', format: 'esm', minify: true });
  if (!built.success || built.outputs.length !== 1) throw new Error(`插件夹具打包失败：${built.logs.join('\n')}`);
  return built.outputs[0]!.text();
}

async function readResult(id: string) {
  const request = await api.waitRequest((entry) => entry.main && !!resultFor(entry, id));
  return resultFor(request, id);
}

/** 这个原生会话的 Claude Code 进程。依赖 SDK 起 CLI 时把原生会话 id 放在命令行参数里（新建 --session-id，续接 --resume）。 */
const sessionProcesses = (nativeId: string) => Bun.spawnSync(['pgrep', '-f', nativeId], { env: ENV(), stdout: 'pipe' })
  .stdout.toString().split('\n').filter(Boolean).map(Number);

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
 * 进程常驻：回合之间进程不退出，下一回合写进同一进程的输入流；换模型后旧进程退出，用 resume 起新进程。
 * 流式输入下 CLI 每个回合都报一次 system/init（2.1.280 实测），不能用 init 的次数判断是否换了进程，改看进程号。
 * MCP 处理器抛错要转成 tool_result.is_error，经原生会话记录投影成失败结果；错误后仍可恢复读取。
 * 插件工具按需加载全靠 Claude Code（2.1.280 实测）：ENABLE_TOOL_SEARCH 在非官方地址上要显式打开；tools: ['ToolSearch'] 留下 ToolSearch
 * （tools: [] 会连它一起关掉）；kite 服务不整体常驻，逐个工具的 alwaysLoad 生效，没设的插件工具不进声明（CLI 另放一个 defer_loading 的占位）；
 * 流式输入下 CLI 启动只等整体常驻的 MCP 服务，CLAUDE_CODE_MCP_STARTUP_WAIT_MS 让它等 kite 服务连上，新进程的首个请求才有 Kite 的工具；
 * ToolSearch 搜到后 CLI 自己生成 tool_reference 结果、下一次请求起声明插件工具，之后才能调用。升级 CLI 就可能变。
 * 没有按需加载的工具时请求里不声明 ToolSearch，init.tools 里仍有它。
 */
test('Claude 常驻进程在 MCP 读取错误后继续工作，换模型后 resume 保留历史与 Kite 工具边界，授权的插件工具不常驻、经 ToolSearch 搜到后调用成功，fable 附件不妨碍切换后端', async () => {
  k = startKited();
  const kk = k;
  const bundle = pluginBundle(temp());
  const mcpStarted = join(kk.root, 'mcp-started');
  const skill = token('project-skill');
  const repo = newRepo(kk.root, 'proj', {
    'a.txt': '首行未选中\n第二行读取成功\n第三行续接成功\n第四行重启后读取成功\n',
    '.claude/settings.local.json': JSON.stringify({ enableAllProjectMcpServers: true }),
    [`.claude/skills/${skill}/SKILL.md`]: `---\nname: ${skill}\ndescription: 项目测试技能\n---\n这是一条项目技能指令。\n`,
    '.mcp.json': JSON.stringify({ mcpServers: {
      projectProbe: { command: '/bin/sh', args: ['-c', 'printf started > "$1"', 'sh', mcpStarted] },
    } }),
  }, null);
  const outside = temp();
  const externalSecret = token('外部机密');
  writeFiles(outside, { 'secret.txt': externalSecret });
  symlinkSync(outside, join(repo, 'escape'));
  commitAll(repo, '准备读取边界');
  const p = await addProject(kk, { path: repo });
  /** 读取结果只含选中的那一行，行号在前。 */
  const onlyLine = (result: any, line: number, content: string) => {
    expect(resultText(result)).toMatch(new RegExp(`(?:^|\\n)\\s*${line}[^\\n]*${content}`));
    expect(resultText(result).match(/首行未选中|第二行读取成功|第三行续接成功|第四行重启后读取成功/g)).toEqual([content]);
  };
  /** 常驻声明的工具恰好是 Kite 自己的（有按需加载的工具时另有 ToolSearch）；CLI 另声明的 defer_loading 占位不算。 */
  const clean = (request: Logged, extra: string[] = []) => {
    const declared = request.body.tools as Array<{ name: string; defer_loading?: boolean }>;
    expect(declared.filter((tool) => !tool.defer_loading).map((tool) => tool.name).sort()).toEqual([...expectedTools, ...extra].sort());
    expect(JSON.stringify(request.body)).not.toContain(skill);
    expect(JSON.stringify(request.body)).not.toContain('这是一条项目技能指令。');
  };

  const a = token('首回合');
  const firstArgs = { path: 'a.txt', offset: 2, limit: 1 };
  const refusedArgs = [{ path: join(outside, 'secret.txt') }, { path: 'escape/secret.txt' }];
  const secondArgs = { path: 'a.txt', offset: 3, limit: 1 };
  const thirdArgs = { path: 'a.txt', offset: 4, limit: 1 };
  const s = await createWorkspace(kk, p.id, `第一条 ${a}\nREAD ${JSON.stringify([firstArgs, ...refusedArgs])}`);
  const req1 = await api.waitRequest((l) => l.main && l.lastUserText.includes(a));
  clean(req1);
  expect(req1.toolUseIds).toHaveLength(3);
  const firstId = req1.toolUseIds[0]!;
  const firstResult = await readResult(firstId);
  expect(firstResult.is_error).toBeFalsy();
  onlyLine(firstResult, 2, '第二行读取成功');
  // 文件边界的各类路径由小测试覆盖；这里保留错误跨 MCP 和原生历史投影的证据。
  const refusedIds = req1.toolUseIds.slice(1);
  for (const id of refusedIds) {
    const result = await readResult(id);
    expect(result.is_error).toBe(true);
    expect(resultText(result)).not.toBe('');
    expect(resultText(result)).not.toContain(externalSecret);
  }
  await waitIdle(kk, s.id);
  const firstHistory = await history(kk, s.id);
  expect(firstHistory.records).toEqual(expect.arrayContaining([
    expect.objectContaining({ block: expect.objectContaining({ type: 'tool_use', id: firstId, name: 'read', input: firstArgs }) }),
    expect.objectContaining({ block: expect.objectContaining({ type: 'tool_result', call: firstId, status: 'success', output: resultText(firstResult) }) }),
    ...refusedIds.map((call) => expect.objectContaining({ block: expect.objectContaining({ type: 'tool_result', call, status: 'error' }) })),
  ]));
  expect(JSON.stringify(firstHistory)).not.toContain(externalSecret);
  const resident = sessionProcesses(s.nativeId);
  expect(resident).toHaveLength(1);

  // 第二回合：读取失败后同一进程仍可正常读取，历史与工具结果在常驻进程里保持。
  const m = mark(kk);
  const b = token('常驻续接');
  await sendThreadMessage(kk, s.id, `第二条 ${b}\nREAD ${JSON.stringify(secondArgs)}`);
  const req2 = await api.waitRequest((l) => l.main && l.lastUserText.includes(b));
  expect(JSON.stringify(req2.body.messages)).toContain(a);
  clean(req2);
  expect(resultValue(resultFor(req2, firstId))).toEqual(resultValue(firstResult));
  expect(req2.toolUseIds).toHaveLength(1);
  const secondId = req2.toolUseIds[0]!;
  const secondResult = await readResult(secondId);
  expect(secondResult.is_error).toBeFalsy();
  onlyLine(secondResult, 3, '第三行续接成功');
  await waitIdle(kk, s.id, m);
  expect(sessionProcesses(s.nativeId)).toEqual(resident);
  expect((await history(kk, s.id)).state.context?.windowTokens).toBe(200_000);
  const query = spyOn(Runner.prototype, 'contextUsage').mockResolvedValueOnce(undefined);
  restoreQuery = () => query.mockRestore();

  // 给代理授权一个插件实例的工具：换模型后重起的进程里它不常驻，要经 ToolSearch 搜到才能调用。
  expect((await kk.call('POST', '/plugin-definitions', {
    id: 'custom.test', title: '测试', bundle: await bundle, lifetime: 'persistent',
  })).status).toBe(200);
  const pluginId = randomUUID();
  expect((await kk.call('POST', `/workspaces/${s.workspace.id}/plugin-instances`, {
    id: pluginId, definitionId: 'custom.test', title: '计数器',
  })).status).toBe(200);
  const grants = await kk.call('GET', `/instances/${s.id}/operation-grants`);
  expect((await kk.call('PUT', `/instances/${s.id}/operation-grants`, {
    expectedRevision: grants.body.revision,
    grants: [...grants.body.grants, { operation: 'plugin.call', instanceId: pluginId, tools: ['state'] }],
  })).status).toBe(200);
  const bindings = (await kk.call('GET', `/threads/${s.id}`)).body.config.pluginTools as Array<{ instanceId: string; modelName: string }>;
  const pluginTool = bindings.find((binding) => binding.instanceId === pluginId)!.modelName;

  // 第三回合：换模型后旧进程退出，resume 起的新进程接着同一原生会话。
  const config = await kk.call('GET', `/instances/${s.id}/agent-config`);
  const agent = config.body.instance.config.agent;
  // 换到 fable：它调用工具后 CLI 会写入批量提醒附件，最后切换后端时用到。
  const model = 'claude-fable-5-1[1m]';
  expect(agent.model.model).not.toBe(model);
  expect((await kk.call('PUT', `/instances/${s.id}/agent-config`, {
    expectedRevision: config.body.revision, agent: { ...agent, model: { ...agent.model, model } },
  })).status).toBe(200);
  expect((await history(kk, s.id)).state.context?.windowTokens).toBeUndefined();
  const n = mark(kk);
  const c = token('换模型');
  await sendThreadMessage(kk, s.id, `第三条 ${c}\nREAD ${JSON.stringify(thirdArgs)}`);
  const req3 = await api.waitRequest((l) => l.main && l.lastUserText.includes(c));
  expect(req3.body.model).not.toBe(req1.body.model);
  const resumedMessages = JSON.stringify(req3.body.messages);
  expect(resumedMessages).toContain(a);
  expect(resumedMessages).toContain(b);
  // 新进程的首个请求：Kite 的工具都已声明（启动时等 kite 服务连上），插件工具不在声明里。
  clean(req3, ['ToolSearch']);
  expect(tools(req3)).not.toContain(pluginTool);
  expect(resultValue(resultFor(req3, firstId))).toEqual(resultValue(firstResult));
  expect(resultValue(resultFor(req3, secondId))).toEqual(resultValue(secondResult));
  expect(req3.toolUseIds).toHaveLength(1);
  const thirdId = req3.toolUseIds[0]!;
  const thirdResult = await readResult(thirdId);
  expect(thirdResult.is_error).toBeFalsy();
  onlyLine(thirdResult, 4, '第四行重启后读取成功');
  await waitIdle(kk, s.id, n);
  const restarted = sessionProcesses(s.nativeId);
  expect(restarted).toHaveLength(1);
  expect(restarted).not.toEqual(resident);

  const resumed = await history(kk, s.id);
  // 换模型后查询失败，前一模型的窗口不能用于新用量。
  expect(resumed.state.context?.inputTokens).toBe(10);
  expect(resumed.state.context?.windowTokens).toBeUndefined();
  expect(resumed.records.filter((record) => record.block.type === 'tool_use').map((record) => record.block)).toEqual([
    expect.objectContaining({ type: 'tool_use', id: firstId, name: 'read', input: firstArgs }),
    ...refusedIds.map((id, index) => expect.objectContaining({ type: 'tool_use', id, name: 'read', input: refusedArgs[index] })),
    expect.objectContaining({ type: 'tool_use', id: secondId, name: 'read', input: secondArgs }),
    expect.objectContaining({ type: 'tool_use', id: thirdId, name: 'read', input: thirdArgs }),
  ]);
  expect(resumed.records).toEqual(expect.arrayContaining([firstResult, secondResult, thirdResult].map((result) =>
    expect.objectContaining({ block: expect.objectContaining({ type: 'tool_result', call: result.tool_use_id, status: 'success', output: resultText(result) }) }))));
  const inits = kk.events.flatMap((e, index) => e.type === 'sdk' && e.threadId === s.id && e.message.type === 'system'
    && e.message.subtype === 'init' ? [{ init: e.message, granted: index >= n }] : []);
  expect(inits.some(({ granted }) => granted)).toBe(true);
  for (const { init, granted } of inits) {
    expect(init.session_id).toBe(s.nativeId);
    // init 列出全部工具，按需加载的插件工具也在内。
    expect([...init.tools].sort()).toEqual([...expectedTools, 'ToolSearch', ...(granted ? [pluginTool] : [])].sort());
    expect(init.mcp_servers).toEqual([expect.objectContaining({ name: 'kite', status: 'connected' })]);
  }
  expect(existsSync(mcpStarted)).toBe(false);

  // 第四回合（同一进程）：模型先调 ToolSearch 搜到插件工具，再调用它，插件真的执行，结果交回模型。
  const o = mark(kk);
  const d = token('按需加载');
  await sendThreadMessage(kk, s.id, [`第四条 ${d}`, `CALL ToolSearch ${JSON.stringify({ query: `select:${pluginTool}` })}`,
    `CALL ${pluginTool} ${JSON.stringify({ action: 'increment' })}`].join('\n'));
  const req4 = await api.waitRequest((l) => l.main && l.lastUserText.includes(d));
  expect(tools(req4)).not.toContain(pluginTool);
  expect(req4.toolUseIds).toHaveLength(1);
  const searchId = req4.toolUseIds[0]!;
  // 搜索结果由 CLI 生成，是指向插件工具的 tool_reference；从这次请求起声明里才有插件工具。
  const loaded = await api.waitRequest((l) => l.main && !!resultFor(l, searchId));
  expect(resultFor(loaded, searchId)).toMatchObject({ content: [{ type: 'tool_reference', tool_name: pluginTool }] });
  expect(tools(loaded)).toContain(pluginTool);
  expect(loaded.toolUseIds).toHaveLength(1);
  const pluginResult = await readResult(loaded.toolUseIds[0]!);
  expect(pluginResult.is_error).toBeFalsy();
  expect(JSON.parse(JSON.parse(resultText(pluginResult)).output)).toMatchObject({ structuredContent: { value: { count: 1 } } });
  await waitIdle(kk, s.id, o);

  // 真实出过的 bug：fable 调用工具后，CLI 2.1.280 在会话记录里写入 batching_reminder_sent 附件（不发给模型），
  // Claude 内容翻译不认识它，切换后端和压缩都返回 409。
  expect(transcript(s.nativeId).some((entry) => entry.type === 'attachment' && entry.attachment?.type === 'batching_reminder_sent')).toBe(true);
  const current = await kk.call('GET', `/instances/${s.id}/agent-config`);
  const switched = await kk.call('PUT', `/instances/${s.id}/agent-config`, {
    expectedRevision: current.body.revision,
    agent: { ...current.body.instance.config.agent, runtime: 'harness', model: { model: defaultAgentModel, reasoning: 'high' } },
  });
  expect(switched).toMatchObject({ status: 200 });
});

/*
 * 上游把 MCP structuredContent 转成模型可见的 JSON 文本；成功与局部失败的 diff 都必须经原生记录和显示投影保留。
 * 在假端点收到下一请求时同步记录已发生的快照事件，防止稍后读取快照列表掩盖 PostToolBatch 的时序回归。
 * 进程常驻：kited 停止时要结束空闲的 Claude 进程（bun test 每个测试后会清掉残留子进程，不断言就看不出泄漏）；
 * 这次结束发生在回合收尾之后，宿主不能把它当成停止，上一回合的结果要保持完成。
 */
test('patch 的结果和快照先于下一模型请求，局部失败及服务重开后仍可查看各次原始 diff；空闲时停服务结束常驻进程，上一回合仍记为完成', async () => {
  k = startKited();
  const kk = k;
  const repo = newRepo(kk.root, 'proj', { 'original.txt': '修改前\n' }, null);
  const p = await addProject(kk, { path: repo });
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
  const thread = await createWorkspace(kk, p.id, `${marker}\nPATCH ${JSON.stringify(args)}\nHOLD_RESULT ${hold}`);
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
  expect(git(thread.checkout.path, 'show', `${snapshot!.commit}:original.txt`)).toBe('修改后');
  expect(git(thread.checkout.path, 'show', `${snapshot!.commit}:created.txt`)).toBe('新建正文');
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
  await waitIdle(kk, thread.id);

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
  await waitIdle(kk, thread.id, since);
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
  expect(completed.state.lastOutcome).toEqual({ kind: 'completed' });
  expect(sessionProcesses(thread.nativeId)).toHaveLength(1);

  await kk.daemon.stop();
  expect(sessionProcesses(thread.nativeId)).toEqual([]);
  restarted = startDaemon({ home: kk.home, port: 0, lightTasks: false });
  const rebuilt = await call(restarted.url, 'GET', `/threads/${thread.id}/history`);
  expect(rebuilt.status).toBe(200);
  expect(rebuilt.body.state.lastOutcome).toEqual({ kind: 'completed' });
  expect(completed.state.context?.windowTokens).toBe(200_000);
  const { requestId, inputTokens, windowTokens } = completed.state.context!;
  expect(rebuilt.body.state.context).toMatchObject({ requestId, inputTokens, windowTokens });
  expect(rebuilt.body.state.context.measuredAt).toBeGreaterThan(0);
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
  ].join('\n') }, null);
  const p = await addProject(kk, { path: repo });
  const quote = (value: string) => `'${value.replaceAll("'", "'\\''")}'`;
  const args = { description: '验证 Claude 命令沙箱及取消', command: `exec ${quote(process.execPath)} probe.ts` };
  const thread = await createWorkspace(kk, p.id, `SHELL ${JSON.stringify(args)}`);
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
