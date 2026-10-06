/**
 * 项目以远程仓库为身份（docs/项目与远程仓库.md）：经 HTTP 登记、clone、迁移同步，
 * kited 与账号服务替身、托管仓库（git http-backend）和目录上报之间的交接。集成与现场推送见 integration.test.ts。
 */
import { afterEach, expect, test } from 'bun:test';
import { realpathSync, rmSync } from 'node:fs';
import { join } from 'node:path';
import type { Checkout, Project, WorkspaceModel } from '../../src/model.ts';
import { type FakeAccount, startFakeAccount } from '../fake-account.ts';
import { call, type Kited, type KitedProcess, registerCheckout, spawnKited, startKited } from '../harness.ts';
import { git, lexists, makeTemp, newDir, read, until } from '../util.ts';

let kited: Kited | undefined;
let child: KitedProcess | undefined;
let account: FakeAccount | undefined;
const dirs: string[] = [];
afterEach(async () => {
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
