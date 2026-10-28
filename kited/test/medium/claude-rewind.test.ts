/**
 * Claude 线程回退到一条人发消息之前：常驻进程退出，Claude 原生会话导入 journal 后在 journal 上回退，
 * 文件按快照还原，再整体重组 Claude 会话，下一回合从重组后的会话恢复。
 * Claude 一侧是真实 Claude Code 进程，模型换成假端点。
 */
import { afterEach, expect, setDefaultTimeout, test } from 'bun:test';
import { randomUUID } from 'node:crypto';
import { join } from 'node:path';
import type { RewindResult } from '../../src/kite.ts';
import type { History } from '../../src/transcript/protocol.ts';
import { api, claudeModel, folderWorkspace, type Kited, mark, openAgent, startKited, waitIdle } from '../harness.ts';
import { newDir, read, writeFiles } from '../util.ts';

setDefaultTimeout(3_000);
let k: Kited | undefined;
afterEach(async () => {
  await k?.stop(); k = undefined;
});

const tag = (name: string) => `${name}-${randomUUID().slice(0, 8)}`;
const json = (value: unknown) => JSON.stringify(value);
/** 正文在请求 JSON 里的样子（去掉首尾引号），换行等按转义比较。 */
const quoted = (text: string) => json(text).slice(1, -1);
/** CLI 合并相邻的用户消息时把字符串正文改成文本块；比较正文时按块比较。 */
const texts = (content: unknown) => (typeof content === 'string' ? [{ type: 'text', text: content }] : content as Array<{ type: string; text?: string }>)
  .flatMap((block) => block.type === 'text' ? [block.text] : []);
/** 回退到第一条消息后 Kite 放在分界后的说明，照抄 src/handoff/handoff.ts 的 REWOUND_TO_START（未导出）。 */
const REWOUND_TO_START = '之前的对话已全部回退，从下一条消息重新开始。';

/*
 * 依赖上游（SDK 0.3.280 自带的 CLI 2.1.280）：CLI 加载 Kite 重组后的会话时只取最后一个合成分界之后的链、按最后一条 last-prompt 接续；
 * 合成的条目比原会话少（回退掉了后面几轮）时照样只接续合成的这段，不把分界之前或原叶子上的条目带回来；
 * last-prompt 指向停在用户消息上的链（回退到第一条消息后，分界后只有 Kite 放的一条回退说明）时照样按它接续，
 * 并自己补一条不落盘的助手回复，再接下一条消息；last-prompt 直接停在 compact_boundary 上则不被采用，会退回原叶子带出全部旧历史。
 * 还依赖 Kite 的 PostToolBatch 钩子给快照记下的 tool_use id 与 Claude 原生记录里的调用 id 相同，导入 journal 后才能按 id 找到还原点。
 * Kite 在回合开头经 UserPromptSubmit 钩子送基础上下文更新，CLI 把钩子的附加上下文放成这条用户消息之后的一条 system 消息。
 * 配合：常驻进程退出与重启、原生会话导入 journal、journal 上的回退、快照还原、会话重组与显示投影接续，单看各部分都确认不了。
 * 真实出过的 bug：回退掉一个送过基础上下文更新的回合后，宿主仍记着更新已送过，之后不再发，代理一直用旧的上下文。
 */
test('Claude 线程回退到第二轮后文件回到原内容，第四轮只接续第一轮且显示只有第一、四轮；再回退到第一条消息（回退掉了第四轮送的项目规则更新），第五轮的请求里只有回退说明、第五轮和按现在的项目规则重发的基础上下文', async () => {
  k = startKited();
  const kk = k;
  const workspace = await folderWorkspace(kk, newDir(kk.root, 'project', { 'a.txt': '原始内容\n' }));
  const id = await openAgent(kk.call, workspace.workspace.id, claudeModel);
  const cwd = ((await kk.call('GET', `/threads/${id}`)).body as { workspace: { cwd: string } }).workspace.cwd;
  const history = async () => {
    const result = await kk.call('GET', `/threads/${id}/history`);
    expect(result.status).toBe(200);
    return result.body as History;
  };
  /** 发一条输入、等回合结束，返回这一轮的主循环请求。 */
  const round = async (inputId: string, text: string) => {
    const since = mark(kk);
    const start = api.log.length;
    expect((await kk.call('POST', `/threads/${id}/messages`, { id: inputId, text })).status).toBe(200);
    await api.waitRequest((l) => l.main && l.lastUserText.includes(text));
    await waitIdle(kk, id, since);
    return api.log.slice(start).filter((l) => l.main);
  };
  /** 回退对话；连文件一起回退时先预览，再带预览给的核对值确认。 */
  const rewind = async (input: string, files: boolean) => {
    let checked: { snapshot: string; through: string } | undefined;
    if (files) {
      const preview = await kk.call('POST', `/threads/${id}/rewind`, { input, conversation: true, files, preview: true });
      expect(preview.status).toBe(200);
      const target = (preview.body as RewindResult).files;
      checked = target && { snapshot: target.snapshot, through: target.through };
    }
    const result = await kk.call('POST', `/threads/${id}/rewind`, { input, conversation: true, files, ...checked ? { expect: checked } : {} });
    expect(result.status).toBe(200);
    return result.body as RewindResult;
  };

  const marks = { r1: tag('第一轮'), r2: tag('第二轮'), r3: tag('第三轮'), r4: tag('第四轮'), r5: tag('第五轮') };
  const edit = { operations: [{ type: 'update_file', path: 'a.txt', diff: '@@\n-原始内容\n+第二轮改过' }] };
  const readCall = (await round('r1', `${marks.r1}\nREAD {"path":"a.txt"}`)).flatMap((l) => l.toolUseIds)[0]!;
  const patchCall = (await round('r2', `${marks.r2}\nPATCH ${json(edit)}`)).flatMap((l) => l.toolUseIds)[0]!;
  expect(read(join(cwd, 'a.txt'))).toBe('第二轮改过\n');
  await round('r3', marks.r3);

  const rewound = await rewind('r2', true);
  expect(rewound.files?.others).toEqual([]);
  expect(read(join(cwd, 'a.txt'))).toBe('原始内容\n');

  // 第四轮从重组后的会话恢复：第一轮的输入、读文件调用与结果在，第二三轮的正文和改文件调用不在。
  // 第四轮之前人改了项目规则，第四轮开头送了一次带新规则的基础上下文更新。
  const rule = tag('第四轮前改的项目规则');
  writeFiles(cwd, { 'AGENTS.md': rule });
  const fourth = (await round('r4', marks.r4))[0]!;
  const sent = json(fourth.body.messages);
  expect(sent).toContain(rule);
  expect(sent).toContain(marks.r1);
  expect(sent).toContain(`"tool_use_id":"${readCall}"`);
  expect(sent).toContain(marks.r4);
  for (const gone of [marks.r2, marks.r3, patchCall, quoted('第二轮改过')]) expect(sent).not.toContain(gone);
  expect(sent.indexOf(marks.r1)).toBeLessThan(sent.indexOf(marks.r4));

  // 显示：重组写入的拷贝条目不重复显示，第四轮接在第一轮后面。
  const shown = (await history()).records;
  expect(shown.flatMap(({ block }) => block.type === 'human' ? [block.id] : [])).toEqual(['r1', 'r4']);
  expect(shown.filter(({ block }) => block.type === 'tool_use' && block.id === readCall)).toHaveLength(1);
  const blocks = json(shown.map((record) => record.block));
  for (const gone of [marks.r2, marks.r3, patchCall]) expect(blocks).not.toContain(gone);

  // 再回退到第一条消息、只回退对话：分界后只有 Kite 的回退说明，CLI 补一条助手回复，再接第五轮；旧内容一概不在。
  // 送过新规则的第四轮回退掉了，第五轮开头要按现在的规则再送一次基础上下文。
  expect((await rewind('r1', false)).files).toBeUndefined();
  const fifth = (await round('r5', marks.r5))[0]!;
  const messages = fifth.body.messages as Array<{ role: string; content: unknown }>;
  const only = json(messages);
  for (const gone of [marks.r1, marks.r4, readCall]) expect(only).not.toContain(gone);
  expect(json(messages.slice(3))).toContain(rule);
  expect(messages.map((message) => message.role)).toEqual(['user', 'assistant', 'user', 'system']);
  expect(json(messages[0]!.content)).toContain(REWOUND_TO_START);
  expect(texts(messages[2]!.content)).toEqual([marks.r5]);
  expect((await history()).records.flatMap(({ block }) => block.type === 'human' ? [block.id] : [])).toEqual(['r5']);
});
