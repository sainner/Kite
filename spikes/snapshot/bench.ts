/** 快照耗时与对象库增长。用法：bun bench.ts <临时目录> [场景...]，场景：pigeon research big */
import { execSync } from 'node:child_process';
import { randomBytes } from 'node:crypto';
import { appendFileSync, mkdirSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { capture, git, objectStoreBytes, openFolder, restore, type Folder } from './snap';

const root = process.argv[2];
const only = process.argv.slice(3);
if (!root) throw new Error('需要临时目录参数');
mkdirSync(root, { recursive: true });
const kiteHome = join(root, 'kite-home');
const sh = (cmd: string, cwd = root) => execSync(cmd, { cwd, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }).trim();
const median = (xs: number[]) => [...xs].sort((a, b) => a - b)[Math.floor(xs.length / 2)];
const ms = (x: number) => `${Math.round(x)} ms`;
const mb = (b: number) => `${(b / 1024 / 1024).toFixed(1)} MB`;
const rows: string[][] = [];
const row = (scene: string, what: string, value: string) => { rows.push([scene, what, value]); console.log(`${scene} | ${what} | ${value}`); };
const timeIt = (fn: () => void) => { const t = performance.now(); fn(); return performance.now() - t; };
let sessionSeq = 0;

function suite(scene: string, f: Folder, turn: () => void, extra?: () => void) {
  const s = `bench${++sessionSeq}`;
  const before = objectStoreBytes(f);
  const cold = capture(f, s, '首次');
  row(scene, '首次快照（要读全部文件）', ms(cold.ms));
  row(scene, '首次快照后对象库增长', mb(objectStoreBytes(f) - before));
  row(scene, '无改动快照，私有索引（中位数/5 次）', ms(median([0, 1, 2, 3, 4].map(() => capture(f, s, '空').ms))));
  const fs = `${s}-fresh`;
  capture(f, fs, '预热', 'fresh');
  row(scene, '无改动快照，每次新建临时索引（中位数/3 次）', ms(median([0, 1, 2].map(() => capture(f, fs, '空', 'fresh').ms))));
  const b2 = objectStoreBytes(f);
  turn();
  const t = capture(f, s, '一个回合');
  row(scene, `一个回合后快照（${t.changedFiles} 个文件变化）`, ms(t.ms));
  row(scene, '这一回合对象库增长', mb(objectStoreBytes(f) - b2));
  row(scene, '整体回退到首次快照', ms(restore(f, s, cold.commit).ms));
  extra?.();
}

// ---------- 场景一：Pigeon 仓库 ----------
if (!only.length || only.includes('pigeon')) {
  const w = join(root, 'pigeon');
  rmSync(w, { recursive: true, force: true });
  sh(`git clone -q --local /Users/sainner/Projects/Pigeon ${w}`);
  sh('bun install --ignore-scripts >/dev/null 2>&1 || true', w);
  const files = Number(sh('git ls-files | wc -l', w));
  row('Pigeon', '规模', `${files} 个跟踪文件，node_modules 已装（被忽略）`);
  row('Pigeon', '参照：git status', ms(median([0, 1, 2].map(() => timeIt(() => sh('git status --porcelain >/dev/null', w))))));
  const f = openFolder(w, kiteHome, 'pigeon');
  const tsFiles = sh("git ls-files 'src/*.ts' | head -20", w).split('\n');
  suite('Pigeon', f, () => {
    for (const p of tsFiles.slice(0, 5)) appendFileSync(join(w, p), '\n// edited\n');
    rmSync(join(w, tsFiles[5]));
    sh('rm -rf docs/archive 2>/dev/null || true', w);
    mkdirSync(join(w, 'scratch'), { recursive: true });
    for (let i = 0; i < 20; i++) writeFileSync(join(w, 'scratch', `n${i}.ts`), `export const x${i} = ${i};\n`);
  });
}

// ---------- 场景二：科研式普通文件夹 ----------
if (!only.length || only.includes('research')) {
  const w = join(root, 'research');
  rmSync(w, { recursive: true, force: true });
  const words = 'the of model data result figure table we propose method sample error mean variance'.split(' ');
  const text = (n: number) => Array.from({ length: n }, (_, i) => words[(i * 7 + n) % words.length]).join(' ');
  for (const d of ['chapters', 'scripts', 'notes', 'data', 'figures', 'refs']) mkdirSync(join(w, d), { recursive: true });
  for (let i = 0; i < 1500; i++) writeFileSync(join(w, 'notes', `note-${i}.md`), `# 笔记 ${i}\n${text(300 + (i % 200))}\n`);
  for (let i = 0; i < 40; i++) writeFileSync(join(w, 'chapters', `ch${i}.tex`), `\\section{${i}}\n${text(4000)}\n`);
  for (let i = 0; i < 200; i++) writeFileSync(join(w, 'scripts', `analysis_${i}.py`), `import numpy as np\n# ${text(200)}\n`);
  for (let i = 0; i < 40; i++) writeFileSync(join(w, 'data', `run-${i}.csv`), Array.from({ length: 40000 }, (_, r) => `${r},${(r * 0.37 + i) % 97},${(r * 13) % 101}`).join('\n'));
  for (let i = 0; i < 25; i++) writeFileSync(join(w, 'figures', `fig-${i}.png`), randomBytes(3 * 1024 * 1024));
  for (let i = 0; i < 15; i++) writeFileSync(join(w, 'refs', `paper-${i}.pdf`), randomBytes(4 * 1024 * 1024));
  mkdirSync(join(w, '.venv/lib'), { recursive: true });
  for (let i = 0; i < 500; i++) writeFileSync(join(w, '.venv/lib', `m${i}.py`), text(100));
  const size = Number(sh(`du -sk "${w}"`).split('\t')[0]) * 1024;
  const count = Number(sh(`find "${w}" -type f | wc -l`));
  row('科研文件夹', '规模', `${count} 个文件，${mb(size)}，含 .venv（默认忽略）`);
  const f = openFolder(w, kiteHome, 'research');
  suite('科研文件夹', f, () => {
    appendFileSync(join(w, 'chapters/ch3.tex'), '\n新增一段\n');
    appendFileSync(join(w, 'data/run-7.csv'), '\n40000,1,2');
    writeFileSync(join(w, 'figures/fig-2.png'), randomBytes(3 * 1024 * 1024));
    sh('rm -rf refs', w);
    writeFileSync(join(w, 'scripts/new_plot.py'), 'import matplotlib\n');
  });
  const b = objectStoreBytes(f);
  git(f, ['gc', '-q', '--prune=now']);
  row('科研文件夹', 'gc 前后对象库', `${mb(b)} → ${mb(objectStoreBytes(f))}`);
}

// ---------- 场景三：五万个小文件 ----------
if (!only.length || only.includes('big')) {
  const w = join(root, 'big');
  rmSync(w, { recursive: true, force: true });
  for (let d = 0; d < 500; d++) {
    mkdirSync(join(w, `pkg${d}`, 'src'), { recursive: true });
    for (let i = 0; i < 100; i++) writeFileSync(join(w, `pkg${d}`, 'src', `f${i}.ts`), `export const v${d}_${i} = ${d * i};\n// ${'x'.repeat(i * 10)}\n`);
  }
  row('五万小文件', '规模', `${readdirSync(w).length * 100} 个文件`);
  const f = openFolder(w, kiteHome, 'big');
  const turn = () => { for (let i = 0; i < 10; i++) appendFileSync(join(w, `pkg${i}`, 'src', 'f1.ts'), '\n// e\n'); rmSync(join(w, 'pkg9'), { recursive: true }); };
  suite('五万小文件', f, turn);
  git(f, ['config', 'core.untrackedCache', 'true']);
  git(f, ['config', 'core.fsmonitor', 'true']);
  const s = 'fsm';
  capture(f, s, '预热一');
  capture(f, s, '预热二');
  row('五万小文件', '无改动快照，私有索引 + fsmonitor + untrackedCache（中位数/5 次）', ms(median([0, 1, 2, 3, 4].map(() => capture(f, s, '空').ms))));
  for (let i = 0; i < 10; i++) appendFileSync(join(w, `pkg${i + 20}`, 'src', 'f2.ts'), '\n// e\n');
  row('五万小文件', '10 个文件变化后快照，同上配置', ms(capture(f, s, '改动').ms));
  try { git(f, ['fsmonitor--daemon', 'stop']); } catch {}
}

console.log('\n| 场景 | 测量 | 结果 |\n|---|---|---|');
for (const r of rows) console.log(`| ${r.join(' | ')} |`);
