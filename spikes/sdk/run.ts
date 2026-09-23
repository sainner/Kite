/**
 * 1b：Agent SDK 常驻进程验证。用假端点驱动真实的 Claude Code（SDK 自带 2.1.280）。
 * 用法：bun run.ts <临时目录>
 */
import { query, type SDKUserMessage } from '@anthropic-ai/claude-agent-sdk';
import { spawn, execSync, type ChildProcess } from 'node:child_process';
import { existsSync, mkdirSync, readdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { startFakeApi, type Logged } from './fake-api';

const root = process.argv[2];
if (!root) throw new Error('需要临时目录参数');
rmSync(root, { recursive: true, force: true });
mkdirSync(root, { recursive: true });
const fake = startFakeApi();
const cfgDir = join(root, 'claude-config');
const home = join(root, 'home');
mkdirSync(cfgDir); mkdirSync(home);
const env = {
  PATH: '/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin',
  HOME: home, TMPDIR: process.env.TMPDIR ?? '/tmp', LANG: 'en_US.UTF-8', USER: process.env.USER ?? 'u', SHELL: '/bin/zsh',
  CLAUDE_CONFIG_DIR: cfgDir,
  ANTHROPIC_BASE_URL: `http://127.0.0.1:${fake.port}`,
  ANTHROPIC_API_KEY: 'sk-ant-fake',
  CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC: '1',
};
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
const median = (xs: number[]) => [...xs].sort((a, b) => a - b)[Math.floor(xs.length / 2)];
const rows: string[][] = [];
const row = (exp: string, what: string, value: string) => { rows.push([exp, what, value]); console.log(`${exp} | ${what} | ${value}`); };
const details: Record<string, unknown> = {};
let markSeq = 0;
const mark = (tag = 'M') => `<<${tag}${String(++markSeq).padStart(3, '0')}>>`;

class Inbox implements AsyncIterable<SDKUserMessage> {
  private buf: SDKUserMessage[] = [];
  private wake?: () => void;
  private closed = false;
  push(text: string, priority?: 'now' | 'next' | 'later') {
    this.buf.push({ type: 'user', message: { role: 'user', content: text }, parent_tool_use_id: null, ...(priority ? { priority } : {}) });
    this.wake?.();
  }
  close() { this.closed = true; this.wake?.(); }
  async *[Symbol.asyncIterator]() {
    while (true) {
      while (this.buf.length) yield this.buf.shift()!;
      if (this.closed) return;
      await new Promise<void>((r) => (this.wake = r));
      this.wake = undefined;
    }
  }
}

class Sess {
  inbox = new Inbox();
  msgs: Array<{ at: number; m: any }> = [];
  sessionId?: string;
  child?: ChildProcess;
  error?: unknown;
  ended: Promise<void>;
  private resultWaiters: Array<(m: any) => void> = [];
  constructor(cwd: string, extra: Record<string, unknown> = {}) {
    const q = query({
      prompt: this.inbox,
      options: {
        cwd, env, settingSources: [], allowedTools: ['Bash'],
        stderr: () => {},
        spawnClaudeCodeProcess: (o) => {
          const cp = spawn(o.command, o.args, { cwd: o.cwd, env: o.env as any, stdio: ['pipe', 'pipe', 'pipe'] });
          cp.stderr?.resume();
          this.child = cp;
          return cp as any;
        },
        ...extra,
      },
    });
    this.ended = (async () => {
      try {
        for await (const m of q) {
          this.msgs.push({ at: Date.now(), m });
          if ((m as any).session_id) this.sessionId = (m as any).session_id;
          if (m.type === 'result') this.resultWaiters.shift()?.(m);
        }
      } catch (e) { this.error = e; }
    })();
  }
  /** 先登记等待，再投递；返回投递时刻和本条结果的 Promise。 */
  send(text: string, priority?: 'now' | 'next' | 'later') {
    const result = new Promise<any>((r) => this.resultWaiters.push(r));
    const at = Date.now();
    this.inbox.push(text, priority);
    return { at, result };
  }
  rssKb(): number { return Number(execSync(`ps -o rss= -p ${this.child!.pid}`).toString().trim()); }
}

const waitReq = (m: string, toolResult = false) => fake.waitFor((l) => l.lastUserText.includes(m) && l.hasToolResult === toolResult);
/**
 * 去掉会随轮次移动的 cache_control 标记，只比较内容。
 * 另外把字符串形式的 content 统一成单个文本块：带缓存标记的消息必须写成数组，
 * 标记挪走后 Claude Code 会退回字符串写法，两者内容相同。
 */
const norm = (x: unknown) => JSON.stringify(x, (k, v) => {
  if (k === 'cache_control') return undefined;
  if (k === 'content' && typeof v === 'string') return [{ type: 'text', text: v }];
  return v;
});
function comparePrefix(before: Logged, after: Logged) {
  const n = before.body.messages.length;
  return {
    system: norm(before.body.system) === norm(after.body.system),
    tools: norm(before.body.tools) === norm(after.body.tools),
    messagesPrefix: norm(before.body.messages) === norm(after.body.messages.slice(0, n)),
    messagesPrefixRaw: JSON.stringify(before.body.messages) === JSON.stringify(after.body.messages.slice(0, n)),
    beforeCount: n, afterCount: after.body.messages.length,
  };
}
/** 列出所有不同的位置，给人看。 */
function firstDiff(before: Logged, after: Logged): string {
  const a = before.body.messages, b = after.body.messages;
  const diffs: string[] = [];
  for (let i = 0; i < a.length; i++) {
    if (norm(a[i]) !== norm(b[i])) diffs.push(`第 ${i}/${a.length} 条：之前 ${norm(a[i]).slice(0, 200)} ／之后 ${norm(b[i]).slice(0, 200)}`);
  }
  return diffs.length ? diffs.join('\n') : '无';
}
const summarize = (m: any) => typeof m.content === 'string'
  ? `${m.role}: ${m.content.slice(0, 160)}`
  : `${m.role}: ` + m.content.map((b: any) => b.type === 'text' ? `text(${b.text.slice(0, 200).replace(/\n/g, ' ')})` : b.type === 'tool_result' ? `tool_result(${JSON.stringify(b.content).slice(0, 120)}${b.is_error ? ', is_error' : ''})` : b.type === 'tool_use' ? `tool_use(${b.name})` : b.type).join(' + ');

const projA = join(root, 'projA');
mkdirSync(projA);

// ---------- E1 常驻多轮 + 长对话 ----------
{
  const t0 = Date.now();
  const s = new Sess(projA);
  const m0 = mark('T');
  s.send(`第一句 ${m0}`);
  const r0 = await waitReq(m0);
  row('E1', '新会话冷启动：创建到第一次请求', `${r0.at - t0} ms`);
  await s.msgs.length; // no-op
  const init = s.msgs.find((x) => x.m.type === 'system' && x.m.subtype === 'init')?.m;
  details.init = { claude_code_version: init?.claude_code_version, model: init?.model, tools: init?.tools?.length };
  await sleep(300);
  fake.config.pad = 20000;
  const deliver: number[] = []; const e2e: number[] = [];
  const pid1 = s.child!.pid;
  let rss1 = 0, size1 = 0;
  let prev49: Logged | undefined;
  for (let i = 1; i <= 50; i++) {
    const m = mark('T');
    const { at, result } = s.send(`第 ${i} 轮 ${m}`);
    const req = await waitReq(m);
    await result;
    deliver.push(req.at - at); e2e.push(Date.now() - at);
    if (i === 1) { rss1 = s.rssKb(); size1 = JSON.stringify(req.body).length; }
    if (i === 49) prev49 = req;
    if (i === 50) {
      const cmp = comparePrefix(prev49!, req);
      row('E1', '对照：正常运行时相邻两轮，历史前缀相同（去标记 / 原样）', `${cmp.messagesPrefix} / ${cmp.messagesPrefixRaw}`);
      if (!cmp.messagesPrefix) details.e1Diff = firstDiff(prev49!, req);
    }
    if (i === 50) {
      row('E1', '50 轮后仍是同一个进程', String(s.child!.pid === pid1));
      row('E1', '请求体大小 第 1 轮 → 第 50 轮', `${(size1 / 1024).toFixed(0)} KB → ${(JSON.stringify(req.body).length / 1024).toFixed(0)} KB`);
      row('E1', '进程内存 第 1 轮 → 第 50 轮', `${(rss1 / 1024).toFixed(0)} MB → ${(s.rssKb() / 1024).toFixed(0)} MB`);
    }
  }
  fake.config.pad = 0;
  row('E1', '投递延迟（投递到请求发出）前 10 轮中位数', `${median(deliver.slice(0, 10))} ms`);
  row('E1', '投递延迟 后 10 轮中位数', `${median(deliver.slice(-10))} ms`);
  row('E1', '投递延迟 最大', `${Math.max(...deliver)} ms`);
  row('E1', '一轮往返（投递到收到结果）中位数', `${median(e2e)} ms`);
  details.e1 = { deliver, e2e };

  // ---------- E2 休眠与唤醒：关闭输入让进程退出，再 resume ----------
  const lastBefore = fake.log.filter((l) => l.main).at(-1)!;
  const sid = s.sessionId!;
  s.inbox.close();
  const tClose = Date.now();
  await s.ended;
  row('E2', '关闭输入后进程退出用时', `${Date.now() - tClose} ms（退出码 ${s.child!.exitCode}）`);
  const wake: number[] = [];
  let sPrev: Sess | null = null; let lastReq = lastBefore;
  for (let k = 0; k < 3; k++) {
    const t1 = Date.now();
    const s2 = new Sess(projA, { resume: sid });
    const m = mark('W');
    const { result } = s2.send(`唤醒 ${m}`);
    const req = await waitReq(m);
    wake.push(req.at - t1);
    await result;
    if (k === 0) {
      const cmp = comparePrefix(lastReq, req);
      row('E2', '唤醒后 system / tools 与休眠前逐字节相同', `${cmp.system} / ${cmp.tools}`);
      row('E2', '唤醒后历史前缀与休眠前相同（去掉 cache_control 标记 / 原样）', `${cmp.messagesPrefix} / ${cmp.messagesPrefixRaw}`);
      if (!cmp.messagesPrefix) details.e2Diff = firstDiff(lastReq, req);
      details.e2Tail = req.body.messages.slice(-3).map(summarize);
    }
    lastReq = req;
    s2.inbox.close(); await s2.ended; sPrev = s2;
  }
  row('E2', '唤醒（resume 约 1 MB 历史）到第一次请求，3 次中位数', `${median(wake)} ms`);
  details.e2Wake = wake;

  // ---------- E3 空闲时被杀 ----------
  {
    const s3 = new Sess(projA, { resume: sid });
    const m = mark('K');
    const { result } = s3.send(`被杀前 ${m}`);
    const before = await waitReq(m);
    await result;
    await sleep(300);
    s3.child!.kill('SIGKILL');
    await s3.ended;
    row('E3', '空闲时 SIGKILL：SDK 迭代器的表现', s3.error ? `抛错：${String((s3.error as Error).message).slice(0, 80)}` : '正常结束，无错误');
    const s4 = new Sess(projA, { resume: sid });
    const m2 = mark('K');
    const { result: r2 } = s4.send(`被杀后 ${m2}`);
    const after = await waitReq(m2);
    await r2;
    const cmp = comparePrefix(before, after);
    row('E3', '被杀后 resume：历史前缀相同（去标记 / 原样）', `${cmp.messagesPrefix} / ${cmp.messagesPrefixRaw}`);
    if (!cmp.messagesPrefix) details.e3Diff = firstDiff(before, after);
    s4.inbox.close(); await s4.ended;
  }
}

// ---------- E4 回合中插话（默认优先级） ----------
const projB = join(root, 'projB');
mkdirSync(projB);
{
  const s = new Sess(projB);
  const m = mark('S');
  const { result } = s.send(`SLEEP 3 ${m}`);
  await waitReq(m);
  await sleep(1000);
  const i1 = mark('I');
  const tIns = Date.now();
  s.inbox.push(`插话 ${i1}`);
  const next = await fake.waitFor((l) => l.hasToolResult && l.at > tIns);
  await result;
  await sleep(1500);
  const results = s.msgs.filter((x) => x.m.type === 'result').length;
  row('E4', '工具执行中插话：下一次请求何时发出（插话后）', `${next.at - tIns} ms（工具还剩约 2 秒）`);
  row('E4', '插话出现在下一次请求里', String(JSON.stringify(next.body.messages.at(-1)).includes(i1)));
  row('E4', '这一回合产生的 result 条数', String(results));
  details.e4Tail = next.body.messages.slice(-2).map(summarize);
  const sid = s.sessionId!;
  s.inbox.close(); await s.ended;
  const jsonl = readdirSync(join(cfgDir, 'projects')).map((d) => join(cfgDir, 'projects', d, `${sid}.jsonl`)).find(existsSync)!;
  details.e4Jsonl = readFileSync(jsonl, 'utf8').split('\n').filter(Boolean).map((l) => JSON.parse(l))
    .filter((o) => o.type === 'queue-operation' || o.attachment?.type === 'queued_command')
    .map((o) => o.type === 'queue-operation' ? `queue-operation ${o.operation}${o.reason ? ' ' + o.reason : ''}` : `attachment queued_command`);
}

// ---------- E5 插话带 priority: 'now' ----------
{
  const s = new Sess(projB);
  const m = mark('S');
  s.send(`SLEEP 6 ${m}`);
  await waitReq(m);
  await sleep(1000);
  const i2 = mark('N');
  const tIns = Date.now();
  s.inbox.push(`急事 ${i2}`, 'now');
  const next = await fake.waitFor((l) => l.at > tIns, 20000);
  await sleep(2000);
  row('E5', 'priority now 插话：下一次请求何时发出', `${next.at - tIns} ms（工具本应还剩约 5 秒）`);
  details.e5Tail = next.body.messages.slice(-3).map(summarize);
  s.inbox.close(); await s.ended;
}

// ---------- E6 回合中被杀（工具执行到一半） ----------
{
  const s = new Sess(projB);
  const m = mark('S');
  s.send(`SLEEP 6 ${m}`);
  await waitReq(m);
  await sleep(1500);
  const sid = s.sessionId!;
  s.child!.kill('SIGKILL');
  await s.ended;
  const s2 = new Sess(projB, { resume: sid });
  const c = mark('C');
  const { result } = s2.send(`继续 ${c}`);
  const req = await waitReq(c);
  await result;
  row('E6', '工具执行中被杀后 resume：能接上', 'true');
  details.e6Tail = req.body.messages.slice(-4).map(summarize);
  s2.inbox.close(); await s2.ended;
}

// ---------- E7 在工作树里跑，工作树删除后能否恢复 ----------
{
  const main = join(root, 'repo');
  const wt = join(root, 'repo-wt');
  mkdirSync(main);
  execSync(`git init -q -b main && git -c user.email=u@x -c user.name=u commit -q --allow-empty -m init && git worktree add -q -b s1 ${wt}`, { cwd: main });
  const s = new Sess(wt);
  const m = mark('W');
  const { result } = s.send(`工作树里 ${m}`);
  const req = await waitReq(m);
  await result;
  const sid = s.sessionId!;
  s.inbox.close(); await s.ended;
  const dirs = readdirSync(join(cfgDir, 'projects')).filter((d) => existsSync(join(cfgDir, 'projects', d, `${sid}.jsonl`)));
  row('E7', '会话记录所在目录（按 cwd 命名）', dirs.join(', '));
  const envText = JSON.stringify(req.body).match(/isWorktree|Is a git worktree[^\\"]*|worktree[^\\"]{0,60}/i)?.[0] ?? '请求里没找到工作树字样';
  row('E7', '请求里对工作树的描述', envText);
  execSync(`git worktree remove --force ${wt}`, { cwd: main });
  // 从主文件夹 resume
  const s2 = new Sess(main, { resume: sid });
  const m2 = mark('W');
  const { result: r2 } = s2.send(`主文件夹里恢复 ${m2}`);
  const got = await Promise.race([waitReq(m2).then((l) => l), sleep(15000).then(() => null)]);
  if (got) {
    await r2;
    row('E7', '工作树删除后从主文件夹 resume', `能恢复；请求里带着之前的历史：${JSON.stringify(got.body.messages).includes(m)}`);
  } else {
    await sleep(500);
    const res = s2.msgs.find((x) => x.m.type === 'result')?.m;
    row('E7', '工作树删除后从主文件夹 resume', `不能恢复：${res?.subtype ?? ''} ${String(res?.errors ?? res?.result ?? s2.error ?? '').slice(0, 120)}`);
  }
  s2.inbox.close(); await s2.ended;
}

fake.stop();
writeFileSync(join(root, 'details.json'), JSON.stringify({ rows, ...details }, null, 2));
console.log('\n| 实验 | 测量 | 结果 |\n|---|---|---|');
for (const r of rows) console.log(`| ${r.join(' | ')} |`);
console.log('\n细节：');
const { e1, ...rest } = details as any;
console.log(JSON.stringify(rest, null, 2).slice(0, 8000));
process.exit(0);
