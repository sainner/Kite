/**
 * kited 依赖的上游行为，直接用 SDK 起 Claude Code 验证，模型换成假端点：D9。
 * 只 import SDK：SDK 升级时 bun.lock 会变，触发全量。
 */
import { query } from '@anthropic-ai/claude-agent-sdk';
import { expect, setDefaultTimeout, test } from 'bun:test';
import { randomUUID } from 'node:crypto';
import { join } from 'node:path';
import { api } from '../setup.ts';
import { gitWorktree, newRepo, read, useTemp, writeFiles } from '../util.ts';

setDefaultTimeout(20_000);
const temp = useTemp();

/*
 * 上游行为三条：
 * 1. 系统提示用 claude_code 预设时带记忆段落，路径是 settings.autoMemoryDirectory（SDK 不指定 systemPrompt 时只发极简提示，没有这一段）；
 * 2. 在 git 工作树里运行时，Claude Code 读主仓库的 .claude/settings.local.json（所以 kited 不用把它复制进工作树）；
 * 3. Bash 工具的 edit diff 在 bypassPermissions 模式下默认开，在 git 仓库里每次调用前后各打一次快照，
 *    结果放在 SDK 发出的 user 消息的 tool_use_result.bashEditDiff 里（新建未跟踪文件也算）；
 *    经 SDK 的 settings 选项（相当于 --settings）传 bashEditDiffEnabled: false 能关掉它，kited 就是这样传的。
 *    Claude Code 2.1.280 实测。这里只测「关掉」这一半，默认开着那一半要多起一次 Claude Code。
 */
test('上游：claude_code 预设的系统提示带指向 autoMemoryDirectory 的记忆段落；在工作树里运行时主仓库 .claude/settings.local.json 的设置生效；settings 传 bashEditDiffEnabled: false 后 Bash 的结果里没有 edit diff', async () => {
  const root = temp();
  const main = newRepo(root, 'main', { 'a.txt': 'a\n' });
  // 没提交，所以不会随检出出现在工作树里
  writeFiles(main, { '.claude/settings.local.json': JSON.stringify({ env: { KITE_T_LOCAL: 'local-ok' } }) });
  const wt = gitWorktree(main, join(root, 'wt'), 'kite/up');
  const memory = join(wt, '.kite', 'memory');
  const tag = `标记D9-${randomUUID().slice(0, 8)}`;

  const q = query({
    prompt: `RUN printf %s "$KITE_T_LOCAL" > local.txt # ${tag}`,
    options: {
      cwd: wt,
      systemPrompt: { type: 'preset', preset: 'claude_code' },
      settingSources: ['user', 'project', 'local'],
      settings: { autoMemoryDirectory: memory, bashEditDiffEnabled: false },
      permissionMode: 'bypassPermissions',
      allowDangerouslySkipPermissions: true,
    },
  });
  const bashIds: string[] = [];
  const results = new Map<string, unknown>();
  for await (const m of q) {
    if (m.type === 'assistant') {
      for (const b of m.message.content) if (b.type === 'tool_use' && b.name === 'Bash') bashIds.push(b.id);
    } else if (m.type === 'user' && Array.isArray(m.message.content)) {
      for (const b of m.message.content) if (b.type === 'tool_result') results.set(b.tool_use_id, m.tool_use_result);
    } else if (m.type === 'result') break;
  }

  const req = api.log.find((l) => l.main && l.lastUserText.includes(tag));
  expect(req).toBeDefined();
  expect(JSON.stringify(req!.body.system)).toContain(memory);
  expect(read(join(wt, 'local.txt'))).toBe('local-ok');

  expect(bashIds).toHaveLength(1);
  const result = results.get(bashIds[0]!) as Record<string, unknown> | undefined;
  // 确实是 Bash 的结构化结果，免得字段整个没了也算通过
  expect(result).toHaveProperty('stdout');
  // 按名字里带 diff 找，上游改了字段名也挡得住
  expect(Object.keys(result!).filter((k) => /diff/i.test(k))).toEqual([]);
});
