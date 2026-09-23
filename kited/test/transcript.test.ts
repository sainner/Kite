/**
 * 会话记录里的消息来源：需求 27。
 */
import { describe, expect, setDefaultTimeout, test } from 'bun:test';
import { Glob } from 'bun';
import { join } from 'node:path';
import { commitAll, mark, newDir, pollUntil, read, register, send, startSession, useKited, waitIdle, writeFiles } from './util.ts';

setDefaultTimeout(60_000);

/** Claude Code 会话记录里 type 为 user 的条目，附上文本。 */
function userEntries(configDir: string, nativeId: string): Array<{ entry: any; text: string }> {
  const files = [...new Glob(`projects/**/${nativeId}.jsonl`).scanSync(configDir)];
  if (files.length === 0) throw new Error(`找不到 ${nativeId}.jsonl`);
  const out: Array<{ entry: any; text: string }> = [];
  for (const f of files) {
    for (const line of read(join(configDir, f)).split('\n')) {
      if (!line.trim()) continue;
      const entry = JSON.parse(line);
      if (entry.type !== 'user') continue;
      const c = entry.message?.content;
      const text = typeof c === 'string' ? c : Array.isArray(c) ? c.filter((b: any) => b.type === 'text').map((b: any) => b.text).join('\n') : '';
      out.push({ entry, text });
    }
  }
  return out;
}

describe('需求 27：人发的消息带 origin，Kite 发的冲突说明不带', () => {
  const kited = useKited();

  test('会话记录里人发的消息带 origin human，冲突说明不带 origin', async () => {
    const k = kited();
    const dir = newDir(k, 'tr27', { 'c.txt': 'base\n' });
    const p = await register(k, dir);
    const { s, t0 } = await startSession(k, p.id, 'RUN echo session > c.txt # 标记H1');
    await waitIdle(k, s.id, t0);
    const t1 = await send(k, s.id, '第二条人话 标记H2');
    await waitIdle(k, s.id, t1);

    // 制造冲突，让 Kite 给 agent 发冲突说明
    writeFiles(dir, { 'c.txt': 'main\n' });
    commitAll(dir, 'main edits c');
    const m = mark(k);
    const r = await k.call('POST', `/sessions/${s.id}/adopt`);
    expect(r.body.status).toBe('conflict');
    await k.waitEvent((e) => e.session === s.id && e.type === 'adopt' && e.result?.status === 'adopted' && k.events.indexOf(e) >= m.i);

    const configDir = k.env.CLAUDE_CONFIG_DIR!;
    // 等说明冲突的那条消息落进会话记录
    await pollUntil(() => userEntries(configDir, s.nativeId).some((u) => u.text.includes('冲突')), 10_000);
    const entries = userEntries(configDir, s.nativeId);

    const h1 = entries.filter((u) => u.text.includes('标记H1'));
    const h2 = entries.filter((u) => u.text.includes('标记H2'));
    const note = entries.filter((u) => u.text.includes('冲突'));
    expect(h1.length).toBeGreaterThan(0);
    expect(h2.length).toBeGreaterThan(0);
    expect(note.length).toBeGreaterThan(0);
    for (const u of [...h1, ...h2]) expect(u.entry.origin).toEqual({ kind: 'human' });
    for (const u of note) expect(u.entry.origin).toBeUndefined();
  });
});
