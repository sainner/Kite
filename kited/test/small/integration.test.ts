/**
 * 工作区的集成与同步（docs/项目与远程仓库.md「工作区与集成」，docs/kited.md「工作区与线程的生命周期」与接口表）：
 * 检出是数据目录里的裸仓库，工作区从它开出工作树；直接合入把工作区合进主线再推送，提交 PR 把工作区分支推到远程同名分支，
 * 同步把主线合进工作区分支、不推送；拉不到远程主线时分远程要登录与暂时不可用两种情况。
 * kited 用真实 git fetch/merge/push 经 git http-backend 访问 Git 平台替身（fake-git.ts）。
 * 替身在本进程里服务，测试直接动远程时用裸仓库路径（util 的 git 是同步调用，经 http 会互相等住）。
 */
import { afterEach, expect, test } from 'bun:test';
import { rmSync } from 'node:fs';
import { dirname, join } from 'node:path';
import type { RegisteredProject } from '../../src/account-data/registry.ts';
import type { Envelope } from '../../src/events.ts';
import type { Workspace, WorkspaceModel } from '../../src/model.ts';
import { checkoutPath } from '../../src/paths.ts';
import { type FakeGit, startFakeGit } from '../fake-git.ts';
import { chatgptLogin, type Kited, startKited } from '../harness.ts';
import { ManualModel } from '../harness-loop.ts';
import { commitMainline, ENV, git, gitOk, lexists, makeTemp, newRepo, read, writeFiles } from '../util.ts';

let kited: Kited | undefined;
let remotes: FakeGit | undefined;
afterEach(async () => {
  await kited?.stop();
  kited = undefined;
  remotes?.stop();
  remotes = undefined;
});

const mark = (k: Kited) => k.events.length;
const after = (k: Kited, since: number) => (e: Envelope) => k.events.indexOf(e) >= since;

function start(model?: ManualModel): Kited {
  const k = kited = startKited(model ? () => model : undefined);
  chatgptLogin(k.home);
  return k;
}

/**
 * 在裸仓库的 branch 上加一个提交（分支还没有时是第一个提交），改这些文件：用临时索引在裸仓库里直接造提交并移动分支，
 * 一个 shell 做完，比克隆再推快得多；beforePush 钩子里同步执行时，替身的事件循环也停得短。返回这个提交。
 */
function commitOnRemote(bare: string, branch: string, files: Record<string, string>, message: string): string {
  const index = join(makeTemp('remote-index-'), 'index');
  const script = ['set -e', 'ref="refs/heads/$1"; msg="$2"; shift 2; parent=""',
    'if git rev-parse -q --verify "$ref" >/dev/null; then git read-tree "$ref"; parent="-p $ref"; fi',
    'while [ $# -gt 0 ]; do blob=$(printf %s "$2" | git hash-object -w --stdin); git update-index --add --cacheinfo "100644,$blob,$1"; shift 2; done',
    'commit=$(git commit-tree "$(git write-tree)" $parent -m "$msg")', 'git update-ref "$ref" "$commit"', 'echo "$commit"'].join('\n');
  const r = Bun.spawnSync(['sh', '-c', script, 'sh', branch, message, ...Object.entries(files).flat()],
    { cwd: bare, env: { ...ENV(), GIT_INDEX_FILE: index }, stdout: 'pipe', stderr: 'pipe' });
  rmSync(dirname(index), { recursive: true, force: true });
  if (r.exitCode !== 0) throw new Error(`往远程 ${branch} 加提交失败：${r.stderr.toString()}`);
  return r.stdout.toString().trim();
}

/** 在替身上新建裸仓库，主线上有一个初始提交；返回访问地址、裸仓库路径和初始提交。 */
function seededRemote(name: string, files: Record<string, string>) {
  const { url, bare } = (remotes ??= startFakeGit()).create(name);
  return { url, bare, initial: commitOnRemote(bare, 'main', files, '初始提交') };
}

async function addProject(k: Kited, body: Record<string, unknown>): Promise<RegisteredProject> {
  const r = await k.call('POST', '/project-registry', body);
  if (r.status !== 200) throw new Error(`添加项目失败：${r.status} ${JSON.stringify(r.body)}`);
  return r.body as RegisteredProject;
}

/** 建工作区（可带名称与首条消息），等它准备好；返回工作区与首个线程。 */
async function openWorkspace(k: Kited, project: string, extra: { name?: string; prompt?: string } = {}): Promise<{ workspace: Workspace; thread?: string }> {
  const created = await k.call('POST', '/workspaces', { project, ...extra });
  if (created.status !== 200) throw new Error(`建工作区失败：${created.status} ${JSON.stringify(created.body)}`);
  const model = created.body as WorkspaceModel;
  await k.waitEvent((e) => e.type === 'workspace.changed' && e.workspaceId === model.workspace.id && e.status === 'open');
  return { workspace: model.workspace, thread: model.threads[0]?.instanceId };
}

const workspaceOf = async (k: Kited, id: string) => ((await k.call('GET', `/workspaces/${id}`)).body as WorkspaceModel).workspace;
const post = async (k: Kited, path: string) => {
  const r = await k.call('POST', path);
  if (r.status !== 200) throw new Error(`${path} 失败：${r.status} ${JSON.stringify(r.body)}`);
  return r.body;
};

/*
 * 经真实 git fetch/merge/push 与 http-backend：直接合入把工作区的改动合进检出主线并推到远程主线；
 * 推送前远程刚多了别人的提交（替身在 receive-pack 引用广告前注入），推送在客户端被判非快进而被拒，
 * kited 重新拉取、合并再推，结果仍是已推送，远程主线同时包含双方的提交。
 */
test('直接合入：工作区的改动推到远程主线，推送时远程刚有别人的提交也重新合并后推上去，远程主线包含双方的提交', async () => {
  const k = start();
  const { url, bare } = seededRemote('app', { 'a.txt': 'a\n' });
  const project = await addProject(k, { remote: url });
  expect(project.integration).toBe('merge');
  const { workspace } = await openWorkspace(k, project.id);
  writeFiles(workspace.cwd, { 'mine.txt': '我的\n' });

  let late: string | undefined;
  let pushes = 0;
  remotes!.beforePush = () => {
    if (pushes++ === 0) late = commitOnRemote(bare, 'main', { 'others.txt': '别人\n' }, '推送前刚到的提交');
  };
  const adopted = await post(k, `/workspaces/${workspace.id}/adopt`);
  expect(adopted).toMatchObject({ status: 'adopted', push: { status: 'pushed' } });
  expect(pushes).toBeGreaterThanOrEqual(2);
  const main = git(bare, 'rev-parse', 'refs/heads/main');
  expect(main).toBe(adopted.commit);
  expect(gitOk(bare, 'merge-base', '--is-ancestor', late!, main)).toBe(true);
  expect(git(bare, 'show', 'refs/heads/main:mine.txt')).toBe('我的');
  expect(git(bare, 'show', 'refs/heads/main:others.txt')).toBe('别人');
}, 1000);

/*
 * 几条 git 命令与项目同步的配合：工作区开出后远程主线前进，项目同步拉取远程主线后按它算出工作区落后几个提交；
 * 同步把远程主线合进工作区分支（工作树随之更新，工作区自己的改动保留），落后归零。
 */
test('工作区开出后远程主线有了新提交：项目同步后工作区显示落后，同步后远程的改动合进工作树、自己的改动保留、落后归零', async () => {
  const k = start();
  const { url, bare } = seededRemote('lib', { 'a.txt': 'a\n' });
  const project = await addProject(k, { remote: url });
  const { workspace } = await openWorkspace(k, project.id);
  writeFiles(workspace.cwd, { 'mine.txt': '我的\n' });

  commitOnRemote(bare, 'main', { 'others.txt': '别人\n' }, '别人合进主线的提交');
  await k.daemon.kite.syncProjects();
  expect((await workspaceOf(k, workspace.id)).behind).toBe(1);

  const synced = await post(k, `/workspaces/${workspace.id}/sync`);
  expect(synced).toMatchObject({ status: 'synced' });
  expect(git(workspace.cwd, 'rev-parse', 'HEAD')).toBe(synced.commit);
  expect((await workspaceOf(k, workspace.id)).behind).toBe(0);
  expect(read(join(workspace.cwd, 'others.txt'))).toBe('别人\n');
  expect(read(join(workspace.cwd, 'mine.txt'))).toBe('我的\n');
}, 1000);

/*
 * 经真实 git push 与 http-backend：提交 PR 把工作区分支推到远程按工作区名生成的分支，不动远程主线和本机检出的主线；
 * 不是 GitHub 的平台不自动开 PR，给去开 PR 的网页、没有编号；工作区记下这个 PR。
 */
test('提交 PR：工作区的改动推到远程 kite/<工作区名> 分支，远程主线与本机检出的主线不动，结果是去开 PR 的网页', async () => {
  const k = start();
  const { url, bare, initial } = seededRemote('web', { 'login.txt': 'v0\n' });
  const project = await addProject(k, { remote: url });
  const changed = await k.call('PUT', `/project-registry/${project.id}/settings`, { integration: 'pullRequest' });
  expect(changed.status).toBe(200);
  expect(changed.body.integration).toBe('pullRequest');
  const { workspace } = await openWorkspace(k, project.id, { name: 'fix login page' });
  const checkout = checkoutPath(k.home, project.id);
  const localMain = git(checkout, 'rev-parse', 'refs/heads/main');

  writeFiles(workspace.cwd, { 'login.txt': 'v1\n' });
  const proposed = await post(k, `/workspaces/${workspace.id}/adopt`);
  expect(proposed.status).toBe('proposed');
  expect(proposed.branch).toBe('kite/fix-login-page');
  expect(proposed.number).toBeUndefined();
  expect(proposed.url).toContain('/compare/');
  expect(proposed.url).toContain(proposed.branch);
  expect(git(bare, 'show', `refs/heads/${proposed.branch}:login.txt`)).toBe('v1');
  expect(gitOk(bare, 'merge-base', '--is-ancestor', initial, `refs/heads/${proposed.branch}`)).toBe(true);
  expect(git(bare, 'rev-parse', 'refs/heads/main')).toBe(initial);
  expect(git(checkout, 'rev-parse', 'refs/heads/main')).toBe(localMain);
  expect((await workspaceOf(k, workspace.id)).pullRequest).toMatchObject({ branch: proposed.branch, url: proposed.url, state: 'open' });
}, 1000);

/*
 * 几个部分的配合：同步遇到冲突时工作树停在合并中途，冲突交给工作区里打开的线程（来源为 kite 的说明）；
 * 线程只改文件去掉冲突标记（沙箱里不能动 Git 元数据），回合正常结束后宿主接着做的必须是同步而不是采纳：
 * 主线合进工作区分支、主线本身不动。没有远程的项目，主线就是本机检出的主线，不经网络。
 */
test('同步冲突交给工作区里的线程：线程去掉冲突标记、回合正常结束后宿主自动接着同步成功，主线不动', async () => {
  const model = new ManualModel();
  const k = start(model);
  const folder = newRepo(k.root, 'notes', { 'c.txt': 'base\n' }, null);
  const project = await addProject(k, { path: folder });
  const checkout = checkoutPath(k.home, project.id);
  const other = (await openWorkspace(k, project.id)).workspace;
  const { workspace, thread } = await openWorkspace(k, project.id, { prompt: '改一下 c.txt' });
  const id = thread!;
  let since = mark(k);
  (await model.call(1)).response.complete();
  await k.waitEvent((e) => e.type === 'idle' && e.threadId === id && after(k, since)(e));

  writeFiles(other.cwd, { 'c.txt': 'main side\n' });
  expect(await post(k, `/workspaces/${other.id}/adopt`)).toMatchObject({ status: 'adopted', push: { status: 'local' } });
  const main = git(checkout, 'rev-parse', 'refs/heads/main');
  writeFiles(workspace.cwd, { 'c.txt': 'workspace side\n' });

  since = mark(k);
  expect(await post(k, `/workspaces/${workspace.id}/sync`)).toEqual({ status: 'conflict', files: ['c.txt'] });
  const resolving = await model.call(2);
  const inputs = resolving.request.history.flatMap((entry) => entry.type === 'input' ? [entry.input] : []);
  expect(inputs.at(-1)).toMatchObject({ source: 'kite' });
  expect(read(join(workspace.cwd, 'c.txt'))).toContain('<<<<<<<');
  writeFiles(workspace.cwd, { 'c.txt': 'resolved\n' });
  resolving.response.complete();

  const done = await k.waitEvent((e) => e.type === 'workspace.sync' && e.workspaceId === workspace.id
    && e.result.status === 'synced' && after(k, since)(e));
  const result = (done as Extract<Envelope, { type: 'workspace.sync' }>).result as { status: 'synced'; commit: string };
  expect(git(workspace.cwd, 'rev-parse', 'HEAD')).toBe(result.commit);
  expect(gitOk(workspace.cwd, 'merge-base', '--is-ancestor', main, 'HEAD')).toBe(true);
  expect(read(join(workspace.cwd, 'c.txt'))).toBe('resolved\n');
  expect(git(checkout, 'rev-parse', 'refs/heads/main')).toBe(main);
  await k.waitEvent((e) => e.type === 'idle' && e.threadId === id && after(k, since)(e));
}, 1000);

/*
 * 代码之外的东西：集成与同步先用 git fetch（LC_ALL=C）拉远程主线，远程回 401、本机没有可用凭据时 git fetch 的实际 stderr
 * 要被认成「远程要登录」，并取出带端口的主机（ls-remote 的输出见 projects.test.ts，这里是另一条 git 命令）。
 * 几个部分的配合：这个识别结果经刷新主线、同步或合进主线、HTTP 回应几层交到 App 手里。同步要先拿到远程主线，拉不到就不做：
 * 409 带上主机，本机主线上别的工作区刚合进来的改动也不合进工作区；直接合入不因拉不到而停，照常合进本机检出的主线，
 * 推送记为失败并带上主机。别的工作区的合入用 commitMainline 直接加在检出的主线上，省一次建工作区。
 */
test('远程要登录时：同步 409 带上含端口的主机、工作区不动；直接合入照常合进本机主线，推送失败并带上这个主机', async () => {
  const k = start();
  const { url, bare, initial } = seededRemote('private', { 'a.txt': 'a\n' });
  const host = new URL(url).host;
  const project = await addProject(k, { remote: url });
  const checkout = checkoutPath(k.home, project.id);
  const { workspace } = await openWorkspace(k, project.id);
  const head = git(workspace.cwd, 'rev-parse', 'HEAD');
  const others = commitMainline(checkout, { 'others.txt': '别的工作区\n' }, '别的工作区刚合进来的改动');

  remotes!.beforeFetch = () => new Response('需要登录', { status: 401, headers: { 'WWW-Authenticate': 'Basic realm="x"' } });
  const sync = await k.call('POST', `/workspaces/${workspace.id}/sync`);
  expect(sync.status).toBe(409);
  expect(sync.body).toMatchObject({ error: expect.any(String), gitLogin: host });
  expect(git(workspace.cwd, 'rev-parse', 'HEAD')).toBe(head);
  expect(lexists(join(workspace.cwd, 'others.txt'))).toBe(false);

  writeFiles(workspace.cwd, { 'mine.txt': '我的\n' });
  const adopted = await post(k, `/workspaces/${workspace.id}/adopt`);
  expect(adopted).toMatchObject({ status: 'adopted', push: { status: 'failed', message: expect.any(String), gitLogin: host } });
  expect(git(checkout, 'rev-parse', 'refs/heads/main')).toBe(adopted.commit);
  expect(gitOk(checkout, 'merge-base', '--is-ancestor', others, adopted.commit)).toBe(true);
  expect(git(checkout, 'show', 'refs/heads/main:mine.txt')).toBe('我的');
  expect(git(bare, 'rev-parse', 'refs/heads/main')).toBe(initial);
}, 1000);

/*
 * 代码之外的东西：远程暂时不可用（服务回 503）时 git fetch 的 stderr 不能被误认成要登录。
 * 几个部分的配合：拉不到远程主线时同步不报错，照用本机主线，别的工作区刚合进本机主线、还没推上去的改动照常合进这个工作区，
 * 它自己的改动保留；直接合入仍合进本机主线、推送失败且不带主机。别的工作区的合入用 commitMainline 模拟，同上。
 */
test('远程暂时不可用时：同步照用本机主线，合进别的工作区刚合入的改动；直接合入合进本机主线、推送失败且不要求登录', async () => {
  const k = start();
  const { url, bare, initial } = seededRemote('flaky', { 'a.txt': 'a\n' });
  const project = await addProject(k, { remote: url });
  const checkout = checkoutPath(k.home, project.id);
  const { workspace } = await openWorkspace(k, project.id);
  writeFiles(workspace.cwd, { 'mine.txt': '我的\n' });
  const others = commitMainline(checkout, { 'others.txt': '别的工作区\n' }, '别的工作区刚合进来、还没推上去的改动');

  remotes!.beforeFetch = () => new Response('暂时不可用', { status: 503 });
  const synced = await post(k, `/workspaces/${workspace.id}/sync`);
  expect(synced).toMatchObject({ status: 'synced' });
  expect(git(workspace.cwd, 'rev-parse', 'HEAD')).toBe(synced.commit);
  expect(gitOk(workspace.cwd, 'merge-base', '--is-ancestor', others, 'HEAD')).toBe(true);
  expect(read(join(workspace.cwd, 'others.txt'))).toBe('别的工作区\n');
  expect(read(join(workspace.cwd, 'mine.txt'))).toBe('我的\n');

  const adopted = await post(k, `/workspaces/${workspace.id}/adopt`);
  expect(adopted).toMatchObject({ status: 'adopted', push: { status: 'failed', message: expect.any(String) } });
  expect(adopted.push.gitLogin).toBeUndefined();
  expect(git(checkout, 'rev-parse', 'refs/heads/main')).toBe(adopted.commit);
  expect(git(checkout, 'show', 'refs/heads/main:mine.txt')).toBe('我的');
  expect(git(bare, 'rev-parse', 'refs/heads/main')).toBe(initial);
}, 1000);
