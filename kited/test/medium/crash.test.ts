/**
 * kited 进程被杀后重启，Claude Code 指向假端点。
 */
import { afterEach, expect, setDefaultTimeout, test } from 'bun:test';
import { randomUUID } from 'node:crypto';
import { join } from 'node:path';
import { readClaudeControl } from '../../src/claude/control.ts';
import { api, call, type KitedProcess, spawnKited } from '../harness.ts';
import { ENV, newRepo, transcript, until, useTemp } from '../util.ts';

setDefaultTimeout(3_000);

// 先停 kited 再删临时目录：afterEach 按登记的先后执行
let kited: KitedProcess | undefined;
const orphans: number[] = [];
afterEach(async () => {
  api.releaseAll();
  try {
    await kited?.kill('SIGTERM');
  } finally {
    kited = undefined;
    await stopOrphans();
  }
});
const temp = useTemp();
const expectedTools = ['read', 'patch', 'shell', 'agent_start', 'agent_list', 'agent_send', 'agent_resume', 'agent_stop']
  .map((name) => `mcp__kite__${name}`).sort();

/** pid 的直接子进程。 */
function children(pid: number): number[] {
  const r = Bun.spawnSync(['pgrep', '-P', String(pid)], { env: ENV(), stdout: 'pipe' });
  return r.stdout.toString().split('\n').filter(Boolean).map(Number);
}

const alive = (pid: number) => { try { process.kill(pid, 0); return true; } catch { return false; } };

async function stopOrphans() {
  for (const pid of orphans) {
    try { process.kill(pid, 'SIGKILL'); } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== 'ESRCH') throw error;
    }
  }
  await until(() => orphans.every((pid) => !alive(pid)), '被杀的 kited 留下的子进程退出', 1_000);
  orphans.length = 0;
}

/* 真实回归：stdin 已接收但尚未纳入的插话在宿主重启后丢失；普通发送也不能顺带重放结果未知的输入。 */
test('kited 被 SIGKILL 后保留未知输入，确认恢复仍禁止普通发送，显式继续才续接原会话', async () => {
  const root = temp();
  const home = join(root, 'kite');
  const repo = newRepo(root, 'proj', { 'a.txt': 'a\n' });
  kited = await spawnKited(home);
  const p = (await call(kited.url, 'POST', '/checkouts', { path: repo })).body;
  const hold = `崩溃-${randomUUID().slice(0, 8)}`;
  const workspace = (await call(kited.url, 'POST', '/workspaces', { checkout: p.checkout.id, prompt: `HOLD ${hold} 开场`, runtime: 'claude' })).body;
  const s = workspace.threads[0];
  const first = await api.held(hold);
  expect(first.body.tools.map((tool: { name: string }) => tool.name).sort()).toEqual(expectedTools);
  const uncertain = { id: 'unconfirmed-after-crash', text: `待确认插话-${randomUUID()}`, source: 'human' };
  expect((await call(kited.url, 'POST', `/threads/${s.instanceId}/messages`, uncertain)).status).toBe(200);
  await until(() => readClaudeControl(join(home, 'sessions', s.instanceId)).inputs
    .some((entry) => entry.input.id === uncertain.id && entry.status === 'submitted'), '插话已交给原生 stdin');
  await until(() => transcript(s.nativeId).some((entry) => entry.type === 'user'), '首条输入已经写入原生历史');

  // 原生请求仍挂起时一起核查并结束残留进程，固定复现 stdin 已收但模型尚未见到插话的窗口。
  orphans.push(...children(kited.pid));
  await kited.kill('SIGKILL');
  kited = undefined;
  await stopOrphans();
  api.release(hold);
  expect(transcript(s.nativeId).some((entry) => entry.type === 'user')).toBe(true);
  expect(JSON.stringify(transcript(s.nativeId).filter((entry) => entry.type === 'user'))).not.toContain(uncertain.text);

  kited = await spawnKited(home);
  const beforeRecovery = api.log.filter((entry) => entry.main).length;
  const recovery = await call(kited.url, 'GET', `/threads/${s.instanceId}/history`);
  expect(recovery.body.state.recovery).toBeDefined();
  expect(recovery.body.pending).toContainEqual(expect.objectContaining(uncertain));
  expect(api.log.filter((entry) => entry.main && entry.lastUserText.includes(hold))).toHaveLength(1);
  const confirmed = await call(kited.url, 'POST', `/threads/${s.instanceId}/recover`);
  expect(confirmed.status).toBe(200);
  const ready = await call(kited.url, 'GET', `/threads/${s.instanceId}/history`);
  expect(ready.body.state.waitingForResume).toBe(true);
  expect(ready.body.state.capabilities.resume).toBe(true);
  expect(ready.body.pending).toContainEqual(expect.objectContaining(uncertain));
  expect((await call(kited.url, 'POST', `/threads/${s.instanceId}/messages`, {
    id: 'unrelated-message', text: '无关的新消息不能顺带重发插话',
  })).status).toBe(409);
  expect(api.log.filter((entry) => entry.main)).toHaveLength(beforeRecovery);
  const since = api.log.length;
  const resumed = await call(kited.url, 'POST', `/workspaces/${workspace.workspace.id}/operations/agent.resume`, {
    operationId: 'resume-after-crash', instanceId: s.instanceId,
  });
  expect(resumed.status).toBe(200);
  const continued = uncertain.text;
  const req = await api.waitRequest((entry) => api.log.indexOf(entry) >= since && entry.main && entry.lastUserText.includes(continued));
  expect(JSON.stringify(req.body.messages)).toContain(hold);
  expect(req.body.tools.map((tool: { name: string }) => tool.name).sort()).toEqual(expectedTools);
  const v = (await call(kited.url, 'GET', `/threads/${s.instanceId}`)).body;
  expect(v.nativeId).toBe(s.nativeId);
  // 公共状态由宿主投影为空闲；同时等到续接的最终文本，避免只见到启动前的空闲状态。
  await until(async () => {
    const history = (await call(kited!.url, 'GET', `/threads/${s.instanceId}/history`)).body;
    return history.state.phase === 'idle' && history.records.some((record: any) =>
      record.block.type === 'text' && record.block.text.includes(continued) && record.generation === 'complete');
  }, '续接完成并回到空闲');
  const completed = (await call(kited.url, 'GET', `/threads/${s.instanceId}/history`)).body;
  expect(completed.pending).toEqual([]);
  expect(completed.records.filter((record: any) => record.block.type === 'human'
    && record.block.id === uncertain.id)).toHaveLength(1);
});
