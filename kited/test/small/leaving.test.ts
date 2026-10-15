/**
 * 工作机睡眠前自动换机（docs/Line与工作区流转.md「工作区流转」的睡眠前换机）：两台本进程 kited 互为组网对端，
 * kite-net 的系统睡眠预告在测试里起不来，直接调 kite.leaving。跨机流转本身见 transfer.test.ts。
 */
import { afterEach, expect, test } from 'bun:test';
import { rmSync } from 'node:fs';
import { join } from 'node:path';
import type { Input, ModelRequest } from '../../src/harness/types.ts';
import type { WorkspaceModel } from '../../src/model.ts';
import type { History } from '../../src/transcript/protocol.ts';
import { chatgptLogin, connect, createWorkspace, type Kited, registerCheckout, startKited, synced } from '../harness.ts';
import { ManualModel } from '../harness-loop.ts';
import { newRepo } from '../util.ts';

const kiteds: Kited[] = [];
const dirs: string[] = [];
afterEach(async () => {
  for (const k of kiteds.splice(0)) await k.stop();
  for (const dir of dirs.splice(0)) rmSync(dir, { recursive: true, force: true });
});

const inputs = (request: ModelRequest) => request.history.flatMap((entry) => entry.type === 'input' ? [entry.input] : []);

/*
 * 几个部分的配合：按目标机的 /environment 选机器、打断正在工作的线程并收回排队的输入、交接、目标机还原（没有远程的项目，
 * 目标机从源机的检出 clone）、源机收到通知后冻结；接管后在目标机上先补一条 kite 来源的说明接着做被打断的回合，
 * 再把排队的输入按原来的正文、来源与经由重发。排队的输入在源机的 journal 里已记为收到（随后被打断收回），副本把它带到了目标机；
 * harness 按输入 ID 永久去重，原 ID 重发会被吞，所以重发换新 ID，这里只认正文与来源。
 */
test('睡眠前自动换机：打开自动换机的项目里正在工作的工作区交给 B，B 上的线程先收到 kite 来源的继续说明，再收到正文与来源相同的排队输入且只一次，A 的记录冻结', async () => {
  const models = { a: new ManualModel(), b: new ManualModel() };
  const [a, b] = [models.a, models.b].map((model) => {
    const k = startKited(() => model, false, { catalogDelayMs: 0 });
    kiteds.push(k);
    chatgptLogin(k.home);
    return k;
  }) as [Kited, Kited];
  await connect(a, b);
  const name = `leaving-${crypto.randomUUID().slice(0, 8)}`;
  // B 没有检出，还原时 clone 到 HOME 下的 ~/code/<项目名>。
  dirs.push(join(process.env.HOME!, 'code', name));
  const registered = await registerCheckout(a, newRepo(a.root, name, { 'a.txt': '一\n' }, null));
  const projectId = registered.project.id;
  const machineA = a.daemon.kite.store.machine.id;
  await synced(b, () => b.daemon.kite.registry.get(projectId) && b.daemon.kite.directory.entries()
    .some((entry) => entry.id === machineA && entry.snapshot?.checkouts.some((checkout) => checkout.projectId === projectId)),
  'B 同步到 A 登记的项目与检出');
  expect((await a.call('PUT', `/project-registry/${projectId}/settings`, { autoHandover: true })).status).toBe(200);
  const thread = await createWorkspace(a, registered.checkout.id, '第一回合', 'harness');
  const workspaceId = thread.workspace.id;
  const working = await models.a.call(1);
  const queued: Input = { id: 'queued-input', text: '排队等着的输入', source: 'human' };
  expect((await a.call('POST', `/threads/${thread.id}/messages`, { id: queued.id, text: queued.text })).status).toBe(200);

  await a.daemon.kite.leaving(Date.now() + 10_000);
  expect(working.signal.aborted).toBe(true);
  expect(((await a.call('GET', `/workspaces/${workspaceId}`)).body as WorkspaceModel).workspace.status).toBe('transferred');
  expect(b.daemon.kite.store.workspace(workspaceId)).toMatchObject({ epoch: 2, status: 'open' });

  const resumed = await models.b.call(1);
  const first = inputs(resumed.request);
  const note = first.findIndex((input) => input.source === 'kite');
  expect(note).toBeGreaterThan(first.findIndex((input) => input.text === '第一回合'));
  const same = (input: Input) => input.text === queued.text && input.source === queued.source;
  // 还原返回前说明与排队的输入都已发出：排队的输入要么赶上了这次请求，要么等在这个还没结束的回合后面。
  const included = first.filter(same);
  const waiting = ((await b.call('GET', `/threads/${thread.id}/history`)).body as History).pending.filter(same);
  expect(included.length + waiting.length).toBe(1);
  let delivered = resumed;
  if (!included.length) {
    resumed.response.complete();
    delivered = await models.b.call(2);
  }
  const deliveredInputs = inputs(delivered.request);
  expect(deliveredInputs.filter(same)).toHaveLength(1);
  expect(deliveredInputs.findIndex(same)).toBeGreaterThan(deliveredInputs.findIndex((input) => input.source === 'kite'));
  expect(models.a.calls.values).toHaveLength(1);
}, 1_000);
