/**
 * 测试共用的小工具：临时目录、建文件夹和仓库、跑 git、等状态。
 */
import { afterEach } from 'bun:test';
import { Glob } from 'bun';
import { lstatSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, readlinkSync, realpathSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';

/** 测试自己起子进程用的环境：隔离环境（setup.ts）加上 git 身份。Bun.spawn 不传 env 会继承启动时的真实环境。 */
export const ENV = (): Record<string, string> => ({
  ...(process.env as Record<string, string>),
  GIT_AUTHOR_NAME: '测试者',
  GIT_AUTHOR_EMAIL: 'tester@example.com',
  GIT_COMMITTER_NAME: '测试者',
  GIT_COMMITTER_EMAIL: 'tester@example.com',
});

function runGit(cwd: string, args: string[]) {
  const r = Bun.spawnSync(['git', '-c', 'core.quotepath=false', ...args], { cwd, env: ENV(), stdout: 'pipe', stderr: 'pipe' });
  return { code: r.exitCode, out: r.stdout.toString().replace(/\n$/, ''), err: r.stderr.toString() };
}

/** 跑 git，失败抛错；返回去掉末尾换行的 stdout。 */
export function git(cwd: string, ...args: string[]): string {
  const r = runGit(cwd, args);
  if (r.code !== 0) throw new Error(`git ${args.join(' ')} 失败（${cwd}）：${r.err}`);
  return r.out;
}

/** 跑 git，只看成不成功。 */
export const gitOk = (cwd: string, ...args: string[]) => runGit(cwd, args).code === 0;

export function writeFiles(dir: string, files: Record<string, string>) {
  for (const [rel, content] of Object.entries(files)) {
    mkdirSync(dirname(join(dir, rel)), { recursive: true });
    writeFileSync(join(dir, rel), content);
  }
}

export const read = (p: string) => readFileSync(p, 'utf8');

/** 路径本身（不跟随链接）是否存在。 */
export const lexists = (p: string) => { try { lstatSync(p); return true; } catch { return false; } };
export const isSymlink = (p: string) => lexists(p) && lstatSync(p).isSymbolicLink();

/** 新建一个临时目录（已解析符号链接）。 */
export const makeTemp = (prefix = 'kited-t-') => realpathSync(mkdtempSync(join(tmpdir(), prefix)));

/**
 * 在调用处（文件顶层或 describe 里）登记：每个测试结束时删掉它建的临时目录。
 * 返回的函数建一个临时目录。
 */
export function useTemp(): (prefix?: string) => string {
  const made: string[] = [];
  afterEach(() => { for (const d of made.splice(0)) rmSync(d, { recursive: true, force: true }); });
  return (prefix) => { const d = makeTemp(prefix); made.push(d); return d; };
}

/** 在 parent 下建名为 name 的文件夹，写入文件。 */
export function newDir(parent: string, name: string, files: Record<string, string> = {}): string {
  const dir = join(parent, name);
  mkdirSync(dir, { recursive: true });
  writeFiles(dir, files);
  return dir;
}

/** 建一个已有提交的 git 仓库（分支 main）。 */
export function newRepo(parent: string, name: string, files: Record<string, string>): string {
  const dir = newDir(parent, name, files);
  // 一次起一个 shell 做完，比分三次跑 git 快
  const r = Bun.spawnSync(['sh', '-c', 'git init -q -b main && git add -A && git commit -q -m init'], { cwd: dir, env: ENV(), stderr: 'pipe' });
  if (r.exitCode !== 0) throw new Error(`建仓库 ${dir} 失败：${r.stderr.toString()}`);
  return dir;
}

/** 提交全部改动，返回新提交。 */
export function commitAll(dir: string, msg: string): string {
  const r = Bun.spawnSync(['sh', '-c', 'git add -A && git commit -q -m "$1" && git rev-parse HEAD', 'sh', msg], { cwd: dir, env: ENV(), stdout: 'pipe', stderr: 'pipe' });
  if (r.exitCode !== 0) throw new Error(`提交 ${dir} 失败：${r.stderr.toString()}`);
  return r.stdout.toString().trim();
}

/** 列出目录下所有文件（跳过顶层 .git），值为内容；符号链接记为 `-> 目标`。 */
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

/**
 * 仓库的 HEAD、检出的分支、暂存区和工作区相对它们的改动（porcelain v2 带每个改动路径在暂存区里的对象），
 * 一次 git 调用拿到，用来确认「没被动过」。
 */
export const repoState = (dir: string) => git(dir, 'status', '--porcelain=v2', '--branch', '--untracked-files=all');

/** 等一个状态成立（轮询），超时抛错。 */
export async function until<T>(fn: () => T | undefined | null | false | Promise<T | undefined | null | false>, what: string, timeoutMs = 5_000): Promise<T> {
  const end = Date.now() + timeoutMs;
  while (true) {
    const v = await fn();
    if (v) return v;
    if (Date.now() > end) throw new Error(`等待超时：${what}`);
    await Bun.sleep(10);
  }
}

/** 给仓库 main 加一个工作树 wt，检出新分支 branch（从 HEAD 开始）。直接用 git，不经被测代码。 */
export function gitWorktree(main: string, wt: string, branch: string): string {
  git(main, 'worktree', 'add', '-q', '-b', branch, wt, 'HEAD');
  return wt;
}

/** Claude Code 的会话记录（CLAUDE_CONFIG_DIR 下 projects 里的 <nativeId>.jsonl）里的条目；写到一半的行跳过。 */
export function transcript(nativeId: string): any[] {
  const dir = process.env.CLAUDE_CONFIG_DIR!;
  return [...new Glob(`projects/**/${nativeId}.jsonl`).scanSync(dir)]
    .flatMap((f) => read(join(dir, f)).split('\n').filter((l) => l.trim()))
    .flatMap((l) => { try { return [JSON.parse(l)]; } catch { return []; } });
}
