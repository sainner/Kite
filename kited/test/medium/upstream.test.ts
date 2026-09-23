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
 * 上游行为两条：
 * 1. 系统提示用 claude_code 预设时带记忆段落，路径是 settings.autoMemoryDirectory（SDK 不指定 systemPrompt 时只发极简提示，没有这一段）；
 * 2. 在 git 工作树里运行时，Claude Code 读主仓库的 .claude/settings.local.json（所以 kited 不用把它复制进工作树）。
 */
test('上游：claude_code 预设的系统提示带指向 autoMemoryDirectory 的记忆段落；在工作树里运行时主仓库 .claude/settings.local.json 的设置生效', async () => {
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
      settings: { autoMemoryDirectory: memory },
      permissionMode: 'bypassPermissions',
      allowDangerouslySkipPermissions: true,
    },
  });
  for await (const m of q) if (m.type === 'result') break;

  const req = api.log.find((l) => l.main && l.lastUserText.includes(tag));
  expect(req).toBeDefined();
  expect(JSON.stringify(req!.body.system)).toContain(memory);
  expect(read(join(wt, 'local.txt'))).toBe('local-ok');
});
