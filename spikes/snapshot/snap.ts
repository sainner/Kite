/**
 * 1a 快照验证原型：把整个文件夹的当前状态存成 git commit，挂在 refs/kite/<会话>，
 * 不碰用户的 HEAD、分支和暂存区。两种文件夹：
 *  - repo：本身是 git 仓库，对象写进它自己的对象库；
 *  - hidden：普通文件夹，对象库放在 Kite 目录，用 --git-dir/--work-tree 分离，文件夹里不出现 .git。
 * 两种索引策略用来对比耗时：
 *  - persistent：每个会话一个私有索引，保留文件修改时间，下次只需 stat；
 *  - fresh：每次新建临时索引（Pigeon 的做法），每次都要重读所有文件算哈希。
 */
import { spawnSync } from 'node:child_process';
import { existsSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';

export type IndexStrategy = 'persistent' | 'fresh';

export interface Folder {
  mode: 'repo' | 'hidden';
  workTree: string;
  gitDir: string; // 该工作树自己的 git 目录（repo 模式下是 rev-parse --git-dir）
  env: Record<string, string>; // hidden 模式带 GIT_DIR / GIT_WORK_TREE
}

/** hidden 模式下默认忽略的东西：系统垃圾、依赖和虚拟环境、编辑器临时文件。 */
const HIDDEN_DEFAULT_EXCLUDES = [
  '.DS_Store', '._*', '.Spotlight-V100', '.Trashes', 'Icon\r',
  'node_modules/', '.venv/', 'venv/', '__pycache__/', '.ipynb_checkpoints/',
  '~$*', '*.swp', '.~lock.*#',
];

export function git(folder: Folder, args: string[], opts: { env?: Record<string, string>; input?: string } = {}): string {
  const r = spawnSync('git', ['-c', 'core.quotePath=false', ...args], {
    cwd: folder.workTree,
    env: { ...process.env, ...folder.env, ...opts.env },
    input: opts.input,
    encoding: 'utf8',
    maxBuffer: 1 << 30,
  });
  if (r.status !== 0) throw new Error(`git ${args.join(' ')} 失败: ${r.stderr}`);
  return r.stdout.trim();
}

export function openFolder(workTree: string, kiteHome: string, id: string): Folder {
  const inRepo = spawnSync('git', ['rev-parse', '--show-toplevel'], { cwd: workTree, encoding: 'utf8' });
  if (inRepo.status === 0 && inRepo.stdout.trim() === workTree) {
    const f: Folder = { mode: 'repo', workTree, gitDir: '', env: {} };
    f.gitDir = git(f, ['rev-parse', '--absolute-git-dir']);
    return f;
  }
  const gitDir = join(kiteHome, 'repos', `${id}.git`);
  const env = { GIT_DIR: gitDir, GIT_WORK_TREE: workTree };
  const f: Folder = { mode: 'hidden', workTree, gitDir, env };
  if (!existsSync(gitDir)) {
    mkdirSync(gitDir, { recursive: true });
    const { GIT_DIR: _d, GIT_WORK_TREE: _w, ...clean } = process.env;
    const r = spawnSync('git', ['init', '-q', '--bare', gitDir], { env: clean, encoding: 'utf8' });
    if (r.status !== 0) throw new Error(`git init 失败: ${r.stderr}`);
    git(f, ['config', 'core.bare', 'false']);
    git(f, ['config', 'core.worktree', workTree]);
    mkdirSync(join(gitDir, 'info'), { recursive: true });
    writeFileSync(join(gitDir, 'info', 'exclude'), HIDDEN_DEFAULT_EXCLUDES.join('\n') + '\n');
  }
  return f;
}

export const snapRef = (session: string) => `refs/kite/${session}`;

function readRef(folder: Folder, ref: string): string | null {
  try { return git(folder, ['rev-parse', '--verify', '--quiet', `${ref}^{commit}`]); } catch { return null; }
}

function headCommit(folder: Folder): string | null {
  if (folder.mode === 'hidden') return null;
  return readRef(folder, 'HEAD');
}

export interface Snapshot { commit: string; tree: string; ms: number; changedFiles: number; }

/** 捕获整个工作树。用户自己的索引、HEAD、分支都不动。 */
export function capture(folder: Folder, session: string, label: string, strategy: IndexStrategy = 'persistent'): Snapshot {
  const t0 = performance.now();
  const ref = snapRef(session);
  const previous = readRef(folder, ref);
  const head = headCommit(folder);

  let tmpRoot: string | null = null;
  let indexPath: string;
  if (strategy === 'persistent') {
    mkdirSync(join(folder.gitDir, 'kite'), { recursive: true });
    indexPath = join(folder.gitDir, 'kite', `index-${session}`);
  } else {
    tmpRoot = mkdtempSync(join(tmpdir(), 'kite-idx-'));
    indexPath = join(tmpRoot, 'index');
  }
  const env = { GIT_INDEX_FILE: indexPath };
  try {
    if (!existsSync(indexPath)) {
      const base = previous ?? head;
      git(folder, base ? ['read-tree', base] : ['read-tree', '--empty'], { env });
    }
    git(folder, ['add', '-A', '--', '.'], { env });
    const tree = git(folder, ['write-tree'], { env });

    const prevTree = previous ? git(folder, ['rev-parse', `${previous}^{tree}`]) : null;
    if (prevTree === tree && previous) {
      return { commit: previous, tree, ms: performance.now() - t0, changedFiles: 0 };
    }
    const changed = prevTree
      ? git(folder, ['diff-tree', '-r', '--name-only', '--no-renames', prevTree, tree]).split('\n').filter(Boolean).length
      : -1;
    const parents: string[] = [];
    if (previous) parents.push('-p', previous);
    if (head && (!previous || !isAncestor(folder, head, previous))) parents.push('-p', head);
    const commit = git(folder, ['commit-tree', tree, ...parents, '-m', label], {
      env: { GIT_AUTHOR_NAME: 'Kite', GIT_AUTHOR_EMAIL: 'kite@localhost', GIT_COMMITTER_NAME: 'Kite', GIT_COMMITTER_EMAIL: 'kite@localhost' },
    });
    // 比较并交换：ref 自读取后被别人动过就失败，不覆盖
    git(folder, ['update-ref', '--no-deref', ref, commit, previous ?? '']);
    return { commit, tree, ms: performance.now() - t0, changedFiles: changed };
  } finally {
    if (tmpRoot) rmSync(tmpRoot, { recursive: true, force: true });
  }
}

function isAncestor(folder: Folder, a: string, b: string): boolean {
  const r = spawnSync('git', ['merge-base', '--is-ancestor', a, b], { cwd: folder.workTree, env: { ...process.env, ...folder.env } });
  return r.status === 0;
}

/**
 * 把整个工作树恢复成某个快照：只动文件，不动 HEAD、分支和用户的暂存区。
 * 先捕获一次当前状态（撤销这次回退的安全网），私有索引此时就等于「当前」，
 * 再用 read-tree --reset -u 切到目标：当前有而目标没有的文件被删，被忽略的文件不碰。
 */
export function restore(folder: Folder, session: string, target: string): { safety: Snapshot; ms: number } {
  const t0 = performance.now();
  const safety = capture(folder, session, `回退前自动保存（目标 ${target.slice(0, 8)}）`);
  const indexPath = join(folder.gitDir, 'kite', `index-${session}`);
  const env = { GIT_INDEX_FILE: indexPath };
  git(folder, ['read-tree', '--reset', '-u', target], { env });
  // 目标树成为新的现状，记一枚快照让链头与盘上一致
  capture(folder, session, `回退到 ${target.slice(0, 8)}`);
  return { safety, ms: performance.now() - t0 };
}

/** 只恢复一个文件。快照里没有这个文件就删掉它。 */
export function restoreFile(folder: Folder, target: string, path: string): void {
  const exists = spawnSync('git', ['cat-file', '-e', `${target}:${path}`], { cwd: folder.workTree, env: { ...process.env, ...folder.env } }).status === 0;
  if (exists) git(folder, ['restore', `--source=${target}`, '--worktree', '--', path]);
  else rmSync(join(folder.workTree, path), { force: true });
}

export function objectStoreBytes(folder: Folder): number {
  const out = git(folder, ['count-objects', '-v']);
  const kv = Object.fromEntries(out.split('\n').map((l) => l.split(': ')));
  return (Number(kv['size']) + Number(kv['size-pack'])) * 1024;
}
