/** 回退语义的正确性检查。用法：bun verify.ts <临时目录> */
import { execSync } from 'node:child_process';
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync, renameSync } from 'node:fs';
import { join } from 'node:path';
import { capture, git, openFolder, restore, restoreFile } from './snap';

const root = process.argv[2];
if (!root) throw new Error('需要临时目录参数');
rmSync(root, { recursive: true, force: true });
mkdirSync(root, { recursive: true });
const kiteHome = join(root, 'kite-home');
let failures = 0;
const check = (name: string, ok: boolean) => { console.log(`${ok ? '✓' : '✗'} ${name}`); if (!ok) failures++; };
const read = (p: string) => (existsSync(p) ? readFileSync(p, 'utf8') : null);
const sh = (cmd: string, cwd: string) => execSync(cmd, { cwd, encoding: 'utf8' }).trim();

// ---------- git 仓库 ----------
{
  console.log('\n[git 仓库]');
  const w = join(root, 'repo');
  mkdirSync(w);
  sh('git init -q -b main && git config user.email u@x && git config user.name u', w);
  writeFileSync(join(w, 'a.txt'), 'a1\n');
  writeFileSync(join(w, 'b.txt'), 'b1\n');
  writeFileSync(join(w, '.gitignore'), '*.log\n');
  sh('git add -A && git commit -qm init', w);
  // 用户自己暂存了一处改动：回退不能动它
  writeFileSync(join(w, 'b.txt'), 'b-staged\n');
  sh('git add b.txt', w);
  writeFileSync(join(w, 'run.log'), 'log-1\n');

  const f = openFolder(w, kiteHome, 'repo');
  const s1 = capture(f, 's', '第一回合前');

  // agent 这一回合：编辑、Bash 删除、移动、新建目录、改被忽略文件、自己提交一次
  writeFileSync(join(w, 'a.txt'), 'a2\n');
  rmSync(join(w, 'b.txt'));
  mkdirSync(join(w, 'dir/sub'), { recursive: true });
  writeFileSync(join(w, 'dir/sub/new.txt'), 'new\n');
  writeFileSync(join(w, 'c.txt'), 'c\n');
  writeFileSync(join(w, 'run.log'), 'log-2\n');
  sh('git add c.txt && git commit -qm agent-commit -- c.txt', w);
  const headAfterAgent = sh('git rev-parse HEAD', w);
  renameSync(join(w, 'c.txt'), join(w, 'c-moved.txt'));
  const s2 = capture(f, 's', '第一回合后');
  check('第二枚快照的父节点包含 agent 的提交', git(f, ['rev-list', '--parents', '-n1', s2.commit]).includes(headAfterAgent));
  check('变更文件数统计到 Bash 的删除和移动（a 改、b 删、new 新建、c 移动后的新名）', s2.changedFiles === 4);

  const userIndexBeforeRestore = sh('git ls-files -s', w);
  const r = restore(f, 's', s1.commit);
  check('a.txt 回到 a1', read(join(w, 'a.txt')) === 'a1\n');
  check('被 Bash 删掉的 b.txt 回来了，内容是当时盘上的版本', read(join(w, 'b.txt')) === 'b-staged\n');
  check('之后新建的文件被删掉', !existsSync(join(w, 'dir/sub/new.txt')) && !existsSync(join(w, 'c-moved.txt')));
  check('之后新建的空目录被清掉', !existsSync(join(w, 'dir')));
  check('被忽略的 run.log 不动', read(join(w, 'run.log')) === 'log-2\n');
  check('HEAD 不动（仍是 agent 的提交）', sh('git rev-parse HEAD', w) === headAfterAgent);
  check('分支不动', sh('git rev-parse main', w) === headAfterAgent);
  check('用户的暂存区不动（回退前后逐条相同）', sh('git ls-files -s', w) === userIndexBeforeRestore);
  check('用户暂存的 b.txt 内容仍是 b-staged', sh('git show :b.txt', w) === 'b-staged');
  check('文件夹里没有多出 git 以外的东西', !existsSync(join(w, '.kite')));

  restoreFile(f, s2.commit, 'a.txt');
  check('单文件恢复：a.txt 回到 a2，其他不动', read(join(w, 'a.txt')) === 'a2\n' && read(join(w, 'b.txt')) === 'b-staged\n');
  restoreFile(f, s2.commit, 'b.txt');
  check('单文件恢复：快照里不存在的文件被删掉', !existsSync(join(w, 'b.txt')));

  restore(f, 's', r.safety.commit);
  check('撤销回退：回到回退前的状态', read(join(w, 'dir/sub/new.txt')) === 'new\n' && read(join(w, 'c-moved.txt')) === 'c\n' && !existsSync(join(w, 'b.txt')));
  check('快照不产生分支、不出现在 git log --all 的分支里', sh('git branch --list', w).split('\n').length === 1);
}

// ---------- 普通文件夹 ----------
{
  console.log('\n[普通文件夹]');
  const w = join(root, 'plain');
  mkdirSync(join(w, 'data'), { recursive: true });
  writeFileSync(join(w, 'paper.tex'), '\\section{v1}\n');
  writeFileSync(join(w, 'data/raw.csv'), 'x,y\n1,2\n');
  writeFileSync(join(w, 'figure.png'), Buffer.from([0x89, 0x50, 0x4e, 0x47, 1, 2, 3]));
  writeFileSync(join(w, '.DS_Store'), 'junk');
  writeFileSync(join(w, '中文 文件名.md'), '笔记 v1\n');
  const f = openFolder(w, kiteHome, 'plain');
  check('识别为普通文件夹', f.mode === 'hidden');
  const s1 = capture(f, 's', '开始');
  check('文件夹里不出现 .git', !existsSync(join(w, '.git')));
  check('.DS_Store 默认被忽略', !git(f, ['ls-tree', '-r', '--name-only', s1.commit]).includes('.DS_Store'));

  execSync(`rm -rf "${join(w, 'data')}" && mv "${join(w, 'paper.tex')}" "${join(w, 'paper-old.tex')}"`);
  writeFileSync(join(w, '中文 文件名.md'), '笔记 v2\n');
  writeFileSync(join(w, 'figure.png'), Buffer.from([9, 9, 9]));
  capture(f, 's', 'agent 用 Bash 删了 data、改了名');
  restore(f, 's', s1.commit);
  check('rm -rf 删掉的目录回来了', read(join(w, 'data/raw.csv')) === 'x,y\n1,2\n');
  check('mv 改名的文件回到原名、新名消失', existsSync(join(w, 'paper.tex')) && !existsSync(join(w, 'paper-old.tex')));
  check('中文带空格的文件名正常', read(join(w, '中文 文件名.md')) === '笔记 v1\n');
  check('二进制文件逐字节还原', readFileSync(join(w, 'figure.png')).equals(Buffer.from([0x89, 0x50, 0x4e, 0x47, 1, 2, 3])));
  check('.DS_Store 不动', read(join(w, '.DS_Store')) === 'junk');
}

console.log(failures === 0 ? '\n全部通过' : `\n${failures} 项失败`);
process.exit(failures === 0 ? 0 : 1);
