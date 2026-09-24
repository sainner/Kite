/**
 * 会话工作树：放在项目文件夹外，由 Kite 管理。建好之后按上游 Claude Code 的格式带上被忽略的必需文件
 * （设置里的 worktree.symlinkDirectories 软链接，.worktreeinclude 复制），再跑项目的初始化脚本 .kite/setup。
 * 软链接和复制的规则照 Claude Code 2.1.280 自己建工作树时的做法：只处理相对路径，不跟随、不复制链接，
 * 目标经已提交的链接逃出工作树就跳过；.worktreeinclude 只复制同时被 .gitignore 忽略的文件。
 */
import { resolveSettings } from '@anthropic-ai/claude-agent-sdk';
import { closeSync, existsSync, lstatSync, mkdirSync, openSync, realpathSync, symlinkSync, writeSync } from 'node:fs';
import { constants, copyFile, mkdir } from 'node:fs/promises';
import { dirname, isAbsolute, join } from 'node:path';
import { git, gitTry } from './git.ts';
import { within } from './projects.ts';
import { SETTING_SOURCES } from './runner.ts';
import { runScript } from './script.ts';

const SETUP_TIMEOUT_MS = 15 * 60_000;

export async function addWorktree(main: string, worktree: string, branch: string, base: string): Promise<void> {
  mkdirSync(dirname(worktree), { recursive: true });
  await git(main, ['worktree', 'add', '-q', '-b', branch, worktree, base]);
  // escapes 按真实路径判断目标有没有经链接逃出工作树
  const real = realpathSync(worktree);
  await linkDirectories(main, real);
  await copyIncludes(main, real);
}

/** 目标路径的父目录经链接落到了工作树外面。 */
function escapes(dest: string, worktreeReal: string): boolean {
  let dir = dirname(dest);
  while (!existsSync(dir)) dir = dirname(dir);
  return !within(realpathSync(dir), worktreeReal);
}

async function linkDirectories(main: string, real: string): Promise<void> {
  // 和会话读同样的设置层，用户级的不算
  const { effective } = await resolveSettings({ cwd: main, settingSources: SETTING_SOURCES });
  for (const d of effective.worktree?.symlinkDirectories ?? []) {
    if (isAbsolute(d) || d.split(/[/\\]/).some((s) => /^\.\.[ .]*$/.test(s))) continue;
    const src = join(main, d);
    const dest = join(real, d);
    if (!existsSync(src) || existsSync(dest) || escapes(dest, real)) continue;
    mkdirSync(dirname(dest), { recursive: true });
    symlinkSync(src, dest);
  }
}

async function copyIncludes(main: string, real: string): Promise<void> {
  const patterns = join(main, '.worktreeinclude');
  if (!existsSync(patterns)) return;
  const split = (s: string) => s.split('\0').filter(Boolean);
  // 主文件夹里匹配 .worktreeinclude 的未跟踪文件，再留下被仓库自己的规则忽略的那些
  const matched = split(await git(main, ['ls-files', '-z', '--others', '--ignored', `--exclude-from=${patterns}`]));
  if (matched.length === 0) return;
  const ignored = split((await gitTry(main, ['check-ignore', '-z', '--stdin'], { input: matched.join('\0') + '\0' })).stdout);
  // 同一个目录只判断、只建一次；复制用异步的，文件多时不卡住 kited 的事件循环
  const dirs = new Map<string, boolean>();
  for (const f of ignored) {
    const src = join(main, f);
    const dest = join(real, f);
    const dir = dirname(dest);
    if (lstatSync(src).isSymbolicLink()) continue;
    let ok = dirs.get(dir);
    if (ok === undefined) {
      ok = !escapes(dest, real);
      if (ok) await mkdir(dir, { recursive: true });
      dirs.set(dir, ok);
    }
    // APFS 上是克隆，不额外占空间
    if (ok) await copyFile(src, dest, constants.COPYFILE_FICLONE);
  }
}

/**
 * 跑工作树里的 .kite/setup，没有这个文件返回 null。只看退出码；主文件夹位置经 KITE_MAIN_DIR 告诉脚本，
 * 脚本不需要自己判断身份，也不写状态文件。输出写进 logPath，另外留下最后 4000 个字符给事件用。
 */
export async function runSetup(main: string, worktree: string, logPath: string): Promise<{ exit: number; tail: string } | null> {
  const script = join(worktree, '.kite', 'setup');
  if (!existsSync(script)) return null;
  mkdirSync(dirname(logPath), { recursive: true });
  const fd = openSync(logPath, 'w');
  let tail = '';
  const write = (text: string) => {
    writeSync(fd, text);
    tail = (tail + text).slice(-4000);
  };
  try {
    const r = await runScript(script, { cwd: worktree, env: { ...process.env, KITE_MAIN_DIR: main }, timeoutMs: SETUP_TIMEOUT_MS, onOutput: write });
    if (r.stopped) write(`\n.kite/setup 超过 ${SETUP_TIMEOUT_MS / 60_000} 分钟，已停止\n`);
    // 超时按 timeout 命令的惯例记 124
    return { exit: r.code ?? 124, tail };
  } finally {
    closeSync(fd);
  }
}

/** 删掉工作树和会话分支。快照引用 refs/kite/snapshots/<会话> 不动。 */
export async function removeWorktree(main: string, worktree: string, branch: string): Promise<void> {
  if ((await gitTry(main, ['worktree', 'remove', '--force', '--force', worktree])).code !== 0) {
    await git(main, ['worktree', 'prune']);
  }
  await gitTry(main, ['branch', '-D', branch]);
}
