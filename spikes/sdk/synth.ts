/**
 * 1c：用假端点制造本机会话记录里缺的记录类型：压缩、从中间分叉、后台任务唤醒、回合中打断。
 * 同时统计 SDK 消息流里出现过的消息类型。生成的会话记录在 <临时目录>/claude-config/projects。
 * 用法：bun synth.ts <临时目录>，之后对 claude-config/projects 跑 spikes/transcripts/census.ts。
 */
import { mkdirSync, rmSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { startFakeApi } from './fake-api';
import { isolatedEnv, Sess } from './harness';

const root = process.argv[2];
if (!root) throw new Error('需要临时目录参数');
rmSync(root, { recursive: true, force: true });
mkdirSync(root, { recursive: true });
const fake = startFakeApi();
const { env } = isolatedEnv(root, fake.port);
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
const report: Record<string, unknown> = {};
const streamKinds = new Map<string, number>();
const collect = (s: Sess) => { for (const { m } of s.msgs) { const k = m.type === 'system' ? `system:${m.subtype}` : m.type === 'result' ? `result:${m.subtype}` : m.type; streamKinds.set(k, (streamKinds.get(k) ?? 0) + 1); } };
const proj = join(root, 'proj');
mkdirSync(proj);

// 一、压缩：先聊几轮，再发 /compact，压缩后再聊一轮
{
  const s = new Sess(proj, env);
  for (let i = 1; i <= 3; i++) await s.send(`压缩前第 ${i} 轮`).result;
  const r = await s.send('/compact').result;
  report.compactResult = r.subtype;
  await s.send('压缩后一轮').result;
  report.compactSession = s.sessionId;
  collect(s); await s.close();
}

// 二、从中间分叉：三轮之后回到第二轮的助手回复，分叉出新会话
{
  const s = new Sess(proj, env);
  for (let i = 1; i <= 3; i++) await s.send(`分叉前第 ${i} 轮`).result;
  const assistants = s.msgs.filter((x) => x.m.type === 'assistant').map((x) => x.m);
  const at = assistants[1].uuid;
  const src = s.sessionId!;
  collect(s); await s.close();
  const f = new Sess(proj, env, { resume: src, resumeSessionAt: at, forkSession: true });
  await f.send('分叉后的新消息').result;
  report.fork = { source: src, forked: f.sessionId, sameId: src === f.sessionId };
  collect(f); await f.close();
}

// 三、后台任务：让 agent 起一个 2 秒的后台命令，回合结束后等它完成自己唤醒会话
{
  const s = new Sess(proj, env);
  await s.send('BG 2 起个后台任务').result;
  const woke = await Promise.race([s.nextResult().then((r) => r.subtype), sleep(15000).then(() => '15 秒内没有自动唤醒')]);
  report.backgroundWake = woke;
  report.backgroundSession = s.sessionId;
  collect(s); await s.close();
}

// 四、回合中打断：工具跑到一半调用 interrupt()，然后再发一条
{
  const s = new Sess(proj, env);
  const { result } = s.send('SLEEP 5 然后被打断');
  await fake.waitFor((l) => l.lastUserText.includes('SLEEP 5 然后被打断') && !l.hasToolResult);
  await sleep(1000);
  const t = Date.now();
  const receipt = await s.q.interrupt();
  const r = await result;
  report.interrupt = { resultSubtype: r.subtype, msUntilResult: Date.now() - t, receipt };
  await s.send('打断之后的新消息').result;
  const last = fake.log.filter((l) => l.main).at(-1)!;
  report.interruptTail = last.body.messages.slice(-4).map((m: any) => typeof m.content === 'string' ? `${m.role}: ${m.content.slice(0, 120)}` : `${m.role}: ` + m.content.map((b: any) => b.type === 'text' ? `text(${b.text.slice(0, 120)})` : b.type === 'tool_result' ? `tool_result(${JSON.stringify(b.content).slice(0, 100)})` : b.type).join(' + '));
  collect(s); await s.close();
}

report.streamKinds = Object.fromEntries([...streamKinds.entries()].sort());
fake.stop();
writeFileSync(join(root, 'synth-report.json'), JSON.stringify(report, null, 2));
console.log(JSON.stringify(report, null, 2));
process.exit(0);
