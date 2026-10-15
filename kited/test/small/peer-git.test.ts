/**
 * 没有远程的项目以各工作机的检出互为远程（src/workspace/peer-git.ts，docs/分布式架构.md「数据的归属与同步」）：
 * 两台本进程 kited 互为组网对端，B 从 A 的检出 clone 和拉取，git 经 A 的 /git/:project 转接到 A 检出上的 http-backend；
 * 之后给项目设远程，全部分支和标签推上去，各工作机随项目同步加上 origin。
 */
import { afterEach, expect, test } from 'bun:test';
import { rmSync } from 'node:fs';
import { join } from 'node:path';
import type { Checkout } from '../../src/model.ts';
import { type FakeGit, startFakeGit } from '../fake-git.ts';
import { connect, type Kited, registerBeforeStart, startKited, synced } from '../harness.ts';
import { commitAll, git, makeTemp, newDir, read, writeFiles } from '../util.ts';

const kiteds: Kited[] = [];
const dirs: string[] = [];
let remotes: FakeGit | undefined;
afterEach(async () => {
  for (const k of kiteds.splice(0)) await k.stop();
  remotes?.stop();
  remotes = undefined;
  for (const dir of dirs.splice(0)) rmSync(dir, { recursive: true, force: true });
});

/**
 * A 上登记了一个没有远程的普通文件夹（先登记再起，见 registerBeforeStart），B 与 A 互为对端，
 * 已从同步来的登记表和目录摘要里看到这个项目和 A 的检出；B 把它 clone 到自己的临时目录下。
 */
async function cloned(files: Record<string, string>) {
  const root = makeTemp('peer-git-');
  dirs.push(root);
  const folder = newDir(root, 'notes', files);
  const [registered] = await registerBeforeStart(root, [folder]);
  const projectId = registered!.project.id;
  const a = startKited(undefined, false, { root });
  const b = startKited();
  kiteds.push(a, b);
  const machineA = a.daemon.kite.store.machine.id;
  await connect(a, b);
  await synced(b, () => b.daemon.kite.registry.get(projectId) && b.daemon.kite.directory.entries()
    .some((entry) => entry.id === machineA && entry.snapshot?.checkouts.some((checkout) => checkout.projectId === projectId)),
  'B 同步到项目登记和 A 的检出');
  const target = join(b.root, 'notes');
  const response = await b.call('POST', '/checkouts', { project: projectId, path: target });
  if (response.status !== 200) throw new Error(`B 从 A clone 失败：${response.status} ${JSON.stringify(response.body)}`);
  return { a, b, folder, target, projectId, machineA, model: response.body };
}

/*
 * 跨部分与 git 的配合：B 的 git clone、fetch 带 X-Kite-Machine 访问 A 的 /git/:project，A 转接给自己检出上的 git http-backend；
 * B 的项目同步把 A 的全部分支取到 refs/kite/peers/<A>/，当前分支落后且干净时快进（工作树一起更新），
 * 两边都有新提交时只更新对端的 ref，不合并、不动 B 的主线和现场。
 * B 收到项目登记后约半秒会自己再同步一次；分叉前先让 B 提交，这次后台同步早晚都不改变结果。
 */
test('B 从 A 的检出 clone 没有远程的项目、不留 origin；A 再提交后 B 项目同步快进主线；B 的提交并推送只在本机提交，与 A 分叉后同步不合并、B 的主线不动', async () => {
  const { b, folder, target, projectId, machineA, model } = await cloned({ 'a.txt': '一\n' });
  const branch = git(folder, 'branch', '--show-current');
  expect(model).toMatchObject({ project: { id: projectId, remote: null }, checkout: { path: target, remote: null } });
  expect(git(target, 'rev-parse', 'HEAD')).toBe(git(folder, 'rev-parse', 'HEAD'));
  expect(git(target, 'branch', '--show-current')).toBe(branch);
  expect(read(join(target, 'a.txt'))).toBe('一\n');
  expect(git(target, 'remote')).toBe('');

  writeFiles(folder, { 'a.txt': '二\n' });
  const second = commitAll(folder, 'A 的第二个提交');
  git(folder, 'branch', 'feature');
  await b.daemon.kite.syncProjects();
  expect(git(target, 'rev-parse', 'HEAD')).toBe(second);
  expect(read(join(target, 'a.txt'))).toBe('二\n');
  expect(git(target, 'status', '--porcelain')).toBe('');
  expect(git(target, 'for-each-ref', '--format=%(refname) %(objectname)', `refs/kite/peers/${machineA}/`).split('\n').sort())
    .toEqual([`refs/kite/peers/${machineA}/${branch} ${second}`, `refs/kite/peers/${machineA}/feature ${second}`].sort());

  // B 先在现场提交（经 kited 的「提交并推送」，没有远程的项目只提交；与后台的项目同步共用检出的锁），A 再提交，两边分叉。
  writeFiles(target, { 'b.txt': 'B 的\n' });
  expect((await b.call('POST', `/checkouts/${model.checkout.id}/push`, { message: 'B 自己的提交' })).status).toBe(200);
  const ours = git(target, 'rev-parse', 'HEAD');
  expect(git(target, 'log', '-1', '--format=%s%n%P')).toBe(`B 自己的提交\n${second}`);
  writeFiles(folder, { 'a.txt': '三\n' });
  const theirs = commitAll(folder, 'A 的第三个提交');
  await b.daemon.kite.syncProjects();
  expect(git(target, 'rev-parse', `refs/kite/peers/${machineA}/${branch}`)).toBe(theirs);
  expect(git(target, 'rev-parse', 'HEAD')).toBe(ours);
  expect(read(join(target, 'a.txt'))).toBe('二\n');
  expect(git(target, 'status', '--porcelain')).toBe('');
}, 1_000);

/*
 * 几条 git 命令与同步的配合：A 用本机检出把全部分支和标签推到新远程（替身上的空裸仓库，经 http-backend 接收推送）并加 origin，
 * 写进登记表；登记表随账号级数据同步到 B，B 的项目同步给自己的检出加上 origin，本机记录的检出远程跟着改。
 */
test('没有远程的项目设远程：全部分支和标签推到远程、A 的检出加上 origin，B 同步到登记表后项目同步也给自己的检出加上 origin', async () => {
  const { a, b, folder, target, projectId } = await cloned({ 'a.txt': '一\n' });
  const branch = git(folder, 'branch', '--show-current');
  git(folder, 'switch', '-q', '-c', 'feature');
  writeFiles(folder, { 'f.txt': '功能\n' });
  commitAll(folder, '功能分支');
  git(folder, 'tag', 'v1');
  git(folder, 'switch', '-q', branch);

  remotes = startFakeGit();
  const { url, bare } = remotes.create('notes');
  const set = await a.call('PUT', `/project-registry/${projectId}/remote`, { remote: url });
  expect(set.status).toBe(200);
  const remote = `${new URL(url).host}/notes`;
  expect(set.body).toMatchObject({ id: projectId, remote, url });
  const refs = (dir: string) => git(dir, 'for-each-ref', '--format=%(refname) %(objectname)', 'refs/heads/', 'refs/tags/');
  expect(refs(bare)).toBe(refs(folder));
  expect(refs(bare).split('\n')).toHaveLength(3);
  expect(git(folder, 'remote', 'get-url', 'origin')).toBe(url);

  await synced(b, () => b.daemon.kite.registry.get(projectId)?.remote, 'B 同步到设好的远程');
  await b.daemon.kite.syncProjects();
  expect(git(target, 'remote', 'get-url', 'origin')).toBe(url);
  expect(((await b.call('GET', '/checkouts')).body as Checkout[]).map((checkout) => [checkout.path, checkout.remote]))
    .toEqual([[target, remote]]);
}, 1_000);
