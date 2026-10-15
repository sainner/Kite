/**
 * 项目登记（docs/项目与远程仓库.md）：经 HTTP 登记本机文件夹、clone 远程或另一台工作机的检出，
 * kited 与本机项目登记表、Git 平台替身上的裸仓库（git http-backend）之间的交接。集成与现场推送见 integration.test.ts，
 * 没有远程的项目在工作机之间拉取与设远程见 peer-git.test.ts。
 */
import { afterEach, expect, test } from 'bun:test';
import { realpathSync, rmSync, symlinkSync } from 'node:fs';
import { join } from 'node:path';
import GITATTRIBUTES_TEMPLATE from '../../../.claude/skills/kite-onboard/templates/gitattributes' with { type: 'text' };
import type { RegisteredProject } from '../../src/account-data/registry.ts';
import { Bus } from '../../src/events.ts';
import { Kite } from '../../src/kite.ts';
import type { Checkout, WorkspaceModel } from '../../src/model.ts';
import { Store } from '../../src/store.ts';
import { type FakeGit, startFakeGit } from '../fake-git.ts';
import { call, chatgptLogin, connect, type Kited, type KitedProcess, registerBeforeStart, registerCheckout, spawnKited, startKited, synced } from '../harness.ts';
import { git, lexists, makeTemp, newDir, newRepo, read } from '../util.ts';

let kited: Kited | undefined;
/** 同一用户的第二台工作机。 */
let second: Kited | undefined;
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
