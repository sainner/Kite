import { afterEach, expect, test } from 'bun:test';
import { existsSync, rmSync } from 'node:fs';
import { join } from 'node:path';
import { startDaemon, type Daemon } from '../../src/daemon.ts';
import type { Envelope } from '../../src/events.ts';
import type { Json, ModelItem } from '../../src/harness/types.ts';
import { call, type Kited, listSnapshots, registerProject, startKited } from '../harness.ts';
import { item, ManualModel, Seen } from '../harness-loop.ts';
import { git, gitOk, makeTemp, newRepo, read } from '../util.ts';

const roots: string[] = [];
let kited: Kited | undefined;
let restarted: Daemon | undefined;
afterEach(async () => {
  await restarted?.stop();
  restarted = undefined;
  await kited?.stop();
  kited = undefined;
  for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true });
});

function calledItem(id: string, name: string, args: Json): ModelItem {
  return { ...item(id, name), call: { id, name, arguments: args } };
}

// HTTP 会话、模型流、受管 patch/shell、git 快照与采纳跨模块交接；第二请求前必须已有完整工具结果。
test('默认 harness 会话的真实工具只改工作树，结果和快照先于下一请求且采纳归档保留快照', async () => {
  const model = new ManualModel();
  kited = startKited(() => model);
  const kk = kited;
  const repo = newRepo(kk.root, 'project', { 'base.txt': '原始\n' });
  const project = await registerProject(kk, repo);
  const created = await kk.call('POST', '/sessions', { project: project.id, prompt: '建立两个文件' });
  expect(created.status).toBe(200);
  const session = created.body;
  expect(session.runtime).toBe('harness');

  const first = await model.call(1);
  expect(first.request.cwd).toBe(session.worktree);
  expect(first.request.tools.map((value) => value.name)).toEqual(expect.arrayContaining(['patch', 'shell']));
  const patch = calledItem('patch-file', 'patch', {
    operations: [{ type: 'create_file', path: 'patch.txt', diff: '+来自 patch\n+' }],
  });
  const shell = calledItem('shell-file', 'shell', { command: "printf '来自 shell\\n' > shell.txt" });
  await first.response.emit({ type: 'item', item: patch });
  await first.response.emit({ type: 'item', item: shell });
  first.response.complete();

  const second = await model.call(2);
  expect(second.request.history).toContainEqual({ type: 'output', item: patch });
  expect(second.request.history).toContainEqual({ type: 'output', item: shell });
  for (const id of ['patch-file', 'shell-file']) {
    expect(second.request.history).toContainEqual(expect.objectContaining({
      type: 'tool_result', callId: id, result: expect.objectContaining({ status: 'success' }),
    }));
  }
  expect(read(join(session.worktree, 'patch.txt'))).toBe('来自 patch\n');
  expect(read(join(session.worktree, 'shell.txt'))).toBe('来自 shell\n');
  expect(existsSync(join(repo, 'patch.txt'))).toBe(false);
  expect(existsSync(join(repo, 'shell.txt'))).toBe(false);
  const snapshots = await listSnapshots(kk, session.id);
  const afterTools = snapshots.find((value) => value.toolUseIds.includes('patch-file') && value.toolUseIds.includes('shell-file'));
  expect(afterTools).toBeDefined();
  expect(git(repo, 'show', `${afterTools!.commit}:patch.txt`)).toBe('来自 patch');
  expect(git(repo, 'show', `${afterTools!.commit}:shell.txt`)).toBe('来自 shell');

  second.response.complete();
  await kk.waitEvent((event) => event.session === session.id && event.type === 'idle');
  const adopted = await kk.call('POST', `/sessions/${session.id}/adopt`);
  expect(adopted.status).toBe(200);
  expect(adopted.body.status).toBe('adopted');
  expect(read(join(repo, 'patch.txt'))).toBe('来自 patch\n');
  expect(read(join(repo, 'shell.txt'))).toBe('来自 shell\n');
  const archived = await kk.call('POST', `/sessions/${session.id}/archive`, { force: true });
  expect(archived.status).toBe(200);
  expect(existsSync(session.worktree)).toBe(false);
  expect(gitOk(repo, 'rev-parse', '--verify', '--quiet', `refs/kite/snapshots/${session.id}`)).toBe(true);
  expect((await listSnapshots(kk, session.id)).map((value) => value.commit)).toContain(afterTools!.commit);
}, 1000);

// 真实 SQLite/journal 关闭重开后，opaque 输出与工具结果必须续接，已完成工具不能重跑。
test('同一 home 重启后用原 nativeId 续接旧 opaque 历史且不重执行工具', async () => {
  const root = makeTemp();
  roots.push(root);
  const home = join(root, 'kite');
  const repo = newRepo(root, 'project', { 'base.txt': '原始\n' });
  const firstModel = new ManualModel();
  let daemon = startDaemon({ home, port: 0, model: () => firstModel });
  restarted = daemon;
  let events = new Seen<Envelope>();
  daemon.kite.bus.subscribe(undefined, (event) => events.add(event));
  const project = await call(daemon.url, 'POST', '/projects', { path: repo });
  expect(project.status).toBe(200);
  const created = await call(daemon.url, 'POST', '/sessions', { project: project.body.id, prompt: '写一次标记' });
  expect(created.status).toBe(200);
  const session = created.body;
  const first = await firstModel.call(1);
  const oldCall = calledItem('write-once', 'shell', { command: "printf 'once\\n' >> marker.txt" });
  await first.response.emit({ type: 'item', item: oldCall });
  first.response.complete();
  const followUp = await firstModel.call(2);
  expect(followUp.request.history).toContainEqual({ type: 'output', item: oldCall });
  expect(followUp.request.history).toContainEqual(expect.objectContaining({ type: 'tool_result', callId: 'write-once' }));
  followUp.response.complete();
  await events.wait((event) => event.session === session.id && event.type === 'idle');
  expect(read(join(session.worktree, 'marker.txt'))).toBe('once\n');
  await daemon.stop();
  restarted = undefined;

  const secondModel = new ManualModel();
  daemon = startDaemon({ home, port: 0, model: () => secondModel });
  restarted = daemon;
  events = new Seen<Envelope>();
  daemon.kite.bus.subscribe(undefined, (event) => events.add(event));
  const sent = await call(daemon.url, 'POST', `/sessions/${session.id}/messages`, { text: '继续', id: 'resume-once' });
  expect(sent.status).toBe(200);
  const resumed = await secondModel.call(1);
  expect(resumed.request.history).toContainEqual({ type: 'output', item: oldCall });
  expect(resumed.request.history).toContainEqual(expect.objectContaining({ type: 'tool_result', callId: 'write-once' }));
  expect(resumed.request.history.filter((value) => value.type === 'input' && value.input.id === 'resume-once')).toHaveLength(1);
  expect(read(join(session.worktree, 'marker.txt'))).toBe('once\n');
  const view = await call(daemon.url, 'GET', `/sessions/${session.id}`);
  expect(view.status).toBe(200);
  expect(view.body.nativeId).toBe(session.nativeId);
  resumed.response.complete();
  await events.wait((event) => event.session === session.id && event.type === 'idle');
  expect(read(join(session.worktree, 'marker.txt'))).toBe('once\n');
}, 1000);

// 关闭时仍有模型请求和排队输入；归档为管理目的打开会话，不得唤醒旧输入再发请求。
test('挂起请求关闭后直接归档不会执行排队消息，工作树仍能安全清理', async () => {
  const root = makeTemp();
  roots.push(root);
  const home = join(root, 'kite');
  const repo = newRepo(root, 'project', { 'base.txt': '原始\n' });
  const firstModel = new ManualModel();
  let daemon = startDaemon({ home, port: 0, model: () => firstModel });
  restarted = daemon;
  const project = await call(daemon.url, 'POST', '/projects', { path: repo });
  expect(project.status).toBe(200);
  const created = await call(daemon.url, 'POST', '/sessions', { project: project.body.id, prompt: '首条挂起' });
  expect(created.status).toBe(200);
  const session = created.body;
  const pending = await firstModel.call(1);
  const queued = await call(daemon.url, 'POST', `/sessions/${session.id}/messages`, { text: '归档前排队', id: 'queued-before-archive' });
  expect(queued.status).toBe(200);
  await daemon.stop();
  restarted = undefined;
  expect(pending.signal.aborted).toBe(true);

  const secondModel = new ManualModel();
  daemon = startDaemon({ home, port: 0, model: () => secondModel });
  restarted = daemon;
  const archived = await call(daemon.url, 'POST', `/sessions/${session.id}/archive`, { force: true });
  expect(archived.status).toBe(200);
  expect(secondModel.calls.values).toHaveLength(0);
  expect(existsSync(session.worktree)).toBe(false);
  const view = await call(daemon.url, 'GET', `/sessions/${session.id}`);
  expect(view.body.status).toBe('archived');
}, 1000);
