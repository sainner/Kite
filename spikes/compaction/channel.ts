/**
 * 实验：宿主另挂一个进程内 MCP 服务 kite-internal，由 mod 的 tool.describe 设为延迟加载移出模型的工具列表，
 * 检查模型请求里是否看不到它、mod 能否经 $.mcp.call 调用它并拿到结果。disallowedTools 在 bypassPermissions 下藏不住它（第一次运行观察到）。用本机假端点。用法：bun channel.ts <输出目录>
 */
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { fakeApi, Inbox, isolated, kiteServer } from '../handoff/native.ts';
const SDK = '../../kited/node_modules/@anthropic-ai/claude-agent-sdk/sdk.mjs';
const { query, createSdkMcpServer, tool } = await import(SDK);
const { z } = await import('../../kited/node_modules/zod/index.js');

const out = resolve(process.argv[2]);
const cwd = join(out, 'work');
mkdirSync(cwd, { recursive: true });
const api = fakeApi();
const { options: base } = isolated(join(out, 'channel'), api.port, cwd);
const logFile = join(cwd, 'mod-log.txt');
const calls: unknown[] = [];
const internal = createSdkMcpServer({ name: 'kite-internal', tools: [
  tool('plan', '宿主内部接口，不给模型使用', { probe: z.string().optional(), echo: z.string().optional() }, async (args: any) => {
    calls.push(args);
    return { content: [{ type: 'text', text: JSON.stringify({ keep: [0, 2], instructions: '只概括第二轮' }) }] };
  }),
] });
const inbox = new Inbox();
let done: () => void = () => {};
const q = query({ prompt: inbox, options: {
  ...base, env: { ...base.env, KITE_SPIKE_LOG: logFile }, model: 'claude-sonnet-4-5', sessionId: crypto.randomUUID(),
  mcpServers: { kite: kiteServer(), 'kite-internal': internal },
  // 与 kited 一样带上 SDK 回调；不带时 mod 的 hook 不会被调用（前几次运行观察到）。
  hooks: { UserPromptSubmit: [{ hooks: [async () => ({ hookSpecificOutput: { hookEventName: 'UserPromptSubmit', additionalContext: 'KITE通知' } })] }] },
  plugins: [...(base.plugins ?? []), { type: 'local', path: join(import.meta.dir, 'channel-plugin'), skipMcpDiscovery: true }],
  stderr: (text: string) => stderr.push(text),
} });
const stderr: string[] = [];
const initialized: any = await q.initializationResult();
const loop = (async () => { for await (const message of q) if (message.type === 'result') done(); })();
const finished = new Promise<void>((resolve) => { done = resolve; });
inbox.push('第一个问题', crypto.randomUUID());
await finished;
// 回合结束 hook 在 result 之后异步调用，稍等一下再收口。
for (let i = 0; i < 80 && calls.length < 2; i++) await Bun.sleep(100);
inbox.close();
await loop;
api.stop();
const tools = api.log.filter((entry) => entry.body.tools).flatMap((entry) => entry.body.tools.map((item: any) => item.name));
const report = {
  modelTools: [...new Set(tools)],
  internalVisibleToModel: tools.some((name: string) => name.includes('kite-internal')),
  systemMentions: api.log.some((entry) => JSON.stringify(entry.body.system ?? '').includes('kite-internal')),
  calls,
  modError: existsSync(logFile) ? readFileSync(logFile, 'utf8') : null,
  plugins: { applied: initialized.plugins_applied, hooks: initialized.hooks_applied, errors: initialized.plugin_errors ?? initialized.errors,
    keys: Object.keys(initialized) },
  stderr: stderr.join('').split('\n').filter((line) => /plugin|hook|mod|error/i.test(line)).slice(0, 20),
};
writeFileSync(join(out, 'result.json'), JSON.stringify(report, null, 2));
console.log(JSON.stringify(report, null, 2));
