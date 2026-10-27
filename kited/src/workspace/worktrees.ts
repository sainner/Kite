/**
 * 工作区的工作树：放在 Kite 数据目录里，从检出（裸仓库）开出。建好之后由调用方写入设了路径的项目密钥，再跑项目的初始化脚本 .kite/setup。
 * 检出里没有可以带入的忽略文件，所以不处理 worktree.symlinkDirectories 与 .worktreeinclude。
 */
import { closeSync, existsSync, mkdirSync, openSync, readFileSync, realpathSync, rmSync, writeFileSync, writeSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { KiteError } from '../errors.ts';
import { git, gitTry } from './git.ts';
import { WorkspaceFiles } from './files.ts';
import { runScript } from '../script.ts';
import { commandEnvironment, prepareSandbox } from '../execution/sandbox.ts';
import { harnessPolicy } from '../execution/policy.ts';
import { forgetWorktree } from './snapshots.ts';
import { ATTACHMENT_DIR } from './attachments.ts';

const SETUP_TIMEOUT_MS = 15 * 60_000;

/** base 为 null 时检出已有的分支（流转来的工作区），否则从 base 新建分支。 */
export async function addWorktree(checkout: string, worktree: string, branch: string, base: string | null): Promise<void> {
  // 同一路径可能刚删过旧工作树（流转回原机），快照的路径缓存要按新建的 git 目录重查。
  forgetWorktree(worktree);
  mkdirSync(dirname(worktree), { recursive: true });
  await git(checkout, ['worktree', 'add', '-q', ...(base === null ? [worktree, branch] : ['-b', branch, worktree, base])]);
}

const EXCLUDED = /# Kite：项目密钥写进工作区的文件，不进 Git\n([\s\S]*?)# Kite：以上\n?/;

/**
 * 设了路径的项目密钥记进检出（Kite 自己的仓库）的 info/exclude：本机这个项目的工作树都忽略它们，快照、集成与同步的提交
 * 不会带上，项目的 .gitignore 之后怎么改都一样。项目跟踪的文件不受 exclude 影响，由 writeSecretFiles 的检查拦下。
 * 返回原来记着、这次没有的路径：密钥删了或换了路径，这些文件要从工作树里删掉。
 */
export function excludeSecretFiles(checkout: string, paths: string[]): string[] {
  const file = join(checkout, 'info', 'exclude');
  const current = existsSync(file) ? readFileSync(file, 'utf8') : '';
  const before = (EXCLUDED.exec(current)?.[1] ?? '').split('\n').filter(Boolean).map((line) => line.slice(1).replace(/\\(.)/g, '$1'));
  let kept = current.replace(EXCLUDED, '');
  if (kept && !kept.endsWith('\n')) kept += '\n';
  // 从仓库根起的确切路径，通配符转义
  const block = paths.map((path) => `/${path.replace(/[*?[\\]/g, (c) => `\\${c}`)}`).join('\n');
  const next = paths.length ? `${kept}# Kite：项目密钥写进工作区的文件，不进 Git\n${block}\n# Kite：以上\n` : kept;
  if (next !== current) {
    mkdirSync(dirname(file), { recursive: true });
    writeFileSync(file, next);
  }
  return before.filter((path) => !paths.includes(path));
}

const ATTACHMENTS_EXCLUDED = `# Kite：消息附件放进工作区的那份，不进 Git\n/${ATTACHMENT_DIR}/\n`;

/** 检出忽略工作区里的附件目录（见 attachments.ts），本机这个项目的工作树都不把它带进快照、集成与同步的提交。已经记着就不动。 */
export function excludeAttachments(checkout: string): void {
  const file = join(checkout, 'info', 'exclude');
  const current = existsSync(file) ? readFileSync(file, 'utf8') : '';
  if (current.includes(ATTACHMENTS_EXCLUDED)) return;
  mkdirSync(dirname(file), { recursive: true });
  writeFileSync(file, (current && !current.endsWith('\n') ? `${current}\n` : current) + ATTACHMENTS_EXCLUDED);
}

/**
 * 把设了路径的项目密钥写进工作树，权限 0600。先用 git check-ignore 确认路径都被忽略（检出的 info/exclude 已记下它们，
 * 没被忽略就是项目跟踪的文件），免得快照把它提交进 Git；有这样的或路径经链接逃出工作树的，一个都不写并报错。
 */
export async function writeSecretFiles(worktree: string, files: Array<{ path: string; value: string }>): Promise<void> {
  if (!files.length || !existsSync(worktree)) return;
  const tree = new WorkspaceFiles(worktree);
  const r = await gitTry(tree.root, ['check-ignore', '-z', '--stdin'], { input: files.map((file) => file.path).join('\0') + '\0' });
  const ignored = new Set(r.stdout.split('\0').filter(Boolean));
  const exposed = files.filter((file) => !ignored.has(file.path)).map((file) => file.path);
  if (exposed.length) throw new KiteError(`这些路径上是项目跟踪的文件，密钥不能写进工作区：${exposed.join('、')}。先把它们从 Git 里移除并忽略`, 409);
  const targets = files.map((file) => ({ target: tree.resolve(file.path), value: file.value }));
  for (const { target, value } of targets) {
    mkdirSync(dirname(target), { recursive: true });
    // 新建文件，不跟着已有的链接写到别处，权限也按新文件的给。
    rmSync(target, { force: true });
    writeFileSync(target, value, { mode: 0o600 });
  }
}

/** 删掉工作树里不再由密钥提供的文件（密钥删了或改了路径）。 */
export function removeSecretFile(worktree: string, path: string): void {
  if (!existsSync(worktree)) return;
  try { rmSync(new WorkspaceFiles(worktree).resolve(path), { force: true }); }
  catch { /* 路径经链接指到了工作树外面：不删 */ }
}

/**
 * 跑工作树里的 .kite/setup，没有这个文件返回 null。只看退出码，脚本不写状态文件。输出写进 logPath，另外留下最后 4000 个字符给事件用。
 * 与模型的 shell 共用沙箱：工作树可写、工具链可读，宿主数据受保护，Git 元数据（含检出）只读，skill 的文件夹不放行（只给代理）；
 * 环境只带开发工具的基础设置。网络在项目级网络授权落地前放行。
 */
export async function runSetup(checkout: string, worktree: string, logPath: string, home: string, signal?: AbortSignal): Promise<{ exit: number; tail: string } | null> {
  if (!existsSync(join(worktree, '.kite', 'setup'))) return null;
  // 沙箱只放行工作树的真实路径：数据目录的 worktrees 换成指向别的盘的符号链接后，经链接的路径在沙箱里打不开（Operation not permitted，sh 退出 126）
  const script = join(realpathSync(worktree), '.kite', 'setup');
  mkdirSync(dirname(logPath), { recursive: true });
  const env = commandEnvironment(process.env);
  const policy = await harnessPolicy({ cwd: worktree, env, home, repository: checkout });
  const fd = openSync(logPath, 'w');
  let sandbox: ReturnType<typeof prepareSandbox> | undefined;
  try {
    sandbox = prepareSandbox(`exec '${script.replaceAll("'", "'\\''")}'`, { cwd: worktree, env, network: 'open', policy });
    const r = await runScript(sandbox.executable, {
      args: sandbox.args, cwd: worktree, env: sandbox.env, timeoutMs: SETUP_TIMEOUT_MS, keep: 4000, signal,
      onOutput: (text) => writeSync(fd, text),
    });
    if (!r.stopped) return { exit: r.code ?? 124, tail: r.tail };
    const note = `\n.kite/setup 超过 ${SETUP_TIMEOUT_MS / 60_000} 分钟，已停止\n`;
    writeSync(fd, note);
    // 超时按 timeout 命令的惯例记 124
    return { exit: 124, tail: (r.tail + note).slice(-4000) };
  } finally {
    sandbox?.dispose();
    closeSync(fd);
  }
}

/** 删掉工作树和工作区分支。快照引用 refs/kite/snapshots/<工作区> 不动。 */
export async function removeWorktree(checkout: string, worktree: string, branch: string): Promise<void> {
  forgetWorktree(worktree);
  if ((await gitTry(checkout, ['worktree', 'remove', '--force', '--force', worktree])).code !== 0) {
    await git(checkout, ['worktree', 'prune']);
  }
  await gitTry(checkout, ['branch', '-D', branch]);
}
