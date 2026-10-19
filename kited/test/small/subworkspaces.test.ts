/**
 * 子工作区（docs/项目与远程仓库.md「子工作区」，docs/实例操作.md「子工作区」）：代理用 agent_start 的 isolation 从父工作区最近的快照
 * 开出子工作区，开出它的代理用 agent_merge 合回；集成、归档父工作区时兜底。每个线程一个手动模型。
 * 开出子工作区的代理是建工作区时带首条消息的首个线程，它的回合一直挂着，等子工作区那边做完再在同一回合里合回，省掉几个回合。
 * 只要有个子工作区、不看谁开的测试，经 HTTP 的 agent.start 带 isolation 开，不起模型回合；整组流转在 transfer.test.ts。
 */
import { afterEach, expect, test } from 'bun:test';
import { existsSync } from 'node:fs';
import { join } from 'node:path';
import { agentWorkspaceContextDefinition } from '../../src/agent-reports.ts';
import type { Json, ModelItem, ModelRequest } from '../../src/harness/types.ts';
import type { Workspace } from '../../src/model.ts';
import { addProject, createWorkspace, folderWorkspace, type Kited, listSnapshots, mark, startKited, waitIdle, workspaceOpened } from '../harness.ts';
import { item, ManualModel } from '../harness-loop.ts';
import { commitMainline, git, gitOk, listTree, newDir, read, writeFiles } from '../util.ts';

let kited: Kited | undefined;
afterEach(async () => { await kited?.stop(); kited = undefined; });

/** 每个线程一个手动模型，kited 与测试都按实例 ID 取同一个，先取的先建。 */
function threadModels() {
  const models = new Map<string, ManualModel>();
  const of = (id: string) => {
    let model = models.get(id);
    if (!model) models.set(id, model = new ManualModel());
    return model;
  };
  return { of, factory: (thread: { id: string }) => of(thread.id) };
}

type Call = Awaited<ReturnType<ManualModel['call']>>;

/** 在代理的这一请求里调一次工具，返回拿到结果的下一请求（还没结束）。 */
async function useTool(model: ManualModel, request: Call, callId: string, name: string, args: Json): Promise<Call> {
  const called: ModelItem = { ...item(callId, name), call: { id: callId, name, arguments: args } };
  await request.response.emit({ type: 'item', item: called });
  request.response.complete();
  return model.call(request.number + 1);
}

/** 请求历史里这次工具调用成功的输出（操作工具输出 JSON）。 */
function outputOf(request: ModelRequest, callId: string) {
  const found = request.history.find((entry) => entry.type === 'tool_result' && entry.callId === callId);
  if (found?.type !== 'tool_result' || found.result.status !== 'success') throw new Error(`工具 ${callId} 没有成功：${JSON.stringify(found)}`);
  return JSON.parse(found.result.output) as Record<string, unknown>;
}

/** 宿主投给线程的 Kite 来源的输入。 */
const kiteInputs = (request: ModelRequest) => request.history.flatMap((entry) =>
  entry.type === 'input' && entry.input.source === 'kite' ? [entry.input.text] : []);

const workspaceOf = (k: Kited, id: string): Workspace => {
  const found = k.daemon.kite.store.workspace(id);
  if (!found) throw new Error(`没有工作区 ${id}`);
  return found;
};

/** 按文件夹添加项目，建工作区时带首条消息；首个线程（用户开的代理）在工作区准备好后开工。 */
async function leadWorkspace(k: Kited, models: ReturnType<typeof threadModels>, files: Record<string, string>, prompt: string) {
  const project = await addProject(k, { path: newDir(k.root, 'main', files) });
  const thread = await createWorkspace(k, project.id, prompt, 'harness');
  return { id: thread.id, workspace: thread.workspace, checkout: thread.checkout.path, model: models.of(thread.id) };
}

/** 用户经 HTTP 在 workspaceId 下开一个子工作区，等它准备好。 */
async function isolate(k: Kited, workspaceId: string, operationId: string, prompt?: string) {
  const started = await k.call('POST', `/workspaces/${workspaceId}/operations/agent.start`,
    { operationId, isolation: 'workspace', ...(prompt ? { prompt } : {}) });
  if (started.status !== 200) throw new Error(`开子工作区失败：${started.status} ${JSON.stringify(started.body)}`);
  const { workspace } = await workspaceOpened(k, started.body.workspaceId as string);
  return { workspace, agentId: started.body.instanceId as string };
}

/*
 * 几条 git 命令合起来的效果：子工作区的起点是父工作区最近的快照（这里是代理改完两处后那一批工具的快照），工作树里要有那两处没提交的改动；
 * 合回时先把父工作区现在的状态（含后来没提交的改动）合进子工作区分支，再合进父工作区并存快照，最后删掉子工作区的工作树。
 * 子工作区里的代理没带 prompt，它的改动由测试直接写，省掉一个回合；带 prompt 开工的在归档父工作区那个测试里，没改动的子工作区合回也在那里。
 */
test('代理开出的子工作区带着父工作区没提交的增改；子工作区改的与父工作区后来改的合回后都在，子工作区连同其中的代理归档、工作树删掉，父工作区多一枚合回的快照', async () => {
  const models = threadModels();
  const k = kited = startKited(models.factory);
  const lead = await leadWorkspace(k, models, { 'base.txt': '原始\n', 'other.txt': '另一个\n', 'third.txt': '第三个\n' }, '拆出去做');
  const parent = lead.workspace;

  // 代理在一批工具里改了一个已跟踪的文件、加了一个新文件，批次之后存下快照；下一请求开子工作区。
  const editing = await lead.model.call(1);
  writeFiles(parent.cwd, { 'base.txt': '父改过\n', 'new.txt': '父新增\n' });
  const looked = await useTool(lead.model, editing, 'look', 'read', { path: 'base.txt' });
  const opened = await useTool(lead.model, looked, 'isolate', 'agent_start', { title: '改另一个文件', isolation: 'workspace' });
  const { instanceId: childAgent, workspaceId: childId } = outputOf(opened.request, 'isolate');
  if (typeof childAgent !== 'string' || typeof childId !== 'string') throw new Error('agent_start 没返回 instanceId 与 workspaceId');

  const child = (await workspaceOpened(k, childId)).workspace;
  const listed = (await k.call('GET', '/workspaces')).body as Array<{ workspace: Workspace }>;
  expect(listed.find((entry) => entry.workspace.id === childId)?.workspace.parentId).toBe(parent.id);
  expect([read(join(child.cwd, 'base.txt')), read(join(child.cwd, 'new.txt'))]).toEqual(['父改过\n', '父新增\n']);

  // 子工作区改 other.txt，父工作区同时改 third.txt；统筹在还没结束的回合里合回。
  writeFiles(child.cwd, { 'other.txt': '子改过\n' });
  writeFiles(parent.cwd, { 'third.txt': '父后来改的\n' });
  const name = workspaceOf(k, child.id).name;
  const merged = await useTool(lead.model, opened, 'merge', 'agent_merge', { instanceId: childAgent });
  expect(outputOf(merged.request, 'merge')).toMatchObject({ status: 'merged' });
  expect(listTree(parent.cwd)).toMatchObject({ 'base.txt': '父改过\n', 'new.txt': '父新增\n', 'other.txt': '子改过\n', 'third.txt': '父后来改的\n' });
  expect(workspaceOf(k, child.id).status).toBe('archived');
  expect(existsSync(child.cwd)).toBe(false);
  expect(k.daemon.kite.store.instance(childAgent)?.status).toBe('archived');
  expect((await listSnapshots(k, parent.id)).filter((snapshot) => snapshot.label === `合回子工作区「${name}」`)).toHaveLength(1);
  merged.response.complete();
}, 1000);

/*
 * 几个部分的配合：合回时的冲突留在子工作区（合并状态），宿主给其中的线程投一条冲突说明、开始它的回合；
 * 那一回合正常结束后宿主接着合，合完归档子工作区，再用 agent.workspace 模板把结果作为 Kite 来源的输入投给发起合回的代理
 * （发起方的回合已经结束，这条输入开始它的下一回合）。代理在沙箱里不能写 Git 元数据，这里只改文件，不替它跑 git。
 * 子工作区里的代理没带 prompt，开头的改动由测试直接写，省掉它的一个回合和随之而来的回报。
 */
test('合回有冲突时立即返回 conflict 和文件、父工作区不动，冲突交给子工作区里的代理；它把文件改好、回合正常结束后宿主接着合，父工作区得到解决后的内容，子工作区归档，发起合回的代理收到一条 Kite 发来的合回结果', async () => {
  const models = threadModels();
  const k = kited = startKited(models.factory);
  const lead = await leadWorkspace(k, models, { 'c.txt': '原始\n' }, '拆出去改 c.txt');
  const parent = lead.workspace;
  const opened = await useTool(lead.model, await lead.model.call(1), 'isolate', 'agent_start', { title: '改 c.txt', isolation: 'workspace' });
  const { instanceId: childAgent, workspaceId: childId } = outputOf(opened.request, 'isolate') as { instanceId: string; workspaceId: string };
  const child = (await workspaceOpened(k, childId)).workspace;
  writeFiles(child.cwd, { 'c.txt': '子改的\n' });
  writeFiles(parent.cwd, { 'c.txt': '父改的\n' });
  const name = workspaceOf(k, child.id).name;

  const asked = await useTool(lead.model, opened, 'merge', 'agent_merge', { instanceId: childAgent });
  expect(outputOf(asked.request, 'merge')).toEqual({ status: 'conflict', files: ['c.txt'] });
  expect(read(join(parent.cwd, 'c.txt'))).toBe('父改的\n');
  asked.response.complete();

  const resolving = await models.of(childAgent).call(1);
  expect(kiteInputs(resolving.request)).toEqual([expect.stringMatching(/^Kite 正在把这个子工作区合回父工作区。/)]);
  expect(read(join(child.cwd, 'c.txt'))).toContain('<<<<<<<');
  writeFiles(child.cwd, { 'c.txt': '合好的\n' });
  resolving.response.complete();

  const told = await lead.model.call(4);
  const results = kiteInputs(told.request);
  expect(results).toHaveLength(1);
  // 模板开头那段文字接着子工作区的名称。
  const first = agentWorkspaceContextDefinition.blocks[0];
  const opening = first?.type === 'paragraph' && first.parts[0]?.type === 'text' ? first.parts[0].text : '';
  expect(opening).not.toBe('');
  expect(results[0]).toContain(`${opening}${name}`);
  expect(results[0]).toContain('已合回当前工作区并归档');
  expect(read(join(parent.cwd, 'c.txt'))).toBe('合好的\n');
  expect(workspaceOf(k, child.id).status).toBe('archived');
  told.response.complete();
}, 1000);

/*
 * 状态流转：集成父工作区之前先看它的子工作区，没改动、没在工作的随手归档，改过的挡住集成并列给用户；
 * 子工作区的改动判断（相对开出时的起点）与父工作区集成的配合。用户放弃改过的那个之后再集成，照常合进主线。
 */
test('集成父工作区：有改过的子工作区时 409 且只列出它、主线不动；用户放弃它之后照常集成，没改动、空闲的子工作区随之归档', async () => {
  const k = kited = startKited(() => new ManualModel());
  const { workspace: parent, checkout } = await folderWorkspace(k, newDir(k.root, 'main', { 'a.txt': '一\n' }));
  const changed = await isolate(k, parent.id, 'changed');
  const untouched = await isolate(k, parent.id, 'untouched');
  writeFiles(parent.cwd, { 'mine.txt': '父的改动\n' });
  writeFiles(changed.workspace.cwd, { 'a.txt': '子改过\n' });
  const mainline = git(checkout.path, 'rev-parse', 'HEAD');

  const refused = await k.call('POST', `/workspaces/${parent.id}/adopt`);
  expect(refused.status).toBe(409);
  expect(refused.body.children).toEqual([{ id: changed.workspace.id, name: workspaceOf(k, changed.workspace.id).name }]);
  expect(git(checkout.path, 'rev-parse', 'HEAD')).toBe(mainline);
  expect(workspaceOf(k, changed.workspace.id).status).toBe('open');

  expect((await k.call('POST', `/workspaces/${changed.workspace.id}/archive`, { force: true })).status).toBe(200);
  const adopted = await k.call('POST', `/workspaces/${parent.id}/adopt`);
  expect(adopted).toMatchObject({ status: 200, body: { status: 'adopted' } });
  expect(git(checkout.path, 'show', 'HEAD:mine.txt')).toBe('父的改动');
  expect(workspaceOf(k, untouched.workspace.id).status).toBe('archived');
}, 1000);

/*
 * 状态流转与时序：合回只要求子工作区空闲，父工作区的线程照常工作；没改动的子工作区合回直接归档（git 上看出没有改动），父工作区的文件不动。
 * 归档父工作区要连同子工作区，子工作区有没合回的改动时同样要 force；不带 force 时要在停任何线程之前拒绝，父子两边正在工作的线程都不被打断。
 */
test('父工作区的线程工作时，没改动的子工作区合回返回 unchanged、直接归档、父工作区不变；子工作区有没合回的改动时，不带 force 归档父工作区被拒，两边都没归档、正在工作的线程都没被打断，带 force 时父子一起归档', async () => {
  const models = threadModels();
  const k = kited = startKited(models.factory);
  const lead = await leadWorkspace(k, models, { 'a.txt': '一\n' }, '一直做');
  const parent = lead.workspace;
  const leading = await lead.model.call(1);

  const untouched = await isolate(k, parent.id, 'untouched');
  const before = listTree(parent.cwd);
  expect(await k.call('POST', `/workspaces/${untouched.workspace.id}/merge`, {})).toMatchObject({ status: 200, body: { status: 'unchanged' } });
  expect(workspaceOf(k, untouched.workspace.id).status).toBe('archived');
  expect(k.daemon.kite.store.instance(untouched.agentId)?.status).toBe('archived');
  expect(listTree(parent.cwd)).toEqual(before);

  const child = await isolate(k, parent.id, 'child', '在子工作区里一直做');
  const working = await models.of(child.agentId).call(1);
  writeFiles(child.workspace.cwd, { 'a.txt': '子改过\n' });

  expect((await k.call('POST', `/workspaces/${parent.id}/archive`, {})).status).toBe(409);
  expect([workspaceOf(k, parent.id).status, workspaceOf(k, child.workspace.id).status]).toEqual(['open', 'open']);
  expect([leading.signal.aborted, working.signal.aborted]).toEqual([false, false]);

  expect((await k.call('POST', `/workspaces/${parent.id}/archive`, { force: true })).status).toBe(200);
  expect([workspaceOf(k, parent.id).status, workspaceOf(k, child.workspace.id).status]).toEqual(['archived', 'archived']);
}, 1000);

/*
 * 几条 git 命令合起来的效果。真实 bug（旧实现）：开出时用快照的树另造一个不在父工作区分支上的起点提交，合回时的共同祖先
 * 是父工作区当时的 HEAD，开出时没提交、之后在父工作区里撤销的改动被当成子工作区的改动，又带回父工作区。
 * 开出前父工作区的线程在一个回合里把 x.txt 从 O 改成 A（没提交），回合结束存了快照，新旧实现的起点都带着 A；
 * 之后父工作区把 x.txt 改回 O，子工作区只改了 y.txt。
 */
test('开出子工作区之后父工作区撤销了当时没提交的改动，合回后父工作区保留撤销，只多出子工作区自己的改动', async () => {
  const models = threadModels();
  const k = kited = startKited(models.factory);
  const lead = await leadWorkspace(k, models, { 'x.txt': 'O\n', 'y.txt': 'y\n' }, '改 x.txt');
  const parent = lead.workspace;
  const since = mark(k);
  const editing = await lead.model.call(1);
  writeFiles(parent.cwd, { 'x.txt': 'A\n' });
  editing.response.complete();
  await waitIdle(k, lead.id, since);
  const child = await isolate(k, parent.id, 'child');
  expect(read(join(child.workspace.cwd, 'x.txt'))).toBe('A\n');

  writeFiles(parent.cwd, { 'x.txt': 'O\n' });
  writeFiles(child.workspace.cwd, { 'y.txt': '子改的\n' });
  expect(await k.call('POST', `/workspaces/${child.workspace.id}/merge`, {})).toMatchObject({ status: 200, body: { status: 'merged' } });
  expect([read(join(parent.cwd, 'x.txt')), read(join(parent.cwd, 'y.txt'))]).toEqual(['O\n', '子改的\n']);
}, 1000);

/*
 * 状态流转。真实 bug（旧实现）：父工作区把主线合进来时冲突，冲突交给父工作区的线程；用户停下那个线程会清掉宿主记着的「正在处理冲突」，
 * 工作树却还停在合并中途（MERGE_HEAD 与冲突标记都在）。这时合回子工作区，先提交父工作区现状那一步把带冲突标记的文件当成解决结果提交了。
 * 现在父工作区有 MERGE_HEAD 时合回与开子工作区都拒绝，父工作区的合并状态与分支都不动。
 * 冲突经同步造出来，不经集成：集成前会清掉没改动、空闲的子工作区，改过的又挡住集成，集成到冲突时留不下改过的子工作区；
 * 同步不看子工作区，冲突的处理与停下同集成。
 */
test('父工作区同步主线冲突、处理冲突的线程已被停下时，合回改过的子工作区被拒，父工作区仍在合并中途、分支没多出提交；这时也开不了新的子工作区', async () => {
  const models = threadModels();
  const k = kited = startKited(models.factory);
  const lead = await leadWorkspace(k, models, { 'c.txt': '原始\n' }, '先做点事');
  const parent = lead.workspace;
  let since = mark(k);
  (await lead.model.call(1)).response.complete();
  await waitIdle(k, lead.id, since);
  const child = await isolate(k, parent.id, 'child');

  writeFiles(parent.cwd, { 'c.txt': '父改的\n' });
  commitMainline(lead.checkout, { 'c.txt': '主线改的\n' }, '主线改了 c');
  writeFiles(child.workspace.cwd, { 'd.txt': '子工作区的改动\n' });
  expect(await k.call('POST', `/workspaces/${parent.id}/sync`)).toMatchObject({ status: 200, body: { status: 'conflict', files: ['c.txt'] } });
  await lead.model.call(2);
  since = mark(k);
  expect((await k.call('POST', `/threads/${lead.id}/interrupt`)).status).toBe(200);
  await waitIdle(k, lead.id, since);
  // 宿主已不记着正在处理冲突：处理冲突期间带首条消息新建线程会被拒，这时能建。下面的拒绝只能来自工作树上的 MERGE_HEAD。
  since = mark(k);
  const other = await k.call('POST', `/workspaces/${parent.id}/threads`, { prompt: '冲突先放着，看看别的' });
  expect(other.status).toBe(200);
  (await models.of(other.body.id as string).call(1)).response.complete();
  await waitIdle(k, other.body.id as string, since);
  const head = git(parent.cwd, 'rev-parse', 'HEAD');

  const refused = await k.call('POST', `/workspaces/${child.workspace.id}/merge`, {});
  expect(refused.status).toBe(409);
  expect(refused.body.error).toContain('父工作区停在合并主线的冲突里');
  expect(gitOk(parent.cwd, 'rev-parse', '-q', '--verify', 'MERGE_HEAD')).toBe(true);
  expect(git(parent.cwd, 'rev-parse', 'HEAD')).toBe(head);
  expect(read(join(parent.cwd, 'c.txt'))).toContain('<<<<<<<');
  expect(workspaceOf(k, child.workspace.id).status).toBe('open');

  const opening = await k.call('POST', `/workspaces/${parent.id}/operations/agent.start`, { operationId: 'during-conflict', isolation: 'workspace' });
  expect(opening.status).toBe(409);
  expect(k.daemon.kite.store.workspaces().filter((w) => w.parentId === parent.id).map((w) => w.id)).toEqual([child.workspace.id]);
}, 1000);
