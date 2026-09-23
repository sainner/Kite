/**
 * 黑盒测试共用的小工具：建文件夹 / 仓库、跑 git、调 kited 接口、等事件。
 * 只依据接口契约，不依赖 kited 的实现。
 */
import { afterAll, beforeAll } from 'bun:test';
import { existsSync, lstatSync, mkdirSync, readdirSync, readFileSync, readlinkSync, rmSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { startKited, type Kited } from './harness.ts';

/** 测试自己跑 git 用的环境：不读用户的全局配置，身份用环境变量给。 */
const GIT_ENV: Record<string, string> = {
  PATH: process.env.PATH ?? '/usr/bin:/bin',
  HOME: process.env.TMPDIR ?? '/tmp',
  LANG: 'en_US.UTF-8',
  GIT_CONFIG_GLOBAL: '/dev/null',
  GIT_CONFIG_NOSYSTEM: '1',
  GIT_TERMINAL_PROMPT: '0',
  GIT_AUTHOR_NAME: '测试者',
  GIT_AUTHOR_EMAIL: 'tester@example.com',
  GIT_COMMITTER_NAME: '测试者',
  GIT_COMMITTER_EMAIL: 'tester@example.com',
};

function runGit(cwd: string, args: string[]) {
  const r = Bun.spawnSync(['git', '-c', 'core.quotepath=false', ...args], { cwd, env: GIT_ENV, stdout: 'pipe', stderr: 'pipe' });
  return { code: r.exitCode, out: r.stdout.toString().replace(/\n$/, ''), err: r.stderr.toString() };
}

/** 跑 git，失败抛错；返回去掉末尾换行的 stdout。 */
export function git(cwd: string, ...args: string[]): string {
  const r = runGit(cwd, args);
  if (r.code !== 0) throw new Error(`git ${args.join(' ')} 失败（${cwd}）：${r.err}`);
  return r.out;
}

/** 跑 git，只看成不成功。 */
export function gitOk(cwd: string, ...args: string[]): boolean {
  return runGit(cwd, args).code === 0;
}

export function writeFiles(dir: string, files: Record<string, string>) {
  for (const [rel, content] of Object.entries(files)) {
    mkdirSync(dirname(join(dir, rel)), { recursive: true });
    writeFileSync(join(dir, rel), content);
  }
}

export const read = (p: string) => readFileSync(p, 'utf8');

let dirSeq = 0;
/** 在 k.root 下建一个全新的普通文件夹（父目录不是 git 仓库），写入文件。 */
export function newDir(k: Kited, name: string, files: Record<string, string> = {}): string {
  const parent = join(k.root, 'w', String(++dirSeq));
  mkdirSync(parent, { recursive: true });
  const dir = join(parent, name);
  mkdirSync(dir);
  writeFiles(dir, files);
  return dir;
}

/** 建一个已有提交的 git 仓库（分支 main）。 */
export function newRepo(k: Kited, name: string, files: Record<string, string>): string {
  const dir = newDir(k, name, files);
  git(dir, 'init', '-q', '-b', 'main');
  git(dir, 'add', '-A');
  git(dir, 'commit', '-q', '-m', 'init');
  return dir;
}

export function commitAll(dir: string, msg: string): string {
  git(dir, 'add', '-A');
  git(dir, 'commit', '-q', '-m', msg);
  return git(dir, 'rev-parse', 'HEAD');
}

/** 列出目录下所有文件（跳过 .git），值为内容；符号链接记为 `-> 目标`。 */
export function listTree(dir: string): Record<string, string> {
  const out: Record<string, string> = {};
  const walk = (rel: string) => {
    for (const name of readdirSync(join(dir, rel))) {
      if (rel === '' && name === '.git') continue;
      const r = rel ? `${rel}/${name}` : name;
      const st = lstatSync(join(dir, r));
      if (st.isSymbolicLink()) out[r] = `-> ${readlinkSync(join(dir, r))}`;
      else if (st.isDirectory()) walk(r);
      else out[r] = readFileSync(join(dir, r), 'utf8');
    }
  };
  walk('');
  return out;
}

export const isSymlink = (p: string) => existsSync(p) && lstatSync(p).isSymbolicLink();
/** 路径本身（不跟随链接）是否存在。 */
export const lexists = (p: string) => { try { lstatSync(p); return true; } catch { return false; } };

export async function pollUntil<T>(fn: () => T | undefined | false | Promise<T | undefined | false>, timeoutMs = 10_000, intervalMs = 100): Promise<T | undefined> {
  const end = Date.now() + timeoutMs;
  while (true) {
    const v = await fn();
    if (v) return v;
    if (Date.now() > end) return undefined;
    await Bun.sleep(intervalMs);
  }
}

/** 每个 describe 起一个 kited；返回取实例的函数。 */
export function useKited(): () => Kited {
  let k: Kited | undefined;
  beforeAll(async () => { k = await startKited(); }, 30_000);
  afterAll(async () => {
    if (!k) return;
    await k.stop();
    if (!process.env.KITE_TEST_KEEP) rmSync(k.root, { recursive: true, force: true });
  }, 30_000);
  return () => k!;
}

// ---- 接口 ----

export async function register(k: Kited, path: string): Promise<any> {
  const r = await k.call('POST', '/projects', { path });
  if (r.status !== 200) throw new Error(`登记 ${path} 失败：${r.status} ${JSON.stringify(r.body)}`);
  return r.body;
}

export async function getSession(k: Kited, id: string): Promise<any> {
  const r = await k.call('GET', `/sessions/${id}`);
  if (r.status !== 200) throw new Error(`取会话 ${id} 失败：${r.status} ${JSON.stringify(r.body)}`);
  return r.body;
}

/**
 * 时间点标记：t 是本机时刻（和假端点日志的 at 比），i 是当时已收到的事件数。
 * 判断事件是否发生在某个动作之后用 i（同一毫秒内的先后也分得清）；传数字则按事件的 at 比。
 */
export interface Mark { t: number; i: number }
export const mark = (k: Kited): Mark => ({ t: Date.now(), i: k.events.length });
export type Since = Mark | number;
export function isAfter(k: Kited, e: any, since: Since): boolean {
  return typeof since === 'number' ? e.at >= since : k.events.indexOf(e) >= since.i;
}

/** 等会话离开 preparing，返回最新视图。 */
export async function waitPrepared(k: Kited, id: string): Promise<any> {
  const v = await pollUntil(async () => { const s = await getSession(k, id); return s.status !== 'preparing' && s; }, 30_000);
  if (!v) throw new Error(`会话 ${id} 一直在 preparing`);
  return v;
}

/** 新建会话并等它准备好（status 为 open）。返回视图和发起前的标记。 */
export async function startSession(k: Kited, project: string, prompt: string): Promise<{ s: any; t0: Mark }> {
  const t0 = mark(k);
  const r = await k.call('POST', '/sessions', { project, prompt });
  if (r.status !== 200) throw new Error(`建会话失败：${r.status} ${JSON.stringify(r.body)}`);
  const s = await waitPrepared(k, r.body.id);
  if (s.status !== 'open') throw new Error(`会话没有准备好：${JSON.stringify(s)}`);
  return { s, t0 };
}

/** 发消息，返回发之前的标记。 */
export async function send(k: Kited, id: string, text: string): Promise<Mark> {
  const t0 = mark(k);
  const r = await k.call('POST', `/sessions/${id}/messages`, { text });
  if (r.status !== 200) throw new Error(`发消息失败：${r.status} ${JSON.stringify(r.body)}`);
  return t0;
}

/** 等 since 之后的 idle 事件，再等接口上 busy 变 false。 */
export async function waitIdle(k: Kited, id: string, since: Since): Promise<void> {
  await k.waitEvent((e) => e.session === id && e.type === 'idle' && isAfter(k, e, since));
  const ok = await pollUntil(async () => !(await getSession(k, id)).busy, 10_000);
  if (!ok) throw new Error(`会话 ${id} idle 之后 busy 仍为 true`);
}

/** 等 since 之后 runner 变为 closed。 */
export function waitClosed(k: Kited, id: string, since: Since, timeoutMs = 60_000): Promise<any> {
  return k.waitEvent((e) => e.session === id && e.type === 'runner' && e.state === 'closed' && isAfter(k, e, since), timeoutMs);
}

/** 等 since 之后 runner 先变为 running 再变为 closed（一次完整的开关）。 */
export async function waitRunThenClosed(k: Kited, id: string, since: Since): Promise<void> {
  const run = await k.waitEvent((e) => e.session === id && e.type === 'runner' && e.state === 'running' && isAfter(k, e, since));
  await waitClosed(k, id, { t: run.at, i: k.events.indexOf(run) + 1 });
}

/** 等接口上 busy 变 true（用来在 agent 工作中发请求）。 */
export async function waitBusy(k: Kited, id: string): Promise<void> {
  const ok = await pollUntil(async () => (await getSession(k, id)).busy, 10_000, 50);
  if (!ok) throw new Error(`会话 ${id} 一直没有 busy`);
}

export async function snapshots(k: Kited, id: string): Promise<Array<{ commit: string; at: number; label: string; toolUseIds: string[] }>> {
  const r = await k.call('GET', `/sessions/${id}/snapshots`);
  if (r.status !== 200) throw new Error(`取快照失败：${r.status} ${JSON.stringify(r.body)}`);
  return r.body;
}

/** 主循环请求里，最后一条用户消息含 token 的那些。 */
export function mainReqs(k: Kited, token: string) {
  return k.api.log.filter((l) => l.main && l.lastUserText.includes(token));
}

/** since 之后这个会话的事件。 */
export function eventsSince(k: Kited, id: string, since: Since, type?: string): any[] {
  return k.events.filter((e) => e.session === id && (!type || e.type === type) && isAfter(k, e, since));
}

/** since 之后这个会话的 SDK assistant 消息里出现的 tool_use id。 */
export function toolUseIdsSince(k: Kited, id: string, since: Since): string[] {
  const ids: string[] = [];
  for (const e of eventsSince(k, id, since, 'sdk')) {
    if (e.message?.type !== 'assistant') continue;
    for (const b of e.message.message?.content ?? []) if (b.type === 'tool_use') ids.push(b.id);
  }
  return ids;
}
