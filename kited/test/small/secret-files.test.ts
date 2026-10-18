/**
 * 设了路径的项目密钥（docs/kited.md「凭据」，docs/工具审批与提问.md「密钥请求」，docs/harness-主循环.md「credentials」）：
 * 添加项目时把文件夹里被忽略的环境变量文件存成项目密钥，宿主在 setup 之前把它写进工作树、密钥变化时重写进本机这个项目的所有工作区；
 * 这些文件对代理只读，要改其中一项用 credentials 的请求动作，由用户在卡片里填写。
 * 自研后端线程的模型用 ManualModel，不起 Claude Code；命令在真实沙箱里跑。
 */
import { afterEach, expect, test } from 'bun:test';
import { chmodSync, existsSync, statSync } from 'node:fs';
import { join } from 'node:path';
import type { Credential } from '../../src/account-data/credentials.ts';
import type { RegisteredProject } from '../../src/account-data/registry.ts';
import type { Envelope } from '../../src/events.ts';
import type { Input, Json, ModelItem, ModelRequest, ToolResult } from '../../src/harness/types.ts';
import type { Workspace, WorkspaceModel } from '../../src/model.ts';
import { checkoutPath } from '../../src/paths.ts';
import type { DisplayState } from '../../src/transcript/protocol.ts';
import type { Ask } from '../../src/waiting.ts';
import { chatgptLogin, type Kited, machine, startKited } from '../harness.ts';
import { item, ManualModel } from '../harness-loop.ts';
import { commitAll, git, newRepo, read, until, writeFiles } from '../util.ts';

let kited: Kited | undefined;
afterEach(async () => {
  await kited?.stop();
  kited = undefined;
});

const mark = (k: Kited) => k.events.length;
const after = (k: Kited, since: number) => (e: Envelope) => k.events.indexOf(e) >= since;

/** 起一个 kited，写好 ChatGPT 订阅登录：建工作区前的环境检查按默认角色的模型看厂商是否已登录。 */
function start(model?: ManualModel): Kited {
  const k = kited = startKited(model ? () => model : undefined);
  chatgptLogin(k.home);
  return k;
}

async function addProject(k: Kited, body: Record<string, unknown>): Promise<RegisteredProject> {
  const r = await k.call('POST', '/project-registry', body);
  if (r.status !== 200) throw new Error(`添加项目失败：${r.status} ${JSON.stringify(r.body)}`);
  return r.body as RegisteredProject;
}

/** 建工作区（可带首条消息），等准备结束（open 或 failed），返回准备结束时的工作区与首个线程。 */
async function openWorkspace(k: Kited, project: string, prompt?: string): Promise<{ workspace: Workspace; thread?: string }> {
  const created = await k.call('POST', '/workspaces', { project, ...(prompt ? { prompt } : {}) });
  if (created.status !== 200) throw new Error(`建工作区失败：${created.status} ${JSON.stringify(created.body)}`);
  const model = created.body as WorkspaceModel;
  const id = model.workspace.id;
  const done = await k.waitEvent((e) => e.type === 'workspace.changed' && e.workspaceId === id && (e.status === 'open' || e.status === 'failed'));
  return { workspace: { ...model.workspace, status: (done as Extract<Envelope, { type: 'workspace.changed' }>).status }, thread: model.threads[0]?.instanceId };
}

async function createSecret(k: Kited, projectId: string, name: string, path: string, value: string): Promise<string> {
  const r = await k.call('POST', '/credentials', { type: 'secret', name, projectId, meta: { kind: 'file', path }, secret: { value } });
  if (r.status !== 201) throw new Error(`存密钥失败：${r.status} ${JSON.stringify(r.body)}`);
  return (r.body as Credential).id;
}

const calledItem = (id: string, name: string, args: Json): ModelItem => ({ ...item(id, name), call: { id, name, arguments: args } });
const resultOf = (request: ModelRequest, callId: string): ToolResult | undefined => {
  const found = request.history.find((entry) => entry.type === 'tool_result' && entry.callId === callId);
  return found?.type === 'tool_result' ? found.result : undefined;
};
const inputs = (request: ModelRequest): Input[] => request.history.flatMap((entry) => entry.type === 'input' ? [entry.input] : []);
/** 请求里宿主交来的、写着这个请求 ID 的那一条输入（只能有一条）。 */
const kiteInput = (request: ModelRequest, askId: string): string => {
  const found = inputs(request).filter((input) => input.source === 'kite' && input.text.includes(askId));
  expect(found).toHaveLength(1);
  return found[0]!.text;
};
/** 等 since 之后线程的 asks 里出现第一项是 first（密钥名或变量名）的密钥请求。 */
async function secretAsk(k: Kited, threadId: string, since: number, first: string): Promise<Ask> {
  const match = (ask: Ask) => ask.kind === 'secret' && (ask.secrets[0]?.name ?? ask.secrets[0]?.key) === first;
  const event = await k.waitEvent((e) => e.type === 'asks' && e.threadId === threadId && e.asks.some(match) && after(k, since)(e));
  return (event as Extract<Envelope, { type: 'asks' }>).asks.find(match)!;
}
const waitIdle = (k: Kited, threadId: string, since: number) => k.waitEvent((e) => e.type === 'idle' && e.threadId === threadId && after(k, since)(e));

/*
 * 文件系统与几个部分的配合：check 用 git 找文件夹里任意层级被忽略的 .env、.env.*（node_modules 里的、被跟踪的不算）；
 * 添加时从文件夹读出内容存成项目密钥，建工作区时宿主在 .kite/setup 运行之前写进工作树，权限 0600。
 * setup 读 .env 写出标记文件，证明顺序；写晚了标记里是「没有」。
 */
test('check 列出文件夹里任意层级被忽略的环境变量文件，带 .env 添加后建工作区时 .env 在 setup 之前写进工作树、权限 0600', async () => {
  const k = start();
  const env = 'PORT=3000\nTOKEN=本机的值\n';
  const folder = newRepo(k.root, 'web', {
    '.gitignore': '.env\n.env.*\nnode_modules/\nsaw-env\n', 'app.js': 'console.log(1)\n',
    '.kite/setup': '#!/bin/sh\nif [ -f .env ]; then cp .env saw-env; else echo 没有 > saw-env; fi\n',
    'config/.env.defaults': 'PORT=80\n', '.env': env, 'services/api/.env.local': 'DB=local\n', 'node_modules/pkg/.env': 'X=1\n',
  }, null);
  chmodSync(join(folder, '.kite/setup'), 0o755);
  git(folder, 'add', '-f', 'config/.env.defaults');
  commitAll(folder, '加 setup 与被跟踪的默认值');

  const checked = await k.call('POST', '/project-registry/check', { path: folder });
  expect(checked.status).toBe(200);
  expect(checked.body.remote).toBeNull();
  expect([...checked.body.envFiles].sort()).toEqual(['.env', 'services/api/.env.local']);

  const project = await addProject(k, { path: folder, envFiles: [{ path: '.env' }] });
  const { workspace } = await openWorkspace(k, project.id);
  expect(workspace.status).toBe('open');
  expect(read(join(workspace.cwd, 'saw-env'))).toBe(env);
  expect(read(join(workspace.cwd, '.env'))).toBe(env);
  expect(statSync(join(workspace.cwd, '.env')).mode & 0o777).toBe(0o600);
}, 1000);

/*
 * 几个部分的配合：环境变量文件写 {path, from} 时，from 是这台工作机上文件夹之外的绝对路径，由处理请求的 kited 自己读出内容，
 * 经 http 校验、添加流程存成设了路径的项目密钥，建工作区时宿主写进工作树。文件夹里同一路径另有一份内容不同的 .env，
 * 工作树里是 from 那份，证明读的是 from 而不是文件夹。from 指向不存在的文件时整个添加失败，返回 404，登记表里没有这个项目。
 */
test('环境变量文件写 from 指向文件夹外的文件：存成路径为 .env 的项目密钥，建工作区后工作树里是那个文件的内容；文件不存在时 404 且不登记项目', async () => {
  const k = start();
  const folder = newRepo(k.root, 'web', { '.gitignore': '.env\n', 'a.txt': 'a\n', '.env': 'FROM=文件夹\n' }, null);
  const elsewhere = join(k.root, 'elsewhere');
  const env = 'PORT=4000\nTOKEN=别处的值\n';
  writeFiles(elsewhere, { 'app.env': env });

  const missing = await k.call('POST', '/project-registry', { path: folder, envFiles: [{ path: '.env', from: join(elsewhere, 'missing.env') }] });
  expect(missing.status).toBe(404);
  expect((await k.call('GET', '/project-registry')).body).toEqual([]);

  const project = await addProject(k, { path: folder, envFiles: [{ path: '.env', from: join(elsewhere, 'app.env') }] });
  const secrets = (await k.call('GET', `/credentials?type=secret&projectId=${project.id}`)).body as Credential[];
  expect(secrets.filter((c) => c.meta.path === '.env')).toEqual([expect.objectContaining({ projectId: project.id })]);
  const { workspace } = await openWorkspace(k, project.id);
  expect(workspace.status).toBe('open');
  expect(read(join(workspace.cwd, '.env'))).toBe(env);
}, 1000);

/** 检出 info/exclude 里 Kite 两行标记之间的行：宿主记下的这个项目设了路径的密钥。 */
function excludedSecrets(k: Kited, projectId: string): string[] {
  const lines = read(join(checkoutPath(k.home, projectId), 'info', 'exclude')).split('\n');
  const start = lines.indexOf('# Kite：项目密钥写进工作区的文件，不进 Git');
  const end = lines.indexOf('# Kite：以上', start);
  return start < 0 || end < 0 ? [] : lines.slice(start + 1, end).filter(Boolean);
}

/*
 * 几个部分的配合：凭据的修改经账号级数据通知到宿主，宿主把新内容重写进本机这个项目所有打开的工作区；
 * 路径改了时旧路径上的文件删掉、新路径写上，检出 info/exclude 里的那一段跟着换掉旧路径。
 * git 怎么解析 info/exclude（锚定路径、通配符转义）要跑起来才知道：项目 .gitignore 没忽略、也没被跟踪的路径
 * （名字里带通配符字符 [ ]，没转义时规则匹配不到它）照样写进新工作区，git check-ignore 认的是检出 info/exclude 里
 * 标记之间的那条规则，集成（快照与合入里的 git add -A）后检出主线上没有这个文件。
 * 曾经的做法是没被项目 .gitignore 忽略就拒绝：只在本机 info/exclude 或全局忽略里忽略的 .env 换台机器整个项目建不出工作区，
 * .gitignore 之后改了，集成与同步又会把它提交推走。
 * 路径上是项目跟踪的文件时不写，建工作区准备失败，失败事件里带这个路径。
 */
test('改密钥内容后本机这个项目打开的各工作区里的文件都换成新内容，改路径后旧文件删掉、新路径写上；没被 .gitignore 忽略的路径照样写进新工作区、集成后不进主线；项目跟踪的文件所在路径建工作区准备失败且不改文件', async () => {
  const k = start();
  const folder = newRepo(k.root, 'api', { '.gitignore': '.env\nsecrets/\n', 'a.txt': 'a\n' }, null);
  const project = await addProject(k, { path: folder });
  const secret = await createSecret(k, project.id, 'dotenv', '.env', 'A=1\n');
  const one = (await openWorkspace(k, project.id)).workspace;
  const two = (await openWorkspace(k, project.id)).workspace;
  for (const w of [one, two]) expect(read(join(w.cwd, '.env'))).toBe('A=1\n');

  expect((await k.call('PUT', `/credentials/${secret}`, { secret: { value: 'A=2\n' } })).status).toBe(200);
  await until(() => [one, two].every((w) => read(join(w.cwd, '.env')) === 'A=2\n'), '两个工作区的 .env 换成新内容', 800);

  expect((await k.call('PUT', `/credentials/${secret}`, { meta: { kind: 'file', path: 'secrets/app.env' } })).status).toBe(200);
  await until(() => [one, two].every((w) => !existsSync(join(w.cwd, '.env')) && existsSync(join(w.cwd, 'secrets/app.env'))),
    '旧路径删掉、新路径写上', 800);
  for (const w of [one, two]) expect(read(join(w.cwd, 'secrets/app.env'))).toBe('A=2\n');
  expect(excludedSecrets(k, project.id)).toEqual(['/secrets/app.env']);

  const checkout = checkoutPath(k.home, project.id);
  const leak = 'leak[1].txt';
  await createSecret(k, project.id, 'leak', leak, 'L=1\n');
  const three = (await openWorkspace(k, project.id)).workspace;
  expect(three.status).toBe('open');
  expect(read(join(three.cwd, leak))).toBe('L=1\n');
  const listed = excludedSecrets(k, project.id);
  expect(listed).toHaveLength(2);
  expect(listed).toContain('/secrets/app.env');
  const [, source, pattern, path] = /^(.*):\d+:(.*)\t(.*)$/.exec(git(three.cwd, 'check-ignore', '-v', '--', leak)) ?? [];
  expect({ source, path }).toEqual({ source: join(checkout, 'info', 'exclude'), path: leak });
  expect(listed).toContain(pattern ?? '没有匹配的规则');
  writeFiles(three.cwd, { 'b.txt': 'b\n' });
  const adopted = await k.call('POST', `/workspaces/${three.id}/adopt`);
  expect(adopted.body).toMatchObject({ status: 'adopted', push: { status: 'local' } });
  const mainline = git(checkout, 'ls-tree', '-r', '--name-only', 'refs/heads/main').split('\n');
  expect(mainline).toContain('b.txt');
  expect(mainline).not.toContain(leak);

  await createSecret(k, project.id, 'tracked', 'a.txt', 'T=1\n');
  const failed = (await openWorkspace(k, project.id)).workspace;
  expect(failed.status).toBe('failed');
  expect(read(join(failed.cwd, 'a.txt'))).toBe('a\n');
  const reported = k.events.filter((e) => 'workspaceId' in e && e.workspaceId === failed.id && (e.type === 'workspace.error' || e.type === 'workspace.setup'));
  expect(JSON.stringify(reported)).toContain('a.txt');
}, 1000);

/*
 * 宿主、工具与沙箱的配合：patch 拒绝修改宿主写进工作区的密钥文件并提示改用 credentials 的请求，
 * shell 的操作系统沙箱不许写它（依赖 macOS sandbox-exec 按路径拒绝写入），read 照常能读。
 */
test('代理改不了宿主写进工作区的 .env：patch 报错并提示用 credentials 的 request，shell 追加被沙箱拒绝，read 能读到内容', async () => {
  const model = new ManualModel();
  const k = start(model);
  const env = 'PORT=3000\nNAME=demo\n';
  const folder = newRepo(k.root, 'svc', { '.gitignore': '.env\n', 'a.txt': 'a\n', '.env': env }, null);
  const project = await addProject(k, { path: folder, envFiles: [{ path: '.env' }] });
  const { workspace, thread } = await openWorkspace(k, project.id, '改一下端口');
  const first = await model.call(1);
  expect(first.request.allowedTools).toEqual(expect.arrayContaining(['patch', 'shell', 'read']));
  await first.response.emit({ type: 'item', item: calledItem('patch-env', 'patch', {
    operations: [{ type: 'update_file', path: '.env', diff: '@@\n PORT=3000\n-NAME=demo\n+NAME=改了' }],
  }) });
  await first.response.emit({ type: 'item', item: calledItem('shell-env', 'shell', { description: '追加一行', command: 'echo x >> .env' }) });
  await first.response.emit({ type: 'item', item: calledItem('read-env', 'read', { path: '.env' }) });
  first.response.complete();

  const second = await model.call(2);
  const patched = resultOf(second.request, 'patch-env');
  expect(patched?.status).toBe('error');
  expect(patched?.output).toContain('credentials');
  expect(resultOf(second.request, 'shell-env')?.status).not.toBe('success');
  const readResult = resultOf(second.request, 'read-env');
  expect(readResult?.status).toBe('success');
  expect(readResult?.output).toContain('NAME=demo');
  expect(read(join(workspace.cwd, '.env'))).toBe(env);
  const since = mark(k);
  second.response.complete();
  await waitIdle(k, thread!, since);
}, 1000);

/*
 * 几个部分的配合：credentials 的请求动作一次要几项，工具把请求存进库就返回请求 ID，线程状态的 asks 里挂出一个密钥请求
 * （逐项带文件与变量名或密钥名），回合照常往下走。用户按请求顺序逐项回应、没填的为 null：宿主先存进凭据，填了几项存几项，
 * 同一个 .env 里填了的几项一起写进文件（逐项各写一次时后写的会盖掉先写的），按 dotenv 的写法替换那几行（没填的行与其他行保留）
 * 并重写进工作区，没填的独立密钥不存；再把逐项写明存好与没填、不带用户填的值的结果作为来源为 kite 的输入交给线程
 * （空闲的开始新回合，在跑的在下一次请求里纳入）。Line 代处理（带 X-Kite-Source）不能回应密钥请求。独立的密钥按用户选的范围存成账号共享。
 * 用户发消息不撤下请求，之后拒绝时线程收到拒绝说明、什么也不存。审批模式为全放行且每项都带值时不问用户，直接存好并在工具结果里逐项说明。
 */
test('密钥请求不等回应：一次要几项时立即返回请求 ID、asks 里挂出逐项的请求，Line 回应得 403；用户只填一部分时只存填了的，同一 .env 里填的几行一起换成新值、没填的行和独立密钥不动，线程收到逐项写明存好与没填且不带值的输入；独立密钥可存成账号共享；发消息后请求仍在，拒绝时线程收到拒绝说明、什么也不存；全放行且每项带值时直接存好', async () => {
  const model = new ManualModel();
  const k = start(model);
  const folder = newRepo(k.root, 'shop', { '.gitignore': '.env\n', 'a.txt': 'a\n', '.env': 'NAME=demo\nPORT=3000\nMODE=dev\n# 注释\n' }, null);
  const project = await addProject(k, { path: folder, envFiles: [{ path: '.env' }] });
  const { workspace, thread } = await openWorkspace(k, project.id, '换个端口');
  const id = thread!;
  const respond = (ask: Ask, body: unknown, headers: Record<string, string> = {}) => machine(k.url).then((m) => fetch(`${k.url}/threads/${id}/waiting/${ask.id}`, {
    method: 'POST', headers: { 'content-type': 'application/json', 'X-Kite-Machine': m.id, ...headers }, body: JSON.stringify(body),
  }));
  const secretNames = async () => [
    ...((await k.call('GET', '/credentials?type=secret')).body as Credential[]),
    ...((await k.call('GET', `/credentials?type=secret&projectId=${project.id}`)).body as Credential[]),
  ].map((c) => c.name);
  const asksNow = async () => ((await k.call('GET', `/threads/${id}/state`)).body as DisplayState).asks ?? [];

  const first = await model.call(1);
  expect(first.request.allowedTools).toContain('credentials');
  let since = mark(k);
  await first.response.emit({ type: 'item', item: calledItem('setup', 'credentials', { request: [
    { file: '.env', key: 'PORT', reason: '开发服务器换个端口', value: '3001' },
    { file: '.env', key: 'NAME', reason: '换个应用名' },
    { file: '.env', key: 'MODE', reason: '切到预发环境' },
    { name: 'SENTRY_DSN', reason: '上报错误' },
  ] }) });
  first.response.complete();
  const asked = await secretAsk(k, id, since, 'PORT');
  expect(asked).toMatchObject({ kind: 'secret', secrets: [
    { file: '.env', key: 'PORT', reason: '开发服务器换个端口', value: '3001', exists: true },
    { file: '.env', key: 'NAME', reason: '换个应用名', exists: true },
    { file: '.env', key: 'MODE', reason: '切到预发环境', exists: true },
    { name: 'SENTRY_DSN', reason: '上报错误', exists: false },
  ] });
  const second = await model.call(2);
  expect(resultOf(second.request, 'setup')?.output).toContain(`已向用户要 4 项密钥，请求 ID 是 ${asked.id}`);
  since = mark(k);
  second.response.complete();
  await waitIdle(k, id, since);
  expect(await asksNow()).toEqual([asked]);

  const byLine = await respond(asked, { secret: { values: ['9999', null, null, null] } },
    { 'X-Kite-Source': JSON.stringify({ kind: 'line', machine: 'line-machine', instance: 'line-instance' }) });
  expect(byLine.status).toBe(403);
  expect((await respond(asked, { secret: { values: ['3002', null, 'staging', null] } })).status).toBe(200);
  const third = await model.call(3);
  const setup = kiteInput(third.request, asked.id);
  // 正文里的请求 ID 是随机 UUID，可能恰好含 3002（出过一次：…-5dfdc75e3002），去掉它再查不带用户填的值。
  const withoutAskId = setup.replaceAll(asked.id, '');
  expect(withoutAskId).not.toContain('3002');
  expect(withoutAskId).not.toContain('staging');
  const [summary, ...lines] = setup.split('\n');
  expect(summary).toBe(`用户回应了你的密钥请求（请求 ${asked.id}），存好 2 项，2 项用户没有填：`);
  expect(lines).toEqual([
    expect.stringMatching(/^- \.env 里的 PORT：已存好/),
    expect.stringMatching(/^- \.env 里的 NAME：用户没有填，没有存/),
    expect.stringMatching(/^- \.env 里的 MODE：已存好/),
    expect.stringMatching(/^- SENTRY_DSN：用户没有填，没有存/),
  ]);
  await until(() => read(join(workspace.cwd, '.env')) === 'NAME=demo\nPORT=3002\nMODE=staging\n# 注释\n', '.env 里 PORT 与 MODE 都换成用户填的值、NAME 不动', 800);
  expect(await secretNames()).not.toContain('SENTRY_DSN');
  expect(await asksNow()).toEqual([]);

  // 线程在跑时回应：结果在同一回合的下一次请求里纳入。
  since = mark(k);
  await third.response.emit({ type: 'item', item: calledItem('stripe', 'credentials', { request: [{ name: 'STRIPE_KEY', reason: '调支付接口' }] }) });
  third.response.complete();
  const stripe = await secretAsk(k, id, since, 'STRIPE_KEY');
  expect(stripe).toMatchObject({ kind: 'secret', secrets: [{ name: 'STRIPE_KEY', exists: false }] });
  const fourth = await model.call(4);
  expect((await respond(stripe, { secret: { values: ['sk_test_7f3a'], scope: 'account' } })).status).toBe(200);
  const shared = (await k.call('GET', '/credentials?type=secret')).body as Credential[];
  expect(shared).toContainEqual(expect.objectContaining({ name: 'STRIPE_KEY', projectId: null }));

  since = mark(k);
  await fourth.response.emit({ type: 'item', item: calledItem('webhook', 'credentials', { request: [{ name: 'WEBHOOK_SECRET', reason: '验签' }] }) });
  fourth.response.complete();
  const webhook = await secretAsk(k, id, since, 'WEBHOOK_SECRET');
  const fifth = await model.call(5);
  const stored = kiteInput(fifth.request, stripe.id);
  expect(stored.startsWith(`用户回应了你的密钥请求（请求 ${stripe.id}），存好 1 项`)).toBe(true);
  expect(stored).not.toContain('sk_test_7f3a');
  expect(k.events.filter((e) => e.type === 'idle' && e.threadId === id && after(k, since)(e))).toEqual([]);

  const text = '先不配 webhook，接着做别的';
  expect((await k.call('POST', `/threads/${id}/messages`, { id: 'skip', text, skipWaiting: webhook.id })).status).toBe(200);
  expect(await asksNow()).toEqual([webhook]);
  expect((await respond(webhook, { decision: 'deny' })).status).toBe(200);
  expect(await asksNow()).toEqual([]);

  // 全放行且每项都带值：不挂请求，直接存好。
  expect((await k.call('PUT', `/instances/${id}/approval-mode`, { mode: 'allow_all' })).body).toMatchObject({ mode: 'allow_all', effective: 'allow_all' });
  since = mark(k);
  await fifth.response.emit({ type: 'item', item: calledItem('direct', 'credentials', { request: [{ name: 'DEPLOY_HOOK', reason: '部署通知', value: 'hook-v1' }] }) });
  fifth.response.complete();
  const sixth = await model.call(6);
  expect(inputs(sixth.request).find((input) => input.id === 'skip')).toEqual({ id: 'skip', text, source: 'human' });
  expect(kiteInput(sixth.request, webhook.id)).toBe(`用户拒绝提供你请求的密钥（请求 ${webhook.id}）：WEBHOOK_SECRET`);
  const direct = resultOf(sixth.request, 'direct');
  expect(direct?.status).toBe('success');
  expect(direct?.output.startsWith('存好 1 项')).toBe(true);
  expect(direct?.output).not.toContain('hook-v1');
  expect(k.events.filter((e) => e.type === 'asks' && e.threadId === id && after(k, since)(e))).toEqual([]);
  const names = await secretNames();
  expect(names).toContain('DEPLOY_HOOK');
  expect(names).not.toContain('WEBHOOK_SECRET');
  since = mark(k);
  sixth.response.complete();
  await waitIdle(k, id, since);
}, 1000);
