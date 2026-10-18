/**
 * 工作区的名字：App 直接建空工作区（不带首条消息），kited 先给占位名，之后跟着顶级代理（用户开的代理）的标题走：
 * 只有一个顶级代理时用它的标题（首条消息被受理时先有以第一行起的即时标题）；有几个时，其中一个的标题由辅助模型生成或手动改过之后，
 * 请辅助模型按各代理的标题重起。经 HTTP 驱动本进程里的 kited，主模型和辅助模型都换成手动应答的自研后端，不起 Claude Code。
 */
import { afterEach, expect, test } from 'bun:test';
import type { ModelItem, ModelRequest } from '../../src/harness/types.ts';
import type { WorkspaceModel } from '../../src/model.ts';
import { workspaceNameTemplate } from '../../src/workspace-names.ts';
import { addProject, chatgptLogin, type Kited, mark, openWorkspace, startKited, waitIdle, workspaceOpened } from '../harness.ts';
import { ManualModel } from '../harness-loop.ts';
import { newDir, until } from '../util.ts';

let k: Kited | undefined;
afterEach(async () => { await k?.stop(); k = undefined; });

/*
 * 几个部分的配合：空工作区异步准备完才能起代理；App 起第一个代理走 POST /workspaces/:id/threads，首条消息经起线程、受理输入、
 * 定下即时标题才走到工作区改名；改名后客户端要看得到——代理还在工作（模型请求挂着）时，就已经有一个让客户端重读目录的事件
 * （workspace.changed 或 thread.changed）是在改名之后发出的，工作区聚合与列表里是新名字。没开轻任务时代理标题不再变，
 * 同一线程再发消息不再改名。
 */
test('App 建的空工作区先叫「新工作区」，起第一个代理时以首条消息的第一行改名、代理工作期间客户端就能重读到，之后的消息不再改名', async () => {
  const model = new ManualModel();
  k = startKited(() => model);
  const kk = k;
  const project = await addProject(kk, { path: newDir(kk.root, 'project', { 'base.txt': '原始\n' }) });
  chatgptLogin(kk.home);
  const id = crypto.randomUUID();
  const created = await kk.call('POST', '/workspaces', { project: project.id, id });
  expect(created.status).toBe(200);
  expect((created.body as WorkspaceModel).workspace).toMatchObject({ id, name: '新工作区' });
  await workspaceOpened(kk, id);
  expect((await kk.call('GET', `/workspaces/${id}`)).body.workspace.name).toBe('新工作区');

  const title = '修复登录页跳转回首页的问题';
  // 事件是同步发出的：发出那一刻读工作区聚合，读到新名字说明客户端收到这个事件去重读时一定看得到。
  let shown = false;
  const unsubscribe = kk.daemon.kite.bus.subscribe(undefined, (e) => {
    if ((e.type !== 'workspace.changed' && e.type !== 'thread.changed') || e.workspaceId !== id) return;
    try { if (kk.daemon.kite.workspace(id).workspace.name === title) shown = true; }
    catch { /* 读不到聚合时不算，也不能打断 kited 的事件分发 */ }
  });
  try {
    const since = mark(kk);
    const opened = await kk.call('POST', `/workspaces/${id}/threads`, { prompt: `${title}\n复现：登录后点返回\n期望停在登录页` });
    expect(opened.status).toBe(200);
    const threadId = opened.body.id as string;
    const first = await model.call(1);
    await until(() => shown, '改名后让客户端重读目录的事件', 1_000);
    expect((await kk.call('GET', `/workspaces/${id}`)).body.workspace.name).toBe(title);
    const listed = await kk.call('GET', `/workspaces?project=${project.id}`);
    expect((listed.body as WorkspaceModel[]).find((model) => model.workspace.id === id)?.workspace.name).toBe(title);
    first.response.complete();
    await waitIdle(kk, threadId, since);

    const again = mark(kk);
    expect((await kk.call('POST', `/threads/${threadId}/messages`, { text: '顺手把注册页也改了\n同样的问题' })).status).toBe(200);
    const second = await model.call(2);
    expect((await kk.call('GET', `/workspaces/${id}`)).body.workspace.name).toBe(title);
    second.response.complete();
    await waitIdle(kk, threadId, again);
    expect((await kk.call('GET', `/workspaces/${id}`)).body.workspace.name).toBe(title);
  } finally { unsubscribe(); }
});

const answer = async (pending: Awaited<ReturnType<ManualModel['call']>>, text: string) => {
  const item: ModelItem = { id: crypto.randomUUID(), raw: { type: 'message', role: 'assistant', content: [{ type: 'output_text', text }] } };
  await pending.response.emit({ type: 'item', item });
  pending.response.complete();
};
const inputText = (request: ModelRequest) =>
  request.history.flatMap((item) => item.type === 'input' ? [item.input.text] : []).join('\n');

/*
 * 几个部分的异步配合：辅助模型生成代理标题 → 与原来不同时通知宿主 → 工作区名跟随；有两个顶级代理时再排一次 workspace.naming 轻任务
 * （和标题生成共用一条串行队列），按名称模板绑定当前名称与各代理的标题，结果写库并发 workspace.changed 让客户端重读。
 * 模板变量接错时 bindContext 抛的错被吞成 console.warn，只有跑起来才看得出改名静默失效。
 * 第二个代理首条消息的即时标题既不直接改名，也不触发重起：重起只有一次，材料里是第二个代理生成后的标题。
 */
test('有两个顶级代理时，后开代理的首行不改工作区名，它的标题生成出来后辅助模型按两个代理的标题重起名，客户端随即重读到', async () => {
  const main = new ManualModel();
  const titles = new ManualModel();
  const naming = new ManualModel();
  k = startKited(() => main, { model: (task) => task.purpose === workspaceNameTemplate.scene ? naming : titles });
  const kk = k;
  const project = await addProject(kk, { path: newDir(kk.root, 'project', { 'base.txt': '原始\n' }) });
  const id = (await openWorkspace(kk, project.id)).workspace.id;
  const name = async () => (await kk.call('GET', `/workspaces/${id}`)).body.workspace.name as string;
  // 每次 workspace.changed 发出那一刻的工作区名：客户端收到事件去重读时看到的就是它。
  const shown: string[] = [];
  const unsubscribe = kk.daemon.kite.bus.subscribe(undefined, (e) => {
    if (e.type !== 'workspace.changed' || e.workspaceId !== id) return;
    try { shown.push(kk.daemon.kite.workspace(id).workspace.name); }
    catch { /* 读不到聚合时不算，也不能打断 kited 的事件分发 */ }
  });
  try {
    expect((await kk.call('POST', `/workspaces/${id}/threads`, { prompt: '登录后点返回会跳到首页\n期望停在登录页' })).status).toBe(200);
    const firstTitle = '修复登录页返回跳转';
    await answer(await titles.call(1), firstTitle);
    await until(() => shown.includes(firstTitle), '唯一的顶级代理有了生成的标题后工作区跟着改名并通知客户端', 800);
    expect(await name()).toBe(firstTitle);

    const firstLine = '注册页也有同样的问题';
    const second = await kk.call('POST', `/workspaces/${id}/threads`, { prompt: `${firstLine}\n注册后点返回也跳到首页` });
    expect(second.status).toBe(200);
    const pendingTitle = await titles.call(2);
    expect((await kk.call('GET', `/threads/${second.body.id as string}/title`)).body.title).toBe(firstLine);
    expect(await name()).toBe(firstTitle);
    expect(naming.calls.values).toHaveLength(0);

    const secondTitle = '修复注册页返回跳转';
    await answer(pendingTitle, secondTitle);
    const pendingName = await naming.call(1);
    const material = inputText(pendingName.request);
    expect(material).toContain(JSON.stringify(firstTitle));
    expect(material).toContain(JSON.stringify(secondTitle));
    const renamed = '修复登录与注册页的返回跳转';
    await answer(pendingName, renamed);
    await until(() => shown.includes(renamed), '辅助模型重起的名字写库并通知客户端', 800);
    expect(await name()).toBe(renamed);
    expect(naming.calls.values).toHaveLength(1);
    expect(titles.calls.values).toHaveLength(2);
  } finally { unsubscribe(); }
}, 1000);
