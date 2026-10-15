/**
 * 工作区执行权（docs/Line与工作区流转.md「工作区的稳定身份与执行权」）：远程 lease 的比较后更新、
 * 联网核对后的冻结，以及工作区表加上 epoch 与 transferred 的旧库迁移。
 */
import { Database } from 'bun:sqlite';
import { afterEach, expect, test } from 'bun:test';
import { randomUUID } from 'node:crypto';
import { join } from 'node:path';
import type { Workspace, WorkspaceModel } from '../../src/model.ts';
import { Store } from '../../src/store.ts';
import { readLease, remoteLeases, writeLease } from '../../src/workspace/lease.ts';
import { type FakeGit, startFakeGit } from '../fake-git.ts';
import { type Kited, listSnapshots, registerCheckout, startKited } from '../harness.ts';
import { ManualModel } from '../harness-loop.ts';
import { git, gitOk, newDir, newRepo, useTemp, writeFiles } from '../util.ts';

const temp = useTemp();
let kited: Kited | undefined;
let remotes: FakeGit | undefined;
afterEach(async () => {
  await kited?.stop();
  kited = undefined;
  remotes?.stop();
  remotes = undefined;
});

/** 只用来写对象和推送的空仓库，代表另一台工作机上的检出。 */
function emptyRepo(parent: string, name: string): string {
  const dir = newDir(parent, name);
  git(dir, 'init', '-q');
  return dir;
}

/*
 * 几条 git 命令合起来的效果：lease 提交经 push --force-with-lease 写到远程，远程按预期的旧值比较后更新。
 * 两处同时创建、拿过期的值接管、源机在被接管后撤回交接，都只能有符合预期的一方成功。
 */
test('lease 比较后更新：同时创建只有一方成功，拿过期的值接管被拒，拿当前值接管成功后旧持有者撤回被拒', async () => {
  const root = temp('lease-');
  const remote = join(root, 'remote.git');
  git(root, 'init', '-q', '--bare', remote);
  const access = { url: remote, env: {} };
  const repos = { source: emptyRepo(root, 'source'), target: emptyRepo(root, 'target') };
  const workspaceId = randomUUID();

  const created = await Promise.all((['source', 'target'] as const).map(async (machine) =>
    ({ machine, result: await writeLease(repos[machine], workspaceId, { machine, epoch: 1, state: 'active' }, null, access) })));
  expect(created.map((entry) => entry.result.status).sort()).toEqual(['conflict', 'written']);
  const winner = created.find((entry) => entry.result.status === 'written')!;
  const holder = winner.machine;
  const taker = holder === 'source' ? 'target' : 'source';
  const first = (winner.result as { commit: string }).commit;
  expect((await remoteLeases(repos[taker], access)).get(workspaceId)).toBe(first);
  expect(await readLease(repos[taker], workspaceId, first, access)).toEqual({ machine: holder, epoch: 1, state: 'active' });

  const handing = await writeLease(repos[holder], workspaceId, { machine: holder, epoch: 1, state: 'handing_off' }, first, access);
  expect(handing.status).toBe('written');
  const takeover = { machine: taker, epoch: 2, state: 'active' } as const;
  expect((await writeLease(repos[taker], workspaceId, takeover, first, access)).status).toBe('conflict');
  const current = (await remoteLeases(repos[taker], access)).get(workspaceId)!;
  expect(current).toBe((handing as { commit: string }).commit);
  const taken = await writeLease(repos[taker], workspaceId, takeover, current, access);
  expect(taken.status).toBe('written');

  expect((await writeLease(repos[holder], workspaceId, { machine: holder, epoch: 1, state: 'active' }, current, access)).status)
    .toBe('conflict');
  const final = (await remoteLeases(repos[holder], access)).get(workspaceId)!;
  expect(final).toBe((taken as { commit: string }).commit);
  expect(await readLease(repos[holder], workspaceId, final, access)).toEqual(takeover);
}, 1000);

/*
 * 几个部分的配合：项目远程上的 lease（ls-remote 与经 http-backend 取回）、线程停止、快照、插件关闭与工作区登记。
 * 别的机器以更高 epoch 接管后，本机核对要停下运行中的线程、把本机多出的改动存成快照、冻结记录；
 * 根工作区冻结后同一检出目录要另有一个可用的根工作区。独立工作区走同一条冻结路径，只少了另建根工作区。
 */
test('别的机器以更高 epoch 接管根工作区后核对执行权：运行中的线程停下、发送 409、本机改动存成快照，检出另得一个 open 的根工作区', async () => {
  const model = new ManualModel();
  kited = startKited(() => model);
  const kk = kited;
  remotes = startFakeGit();
  const remote = remotes.create('project');
  const repo = newRepo(kk.root, 'project', { 'base.txt': '原始\n' }, remote.url);
  const registered = await registerCheckout(kk, repo);
  const root = registered.workspace;
  const started = await kk.call('POST', `/workspaces/${root.id}/operations/agent.start`, { operationId: 'worker' });
  expect(started.status).toBe(200);
  const threadId = started.body.instanceId as string;
  expect((await kk.call('POST', `/threads/${threadId}/messages`, { id: 'kickoff', text: '保持运行' })).status).toBe(200);
  const running = await model.call(1);
  writeFiles(repo, { 'local.txt': '只在本机\n' });

  // 另一台工作机接管：直接推到远程的裸仓库。
  const other = emptyRepo(kk.root, 'other-machine');
  const access = { url: remote.bare, env: {} };
  const written = await writeLease(other, root.id, { machine: 'other-machine', epoch: 2, state: 'active' }, null, access);
  expect(written.status).toBe('written');
  // 启动时的那一轮核对若还没结束，第一次调用会并入它；第二次保证有一轮在 lease 写好之后开始。
  await kk.daemon.kite.syncLeases();
  await kk.daemon.kite.syncLeases();

  expect(((await kk.call('GET', `/workspaces/${root.id}`)).body as WorkspaceModel).workspace.status).toBe('transferred');
  expect(running.signal.aborted).toBe(true);
  const sent = await kk.call('POST', `/threads/${threadId}/messages`, { id: 'after-transfer', text: '继续' });
  expect(sent.status).toBe(409);
  expect(model.calls.values).toHaveLength(1);

  const snapshots = await listSnapshots(kk, root.id);
  expect(snapshots.some((snapshot) => gitOk(repo, 'cat-file', '-e', `${snapshot.commit}:local.txt`)
    && git(repo, 'show', `${snapshot.commit}:local.txt`) === '只在本机')).toBe(true);

  const listed = (await kk.call('GET', '/workspaces')).body as WorkspaceModel[];
  const roots = listed.filter((entry) => entry.checkout.id === registered.checkout.id && entry.workspace.kind === 'root'
    && entry.workspace.status === 'open');
  expect(roots).toHaveLength(1);
  expect(roots[0]!.workspace.id).not.toBe(root.id);
  expect(roots[0]!.workspace.cwd).toBe(root.cwd);
}, 1000);

/*
 * 依赖 SQLite 的改表行为：状态的 check 约束只能随表重建。旧表有引用它的实例、窗口和窗口请求，
 * 重建后外键要仍然成立，旧的唯一索引（根工作区、cwd）要换成允许冻结记录与新根工作区并存的新索引。
 */
test('旧库的工作区表迁移后数据与外键保留、epoch 为 1，可以冻结根工作区并为同一目录另建根工作区', () => {
  const root = temp('store-migration-');
  const path = join(root, 'kite.db');
  const old = new Database(path, { create: true, strict: true });
  old.exec(`
create table machine (
  slot integer primary key check (slot = 1), id text not null unique, name text not null, created_at integer not null
);
create table projects (id text primary key, name text not null, remote text not null, created_at integer not null);
create table checkouts (
  id text primary key, project_id text not null references projects(id), machine_id text not null references machine(id),
  path text not null, remote text not null, created_at integer not null,
  unique(machine_id, path)
);
create table workspaces (
  id text primary key, checkout_id text not null references checkouts(id), name text not null, cwd text not null unique,
  kind text not null check (kind in ('root', 'worktree')), branch text, base text,
  status text not null check (status in ('preparing', 'open', 'failed', 'archived')), created_at integer not null,
  check ((kind = 'root' and branch is null and base is null) or (kind = 'worktree' and branch is not null and base is not null))
);
create unique index root_workspace on workspaces(checkout_id) where kind = 'root';
create table plugin_instances (
  id text primary key, workspace_id text not null references workspaces(id), definition_id text not null, title text not null,
  config text not null, state text not null, presentation text not null check (presentation in ('window', 'inline', 'background')),
  status text not null check (status in ('open', 'archived')), created_at integer not null, origin text
);
create table workspace_windows (
  id text primary key, workspace_id text not null references workspaces(id),
  instance_id text not null, view_id text not null,
  state text not null check (state in ('open', 'closed')), created_at integer not null
);
create table window_requests (
  id text primary key, workspace_id text not null references workspaces(id),
  window_id text not null references workspace_windows(id), content text not null
);
insert into machine values (1, 'machine-1', '旧工作机', 1);
insert into projects values ('project-1', 'demo', 'example.test/demo', 1);
insert into checkouts values ('checkout-1', 'project-1', 'machine-1', '/work/demo', 'example.test/demo', 1);
insert into workspaces values ('root-1', 'checkout-1', '', '/work/demo', 'root', null, null, 'open', 1);
insert into workspaces values ('tree-1', 'checkout-1', '功能', '/kite/worktrees/tree-1', 'worktree', 'kite/tree-1', 'abc', 'open', 2);
insert into plugin_instances values ('instance-1', 'tree-1', 'kite.todo', '待办', '{}', '{}', 'window', 'open', 3, null);
insert into workspace_windows values ('window-1', 'tree-1', 'instance-1', 'main', 'open', 4);
insert into window_requests values ('request-1', 'tree-1', 'window-1', '{}');
`);
  old.close();

  let store = new Store(path);
  try {
    expect(store.machine.id).toBe('machine-1');
    expect(store.workspaces().map((w) => [w.id, w.epoch, w.status]).sort())
      .toEqual([['root-1', 1, 'open'], ['tree-1', 1, 'open']]);
    expect(store.instances('tree-1').map((instance) => instance.id)).toEqual(['instance-1']);
    expect(store.windows('tree-1').map((window) => window.id)).toEqual(['window-1']);
    expect(store.windowRequest('request-1')).toMatchObject({ workspaceId: 'tree-1', windowId: 'window-1' });

    const replacement: Workspace = { id: 'root-2', epoch: 1, checkoutId: 'checkout-1', name: '', cwd: '/work/demo', kind: 'root',
      branch: null, base: null, status: 'open', createdAt: 5 };
    store.freezeWorkspace('root-1', replacement);
    store.freezeWorkspace('tree-1');
    store.close();
    store = new Store(path);
    expect(store.workspaces().map((w) => [w.id, w.status]).sort())
      .toEqual([['root-1', 'transferred'], ['root-2', 'open'], ['tree-1', 'transferred']]);
    expect(store.rootWorkspaceModel('checkout-1')?.workspace.id).toBe('root-2');
    expect(store.instances('tree-1').map((instance) => instance.id)).toEqual(['instance-1']);
  } finally { store.close(); }
  const check = new Database(path);
  try { expect(check.query('pragma foreign_key_check').all()).toEqual([]); } finally { check.close(); }
});
