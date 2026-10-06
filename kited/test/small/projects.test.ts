/**
 * 项目以远程仓库为身份（docs/项目与远程仓库.md）：经 HTTP 登记、clone、迁移同步，
 * kited 与账号服务替身、托管仓库（git http-backend）和目录上报之间的交接。集成与现场推送见 integration.test.ts。
 */
import { afterEach, expect, test } from 'bun:test';
import { realpathSync, rmSync, symlinkSync } from 'node:fs';
import { join } from 'node:path';
import { AccountClient } from '../../src/account-client.ts';
import { Bus } from '../../src/events.ts';
import { Kite } from '../../src/kite.ts';
import type { Checkout, Project, WorkspaceModel } from '../../src/model.ts';
import { Store } from '../../src/store.ts';
import { type FakeAccount, startFakeAccount } from '../fake-account.ts';
import { call, type Kited, type KitedProcess, registerCheckout, spawnKited, startKited } from '../harness.ts';
import { git, lexists, makeTemp, newDir, newRepo, read, until } from '../util.ts';

let kited: Kited | undefined;
let child: KitedProcess | undefined;
let account: FakeAccount | undefined;
const dirs: string[] = [];
const releases: Array<() => void> = [];
afterEach(async () => {
  for (const release of releases.splice(0)) release();
  await kited?.stop();
  kited = undefined;
  await child?.kill('SIGTERM');
  child = undefined;
  account?.stop();
  account = undefined;
  for (const dir of dirs.splice(0)) rmSync(dir, { recursive: true, force: true });
});

/** 等账号替身收到的目录快照里，这个检出和它的项目都带上 remote。 */
function reported(account: FakeAccount, checkoutId: string, remote: string) {
  return until(() => {
    const snapshot = account.snapshot;
    const checkout = snapshot?.checkouts.find((entry) => entry.id === checkoutId);
    const project = snapshot?.projects.find((entry) => entry.id === checkout?.projectId);
    return checkout?.remote === remote && project?.remote === remote && snapshot;
  }, `目录上报带上 ${remote}`, 900);
}

/*
 * 几条真实 git 命令与账号服务的交接：git init、写 .gitignore、初始提交，向账号建托管项目，
 * remote add 后经 git http-backend 推到托管裸仓库；目录上报随登记发出。
 * 迁移完成后同步一次：登记表、git remote set-url、SQLite 与目录上报交接，账号服务据新远程回收托管仓库。
 */
test('普通文件夹登记后推到新建的托管仓库并上报远程，迁移后同步把 origin 改到新地址并上报新远程', async () => {
  kited = startKited();
  const folder = newDir(kited.root, 'notes', { 'readme.txt': '笔记\n' });
  const model = await registerCheckout(kited, folder);
  const hosted = kited.account.projects.get(model.project.id)!;
  expect(hosted.hosted).toBe(true);
  expect(model.project.remote).toBe(hosted.remote);
  expect(model.checkout.remote).toBe(hosted.remote);
  expect(git(folder, 'remote', 'get-url', 'origin')).toBe(hosted.url);

  const bare = join(kited.account.repos, `${hosted.id}.git`);
  const head = git(folder, 'rev-parse', 'HEAD');
  expect(git(bare, 'rev-parse', `refs/heads/${git(folder, 'branch', '--show-current')}`)).toBe(head);
  expect(git(bare, 'ls-tree', '--name-only', head).split('\n').sort()).toEqual(['.gitignore', 'readme.txt']);
  expect(git(bare, 'show', `${head}:.gitignore`)).toBe(read(join(folder, '.gitignore')).replace(/\n$/, ''));
  expect(git(folder, 'status', '--porcelain')).toBe('');
  await reported(kited.account, model.checkout.id, hosted.remote);

  const moved = kited.account.migrate(model.project.id, 'https://example.test/Owner/Notes.git');
  await kited.daemon.kite.syncProjects();
  expect(git(folder, 'remote', 'get-url', 'origin')).toBe('https://example.test/Owner/Notes.git');
  expect(moved.remote).toBe('example.test/owner/notes');
  expect((await kited.call('GET', '/checkouts')).body).toEqual([{ ...model.checkout, remote: moved.remote }]);
  expect((await kited.call('GET', '/projects')).body).toEqual([{ ...model.project, remote: moved.remote }]);
  await reported(kited.account, model.checkout.id, moved.remote);
});

/*
 * 两处都看 homedir()：同步目录（Dropbox 等）的判定和 clone 的默认位置。Bun 在进程启动时缓存 homedir()，
 * 本进程里的 kited 会用真实的 HOME（clone 会落到真实的 ~/code），所以起子进程，让它从启动起就用 setup.ts 的隔离 HOME。
 * 同步目录里的普通文件夹由 Kite git init，仓库本体放进 Kite 目录、按检出 ID 命名，文件夹里只留 .git 指针，再推到托管远程；
 * 另一份检出经真实 git clone（托管仓库的 http-backend）后按 origin 登记，应得到同一项目；目标非空时不碰用户文件。
 */
test('同步目录里的普通文件夹把仓库放进 Kite 目录，按托管地址 clone 到 ~/code 下得到同一项目，目标非空时拒绝', async () => {
  const root = makeTemp('clone-checkout-');
  dirs.push(root);
  const home = join(root, 'kite');
  account = startFakeAccount(join(root, 'account'));
  child = await spawnKited(home, account);
  const dropbox = newDir(process.env.HOME!, `Dropbox/kite-projects-${crypto.randomUUID()}`);
  dirs.push(dropbox);
  const source = newDir(dropbox, 'source', { 'a.txt': '原始\n' });
  const first = await call(child.url, 'POST', '/checkouts', { path: source });
  expect(first.status).toBe(200);
  expect(git(source, 'rev-parse', '--absolute-git-dir')).toBe(realpathSync(join(home, 'repos', `${first.body.checkout.id}.git`)));
  const project = first.body.project as Project;
  const url = account.projects.get(project.id)!.url;
  const host = project.remote.split('/')[0]!;
  dirs.push(join(process.env.HOME!, 'code', host));

  const cloned = await call(child.url, 'POST', '/checkouts', { remote: url });
  expect(cloned.status).toBe(200);
  const model = cloned.body as WorkspaceModel;
  const expected = join(process.env.HOME!, 'code', ...project.remote.split('/'));
  expect(model.project).toEqual(project);
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
  const source = newDir(running.root, 'source', { 'a.txt': '原始\n' });
  const first = await registerCheckout(running, source);
  const remote = running.account.projects.get(first.project.id)!.url;
  const parent = newRepo(running.root, 'parent', { 'parent.txt': '父目录\n' });
  const target = join(parent, 'cloned');
  const alias = join(running.root, 'alias');
  symlinkSync(parent, alias);
  const held = Promise.withResolvers<void>();
  const release = Promise.withResolvers<void | Response>();
  releases.push(() => release.resolve());
  let fetches = 0;
  running.account.beforeFetch = () => {
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
  account = startFakeAccount(join(root, 'account'));
  const fake = account;
  const store = new Store(join(home, 'kite.sqlite'));
  const kite = new Kite(store, home, new Bus(), { lightTasks: false },
    new AccountClient(() => ({ url: fake.url, token: fake.token })));
  const held = Promise.withResolvers<void>();
  const release = Promise.withResolvers<void>();
  releases.push(() => release.resolve());
  const completed: string[] = [];
  let stopping: Promise<void> | undefined;
  try {
    const source = newDir(root, 'source', { 'a.txt': '关闭前收到的 clone\n' });
    const first = await kite.registerCheckout({ path: source });
    const remote = fake.projects.get(first.project.id)!.url;
    const target = join(root, 'cloned');
    fake.beforeFetch = () => { held.resolve(); return release.promise; };
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
