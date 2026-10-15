/**
 * 账号级数据经工作机之间的同步链路（src/account-data/directory.ts、replication.ts）：两台本进程 kited 各有自己的数据目录
 * 和凭据密钥文件，用 harness 的 connect 互为组网对端，读 /machine 发现、长轮询拉增量都直接访问对方的监听地址。
 * 资源库经同一链路交接见 library-sync.test.ts。
 */
import { afterEach, expect, test } from 'bun:test';
import { existsSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import type { Project, WorkspaceModel } from '../../src/model.ts';
import { connect, type Kited, registerCheckout, startKited, synced } from '../harness.ts';
import { newRepo } from '../util.ts';

const kiteds: Kited[] = [];
afterEach(async () => {
  for (const k of kiteds.splice(0)) await k.stop();
});

/** 账号级数据落地的文件（含 WAL），按字节拼起来查有没有明文。 */
const stored = (k: Kited) => ['account.db', 'account.db-wal'].map((name) => join(k.home, name)).filter(existsSync)
  .map((path) => readFileSync(path).toString('latin1')).join('');

// 凭据的保密内容在 A 用 A 的密钥封装落地，传给 B 时解开成明文，B 要用自己的密钥重新封装：B 存成 A 的密文就解不开，
// 存成明文就泄露在磁盘上。目录摘要由 A 写进账号级数据，随同一条同步传到 B，B 读 /machine 判断 A 在线。
test('A 新建的 Git 凭据和共享密钥同步到 B 后 B 能取用、两边落地都不是明文，A 的目录摘要出现在 B 的工作机目录里且在线', async () => {
  const a = startKited();
  const b = startKited();
  kiteds.push(a, b);
  await connect(a, b);
  const machineA = a.daemon.kite.store.machine.id;
  const token = `git-token-${crypto.randomUUID()}`;
  const value = `secret-value-${crypto.randomUUID()}`;
  const git = await a.call('POST', '/credentials', { type: 'git', name: 'git.example.test', meta: { username: 'kite-bot' }, secret: { token } });
  expect(git.status).toBe(201);
  const secret = await a.call('POST', '/credentials', { type: 'secret', name: 'DEPLOY_TOKEN', meta: { kind: 'text' }, secret: { value } });
  expect(secret.status).toBe(201);

  await synced(b, () => b.daemon.kite.credentials.list('git').length > 0 && b.daemon.kite.credentials.list('secret').length > 0,
    'B 同步到 A 新建的凭据');
  expect(await b.daemon.kite.git.credential('https://git.example.test/owner/project.git')).toEqual({ username: 'kite-bot', password: token });
  expect(await b.daemon.kite.credentials.resolve(['{account.DEPLOY_TOKEN}']))
    .toEqual([{ reference: '{account.DEPLOY_TOKEN}', kind: 'text', value }]);
  for (const k of [a, b]) {
    expect(stored(k).includes(token)).toBe(false);
    expect(stored(k).includes(value)).toBe(false);
  }

  await synced(b, () => b.daemon.kite.directory.entries().some((entry) => entry.id === machineA && entry.snapshot), 'B 同步到 A 的目录摘要');
  const machines = await b.call('GET', '/machines');
  expect(machines.status).toBe(200);
  expect(machines.body).toContainEqual(expect.objectContaining({
    id: machineA, online: true, snapshot: expect.objectContaining({ machine: expect.objectContaining({ id: machineA }) }),
  }));
}, 1000);

// 两台工作机没同步上时各自登记了同一远程（HTTPS 与 SSH 写法），各得一个项目；连上后登记表随同步合并，
// 先登记的保留、后登记的记为并入它，各机 syncProjects 时把本机检出与工作区改挂过去。
// 要登记表、同步、两边各自合并与本机 SQLite 改挂合起来才看得出。
test('两台工作机没同步时各自登记同一远程，连上同步后两边都只剩先登记的项目，后登记那台的检出和工作区改挂过去', async () => {
  const a = startKited();
  const b = startKited();
  kiteds.push(a, b);
  const path = `owner/${crypto.randomUUID()}`;
  const first = await registerCheckout(a, newRepo(a.root, 'project', { 'a.txt': 'A\n' }, `https://example.test/${path}.git`));
  const second = await registerCheckout(b, newRepo(b.root, 'project', { 'b.txt': 'B\n' }, `git@example.test:${path}.git`));
  expect(second.project.id).not.toBe(first.project.id);
  expect(second.project.remote).toBe(first.project.remote);
  expect(b.daemon.kite.registry.get(second.project.id)!.createdAt).toBeGreaterThan(a.daemon.kite.registry.get(first.project.id)!.createdAt);

  await connect(a, b);
  for (const k of [a, b]) {
    await synced(k, () => k.daemon.kite.registry.canonical(second.project.id) === first.project.id, '后登记的项目并入先登记的');
  }
  await Promise.all([a.daemon.kite.syncProjects(), b.daemon.kite.syncProjects()]);

  for (const k of [a, b]) {
    expect(k.daemon.kite.registry.list().filter((project) => project.remote === first.project.remote).map((project) => project.id))
      .toEqual([first.project.id]);
  }
  expect(((await b.call('GET', '/projects')).body as Project[]).map((project) => project.id)).toEqual([first.project.id]);
  expect((await b.call('GET', '/checkouts')).body).toEqual([expect.objectContaining({ id: second.checkout.id, projectId: first.project.id })]);
  const workspaces = (await b.call('GET', '/workspaces')).body as WorkspaceModel[];
  expect(workspaces.map((model) => [model.workspace.id, model.project.id])).toEqual([[second.workspace.id, first.project.id]]);
  expect(((await a.call('GET', '/projects')).body as Project[]).map((project) => project.id)).toEqual([first.project.id]);
  expect((await a.call('GET', '/checkouts')).body).toEqual([expect.objectContaining({ id: first.checkout.id, projectId: first.project.id })]);
}, 1000);
