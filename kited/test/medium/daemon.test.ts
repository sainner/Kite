/**
 * 经 HTTP 驱动本进程里的 kited，会话起真实的 Claude Code，模型换成假端点：D1、D6、D7，以及会话的 check 工具。
 */
import { afterEach, expect, setDefaultTimeout, test } from 'bun:test';
import { randomUUID } from 'node:crypto';
import { chmodSync, existsSync } from 'node:fs';
import { join } from 'node:path';
import {
  after, api, createSession, type Kited, listSnapshots, mark, registerProject, sendMessage, startKited, waitRunner,
} from '../harness.ts';
import { commitAll, git, gitOk, newRepo, read, transcript, until, writeFiles } from '../util.ts';

setDefaultTimeout(20_000);

let k: Kited | undefined;
afterEach(async () => { await k?.stop(); k = undefined; delete process.env.ENABLE_TOOL_SEARCH; });

const token = (name: string) => `${name}-${randomUUID().slice(0, 8)}`;
const history = (l: { body: any }) => JSON.stringify(l.body.messages);
/** 请求里给模型的工具。 */
const tools = (l: { body: any }) => l.body.tools as any[];
/** 请求历史里回应 tool_use id 的 tool_result。 */
const toolResult = (l: { body: any }, id: string) => (l.body.messages as any[])
  .flatMap((x) => (Array.isArray(x.content) ? x.content : []))
  .find((c: any) => c.type === 'tool_result' && c.tool_use_id === id);

test('一条完整的会话：第一条消息到达 agent，「会话开始」是最早的快照，一批并行工具调用一枚快照，回合结束关闭，再发消息续接同一个原生会话，有没合回的改动时归档要 force，归档后工作树和分支删掉、快照留下、不能再发消息；项目里有 .kite/check 时 agent 常驻一个名为 check 的工具，调用它（带 all）跑检查，结果发成 check 事件、输出回到模型', async () => {
  // 地址不是官方的时候上游默认不开工具搜索，所有工具都常驻；打开它，「check 常驻、不经 ToolSearch」才验得出来
  process.env.ENABLE_TOOL_SEARCH = 'true';
  k = startKited();
  const kk = k;
  const repo = newRepo(kk.root, 'proj', { 'a.txt': 'a\n' });
  const out = token('检查输出');
  writeFiles(repo, { '.kite/check': `#!/bin/sh\necho "${out} args=[$*]"\n` });
  chmodSync(join(repo, '.kite/check'), 0o755);
  const head = commitAll(repo, '加检查命令');
  const p = await registerProject(kk, repo);

  const a = token('标记D1A');
  const firstLine = `并行写两个文件 ${a}`;
  const s = await createSession(kk, p.id, `${firstLine}\nPAR echo a > p1.txt ;; echo b > p2.txt`);
  const req1 = await api.waitRequest((l) => l.main && l.lastUserText.includes(a));
  expect(req1.toolUseIds).toHaveLength(2);
  expect(tools(req1).map((t) => t.name)).toContain('ToolSearch');
  const checkTool = tools(req1).find((t) => t.name === 'check');
  expect(checkTool).toBeDefined();
  expect(checkTool.defer_loading).toBeFalsy();
  await waitRunner(kk, s.id, 'closed');

  const snaps = await listSnapshots(kk, s.id);
  expect(snaps.at(-1)!.label).toBe('会话开始');
  const batch = snaps.filter((x) => x.label === firstLine);
  expect(batch).toHaveLength(1);
  expect([...batch[0]!.toolUseIds].sort()).toEqual([...req1.toolUseIds].sort());
  expect(git(repo, 'show', `${batch[0]!.commit}:p1.txt`)).toBe('a');
  expect(git(repo, 'show', `${batch[0]!.commit}:p2.txt`)).toBe('b');

  // 再发一条：进程已关闭，续接同一个原生会话，历史还在；这一回合 agent 调 check
  const m = mark(kk);
  const b = token('标记D1B');
  await sendMessage(kk, s.id, `第二条 ${b}\nCALL check {"all":true}`);
  const req2 = await api.waitRequest((l) => l.main && l.lastUserText.includes(b));
  expect(history(req2)).toContain(a);
  expect(req2.toolUseIds).toHaveLength(1);
  const callId = req2.toolUseIds[0]!;
  const back = await api.waitRequest((l) => l.main && !!toolResult(l, callId));
  const result = toolResult(back, callId);
  expect(JSON.stringify(result.content)).toContain(`${out} args=[--all]`);
  expect(result.is_error).toBeFalsy();
  const checked = await kk.waitEvent((e) => e.session === s.id && e.type === 'check' && after(kk, m)(e));
  expect(checked.type === 'check' && checked.result).toMatchObject({ ok: true, code: 0, all: true, base: head });
  const init = await kk.waitEvent((e) => e.session === s.id && e.type === 'sdk' && e.message.type === 'system' && e.message.subtype === 'init' && after(kk, m)(e));
  expect(init.type === 'sdk' && init.message.session_id).toBe(s.nativeId);
  await waitRunner(kk, s.id, 'closed', m);

  // 归档：有没合回的改动时不带 force 被拒绝
  const refused = await kk.call('POST', `/sessions/${s.id}/archive`, {});
  expect(refused.status).toBe(409);
  expect(existsSync(s.worktree)).toBe(true);
  const archived = await kk.call('POST', `/sessions/${s.id}/archive`, { force: true });
  expect(archived.status).toBe(200);
  expect(existsSync(s.worktree)).toBe(false);
  expect(gitOk(repo, 'rev-parse', '--verify', '--quiet', `refs/heads/${s.branch}`)).toBe(false);
  expect(gitOk(repo, 'rev-parse', '--verify', '--quiet', `refs/kite/snapshots/${s.id}`)).toBe(true);
  const kept = (await listSnapshots(kk, s.id)).map((x) => x.commit);
  expect(kept).toEqual(expect.arrayContaining(snaps.map((x) => x.commit)));
  const late = await kk.call('POST', `/sessions/${s.id}/messages`, { text: '还在吗' });
  expect(late.status).toBe(409);
});

test('agent 正在工作时，采纳和回退都被拒绝（409）；项目里没有 .kite/check 时 agent 没有 check 工具', async () => {
  k = startKited();
  const kk = k;
  const repo = newRepo(kk.root, 'proj', { 'a.txt': 'a\n' });
  const p = await registerProject(kk, repo);
  const hold = token('d6');
  const s = await createSession(kk, p.id, `HOLD ${hold} 慢慢想`);
  const req = await api.held(hold);
  // 这里没开工具搜索，提供了的工具全都列在请求里
  expect(tools(req).map((t) => t.name)).not.toContain('check');
  const start = (await listSnapshots(kk, s.id)).at(-1)!;
  writeFiles(s.worktree, { 'wip.txt': 'agent 写到一半\n' });
  const head = git(repo, 'rev-parse', 'HEAD');

  const adopt = await kk.call('POST', `/sessions/${s.id}/adopt`);
  expect(adopt.status).toBe(409);
  expect(typeof adopt.body.error).toBe('string');
  const restore = await kk.call('POST', `/sessions/${s.id}/restore`, { commit: start.commit });
  expect(restore.status).toBe(409);
  expect(typeof restore.body.error).toBe('string');

  expect(git(repo, 'rev-parse', 'HEAD')).toBe(head);
  expect(read(join(s.worktree, 'wip.txt'))).toBe('agent 写到一半\n');
});

/** 会话记录里 type 为 user 的条目和它的文本。 */
function userEntries(nativeId: string): Array<{ entry: any; text: string }> {
  return transcript(nativeId).filter((e) => e.type === 'user').map((entry) => {
    const c = entry.message?.content;
    const text = typeof c === 'string' ? c : Array.isArray(c) ? c.filter((x: any) => x.type === 'text').map((x: any) => x.text).join('\n') : '';
    return { entry, text };
  });
}

test('采纳冲突：返回冲突文件并把说明交给 agent，这一回合结束后自动重试、合回会话一侧；会话记录里人发的消息带 origin human，冲突说明不带', async () => {
  k = startKited();
  const kk = k;
  const repo = newRepo(kk.root, 'proj', { 'c.txt': 'base\n' });
  const p = await registerProject(kk, repo);
  const h = token('标记D7');
  const s = await createSession(kk, p.id, `RUN echo session > c.txt # ${h}`);
  await waitRunner(kk, s.id, 'closed');

  writeFiles(repo, { 'c.txt': 'main\n' });
  const mainCommit = commitAll(repo, '主线改了 c');
  const m = mark(kk);
  const sent = Date.now();
  const r = await kk.call('POST', `/sessions/${s.id}/adopt`);
  expect(r.status).toBe(200);
  expect(r.body.status).toBe('conflict');
  expect(r.body.files).toEqual(['c.txt']);
  expect(git(repo, 'rev-parse', 'HEAD')).toBe(mainCommit);

  await api.waitRequest((l) => l.main && l.at >= sent && l.lastUserText.includes('冲突'));
  const ev = await kk.waitEvent((e) => e.session === s.id && e.type === 'adopt' && e.result.status === 'adopted' && after(kk, m)(e));
  expect(ev.type === 'adopt' && ev.result.status === 'adopted' && ev.result.commit).toBe(git(repo, 'rev-parse', 'HEAD'));
  expect(gitOk(repo, 'merge-base', '--is-ancestor', mainCommit, 'HEAD')).toBe(true);
  expect(read(join(repo, 'c.txt'))).toBe('session\n');
  expect(git(repo, 'status', '--porcelain')).toBe('');

  const entries = await until(() => {
    const all = userEntries(s.nativeId);
    return all.some((u) => u.text.includes('冲突')) && all;
  }, '冲突说明写进会话记录');
  const human = entries.filter((u) => u.text.includes(h));
  const note = entries.filter((u) => u.text.includes('冲突'));
  expect(human.length).toBeGreaterThan(0);
  expect(note.length).toBeGreaterThan(0);
  for (const u of human) expect(u.entry.origin).toEqual({ kind: 'human' });
  for (const u of note) expect(u.entry.origin).toBeUndefined();
});
