/**
 * Claude 后端的按需加载：kited 的 Claude 配置（tools: [] 关掉全部内置工具）下打开 ENABLE_TOOL_SEARCH，
 * kite 服务不设整体常驻，read 单独设 alwaysLoad，插件工具 todo_add 不设。
 * fake：接假端点，打印第一次主循环请求的工具声明（ToolSearch 在不在、todo_add 是否 defer_loading）与提到 todo_add 的位置。
 * real：真实 Anthropic API，让模型加一条待办，打印它调了哪些工具、ToolSearch 的结果形状。用本机默认 Claude 登录，消耗少量订阅额度。
 * resume：新进程接着 real 跑过的会话再加一条，看加载过的工具还能不能直接调用；带 strip 时先复制一份去掉 ToolSearch 的调用与结果，
 * 模拟从自研 harness 交接过来、历史里有插件工具调用却没有加载记录的会话。
 * 用法：bun claude.ts fake|real <工作目录> [模型]；bun claude.ts resume <real 用过的工作目录> <会话 ID> [strip]
 */
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join, resolve } from 'node:path';
import { claudeOptions } from '../../kited/src/claude/options.ts';
import { z } from '../../kited/node_modules/zod/index.js';
import { fakeApi, Inbox, isolated } from '../handoff/native.ts';
const { query, createSdkMcpServer, tool } = await import('../../kited/node_modules/@anthropic-ai/claude-agent-sdk/sdk.mjs');

const mode = process.argv[2];
const cwd = resolve(process.argv[3]);
const model = mode === 'resume' ? 'sonnet' : process.argv[4] ?? 'sonnet';
let resume: string | undefined;
if (mode === 'resume') {
  resume = process.argv[4];
  if (process.argv[5] === 'strip') {
    const dir = join(homedir(), '.claude', 'projects', cwd.replace(/[^a-zA-Z0-9]/g, '-'));
    const rows = readFileSync(join(dir, `${resume}.jsonl`), 'utf8').split('\n').filter(Boolean).map((line) => JSON.parse(line));
    const searchIds = new Set(rows.flatMap((row) => Array.isArray(row.message?.content)
      ? row.message.content.filter((b: any) => b.type === 'tool_use' && b.name === 'ToolSearch').map((b: any) => b.id) : []));
    const dropped = new Map<string, string | null>();
    const kept = rows.filter((row) => {
      const content = Array.isArray(row.message?.content) ? row.message.content : [];
      const drop = content.some((b: any) => (b.type === 'tool_use' && searchIds.has(b.id)) || (b.type === 'tool_result' && searchIds.has(b.tool_use_id)));
      if (drop) dropped.set(row.uuid, row.parentUuid);
      return !drop;
    });
    const copy = crypto.randomUUID();
    for (const row of kept) {
      while (row.parentUuid && dropped.has(row.parentUuid)) row.parentUuid = dropped.get(row.parentUuid)!;
      if (row.sessionId) row.sessionId = copy;
    }
    writeFileSync(join(dir, `${copy}.jsonl`), kept.map((row) => JSON.stringify(row)).join('\n') + '\n');
    console.log('去掉 ToolSearch 后的会话:', copy, '删掉', dropped.size, '行');
    resume = copy;
  }
}
mkdirSync(cwd, { recursive: true });

const added: string[] = [];
const server = () => createSdkMcpServer({ name: 'kite', tools: [
  tool('read', '读取文件', { path: z.string() }, async (args: any) => ({ content: [{ type: 'text', text: `${args.path} 的内容` }] }), { alwaysLoad: true }),
  tool('todo_add', '在待办插件里新增一条待办', { title: z.string() }, async (args: any) => {
    added.push(args.title);
    return { content: [{ type: 'text', text: `已添加：${args.title}` }] };
  }),
] });

let options: any;
let api: ReturnType<typeof fakeApi> | undefined;
if (mode === 'fake') {
  api = fakeApi();
  options = isolated(join(cwd, 'fake'), api.port, cwd).options;
  options.env.ENABLE_TOOL_SEARCH = process.env.PROBE_SEARCH ?? 'true';
} else {
  const base = claudeOptions(cwd);
  // 去掉本机 Claude Code 会话带进来的变量，按 kited 的方式启动。
  const env = Object.fromEntries(Object.entries(base.env!).filter(([key]) => !/^(CLAUDECODE|CLAUDE_PID|CLAUDE_EFFORT|CLAUDE_CODE_(ENTRYPOINT|MESSAGING_.*|EXECPATH|SESSION_ID|CHILD_SESSION|SESSION_ATTENDED))$/.test(key)));
  // 照 Kite 基础上下文的「插件工具」列出名字；关了附件，CLI 不会自己列出推迟的工具。
  options = { ...base, env: { ...env, ENABLE_TOOL_SEARCH: 'true' }, systemPrompt: { ...base.systemPrompt as object,
    prompt: `${(base.systemPrompt as { prompt: string }).prompt}\n\n插件工具（用 ToolSearch 加载后调用）：待办实例 todo-1 的 ${process.env.PROBE_NAME ?? 'mcp__kite__todo_add'}` } };
}

// PROBE_TOOLS=preset 换回内置工具全集、search 只放 ToolSearch，对照 tools: [] 的影响。
if (process.env.PROBE_TOOLS === 'preset') options.tools = { type: 'preset', preset: 'claude_code' };
if (process.env.PROBE_TOOLS === 'search') options.tools = ['ToolSearch'];
const inbox = new Inbox();
const q = query({ prompt: inbox, options: { ...options, model, mcpServers: { kite: server() }, ...(resume ? { resume } : {}) } });
inbox.push(mode === 'fake' ? '你好' : mode === 'resume' ? '再加一条待办「买面包」，加好后只回答「好了」。'
  : '用待办插件新增一条待办「买牛奶」，加好后只回答「好了」。', crypto.randomUUID());
const calls: Array<{ name: string; input: unknown }> = [];
for await (const m of q) {
  if (m.type === 'system' && m.subtype === 'init') console.log('init tools:', JSON.stringify(m.tools));
  if (m.type === 'assistant') for (const block of m.message.content) if (block.type === 'tool_use') calls.push({ name: block.name, input: block.input });
  if (m.type === 'user' && Array.isArray(m.message.content)) for (const block of m.message.content) {
    if (block.type === 'tool_result') console.log('tool_result:', JSON.stringify(block.content).slice(0, 400));
  }
  if (m.type === 'result') { console.log('result:', m.subtype, JSON.stringify(m.result ?? m.errors)); inbox.close(); }
}
if (api) {
  api.stop();
  const main = api.log.find((entry) => entry.main);
  if (!main) console.log('没有主循环请求');
  else {
    console.log('声明的工具:', JSON.stringify(main.body.tools.map((t: any) => ({ name: t.name, type: t.type, defer_loading: t.defer_loading }))));
    if (process.env.PROBE_DUMP) for (const t of main.body.tools) if (t.name === 'ToolSearch' || t.name === 'DeferredToolPlaceholder') console.log(JSON.stringify(t));
    const text = JSON.stringify({ system: main.body.system, messages: main.body.messages });
    const at = text.indexOf('todo_add');
    console.log('todo_add 出现在:', at < 0 ? '无' : text.slice(Math.max(0, at - 300), at + 100));
  }
} else console.log('调用:', JSON.stringify(calls), '新增:', JSON.stringify(added));
