import { afterEach, expect, test } from 'bun:test';
import { existsSync, readFileSync, rmSync } from 'node:fs';
import { join } from 'node:path';
import { startDaemon, type Daemon } from '../../src/daemon.ts';
import type { Envelope } from '../../src/events.ts';
import { FileJournal, readJournal } from '../../src/harness/journal.ts';
import { responsesInput } from '../../src/harness/responses.ts';
import type { Json, ModelItem, ModelRequest } from '../../src/harness/types.ts';
import type { History } from '../../src/transcript/protocol.ts';
import { attachmentPath } from '../../src/workspace/attachments.ts';
import {
  addProject, after, call, createWorkspace, folderWorkspace, type Kited, listSnapshots, machine, mark, openAgent, putAttachment, startKited, waitIdle,
} from '../harness.ts';
import { input, item, ManualModel, Seen } from '../harness-loop.ts';
import { commitMainline, git, gitOk, imageSize, makeTemp, newDir, png, read, writeFiles } from '../util.ts';

const roots: string[] = [];
let kited: Kited | undefined;
let restarted: Daemon | undefined;
afterEach(async () => {
  await restarted?.stop();
  restarted = undefined;
  await kited?.stop();
  kited = undefined;
  for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true });
});

function calledItem(id: string, name: string, args: Json): ModelItem {
  return { ...item(id, name), call: { id, name, arguments: args } };
}

// HTTP 线程、模型流、受管 patch/shell、git 快照与采纳跨模块交接；第二请求前必须已有完整工具结果。
// 采纳合进的是 Kite 检出（裸仓库）的主线，导入来源的文件夹不动。
test('默认 harness 线程的真实工具只改工作树，结果和快照先于下一请求且采纳归档保留快照', async () => {
  const model = new ManualModel();
  kited = startKited(() => model);
  const kk = kited;
  // 没有远程的项目：合回只到本机主线。
  const repo = newDir(kk.root, 'project', { 'base.txt': '原始\n' });
  const project = await addProject(kk, { path: repo });
  const session = await createWorkspace(kk, project.id, '建立两个文件', 'harness');
  const checkout = session.checkout.path;

  const first = await model.call(1);
  expect(first.request.cwd).toBe(session.workspace.cwd);
  const patch = calledItem('patch-file', 'patch', {
    operations: [{ type: 'create_file', path: 'patch.txt', diff: '+来自 patch\n+' }],
  });
  const shell = calledItem('shell-file', 'shell', { description: '写入 shell 文件', command: "printf '来自 shell\\n' > shell.txt" });
  await first.response.emit({ type: 'item', item: patch });
  await first.response.emit({ type: 'item', item: shell });
  first.response.complete();

  const second = await model.call(2);
  expect(second.request.history).toContainEqual({ type: 'output', item: patch });
  expect(second.request.history).toContainEqual({ type: 'output', item: shell });
  for (const id of ['patch-file', 'shell-file']) {
    expect(second.request.history).toContainEqual(expect.objectContaining({
      type: 'tool_result', callId: id, result: expect.objectContaining({ status: 'success' }),
    }));
  }
  expect(read(join(session.workspace.cwd, 'patch.txt'))).toBe('来自 patch\n');
  expect(read(join(session.workspace.cwd, 'shell.txt'))).toBe('来自 shell\n');
  expect(existsSync(join(repo, 'patch.txt'))).toBe(false);
  expect(existsSync(join(repo, 'shell.txt'))).toBe(false);
  const snapshots = await listSnapshots(kk, session.workspace.id);
  const afterTools = snapshots.find((value) => value.toolUseIds.includes('patch-file') && value.toolUseIds.includes('shell-file'));
  expect(afterTools).toBeDefined();
  expect(git(checkout, 'show', `${afterTools!.commit}:patch.txt`)).toBe('来自 patch');
  expect(git(checkout, 'show', `${afterTools!.commit}:shell.txt`)).toBe('来自 shell');

  second.response.complete();
  await kk.waitEvent((event) => event.type === 'idle' && event.threadId === session.id);
  const adopted = await kk.call('POST', `/workspaces/${session.workspace.id}/adopt`);
  expect(adopted.status).toBe(200);
  expect(adopted.body).toMatchObject({ status: 'adopted', push: { status: 'local' } });
  expect(git(checkout, 'rev-parse', 'HEAD')).toBe(adopted.body.commit);
  expect(git(checkout, 'show', 'HEAD:patch.txt')).toBe('来自 patch');
  expect(git(checkout, 'show', 'HEAD:shell.txt')).toBe('来自 shell');
  expect(existsSync(join(repo, 'patch.txt'))).toBe(false);
  const archived = await kk.call('POST', `/workspaces/${session.workspace.id}/archive`, { force: true });
  expect(archived.status).toBe(200);
  expect(existsSync(session.workspace.cwd)).toBe(false);
  expect(gitOk(checkout, 'rev-parse', '--verify', '--quiet', `refs/kite/snapshots/${session.workspace.id}`)).toBe(true);
  expect((await listSnapshots(kk, session.workspace.id)).map((value) => value.commit)).toContain(afterTools!.commit);
}, 1000);

/*
 * 几个部分的配合：附件经 HTTP 存进附件存储并在工作区里放一份；发消息时操作层把附件 ID 换成存好的附件，harness 收下输入时
 * 把图片规整好记进 journal，适配器（OpenAI Responses 格式）把正文后的附件说明和图片交给模型；显示投影的人消息带着附件。
 * git：工作区里那份不进快照靠的是检出（裸仓库）的 info/exclude，与快照用的几条 git 命令合起来是否认这条忽略，要跑起来才知道。
 */
test('只带附件、没有正文的消息：模型收到两个附件在工作区里的路径和那张图片，记录里的人消息带着附件，工作区里那份不进之后的快照，发出的附件不能再删', async () => {
  const model = new ManualModel();
  kited = startKited(() => model);
  const kk = kited;
  const opened = await folderWorkspace(kk, newDir(kk.root, 'project', { 'base.txt': '原始\n' }));
  const { workspace, checkout } = opened;
  const id = await openAgent(kk.call, workspace.id);
  const picture = await png(6, 4);
  const note = Buffer.from('附件里的说明\n');
  const image = await putAttachment(kk, workspace.id, crypto.randomUUID(), '截图.png', picture);
  const text = await putAttachment(kk, workspace.id, crypto.randomUUID(), 'notes.txt', note);
  expect(image).toMatchObject({ status: 200, body: { name: '截图.png', mediaType: 'image/png', size: picture.length, width: 6, height: 4 } });
  expect(text).toMatchObject({ status: 200, body: { name: 'notes.txt', size: note.length } });
  expect(text.body.width).toBeUndefined();
  const refs = [image.body, text.body];
  expect(readFileSync(join(workspace.cwd, attachmentPath(image.body)))).toEqual(picture);
  expect(readFileSync(join(workspace.cwd, attachmentPath(text.body)))).toEqual(note);

  const sent = await kk.call('POST', `/threads/${id}/messages`, { id: 'only-attachments', text: '', attachments: refs.map((ref) => ref.id) });
  expect(sent.status).toBe(200);
  const first = await model.call(1);
  const user = responsesInput(first.request.history).filter((message) => message.role === 'user').at(-1)!;
  const parts = user.content as Array<{ type: string; text?: string; image_url?: string }>;
  const told = parts.flatMap((part) => part.type === 'input_text' ? [part.text!] : []).join('\n');
  for (const ref of refs) expect(told).toContain(attachmentPath(ref));
  const images = parts.filter((part) => part.type === 'input_image');
  expect(images).toHaveLength(1);
  expect(images[0]!.image_url).toStartWith('data:image/');
  expect(await imageSize(images[0]!.image_url!)).toEqual({ width: 6, height: 4 });

  // 模型改一个文件，工具批次后拍快照。
  const patch = calledItem('after-attachments', 'patch', { operations: [{ type: 'create_file', path: 'reply.txt', diff: '+看过附件\n+' }] });
  await first.response.emit({ type: 'item', item: patch });
  first.response.complete();
  const since = mark(kk);
  (await model.call(2)).response.complete();
  await waitIdle(kk, id, since);
  const snapshot = (await listSnapshots(kk, workspace.id)).find((value) => value.toolUseIds.includes('after-attachments'));
  expect(snapshot).toBeDefined();
  const files = git(checkout.path, 'ls-tree', '-r', '--name-only', snapshot!.commit).split('\n');
  expect(files).toContain('reply.txt');
  expect(files.filter((file) => file.startsWith('.kite/attachments'))).toEqual([]);
  expect(existsSync(join(workspace.cwd, attachmentPath(image.body)))).toBe(true);

  const history = (await kk.call('GET', `/threads/${id}/history`)).body as History;
  expect(history.records.flatMap(({ block }) => block.type === 'human' ? [block] : []))
    .toEqual([expect.objectContaining({ id: 'only-attachments', text: '', attachments: refs })]);
  expect((await kk.call('DELETE', `/workspaces/${workspace.id}/attachments/${image.body.id}`)).status).toBe(409);
}, 1000);

/*
 * 几个部分的配合：同一工作区两个线程的 runner 并行，各自工具批次后的快照拍整个工作区、接在同一条快照链上；
 * 触发线程写进提交说明的 Kite-Thread trailer，列快照时经 git 的 %(trailers:key=...) 读回。回退动整个工作区，有线程在忙时仍拒绝。
 */
test('同一工作区 A 的请求挂着时 B 能发消息并跑完改文件的工具批次，两批快照各带触发线程，A 在忙时回退得 409', async () => {
  const models = new Map<string, ManualModel>();
  const modelOf = (threadId: string) => {
    let model = models.get(threadId);
    if (!model) { model = new ManualModel(); models.set(threadId, model); }
    return model;
  };
  kited = startKited((thread) => modelOf(thread.id));
  const kk = kited;
  const project = await addProject(kk, { path: newDir(kk.root, 'project', { 'base.txt': '原始\n' }) });
  const a = await createWorkspace(kk, project.id, 'A 的任务', 'harness');
  const workspaceId = a.workspace.id;
  const cwd = a.workspace.cwd;
  const aFirst = await modelOf(a.id).call(1);
  const patch = (id: string, path: string, text: string) =>
    calledItem(id, 'patch', { operations: [{ type: 'create_file', path, diff: `+${text}\n+` }] });
  const resultOf = (request: ModelRequest, callId: string) => {
    const found = request.history.find((entry) => entry.type === 'tool_result' && entry.callId === callId);
    return found?.type === 'tool_result' ? found.result.status : undefined;
  };

  const started = await kk.call('POST', `/workspaces/${workspaceId}/operations/agent.start`, { operationId: 'thread-b' });
  expect(started.status).toBe(200);
  const b = started.body.instanceId as string;
  expect((await kk.call('POST', `/threads/${b}/messages`, { id: 'b-kickoff', text: 'B 的任务' })).status).toBe(200);
  const bFirst = await modelOf(b).call(1);
  expect(bFirst.request.cwd).toBe(cwd);
  await bFirst.response.emit({ type: 'item', item: patch('b-patch', 'b.txt', 'B 写的') });
  bFirst.response.complete();
  const bSecond = await modelOf(b).call(2);
  expect(resultOf(bSecond.request, 'b-patch')).toBe('success');
  const bSince = mark(kk);
  bSecond.response.complete();
  await kk.waitEvent((event) => event.type === 'idle' && event.threadId === b && after(kk, bSince)(event));
  expect(aFirst.signal.aborted).toBe(false);

  const bSnapshot = (await listSnapshots(kk, workspaceId)).find((value) => value.toolUseIds.includes('b-patch'));
  expect(bSnapshot?.threadId).toBe(b);
  const refused = await kk.call('POST', `/workspaces/${workspaceId}/restore`, { commit: bSnapshot!.commit });
  expect(refused.status).toBe(409);
  expect(aFirst.signal.aborted).toBe(false);
  expect(read(join(cwd, 'b.txt'))).toBe('B 写的\n');

  await aFirst.response.emit({ type: 'item', item: patch('a-patch', 'a.txt', 'A 写的') });
  aFirst.response.complete();
  const aSecond = await modelOf(a.id).call(2);
  expect(resultOf(aSecond.request, 'a-patch')).toBe('success');
  const aSince = mark(kk);
  aSecond.response.complete();
  await kk.waitEvent((event) => event.type === 'idle' && event.threadId === a.id && after(kk, aSince)(event));

  const snapshots = await listSnapshots(kk, workspaceId);
  const byTool = (id: string) => snapshots.find((value) => value.toolUseIds.includes(id));
  expect(byTool('a-patch')?.threadId).toBe(a.id);
  expect(byTool('b-patch')).toEqual(bSnapshot);
  // 新的在前：A 这一批接在 B 那一批后面，内容是整个工作区，含 B 先写的文件。
  expect(snapshots.indexOf(byTool('a-patch')!)).toBeLessThan(snapshots.indexOf(byTool('b-patch')!));
  expect(git(a.checkout.path, 'show', `${byTool('a-patch')!.commit}:b.txt`)).toBe('B 写的');
  expect(gitOk(a.checkout.path, 'cat-file', '-e', `${bSnapshot!.commit}:a.txt`)).toBe(false);
}, 1000);

// HTTP 采纳、git 冲突状态、自研 harness 输入来源、同一工作区线程之间的启动约束及回合结束后的自动重试必须连起来验证。
// 真实 bug：agent 的命令跑在沙箱里，Git 元数据只读，只能改文件不能 add/commit；原来自动重试只认已提交的解决，
// 冲突永远合不回去。这里只改工作树文件模拟 agent，不在沙箱外替它跑 git。
// 真实 bug：冲突转交后工作树停在合并中途（MERGE_HEAD），同一工作区的其他线程照常能开始工作、改文件；处理回合结束后
// 自动采纳先查全员空闲，有线程在忙就 409，冲突要再走一轮。处理回合期间其他线程发消息、新建带首条消息的线程都要被拒，
// 停下处理冲突的线程即放开；手动重试遗留冲突仍转交，这次回合正常结束才由宿主接着采纳。
test('采纳冲突转交一个线程处理：回合期间同一工作区的其他线程不能开始工作，停下它即放开；重试仍转交，回合结束后自动合回，用户输入与系统通知保持不同来源', async () => {
  const models = new Map<string, ManualModel>();
  const modelOf = (id: string) => {
    let model = models.get(id);
    if (!model) { model = new ManualModel(); models.set(id, model); }
    return model;
  };
  kited = startKited((thread) => modelOf(thread.id));
  const kk = kited;
  // 没有远程的项目：合回只到本机主线。
  const project = await addProject(kk, { path: newDir(kk.root, 'proj', { 'c.txt': 'base\n' }) });
  const thread = await createWorkspace(kk, project.id, '改一下 c.txt', 'harness');
  const checkout = thread.checkout.path;
  const workspaceId = thread.workspace.id;
  (await modelOf(thread.id).call(1)).response.complete();
  await waitIdle(kk, thread.id);
  const opened = await kk.call('POST', `/workspaces/${workspaceId}/threads`, { prompt: '看看文档' });
  expect(opened.status).toBe(200);
  const prompts = new Map([[thread.id, '改一下 c.txt'], [opened.body.id as string, '看看文档']]);
  (await modelOf(opened.body.id).call(1)).response.complete();
  await waitIdle(kk, opened.body.id);
  writeFiles(thread.workspace.cwd, { 'c.txt': 'session\n' });
  const mainCommit = commitMainline(checkout, { 'c.txt': 'main\n' }, '主线改了 c');

  const since = mark(kk);
  const conflict = await kk.call('POST', `/workspaces/${workspaceId}/adopt`);
  expect(conflict.status).toBe(200);
  expect(conflict.body).toMatchObject({ status: 'conflict', files: ['c.txt'] });
  expect(git(checkout, 'rev-parse', 'HEAD')).toBe(mainCommit);

  // 冲突转交给其中一个线程，另一个在旁边。
  const notice = await Promise.race([...prompts.keys()].map((id) => modelOf(id).call(2).then((call) => ({ id, call }))));
  const resolver = notice.id;
  const bystander = [...prompts.keys()].find((id) => id !== resolver)!;
  const inputs = notice.call.request.history.flatMap((item) => item.type === 'input' ? [item.input] : []);
  expect(inputs).toContainEqual(expect.objectContaining({ source: 'human', text: prompts.get(resolver) }));
  expect(inputs).toContainEqual(expect.objectContaining({ source: 'kite', text: expect.stringContaining('冲突') }));
  expect((await kk.call('POST', `/threads/${bystander}/messages`, { text: '顺手改别的' })).status).toBe(409);
  expect((await kk.call('POST', `/workspaces/${workspaceId}/threads`, { prompt: '再开一个' })).status).toBe(409);
  expect(notice.call.signal.aborted).toBe(false);

  // 停下处理冲突的线程，其他线程随即能开始工作；工作区仍停在冲突里。
  expect((await kk.call('POST', `/threads/${resolver}/interrupt`)).status).toBe(200);
  const freed = mark(kk);
  expect((await kk.call('POST', `/threads/${bystander}/messages`, { text: '顺手改别的' })).status).toBe(200);
  (await modelOf(bystander).call(2)).response.complete();
  await waitIdle(kk, bystander, freed);

  // 手动重试：遗留冲突仍转交给它。模拟沙箱里的 agent 采用会话一侧：只把文件改成去掉冲突标记的内容，不碰 git；
  // 完成这个回合后 kited 才能自动重试采纳。
  const retried = await kk.call('POST', `/workspaces/${workspaceId}/adopt`);
  expect(retried.body).toMatchObject({ status: 'conflict', files: ['c.txt'] });
  const resolving = await modelOf(resolver).call(3);
  writeFiles(thread.workspace.cwd, { 'c.txt': 'session\n' });
  resolving.response.complete();
  const adopted = await kk.waitEvent((event) => event.type === 'workspace.adopt' && event.workspaceId === workspaceId
    && event.result.status === 'adopted' && after(kk, since)(event));
  expect(adopted.type === 'workspace.adopt' && adopted.result.status === 'adopted' && adopted.result.commit)
    .toBe(git(checkout, 'rev-parse', 'HEAD'));
  expect(gitOk(checkout, 'merge-base', '--is-ancestor', mainCommit, 'HEAD')).toBe(true);
  expect(git(checkout, 'show', 'HEAD:c.txt')).toBe('session');
  expect(git(thread.workspace.cwd, 'status', '--porcelain')).toBe('');
  await waitIdle(kk, resolver, freed);

  const settled = mark(kk);
  expect((await kk.call('POST', `/threads/${bystander}/messages`, { text: '合回之后接着做' })).status).toBe(200);
  (await modelOf(bystander).call(3)).response.complete();
  await waitIdle(kk, bystander, settled);
}, 1000);

// 真实 bug：不带 force 归档时先停止所有线程再检查未采纳改动，「先试探、收到 409 再问用户」的流程
// 会把正在工作的 agent 打断后才拒绝。HTTP 请求、工作区锁、runner 生命周期与挂起的模型请求之间的时序要跑起来才能确认。
test('有未采纳改动时不带 force 归档直接拒绝，正在工作的线程不被打断并正常完成回合', async () => {
  const model = new ManualModel();
  kited = startKited(() => model);
  const kk = kited;
  const project = await addProject(kk, { path: newDir(kk.root, 'proj', { 'a.txt': 'base\n' }) });
  const thread = await createWorkspace(kk, project.id, '改一下 a.txt', 'harness');
  const pending = await model.call(1);
  writeFiles(thread.workspace.cwd, { 'a.txt': 'session\n' });

  const since = mark(kk);
  const refused = await kk.call('POST', `/workspaces/${thread.workspace.id}/archive`, {});
  expect(refused.status).toBe(409);
  expect(pending.signal.aborted).toBe(false);

  pending.response.complete();
  const finished = await kk.waitEvent((event) => event.type === 'harness' && event.threadId === thread.id
    && event.event.type === 'record' && event.event.record.type === 'turn.finished' && after(kk, since)(event));
  expect(finished.type === 'harness' && finished.event.type === 'record' && finished.event.record.type === 'turn.finished'
    && finished.event.record.outcome).toEqual({ kind: 'completed' });
  await kk.waitEvent((event) => event.type === 'idle' && event.threadId === thread.id && after(kk, since)(event));
  const view = await kk.call('GET', `/workspaces/${thread.workspace.id}`);
  expect(view.body.workspace.status).toBe('open');
  expect(read(join(thread.workspace.cwd, 'a.txt'))).toBe('session\n');
}, 1000);

// 真实 SQLite/journal 关闭重开后，opaque 输出与工具结果必须续接，已完成工具不能重跑。
test('同一 home 重启后用原 nativeId 续接旧 opaque 历史且不重执行工具', async () => {
  const root = makeTemp();
  roots.push(root);
  const home = join(root, 'kite');
  const repo = newDir(root, 'project', { 'base.txt': '原始\n' });
  const firstModel = new ManualModel();
  let daemon = startDaemon({ home, port: 0, lightTasks: false, model: () => firstModel });
  restarted = daemon;
  let events = new Seen<Envelope>();
  daemon.kite.bus.subscribe(undefined, (event) => events.add(event));
  const session = await createWorkspace(daemon, (await addProject(daemon, { path: repo })).id, '写一次标记', 'harness');
  const first = await firstModel.call(1);
  const oldCall = calledItem('write-once', 'shell', { description: '写入一次性标记', command: "printf 'once\\n' >> marker.txt" });
  await first.response.emit({ type: 'item', item: oldCall });
  first.response.complete();
  const followUp = await firstModel.call(2);
  expect(followUp.request.history).toContainEqual({ type: 'output', item: oldCall });
  expect(followUp.request.history).toContainEqual(expect.objectContaining({ type: 'tool_result', callId: 'write-once' }));
  followUp.response.complete();
  await events.wait((event) => event.type === 'idle' && event.threadId === session.id);
  expect(read(join(session.workspace.cwd, 'marker.txt'))).toBe('once\n');
  await daemon.stop();
  restarted = undefined;

  const secondModel = new ManualModel();
  daemon = startDaemon({ home, port: 0, lightTasks: false, model: () => secondModel });
  restarted = daemon;
  events = new Seen<Envelope>();
  daemon.kite.bus.subscribe(undefined, (event) => events.add(event));
  const sent = await call(daemon.url, 'POST', `/threads/${session.id}/messages`, { text: '继续', id: 'resume-once' });
  expect(sent.status).toBe(200);
  const resumed = await secondModel.call(1);
  expect(resumed.request.history).toContainEqual({ type: 'output', item: oldCall });
  expect(resumed.request.history).toContainEqual(expect.objectContaining({ type: 'tool_result', callId: 'write-once' }));
  expect(resumed.request.history.filter((value) => value.type === 'input' && value.input.id === 'resume-once')).toHaveLength(1);
  expect(read(join(session.workspace.cwd, 'marker.txt'))).toBe('once\n');
  const view = await call(daemon.url, 'GET', `/threads/${session.id}`);
  expect(view.status).toBe(200);
  expect(view.body.nativeId).toBe(session.nativeId);
  resumed.response.complete();
  await events.wait((event) => event.type === 'idle' && event.threadId === session.id);
  expect(read(join(session.workspace.cwd, 'marker.txt'))).toBe('once\n');
}, 1000);

// 关闭时仍有模型请求和排队输入；归档为管理目的打开会话，不得唤醒旧输入再发请求。
test('挂起请求关闭后直接归档不会执行排队消息，工作树仍能安全清理', async () => {
  const root = makeTemp();
  roots.push(root);
  const home = join(root, 'kite');
  const repo = newDir(root, 'project', { 'base.txt': '原始\n' });
  const firstModel = new ManualModel();
  let daemon = startDaemon({ home, port: 0, lightTasks: false, model: () => firstModel });
  restarted = daemon;
  const session = await createWorkspace(daemon, (await addProject(daemon, { path: repo })).id, '首条挂起', 'harness');
  const pending = await firstModel.call(1);
  const queued = await call(daemon.url, 'POST', `/threads/${session.id}/messages`, { text: '归档前排队', id: 'queued-before-archive' });
  expect(queued.status).toBe(200);
  await daemon.stop();
  restarted = undefined;
  expect(pending.signal.aborted).toBe(true);

  const secondModel = new ManualModel();
  daemon = startDaemon({ home, port: 0, lightTasks: false, model: () => secondModel });
  restarted = daemon;
  const archived = await call(daemon.url, 'POST', `/workspaces/${session.workspace.id}/archive`, { force: true });
  expect(archived.status).toBe(200);
  expect(secondModel.calls.values).toHaveLength(0);
  expect(existsSync(session.workspace.cwd)).toBe(false);
  const view = await call(daemon.url, 'GET', `/threads/${session.id}`);
  expect(view.body.status).toBe('archived');
}, 1000);

/**
 * 构造自研后端的恢复阻塞，按真实崩溃留下的日志：线程的第一轮请求已发给 model，放它正常结束，日志里留下宿主自己的上下文和请求配置；
 * 停掉 kk 后续写一轮工具 shell 已开始而没有结果的记录，重开后补成结果未知。
 */
async function crashMidTool(kk: Kited, id: string, model: ManualModel): Promise<void> {
  const first = await model.call(1);
  const since = mark(kk);
  first.response.complete();
  await waitIdle(kk, id, since);
  await kk.halt();
  const path = join(kk.home, 'sessions', id, 'journal.jsonl');
  const records = readJournal(path);
  const contextId = records.findLast((record) => record.type === 'context.prepared')!.snapshot.id;
  const configurationId = records.findLast((record) => record.type === 'request.configured')!.snapshot.id;
  const journal = new FileJournal(path);
  const ids = { turnId: 'crashed-turn', requestId: 'crashed-request' };
  const uncertain = item('uncertain', 'shell');
  journal.append({ type: 'input.received', input: input('before-crash') });
  journal.append({ type: 'turn.started', turnId: ids.turnId });
  journal.append({ type: 'request.started', ...ids, inputIds: ['before-crash'], contextId, configurationId });
  journal.append({ type: 'model.item', ...ids, item: uncertain });
  journal.append({ type: 'tool.started', ...ids, callId: uncertain.id });
  journal.close();
}

// 几个部分的配合：HTTP 的 confirmRecovery、宿主确认恢复和 agent.send 交接。自研主循环确认恢复后仍停在待继续，
// 同一请求里的发送要接在确认之后进主循环，不能只确认不发送，也不能被尚未解除的恢复挡回；被拒的发送不能顺带确认。
test('自研后端崩溃后的恢复阻塞只由 App 带确认的发送解除，新消息接在补齐的未知工具结果后交给模型，普通发送和 Line 的发送不解除', async () => {
  const model = new ManualModel();
  kited = startKited(() => model);
  const kk = kited;
  const project = await folderWorkspace(kk, newDir(kk.root, 'project', { 'base.txt': '原始\n' }));
  const id = await openAgent(kk.call, project.workspace.id);
  expect((await kk.call('POST', `/threads/${id}/messages`, { id: 'first', text: '先正常对话一轮' })).status).toBe(200);
  await crashMidTool(kk, id, model);

  const resumedModel = new ManualModel();
  restarted = startDaemon({ home: kk.home, port: 0, lightTasks: false, model: () => resumedModel });
  const url = restarted.url;
  const events = new Seen<Envelope>();
  restarted.kite.bus.subscribe(undefined, (event) => events.add(event));
  const history = async () => (await call(url, 'GET', `/threads/${id}/history`)).body as History;
  expect((await history()).state.recovery).toBeDefined();
  expect((await call(url, 'POST', `/threads/${id}/messages`, { id: 'plain', text: '没带确认' })).status).toBe(409);
  const fromLine = await fetch(`${url}/threads/${id}/messages`, {
    method: 'POST',
    headers: {
      'content-type': 'application/json', 'X-Kite-Machine': (await machine(url)).id,
      'X-Kite-Source': JSON.stringify({ kind: 'line', machine: 'line-machine', instance: 'line-instance' }),
    },
    body: JSON.stringify({ id: 'from-line', text: 'Line 想顺带确认', confirmRecovery: true }),
  });
  expect(fromLine.status).toBe(400);
  expect((await history()).state.recovery).toBeDefined();
  expect(resumedModel.calls.values).toHaveLength(0);

  const sending = events.values.length;
  const sent = await call(url, 'POST', `/threads/${id}/messages`, { id: 'after-crash', text: '确认并继续', confirmRecovery: true });
  expect(sent.status).toBe(200);
  const next = await resumedModel.call(1);
  expect(next.request.history.flatMap((entry) => entry.type === 'input' ? [entry.input.id] : []))
    .toEqual(['first', 'before-crash', 'after-crash']);
  expect(next.request.history.flatMap((entry) => entry.type === 'tool_result' ? [[entry.callId, entry.result.status]] : []))
    .toEqual([['uncertain', 'unknown']]);
  expect(next.request.history.at(-1)).toEqual({ type: 'input', input: { id: 'after-crash', text: '确认并继续', source: 'human' } });
  next.response.complete();
  await events.wait((event) => event.type === 'idle' && event.threadId === id && events.values.indexOf(event) >= sending);
  const done = await history();
  expect(done.state.recovery).toBeUndefined();
  expect(done.state.waitingForResume).toBe(false);
  expect(resumedModel.calls.values).toHaveLength(1);
}, 1000);

/*
 * 几个部分的配合：HTTP 的 adopt 带 confirmRecovery 时，宿主要在工作区里逐个找出待恢复的线程，打开它的主循环确认恢复，
 * 再过合回前「没有线程在工作或等待恢复确认」的检查；只确认不合回、或确认后仍被挡回，都要跑起来才看得出。
 * 重开后先不读线程状态，确认前是否已恢复看日志，免得测试自己先把线程的主循环打开，盖住合回这条路径上的打开。
 */
test('工作区的线程崩溃后恢复阻塞时合回被拒，带确认合回先解除线程的恢复再合回本机主线，不请求模型', async () => {
  const model = new ManualModel();
  kited = startKited(() => model);
  const kk = kited;
  // 没有远程的项目：合回只到本机主线，不去推送。
  const project = await addProject(kk, { path: newDir(kk.root, 'project', { 'base.txt': '原始\n' }) });
  const session = await createWorkspace(kk, project.id, '先正常对话一轮', 'harness');
  const checkout = session.checkout.path;
  await crashMidTool(kk, session.id, model);
  // 工作区是异步准备的，等首轮请求发出（crashMidTool 里）后工作树才在，这时再放要合回的改动。
  writeFiles(session.workspace.cwd, { 'w.txt': '工作区\n' });

  const resumedModel = new ManualModel();
  restarted = startDaemon({ home: kk.home, port: 0, lightTasks: false, model: () => resumedModel });
  const url = restarted.url;
  const adopt = `/workspaces/${session.workspace.id}/adopt`;
  const confirmations = () => readJournal(join(kk.home, 'sessions', session.id, 'journal.jsonl'))
    .filter((record) => record.type === 'recovery.confirmed').length;
  expect(await call(url, 'POST', adopt)).toEqual({ status: 409, body: { error: '工作区有线程正在工作或等待恢复确认' } });
  expect(confirmations()).toBe(0);
  expect(gitOk(checkout, 'cat-file', '-e', 'HEAD:w.txt')).toBe(false);

  const adopted = await call(url, 'POST', adopt, { confirmRecovery: true });
  expect(adopted).toMatchObject({ status: 200, body: { status: 'adopted', push: { status: 'local' } } });
  expect(git(checkout, 'show', 'HEAD:w.txt')).toBe('工作区');
  expect(confirmations()).toBe(1);
  const state = ((await call(url, 'GET', `/threads/${session.id}/history`)).body as History).state;
  expect(state.recovery).toBeUndefined();
  expect(resumedModel.calls.values).toHaveLength(0);
}, 1000);
