/**
 * 项目与远程仓库（docs/项目与远程仓库.md），分两段：
 * 一、添加项目与建工作区：经 HTTP 添加本机文件夹（导入成 Kite 数据目录里的裸仓库检出）或远程，按项目建工作区时从远程
 *    或另一台工作机的检出 clone，kited 与本机项目登记表、Git 平台替身上的裸仓库（git http-backend）之间的交接；
 * 二、没有远程的项目以各工作机的检出互为远程（src/workspace/peer-git.ts，docs/分布式架构.md「数据的归属与同步」）：
 *    两台本进程 kited 互为组网对端，B 从 A 的检出 clone 和拉取，git 经 A 的 /git/:project 转接到 A 检出上的 http-backend；
 *    之后给项目设远程，全部分支和标签推上去，各工作机随项目同步加上 origin。
 * 导入文件夹的细节见 project-import.test.ts，集成与同步见 integration.test.ts，删除项目在别的工作机上的移除见 account-sync.test.ts。
 */
import { afterEach, expect, test } from 'bun:test';
import { rmSync } from 'node:fs';
import { join } from 'node:path';
import { Bus } from '../../src/events.ts';
import { Kite } from '../../src/kite.ts';
import type { Checkout, WorkspaceModel } from '../../src/model.ts';
import { checkoutPath } from '../../src/paths.ts';
import { Store } from '../../src/store.ts';
import { type FakeGit, startFakeGit } from '../fake-git.ts';
import {
  addProject, chatgptLogin, connect, createWorkspace, type Kited, openWorkspace, registerBeforeStart, startKited, synced, workspaceOpened,
} from '../harness.ts';
import { ManualModel } from '../harness-loop.ts';
import { commitMainline, git, gitOk, lexists, listTree, makeTemp, newDir, newRepo, read, writeFiles } from '../util.ts';

let kited: Kited | undefined;
/** 同一用户的第二台工作机。 */
let second: Kited | undefined;
/** 互为组网对端的几台工作机（没有远程的项目一段）。 */
const kiteds: Kited[] = [];
let remotes: FakeGit | undefined;
const dirs: string[] = [];
const releases: Array<() => void> = [];
afterEach(async () => {
  for (const release of releases.splice(0)) release();
  await kited?.stop();
  kited = undefined;
  await second?.stop();
  second = undefined;
  for (const k of kiteds.splice(0)) await k.stop();
  remotes?.stop();
  remotes = undefined;
  for (const dir of dirs.splice(0)) rmSync(dir, { recursive: true, force: true });
});

/**
 * 在替身上新建裸仓库，在 parent 下建一个 origin 指向它、主线已推上去的仓库。直接推到裸仓库路径：
 * util 的 git 是同步调用，替身的 HTTP 服务在本进程里，经 http 推会互相等住。
 */
function pushedRepo(parent: string, name: string, files: Record<string, string>) {
  const { url, bare } = (remotes ??= startFakeGit()).create(name);
  const repo = newRepo(parent, name, files, url);
  git(repo, 'push', '-q', bare, 'main');
  return { repo, url, bare };
}

/*
 * 建工作区时本机没有检出，git clone 在 HTTP 引用广告前挂起：别的项目照样能添加，不被这次 clone 挡住。
 * 远程失败让 clone 的 git 子进程退出后，建工作区报错、数据目录里不留半成品的检出，同一项目再建工作区能 clone 成功。
 */
test('建工作区 clone 等远程时别的项目照样能添加，clone 失败后不留检出，再建工作区能成', async () => {
  kited = startKited();
  const running = kited;
  const { url } = pushedRepo(running.root, 'source', { 'a.txt': '原始\n' });
  const project = await addProject(running, { remote: url });
  chatgptLogin(running.home);
  const held = Promise.withResolvers<void>();
  const release = Promise.withResolvers<void | Response>();
  releases.push(() => release.resolve());
  // 挂住之后所有的拉取（clone 和后台可能的 ls-remote 都经引用广告），放行时一起失败。
  remotes!.beforeFetch = () => { held.resolve(); return release.promise; };
  const creating = running.call('POST', '/workspaces', { project: project.id });
  try {
    await held.promise;
    const independent = await addProject(running, { path: newRepo(running.root, 'local', { 'local.txt': '本地\n' }, null) });
    expect(independent.id).not.toBe(project.id);
    release.resolve(new Response('模拟远程暂时不可用', { status: 503 }));
    expect((await creating).status).toBeGreaterThanOrEqual(400);
    expect(running.daemon.kite.store.checkouts(project.id)).toEqual([]);
    expect(lexists(checkoutPath(running.home, project.id))).toBe(false);
    remotes!.beforeFetch = undefined;
    const retried = await openWorkspace(running, project.id);
    expect(retried.checkout.path).toBe(checkoutPath(running.home, project.id));
    expect(read(join(retried.workspace.cwd, 'a.txt'))).toBe('原始\n');
  } finally {
    release.resolve();
    await creating;
  }
}, 1_000);

/*
 * HTTP 挂起的 git 子进程、登记入库与关闭交错：直接进入 Kite.shutdown，排除服务外围收尾碰巧等够了的假通过。
 * 添加远程先 ls-remote 确认访问得到，调用方在 shutdown 返回时立刻关 SQLite，已接收的添加仍必须完成登记。
 */
test('关闭等待已经接收的添加项目完成登记后才允许关闭数据库', async () => {
  const root = makeTemp('shutdown-add-');
  dirs.push(root);
  const home = newDir(root, 'kite');
  const store = new Store(join(home, 'kite.sqlite'));
  const kite = new Kite(store, home, new Bus(), { lightTasks: false });
  const held = Promise.withResolvers<void>();
  const release = Promise.withResolvers<void>();
  releases.push(() => release.resolve());
  const completed: string[] = [];
  let stopping: Promise<void> | undefined;
  try {
    const { url } = pushedRepo(root, 'source', { 'a.txt': '关闭前收到的添加\n' });
    remotes!.beforeFetch = () => { held.resolve(); return release.promise; };
    const adding = kite.addProject({ remote: url }).then((project) => {
      completed.push('registered');
      return { project, listed: kite.registry.get(project.id) };
    });
    await held.promise;
    stopping = kite.shutdown().then(() => { store.close(); completed.push('stopped'); });
    release.resolve();
    const [{ project, listed }] = await Promise.all([adding, stopping]);
    expect(project.url).toBe(url);
    expect(listed).toEqual(project);
    expect(completed).toEqual(['registered', 'stopped']);
  } finally {
    release.resolve();
    if (stopping) await stopping;
    else { await kite.shutdown(); store.close(); }
  }
}, 1_000);

/*
 * 几个部分的配合：同步来的项目登记与目录摘要、本机环境检查、从另一台工作机的检出 clone（对端 kited 转接 git http-backend）、
 * 登记和工作树准备。没有远程的项目在 B 上没有检出时，从目录里有检出的 A 取，clone 到 B 数据目录的 repos/<项目 ID>.git，不留 origin。
 */
test('按项目建工作区：所选模型的厂商未登录时 409 且不 clone，登录后从另一台工作机 clone 到数据目录登记为同一项目并建好工作树', async () => {
  const root = makeTemp('project-workspace-');
  dirs.push(root);
  const source = newDir(root, 'peer', { 'a.txt': '原始\n' });
  const [registered] = await registerBeforeStart(root, [source]);
  const projectId = registered!.id;
  kited = startKited(undefined, false, { root });
  const machineA = kited.daemon.kite.store.machine.id;

  second = startKited();
  const other = second;
  await connect(kited, other);
  await synced(other, () => other.daemon.kite.registry.get(projectId) && other.daemon.kite.directory.entries()
    .some((entry) => entry.id === machineA && entry.snapshot?.checkouts.some((checkout) => checkout.projectId === projectId)),
  '第二台工作机同步到项目登记和 A 的检出');
  const before = await other.call('GET', `/environment?project=${projectId}`);
  expect(before.status).toBe(200);
  expect(before.body).toMatchObject({ checkout: null, logins: { chatgpt: { status: 'missing' } } });
  const target = checkoutPath(other.home, projectId);

  const refused = await other.call('POST', '/workspaces', { project: projectId });
  expect(refused.status).toBe(409);
  expect(lexists(target)).toBe(false);
  expect((await other.call('GET', '/checkouts')).body).toEqual([]);

  chatgptLogin(other.home);
  const created = await other.call('POST', '/workspaces', { project: projectId });
  expect(created.status).toBe(200);
  const model = created.body as WorkspaceModel;
  expect(model.project).toMatchObject({ id: projectId, remote: null });
  expect(model.checkout.path).toBe(target);
  expect(git(target, 'rev-parse', 'HEAD')).toBe(git(checkoutPath(kited.home, projectId), 'rev-parse', 'HEAD'));
  expect(git(target, 'remote')).toBe('');
  expect(model.workspace).toMatchObject({ checkoutId: model.checkout.id, branch: `kite/${model.workspace.id}` });
  const opened = await workspaceOpened(other, model.workspace.id);
  expect(read(join(opened.workspace.cwd, 'a.txt'))).toBe('原始\n');
  const environment = await other.call('GET', `/environment?project=${projectId}`);
  expect(environment.body).toMatchObject({ checkout: { id: model.checkout.id, path: target }, logins: { chatgpt: { status: 'ready' } } });
}, 1_000);

/*
 * 删除项目在接请求的这台（docs/项目与远程仓库.md「删除项目」）：停下正在跑的回合，回收工作树和分支，
 * 再删工作区、会话、Kite 的检出与项目。SQLite 的外键在这个删除顺序下成不成立、git worktree 的登记与检出目录一起去掉，
 * 要跑起来才知道；导入来源的文件夹不受影响，同一文件夹再添加得到新项目。
 */
test('删除项目：停下回合，工作树、记录、会话与 Kite 的检出都删掉，原文件夹不动，同一文件夹再添加是新项目', async () => {
  const model = new ManualModel();
  kited = startKited(() => model);
  const running = kited;
  const kite = running.daemon.kite;
  const folder = newDir(running.root, 'notes', { 'readme.txt': '笔记\n' });
  const project = await addProject(running, { path: folder });
  const thread = await createWorkspace(running, project.id, '开始写', 'harness');
  const { workspace, checkout } = thread;
  const turn = await model.call(1);
  writeFiles(workspace.cwd, { 'readme.txt': '工作区里改过\n', 'draft.txt': '未提交的草稿\n' });
  expect(gitOk(checkout.path, 'show-ref', '--verify', `refs/heads/${workspace.branch}`)).toBe(true);

  await kite.deleteProject(project.id);

  expect(turn.signal.aborted).toBe(true);
  expect(kite.registry.get(project.id)).toBeUndefined();
  expect(kite.store.projects().map((value) => value.id)).not.toContain(project.id);
  expect(kite.store.checkouts()).toEqual([]);
  expect(kite.store.workspaces()).toEqual([]);
  expect(kite.store.thread(thread.id)).toBeNull();
  expect(lexists(join(running.home, 'sessions', thread.id))).toBe(false);
  expect(lexists(workspace.cwd)).toBe(false);
  expect(lexists(checkout.path)).toBe(false);
  expect(listTree(folder)).toEqual({ 'readme.txt': '笔记\n' });
  expect(lexists(join(folder, '.git'))).toBe(false);

  const again = await addProject(running, { path: folder });
  expect(again.id).not.toBe(project.id);
  expect(again).toMatchObject({ name: 'notes', remote: null });
  expect(kite.store.checkouts(again.id)).toEqual([expect.objectContaining({ path: checkoutPath(running.home, again.id) })]);
}, 1_000);

// ---- 没有远程的项目以各工作机的检出互为远程 ----

/**
 * A 上添加了一个没有远程的普通文件夹（先登记再起，见 registerBeforeStart），B 与 A 互为对端，
 * 已从同步来的登记表和目录摘要里看到这个项目和 A 的检出；B 为它建工作区，从 A 的检出 clone 到自己的数据目录。
 */
async function cloned(files: Record<string, string>) {
  const root = makeTemp('peer-git-');
  dirs.push(root);
  const [registered] = await registerBeforeStart(root, [newDir(root, 'notes', files)]);
  const projectId = registered!.id;
  const a = startKited(undefined, false, { root });
  const b = startKited();
  kiteds.push(a, b);
  const machineA = a.daemon.kite.store.machine.id;
  await connect(a, b);
  await synced(b, () => b.daemon.kite.registry.get(projectId) && b.daemon.kite.directory.entries()
    .some((entry) => entry.id === machineA && entry.snapshot?.checkouts.some((checkout) => checkout.projectId === projectId)),
  'B 同步到项目登记和 A 的检出');
  const model = await openWorkspace(b, projectId);
  return { a, b, projectId, machineA, checkoutA: checkoutPath(a.home, projectId), checkoutB: model.checkout.path, model };
}

/*
 * 跨部分与 git 的配合：B 的 git clone、fetch 带 X-Kite-Machine 访问 A 的 /git/:project，A 转接给自己检出上的 git http-backend；
 * B 的项目同步把 A 的全部分支取到 refs/kite/peers/<A>/，主线落后时快进，两边都有新提交时只更新对端的 ref，不合并、不动 B 的主线。
 * B 收到项目登记后约半秒会自己再同步一次；分叉前先让 B 合入，这次后台同步早晚都不改变结果。
 */
test('B 从 A 的检出 clone 没有远程的项目、不留 origin；A 再提交后 B 项目同步快进主线；B 的工作区合入只到本机主线，与 A 分叉后同步不合并、B 的主线不动', async () => {
  const { b, projectId, machineA, checkoutA, checkoutB, model } = await cloned({ 'a.txt': '一\n' });
  expect(model).toMatchObject({ project: { id: projectId, remote: null }, checkout: { path: checkoutPath(b.home, projectId), remote: null } });
  expect(git(checkoutB, 'rev-parse', 'main')).toBe(git(checkoutA, 'rev-parse', 'main'));
  expect(git(checkoutB, 'remote')).toBe('');

  const second = commitMainline(checkoutA, { 'a.txt': '二\n' }, 'A 的第二个提交');
  git(checkoutA, 'branch', 'feature', 'main');
  await b.daemon.kite.syncProjects();
  expect(git(checkoutB, 'rev-parse', 'main')).toBe(second);
  expect(git(checkoutB, 'for-each-ref', '--format=%(refname) %(objectname)', `refs/kite/peers/${machineA}/`).split('\n').sort())
    .toEqual([`refs/kite/peers/${machineA}/main ${second}`, `refs/kite/peers/${machineA}/feature ${second}`].sort());

  // B 先在自己的工作区里改并合入（没有远程的项目只合进本机主线；与后台的项目同步共用检出的锁），A 再提交，两边分叉。
  writeFiles(model.workspace.cwd, { 'b.txt': 'B 的\n' });
  const adopted = await b.call('POST', `/workspaces/${model.workspace.id}/adopt`);
  expect(adopted.body).toMatchObject({ status: 'adopted', push: { status: 'local' } });
  const ours = git(checkoutB, 'rev-parse', 'main');
  expect(ours).toBe(adopted.body.commit);
  expect(gitOk(checkoutB, 'merge-base', '--is-ancestor', second, ours)).toBe(true);
  const theirs = commitMainline(checkoutA, { 'a.txt': '三\n' }, 'A 的第三个提交');
  await b.daemon.kite.syncProjects();
  expect(git(checkoutB, 'rev-parse', `refs/kite/peers/${machineA}/main`)).toBe(theirs);
  expect(git(checkoutB, 'rev-parse', 'main')).toBe(ours);
  expect(git(checkoutB, 'show', 'main:a.txt')).toBe('二');
}, 1_000);

/*
 * 几条 git 命令与同步的配合：A 用本机检出把全部分支和标签推到新远程（替身上的空裸仓库，经 http-backend 接收推送）并加 origin，
 * 写进登记表；登记表随账号级数据同步到 B，B 的项目同步给自己的检出加上 origin，本机记录的检出远程跟着改。
 */
test('没有远程的项目设远程：全部分支和标签推到远程、A 的检出加上 origin，B 同步到登记表后项目同步也给自己的检出加上 origin', async () => {
  const { a, b, projectId, checkoutA, checkoutB } = await cloned({ 'a.txt': '一\n' });
  git(checkoutA, 'branch', 'feature', 'main');
  git(checkoutA, 'tag', 'v1', 'main');

  remotes = startFakeGit();
  const { url, bare } = remotes.create('notes');
  const set = await a.call('PUT', `/project-registry/${projectId}/remote`, { remote: url });
  expect(set.status).toBe(200);
  const remote = `${new URL(url).host}/notes`;
  expect(set.body).toMatchObject({ id: projectId, remote, url });
  const refs = (dir: string) => git(dir, 'for-each-ref', '--format=%(refname) %(objectname)', 'refs/heads/', 'refs/tags/');
  expect(refs(bare)).toBe(refs(checkoutA));
  expect(refs(bare).split('\n')).toHaveLength(3);
  expect(git(checkoutA, 'remote', 'get-url', 'origin')).toBe(url);

  await synced(b, () => b.daemon.kite.registry.get(projectId)?.remote, 'B 同步到设好的远程');
  await b.daemon.kite.syncProjects();
  expect(git(checkoutB, 'remote', 'get-url', 'origin')).toBe(url);
  expect(((await b.call('GET', '/checkouts')).body as Checkout[]).map((checkout) => [checkout.path, checkout.remote]))
    .toEqual([[checkoutB, remote]]);
}, 1_000);
