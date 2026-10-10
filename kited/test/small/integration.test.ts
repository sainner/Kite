/**
 * 工作区集成与检出现场推送（docs/项目与远程仓库.md「工作区与集成」）：经 HTTP 接口，
 * kited 用真实 git fetch/merge/push 访问账号服务替身的托管仓库（git http-backend）。
 */
import { afterEach, expect, test } from 'bun:test';
import { existsSync } from 'node:fs';
import { join } from 'node:path';
import type { WorkspaceModel } from '../../src/model.ts';
import { type Kited, registerCheckout, startKited } from '../harness.ts';
import { git, gitOk, newDir, read, repoState, writeFiles } from '../util.ts';

let kited: Kited | undefined;
afterEach(async () => {
  await kited?.stop();
  kited = undefined;
});

/** 直接在托管裸仓库的分支上加一个提交（沿用父提交的文件），模拟另一台机器刚推了提交；返回这个提交。 */
function advanceRemote(bare: string, branch: string, message: string): string {
  const ref = `refs/heads/${branch}`;
  const commit = git(bare, 'commit-tree', `${ref}^{tree}`, '-p', ref, '-m', message);
  git(bare, 'update-ref', ref, commit);
  return commit;
}

/** 登记一个普通文件夹（托管远程），返回检出、托管裸仓库路径和分支名。 */
async function hostedCheckout(k: Kited, name: string, files: Record<string, string>) {
  const folder = newDir(k.root, name, files);
  const model = await registerCheckout(k, folder);
  const bare = join(k.account.repos, `${model.project.id}.git`);
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
  const { folder, model, bare, branch } = await hostedCheckout(kited, 'draft', { 'a.txt': '已提交\n' });
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
  const { folder, model, bare, branch } = await hostedCheckout(kited, 'site', { 'a.txt': 'a\n' });
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
  const { folder, model, bare, branch } = await hostedCheckout(kited, 'app', { 'a.txt': 'a\n' });
  const workspace = await openWorkspace(kited, model.checkout.id);
  writeFiles(workspace.cwd, { 'w.txt': '工作区\n' });

  let late: string | undefined;
  let pushes = 0;
  kited.account.beforePush = () => {
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
