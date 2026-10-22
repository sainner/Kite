/**
 * kited 进程被杀后重启，Claude Code 指向假端点。
 */
import { afterEach, expect, setDefaultTimeout, test } from 'bun:test';
import { randomUUID } from 'node:crypto';
import { join } from 'node:path';
import { readClaudeControl } from '../../src/claude/control.ts';
import type { Logged } from '../fake-api.ts';
import { api, call, chatgptLogin, claudeRole, type KitedProcess, spawnKited } from '../harness.ts';
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
const expectedTools = ['read', 'patch', 'shell', 'credentials', 'question', 'agent_start', 'agent_list', 'agent_send', 'agent_resume', 'agent_stop',
  'agent_merge', 'monitor_start', 'monitor_list', 'monitor_stop', 'terminal_run', 'terminal_list', 'terminal_read', 'terminal_stop',
  'preview_open', 'preview_action', 'preview_inspect', 'preview_list', 'preview_close'].sort();

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

/*
 * 真实回归：stdin 已接收但尚未纳入的插话在宿主重启后丢失。
 * 恢复阻塞只能由 App 用户的下一步操作确认：不带 confirmRecovery 的发送不能顺带重放结果未知的输入；
 * 带 confirmRecovery 的发送先确认恢复，再把结果未知的插话按原顺序重新交给原生会话，之后才接新消息。
 * 依赖 Claude Code：用 --resume 续接被杀进程留下的原生会话，stdin 先后收到的两条用户消息按到达顺序进入模型请求。
 */
test('kited 被 SIGKILL 后保留未知插话，不确认恢复的发送被拒，App 带确认发送时插话先于新消息各投一次并续接原会话', async () => {
  const root = temp();
  const home = join(root, 'kite');
  const repo = newRepo(root, 'proj', { 'a.txt': 'a\n' }, null);
  kited = await spawnKited(home);
  const hold = `崩溃-${randomUUID().slice(0, 8)}`;
  const url = kited.url;
  const project = (await call(url, 'POST', '/project-registry', { path: repo })).body;
  // 建工作区先查默认角色的厂商登录；kited 是子进程，环境变量改不到它，写一份 ChatGPT 登录到它的数据目录。
  chatgptLogin(home);
  const workspace = (await call(url, 'POST', '/workspaces', { project: project.id })).body;
  await until(async () => (await call(url, 'GET', `/workspaces/${workspace.workspace.id}`)).body.workspace.status === 'open', '工作区准备好');
  const role = await claudeRole((method, path, body) => call(url, method, path, body));
  const s = (await call(url, 'POST', `/workspaces/${workspace.workspace.id}/threads`, { prompt: `HOLD ${hold} 开场`, role })).body;
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
  expect((await call(kited.url, 'POST', `/threads/${s.instanceId}/messages`, {
    id: 'unconfirmed-send', text: '没确认恢复的发送不能顺带重发插话',
  })).status).toBe(409);
  expect(api.log.filter((entry) => entry.main)).toHaveLength(beforeRecovery);

  const since = api.log.length;
  const fresh = { id: 'confirmed-send', text: `确认后的新消息-${randomUUID().slice(0, 8)}` };
  expect((await call(kited.url, 'POST', `/threads/${s.instanceId}/messages`, { ...fresh, confirmRecovery: true })).status).toBe(200);
  const req = await api.waitRequest((entry) => api.log.indexOf(entry) >= since && entry.main && entry.lastUserText.includes(fresh.text));
  // 只看用户一侧的文本：假端点的回显也会带上用户原文。
  const userText = (entry: Logged) => (entry.body.messages as any[]).filter((message) => message.role === 'user')
    .flatMap((message) => typeof message.content === 'string' ? [message.content]
      : message.content.flatMap((block: any) => block.type === 'text' ? [block.text] : []))
    .join('\n');
  const occurrences = (text: string, part: string) => text.split(part).length - 1;
  // 确认后的每个主循环请求都已带上插话且只带一次；见到新消息的请求里新消息也只一次，并排在插话之后。
  for (const entry of api.log.slice(since).filter((entry) => entry.main)) {
    const seen = userText(entry);
    expect(occurrences(seen, uncertain.text)).toBe(1);
    expect(occurrences(seen, fresh.text)).toBeLessThanOrEqual(1);
    if (seen.includes(fresh.text)) expect(seen.indexOf(uncertain.text)).toBeLessThan(seen.indexOf(fresh.text));
  }
  expect(JSON.stringify(req.body.messages)).toContain(hold);
  expect(req.body.tools.map((tool: { name: string }) => tool.name).sort()).toEqual(expectedTools);
  const v = (await call(kited.url, 'GET', `/threads/${s.instanceId}`)).body;
  expect(v.nativeId).toBe(s.nativeId);
  // 公共状态由宿主投影为空闲；同时等到新消息的最终回复，避免只见到启动前的空闲状态。
  await until(async () => {
    const history = (await call(kited!.url, 'GET', `/threads/${s.instanceId}/history`)).body;
    return history.state.phase === 'idle' && history.records.some((record: any) =>
      record.block.type === 'text' && record.block.text.includes(fresh.text) && record.generation === 'complete');
  }, '新消息回复完成并回到空闲');
  const completed = (await call(kited.url, 'GET', `/threads/${s.instanceId}/history`)).body;
  expect(completed.state.recovery).toBeUndefined();
  expect(completed.pending).toEqual([]);
  const humans = completed.records.filter((record: any) => record.block.type === 'human').map((record: any) => record.block.id);
  expect(humans.filter((id: string) => id === uncertain.id)).toHaveLength(1);
  expect(humans.filter((id: string) => id === fresh.id)).toHaveLength(1);
  expect(humans.indexOf(uncertain.id)).toBeLessThan(humans.indexOf(fresh.id));
});
