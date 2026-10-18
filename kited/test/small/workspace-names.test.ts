/**
 * 工作区的名字：App 直接建空工作区（不带名字和首条消息），kited 先给占位名，第一条用户消息被受理时以它的第一行起名。
 * 经 HTTP 驱动本进程里的 kited，模型换成手动应答的自研后端，不起 Claude Code。
 */
import { afterEach, expect, test } from 'bun:test';
import type { WorkspaceModel } from '../../src/model.ts';
import { addProject, chatgptLogin, type Kited, mark, startKited, waitIdle, workspaceOpened } from '../harness.ts';
import { ManualModel } from '../harness-loop.ts';
import { newDir, until } from '../util.ts';

let k: Kited | undefined;
afterEach(async () => { await k?.stop(); k = undefined; });

/*
 * 几个部分的配合：空工作区异步准备完才能起代理；App 起第一个代理走 POST /workspaces/:id/threads，首条消息经起线程、受理输入
 * 才走到改名；改名后客户端要看得到——代理还在工作（模型请求挂着）时，就已经有一个让客户端重读目录的事件
 * （workspace.changed 或 thread.changed）是在改名之后发出的，工作区聚合与列表里是新名字。改过名后同一线程再发消息不再改名。
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
