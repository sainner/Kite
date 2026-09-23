/**
 * kited 进程被杀后重启：D4。按路径起 kited 子进程（bun src/main.ts），Claude Code 指向假端点。
 */
import { afterEach, expect, setDefaultTimeout, test } from 'bun:test';
import { randomUUID } from 'node:crypto';
import { join } from 'node:path';
import { api, call, type KitedProcess, spawnKited } from '../harness.ts';
import { ENV, newRepo, transcript, until, useTemp } from '../util.ts';

setDefaultTimeout(20_000);

// 先停 kited 再删临时目录：afterEach 按登记的先后执行
let kited: KitedProcess | undefined;
afterEach(async () => {
  api.releaseAll();
  await kited?.kill('SIGTERM');
  kited = undefined;
});
const temp = useTemp();

/** pid 的直接子进程。 */
function children(pid: number): number[] {
  const r = Bun.spawnSync(['pgrep', '-P', String(pid)], { env: ENV(), stdout: 'pipe' });
  return r.stdout.toString().split('\n').filter(Boolean).map(Number);
}

const alive = (pid: number) => { try { process.kill(pid, 0); return true; } catch { return false; } };

test('kited 在回合进行中被 SIGKILL，重新启动后给同一个会话发消息能续接，历史还在', async () => {
  const root = temp();
  const home = join(root, 'kite');
  const repo = newRepo(root, 'proj', { 'a.txt': 'a\n' });
  kited = await spawnKited(home);
  const p = (await call(kited.url, 'POST', '/projects', { path: repo })).body;
  const hold = `d4-${randomUUID().slice(0, 8)}`;
  const s = (await call(kited.url, 'POST', '/sessions', { project: p.id, prompt: `HOLD ${hold} 开场` })).body;
  await api.held(hold);

  // kited 死后它起的 Claude Code 进程还活着：放行它的请求，等它把这一回合写进会话记录，
  // 再替它收尾（它自己要约 2 秒才退出），免得和续接的进程同时写会话记录
  const orphans = children(kited.pid);
  await kited.kill('SIGKILL');
  api.release(hold);
  await until(() => transcript(s.nativeId).some((e) => e.type === 'assistant'), '被杀前那一回合写进会话记录');
  for (const pid of orphans) if (alive(pid)) process.kill(pid, 'SIGKILL');
  await until(() => orphans.every((pid) => !alive(pid)), '被杀的 kited 留下的子进程退出');

  kited = await spawnKited(home);
  const b = `标记D4-${randomUUID().slice(0, 8)}`;
  const sent = await call(kited.url, 'POST', `/sessions/${s.id}/messages`, { text: `续接 ${b}` });
  expect(sent.status).toBe(200);
  const req = await api.waitRequest((l) => l.main && l.lastUserText.includes(b));
  expect(JSON.stringify(req.body.messages)).toContain(hold);
  const v = (await call(kited.url, 'GET', `/sessions/${s.id}`)).body;
  expect(v.status).toBe('open');
  expect(v.nativeId).toBe(s.nativeId);
  // 等这一回合收口、进程退出，再停 kited
  await until(async () => (await call(kited!.url, 'GET', `/sessions/${s.id}`)).body.runner === 'closed', 'runner 关闭');
});
