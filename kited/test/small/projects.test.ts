/**
 * 项目与远程仓库（docs/项目与远程仓库.md），分三段：
 * 一、项目登记：经 HTTP 登记本机文件夹、clone 远程或另一台工作机的检出，kited 与本机项目登记表、
 *    Git 平台替身上的裸仓库（git http-backend）之间的交接；
 * 二、工作区集成与检出现场推送：kited 用真实 git fetch/merge/push 访问替身上的裸仓库；
 * 三、没有远程的项目以各工作机的检出互为远程（src/workspace/peer-git.ts，docs/分布式架构.md「数据的归属与同步」）：
 *    两台本进程 kited 互为组网对端，B 从 A 的检出 clone 和拉取，git 经 A 的 /git/:project 转接到 A 检出上的 http-backend；
 *    之后给项目设远程，全部分支和标签推上去，各工作机随项目同步加上 origin。
 * 删除项目在别的工作机上的移除见 account-sync.test.ts。
 */
import { afterEach, expect, test } from 'bun:test';
import { existsSync, realpathSync, rmSync, symlinkSync } from 'node:fs';
import { join } from 'node:path';
import GITATTRIBUTES_TEMPLATE from '../../../.claude/skills/kite-onboard/templates/gitattributes' with { type: 'text' };
import type { RegisteredProject } from '../../src/account-data/registry.ts';
import { Bus } from '../../src/events.ts';
import { Kite } from '../../src/kite.ts';
import type { Checkout, WorkspaceModel } from '../../src/model.ts';
import { Store } from '../../src/store.ts';
import { snapshotRef } from '../../src/workspace/snapshots.ts';
import { type FakeGit, startFakeGit } from '../fake-git.ts';
import {
  call, chatgptLogin, connect, createWorkspace, type Kited, type KitedProcess, registerBeforeStart, registerCheckout, spawnKited, startKited, synced,
} from '../harness.ts';
import { ManualModel } from '../harness-loop.ts';
import { commitAll, git, gitOk, lexists, makeTemp, newDir, newRepo, read, repoState, writeFiles } from '../util.ts';

let kited: Kited | undefined;
/** 同一用户的第二台工作机。 */
let second: Kited | undefined;
/** 互为组网对端的几台工作机（没有远程的项目一段）。 */
const kiteds: Kited[] = [];
let child: KitedProcess | undefined;
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
  await child?.kill('SIGTERM');
  child = undefined;
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
 * 几条真实 git 命令的配合：git init、写 .gitignore 与 .gitattributes（模板）、初始提交。没有 origin 的文件夹登记成
 * 没有远程的项目，不建远程、不推送，提交后现场是干净的。
 */
test('普通文件夹登记成没有远程的项目：Kite 初始化仓库并提交模板文件，不加 origin，现场干净', async () => {
  kited = startKited();
  const folder = newDir(kited.root, 'notes', { 'readme.txt': '笔记\n' });
  const model = await registerCheckout(kited, folder);
  expect(model.project.remote).toBeNull();
  expect(model.checkout.remote).toBeNull();
  expect(kited.daemon.kite.registry.get(model.project.id)).toMatchObject({ name: 'notes', remote: null, url: null });
  expect(git(folder, 'remote')).toBe('');
  const head = git(folder, 'rev-parse', 'HEAD');
  expect(git(folder, 'ls-tree', '--name-only', head).split('\n').sort()).toEqual(['.gitattributes', '.gitignore', 'readme.txt']);
  expect(git(folder, 'show', `${head}:.gitattributes`)).toBe(GITATTRIBUTES_TEMPLATE.replace(/\n$/, ''));
  expect(git(folder, 'status', '--porcelain')).toBe('');
});

/*
 * 两处都看 homedir()：同步目录（Dropbox 等）的判定和 clone 的默认位置。Bun 在进程启动时缓存 homedir()，
 * 本进程里的 kited 会用真实的 HOME（clone 会落到真实的 ~/code），所以起子进程，让它从启动起就用 setup.ts 的隔离 HOME。
 * 同步目录里的普通文件夹由 Kite git init，仓库本体放进 Kite 目录、按检出 ID 命名，文件夹里只留 .git 指针；
 * 设远程时从这份检出推上去，另一份检出经真实 git clone（替身的 http-backend）后按 origin 登记，应得到同一项目；目标非空时不碰用户文件。
 */
test('同步目录里的普通文件夹把仓库放进 Kite 目录，设远程后按地址 clone 到 ~/code 下得到同一项目，目标非空时拒绝', async () => {
  const root = makeTemp('clone-checkout-');
  dirs.push(root);
  const home = join(root, 'kite');
  remotes = startFakeGit();
  child = await spawnKited(home);
  const dropbox = newDir(process.env.HOME!, `Dropbox/kite-projects-${crypto.randomUUID()}`);
  dirs.push(dropbox);
  const source = newDir(dropbox, 'source', { 'a.txt': '原始\n' });
  const first = await call(child.url, 'POST', '/checkouts', { path: source });
  expect(first.status).toBe(200);
  expect(git(source, 'rev-parse', '--absolute-git-dir')).toBe(realpathSync(join(home, 'repos', `${first.body.checkout.id}.git`)));
  const { url, bare } = remotes.create('source');
  const set = await call(child.url, 'PUT', `/project-registry/${first.body.project.id}/remote`, { remote: url });
  expect(set.status).toBe(200);
  const project = set.body as RegisteredProject;
  expect(project.id).toBe(first.body.project.id);
  expect(git(bare, 'rev-parse', `refs/heads/${git(source, 'branch', '--show-current')}`)).toBe(git(source, 'rev-parse', 'HEAD'));
  const host = project.remote!.split('/')[0]!;
  dirs.push(join(process.env.HOME!, 'code', host));

  const cloned = await call(child.url, 'POST', '/checkouts', { remote: url });
  expect(cloned.status).toBe(200);
  const model = cloned.body as WorkspaceModel;
  const expected = join(process.env.HOME!, 'code', ...project.remote!.split('/'));
  expect(model.project).toMatchObject({ id: project.id, remote: project.remote });
  expect(model.checkout).toMatchObject({ path: expected, remote: project.remote });
  expect(model.checkout.id).not.toBe(first.body.checkout.id);
  expect(git(expected, 'rev-parse', 'HEAD')).toBe(git(source, 'rev-parse', 'HEAD'));
  expect(git(expected, 'remote', 'get-url', 'origin')).toBe(url);
  expect(read(join(expected, 'a.txt'))).toBe('原始\n');

  const occupied = newDir(root, 'occupied', { 'mine.txt': '用户的文件\n' });
  const rejected = await call(child.url, 'POST', '/checkouts', { remote: url, path: occupied });
  expect(rejected.status).toBe(409);
  expect(read(join(occupied, 'mine.txt'))).toBe('用户的文件\n');
  expect(lexists(join(occupied, '.git'))).toBe(false);
  expect(((await call(child.url, 'GET', '/checkouts')).body as Checkout[]).map((c) => c.id).sort())
    .toEqual([first.body.checkout.id, model.checkout.id].sort());
});

/*
 * git clone 在 HTTP 引用广告前挂起时，独立目录必须继续登记；真实父子仓库和符号链接需要与目录占位一起判断。
 * 远程失败让 git 子进程退出后，同一路径必须可重试，不能留下永久占位。
 */
test('clone 等远程时独立 clone 和本地登记可完成，父子目录及别名拒绝登记，失败后原路径可重试', async () => {
  kited = startKited();
  const running = kited;
  const { repo: source, url: remote } = pushedRepo(running.root, 'source', { 'a.txt': '原始\n' });
  const first = await registerCheckout(running, source);
  const parent = newRepo(running.root, 'parent', { 'parent.txt': '父目录\n' });
  const target = join(parent, 'cloned');
  const alias = join(running.root, 'alias');
  symlinkSync(parent, alias);
  const held = Promise.withResolvers<void>();
  const release = Promise.withResolvers<void | Response>();
  releases.push(() => release.resolve());
  // 登记后后台的执行权核对会 ls-remote 同一个远程，也走 upload-pack；先等它这一轮结束，挂住的才是 clone 的请求。
  await running.daemon.kite.syncLeases();
  let fetches = 0;
  remotes!.beforeFetch = () => {
    if (fetches++ !== 0) return;
    held.resolve();
    return release.promise;
  };
  const cloning = running.call('POST', '/checkouts', { remote, path: target });
  try {
    await held.promise;
    const nested = newRepo(target, 'nested', { 'nested.txt': '子目录\n' });
    const independent = newRepo(running.root, 'local', { 'local.txt': '本地\n' });
    const [otherClone, local, ...overlapping] = await Promise.all([
      running.call('POST', '/checkouts', { remote, path: join(running.root, 'other-clone') }),
      running.call('POST', '/checkouts', { path: independent }),
      ...[target, parent, nested, join(alias, 'cloned')].map((path) => running.call('POST', '/checkouts', { path })),
      running.call('POST', '/checkouts', { remote, path: join(alias, 'cloned', 'another') }),
    ]);
    expect(otherClone.status).toBe(200);
    expect(otherClone.body.project.id).toBe(first.project.id);
    expect(local.status).toBe(200);
    expect(overlapping.map((response) => response.status)).toEqual([409, 409, 409, 409, 409]);
    expect(running.daemon.kite.checkouts()).toHaveLength(3);
    release.resolve(new Response('模拟远程暂时不可用', { status: 503 }));
    expect((await cloning).status).toBeGreaterThanOrEqual(400);
    const retried = await running.call('POST', '/checkouts', { remote, path: target });
    expect(retried.status).toBe(200);
    expect(retried.body.project.id).toBe(first.project.id);
    expect(read(join(target, 'a.txt'))).toBe('原始\n');
    expect(running.daemon.kite.checkouts()).toHaveLength(4);
  } finally {
    release.resolve();
    await cloning;
  }
}, 1_000);

/*
 * HTTP 挂起的 git 子进程、登记入库与关闭交错：直接进入 Kite.shutdown，排除服务外围收尾碰巧等够了的假通过。
 * 调用方在 shutdown 返回时立刻关 SQLite，已接收的 clone 仍必须完成登记。
 */
test('关闭等待已经接收的 clone 登记完成后才允许关闭数据库', async () => {
  const root = makeTemp('shutdown-clone-');
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
    const { repo: source, url: remote } = pushedRepo(root, 'source', { 'a.txt': '关闭前收到的 clone\n' });
    const first = await kite.registerCheckout({ path: source });
    const target = join(root, 'cloned');
    remotes!.beforeFetch = () => { held.resolve(); return release.promise; };
    const cloning = kite.registerCheckout({ remote, path: target }).then((model) => {
      completed.push('registered');
      return model;
    });
    await held.promise;
    stopping = kite.shutdown().then(() => { store.close(); completed.push('stopped'); });
    release.resolve();
    const [model] = await Promise.all([cloning, stopping]);
    expect(model.project.id).toBe(first.project.id);
    expect(model.checkout.path).toBe(target);
    expect(read(join(target, 'a.txt'))).toBe('关闭前收到的 clone\n');
    expect(completed).toEqual(['registered', 'stopped']);
  } finally {
    release.resolve();
    if (stopping) await stopping;
    else { await kite.shutdown(); store.close(); }
  }
}, 1_000);

/*
 * 几个部分的配合：同步来的项目登记与目录摘要、本机环境检查、从另一台工作机的检出 clone（对端 kited 转接 git http-backend）、
 * 登记和工作树准备。没有远程的项目在 B 上没有检出时，从目录里有检出的 A 取。
 * 真实 bug：Bun 的 os.homedir() 在进程启动时缓存，不随 setup.ts 改过的 HOME 变化，按项目建工作区的默认 clone
 * 曾落到真实的 ~/code。这里的第二台工作机在本进程里起，clone 位置必须在隔离的 HOME 下；环境检查先报出这个位置，
 * 位置不对时测试在 clone 之前就失败。
 */
test('按项目建工作区：所选模型的厂商未登录时 409 且不 clone，登录后从另一台工作机 clone 到默认位置登记为同一项目并建好工作树', async () => {
  const root = makeTemp('project-workspace-');
  dirs.push(root);
  const name = `peer-${crypto.randomUUID().slice(0, 8)}`;
  const source = newDir(root, name, { 'a.txt': '原始\n' });
  const [registered] = await registerBeforeStart(root, [source]);
  const projectId = registered!.project.id;
  kited = startKited(undefined, false, { root });
  const machineA = kited.daemon.kite.store.machine.id;
  dirs.push(join(process.env.HOME!, 'code', name));

  second = startKited();
  const other = second;
  await connect(kited, other);
  await synced(other, () => other.daemon.kite.registry.get(projectId) && other.daemon.kite.directory.entries()
    .some((entry) => entry.id === machineA && entry.snapshot?.checkouts.some((checkout) => checkout.projectId === projectId)),
  '第二台工作机同步到项目登记和 A 的检出');
  const before = await other.call('GET', `/environment?project=${projectId}`);
  expect(before.status).toBe(200);
  expect(before.body).toMatchObject({ checkout: null, logins: { chatgpt: { status: 'missing' } } });
  const clonePath = before.body.clonePath as string;
  expect(clonePath).toBe(join(process.env.HOME!, 'code', name));

  const refused = await other.call('POST', '/workspaces', { project: projectId });
  expect(refused.status).toBe(409);
  expect(lexists(clonePath)).toBe(false);
  expect((await other.call('GET', '/checkouts')).body).toEqual([]);

  chatgptLogin(other.home);
  const created = await other.call('POST', '/workspaces', { project: projectId });
  expect(created.status).toBe(200);
  const model = created.body as WorkspaceModel;
  expect(model.project).toMatchObject({ id: projectId, remote: null });
  expect(model.checkout.path).toBe(clonePath);
  expect(git(clonePath, 'rev-parse', 'HEAD')).toBe(git(source, 'rev-parse', 'HEAD'));
  expect(git(clonePath, 'remote')).toBe('');
  expect(model.workspace).toMatchObject({ kind: 'worktree', checkoutId: model.checkout.id });
  await other.waitEvent((e) => e.type === 'workspace.changed' && e.workspaceId === model.workspace.id && e.status === 'open');
  expect(read(join(model.workspace.cwd, 'a.txt'))).toBe('原始\n');
  const environment = await other.call('GET', `/environment?project=${projectId}`);
  expect(environment.body).toMatchObject({ checkout: { id: model.checkout.id, path: clonePath }, logins: { chatgpt: { status: 'ready' } } });
}, 1_000);

/*
 * 删除项目在接请求的这台（docs/项目与远程仓库.md「删除项目」）：停下正在跑的回合，工作树先存快照再回收，
 * 再删工作区、会话、检出与项目。几条 git 命令合起来的效果（快照引用留在检出里、git worktree 的登记和工作区分支都去掉），
 * 以及 SQLite 的外键与唯一索引（checkouts(machine_id, path)、workspaces(cwd)）在这个删除顺序下成不成立，
 * 要跑起来才知道：同一文件夹再登记要越过这两个唯一索引，得到新项目。
 */
test('删除项目：停下回合，工作树里未提交的改动存进检出的快照引用后回收工作树和分支，记录与会话都删掉而检出目录原样，同一文件夹再登记是新项目', async () => {
  const model = new ManualModel();
  kited = startKited(() => model);
  const running = kited;
  const kite = running.daemon.kite;
  const folder = newDir(running.root, 'notes', { 'readme.txt': '笔记\n' });
  const registered = await registerCheckout(running, folder);
  const projectId = registered.project.id;
  const thread = await createWorkspace(running, registered.checkout.id, '开始写', 'harness');
  const workspace = thread.workspace;
  const turn = await model.call(1);
  writeFiles(workspace.cwd, { 'readme.txt': '工作区里改过\n', 'draft.txt': '未提交的草稿\n' });
  expect(workspace.kind).toBe('worktree');
  expect(gitOk(folder, 'show-ref', '--verify', `refs/heads/${workspace.branch}`)).toBe(true);
  const head = git(folder, 'rev-parse', 'HEAD');

  await kite.deleteProject(projectId);

  expect(turn.signal.aborted).toBe(true);
  expect(kite.registry.get(projectId)).toBeUndefined();
  expect(kite.store.projects().map((project) => project.id)).not.toContain(projectId);
  expect(kite.store.checkouts()).toEqual([]);
  expect(kite.store.workspaces()).toEqual([]);
  expect(kite.store.thread(thread.id)).toBeNull();
  expect(lexists(join(running.home, 'sessions', thread.id))).toBe(false);
  expect(lexists(workspace.cwd)).toBe(false);
  expect(git(folder, 'worktree', 'list', '--porcelain')).not.toContain(workspace.cwd);
  expect(gitOk(folder, 'show-ref', '--verify', `refs/heads/${workspace.branch}`)).toBe(false);
  const snapshot = snapshotRef(workspace.id);
  expect(git(folder, 'show', `${snapshot}:draft.txt`)).toBe('未提交的草稿');
  expect(git(folder, 'show', `${snapshot}:readme.txt`)).toBe('工作区里改过');
  expect(read(join(folder, 'readme.txt'))).toBe('笔记\n');
  expect(git(folder, 'rev-parse', 'HEAD')).toBe(head);
  expect(git(folder, 'status', '--porcelain')).toBe('');

  const again = await registerCheckout(running, folder);
  expect(again.project.id).not.toBe(projectId);
  expect(again.checkout.path).toBe(folder);
  expect(kite.registry.get(again.project.id)).toMatchObject({ name: 'notes' });
}, 1_000);

// ---- 工作区集成与检出现场推送 ----

/** 直接在裸仓库的分支上加一个提交（沿用父提交的文件），模拟另一台机器刚推了提交；返回这个提交。 */
function advanceRemote(bare: string, branch: string, message: string): string {
  const ref = `refs/heads/${branch}`;
  const commit = git(bare, 'commit-tree', `${ref}^{tree}`, '-p', ref, '-m', message);
  git(bare, 'update-ref', ref, commit);
  return commit;
}

/** 登记一个普通文件夹（Kite 初始化仓库），再给项目设远程，内容推到替身的裸仓库；返回检出、裸仓库路径和分支名。 */
async function remoteCheckout(k: Kited, name: string, files: Record<string, string>) {
  const folder = newDir(k.root, name, files);
  const model = await registerCheckout(k, folder);
  const { url, bare } = (remotes ??= startFakeGit()).create(name);
  const set = await k.call('PUT', `/project-registry/${model.project.id}/remote`, { remote: url });
  if (set.status !== 200) throw new Error(`设远程失败：${set.status} ${JSON.stringify(set.body)}`);
  return { folder, model, bare, branch: git(folder, 'branch', '--show-current') };
}

/** 建一个工作区（不带线程），等它准备好。 */
async function openWorkspace(k: Kited, checkoutId: string): Promise<WorkspaceModel['workspace']> {
  const created = await k.call('POST', '/workspaces', { checkout: checkoutId });
  expect(created.status).toBe(200);
  const workspace = (created.body as WorkspaceModel).workspace;
  await k.waitEvent((e) => e.type === 'workspace.changed' && e.workspaceId === workspace.id && e.status === 'open');
  return ((await k.call('GET', `/workspaces/${workspace.id}`)).body as WorkspaceModel).workspace;
}

/*
 * 现场归用户（真实回归方向：以前 Kite 初始化的文件夹建工作区时会把现场改动提交成「Kite：保存主文件夹里的改动」）。
 * 建工作区经异步准备和 git worktree add，现场的 HEAD、暂存区和改动都不动，工作区从检出 HEAD 开始；
 * 集成直接拒绝；远程领先时现场推送先真实 fetch，判定分叉后拒绝，不在现场提交或合并。
 */
test('现场有未提交改动时建工作区不自动提交，集成和远程领先时的推送都拒绝，现场与远程不变', async () => {
  kited = startKited();
  const { folder, model, bare, branch } = await remoteCheckout(kited, 'draft', { 'a.txt': '已提交\n' });
  const remoteHead = advanceRemote(bare, branch, '另一台机器的提交');
  writeFiles(folder, { 'a.txt': '现场改动\n', 'new.txt': '新文件\n' });
  const head = git(folder, 'rev-parse', 'HEAD');
  const before = repoState(folder);

  const workspace = await openWorkspace(kited, model.checkout.id);
  expect(repoState(folder)).toBe(before);
  expect(workspace.base).toBe(head);
  expect(read(join(workspace.cwd, 'a.txt'))).toBe('已提交\n');
  expect(existsSync(join(workspace.cwd, 'new.txt'))).toBe(false);

  writeFiles(workspace.cwd, { 'w.txt': '工作区\n' });
  expect((await kited.call('POST', `/workspaces/${workspace.id}/adopt`)).status).toBe(409);
  expect((await kited.call('POST', `/checkouts/${model.checkout.id}/push`, { message: '现场提交' })).status).toBe(409);
  expect(repoState(folder)).toBe(before);
  expect(git(bare, 'rev-parse', `refs/heads/${branch}`)).toBe(remoteHead);
});

/*
 * 经真实 git fetch/merge/push 与 http-backend：远程领先、现场干净时推送只把现场快进到远程；
 * 现场有新改动时提交并推送；切换到远程尚无的新分支时也能建立分支，跟踪引用与 sync 随之更新。
 */
test('现场推送在远程领先时快进，现场领先时提交并推送，也能建立远程缺少的分支，sync 显示一致', async () => {
  kited = startKited();
  const { folder, model, bare, branch } = await remoteCheckout(kited, 'site', { 'a.txt': 'a\n' });
  const remoteHead = advanceRemote(bare, branch, '另一台机器的提交');
  expect((await kited.call('POST', `/checkouts/${model.checkout.id}/push`, {})).status).toBe(200);
  expect(git(folder, 'rev-parse', 'HEAD')).toBe(remoteHead);

  writeFiles(folder, { 'local.txt': '现场\n' });
  const pushed = await kited.call('POST', `/checkouts/${model.checkout.id}/push`, { message: '现场提交' });
  expect(pushed.status).toBe(200);
  expect(pushed.body).toEqual({ branch, dirty: false, ahead: 0, behind: 0 });
  const [subject, parents, head] = git(folder, 'log', '-1', '--format=%s%n%P%n%H').split('\n');
  expect(subject).toBe('现场提交');
  expect(parents!.split(' ')[0]).toBe(remoteHead);
  expect(git(bare, 'rev-parse', `refs/heads/${branch}`)).toBe(head!);
  expect((await kited.call('GET', `/checkouts/${model.checkout.id}/sync`)).body).toEqual(pushed.body);

  git(folder, 'switch', '-q', '-c', 'new-branch');
  expect(gitOk(bare, 'show-ref', '--verify', 'refs/heads/new-branch')).toBe(false);
  const created = await kited.call('POST', `/checkouts/${model.checkout.id}/push`, {});
  expect(created.status).toBe(200);
  expect(created.body).toEqual({ branch: 'new-branch', dirty: false, ahead: 0, behind: 0 });
  expect(git(bare, 'rev-parse', 'refs/heads/new-branch')).toBe(git(folder, 'rev-parse', 'HEAD'));
  expect((await kited.call('GET', `/checkouts/${model.checkout.id}/sync`)).body).toEqual(created.body);
});

/*
 * 经真实 git fetch/merge/push 与 http-backend：推送前远程又多了另一台机器的提交（替身在 receive-pack 引用广告前注入），
 * 推送在客户端被判非快进而被拒；kited 重新拉取、把远程合进来再推，远程和主目录都包含双方的提交。
 */
test('集成推送被拒后重新拉取合并再推送，远程与主目录包含双方的提交', async () => {
  kited = startKited();
  const { folder, model, bare, branch } = await remoteCheckout(kited, 'app', { 'a.txt': 'a\n' });
  const workspace = await openWorkspace(kited, model.checkout.id);
  writeFiles(workspace.cwd, { 'w.txt': '工作区\n' });

  let late: string | undefined;
  let pushes = 0;
  remotes!.beforePush = () => {
    if (pushes++ === 0) late = advanceRemote(bare, branch, '推送前刚到的提交');
  };
  const adopted = await kited.call('POST', `/workspaces/${workspace.id}/adopt`);
  expect(adopted.status).toBe(200);
  expect(adopted.body).toMatchObject({ status: 'adopted', push: { status: 'pushed' } });
  expect(pushes).toBe(2);

  const head = git(folder, 'rev-parse', 'HEAD');
  expect(git(bare, 'rev-parse', `refs/heads/${branch}`)).toBe(head);
  expect(gitOk(folder, 'merge-base', '--is-ancestor', late!, head)).toBe(true);
  expect(git(folder, 'show', `${head}:w.txt`)).toBe('工作区');
  expect(git(folder, 'status', '--porcelain')).toBe('');
});

// ---- 没有远程的项目以各工作机的检出互为远程 ----

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
