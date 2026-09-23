/**
 * Kite 仓库的检查命令，由 .kite/check 调用，契约见 kite-onboard skill（.claude/skills/kite-onboard/SKILL.md）。
 * 先做类型检查，再跑受影响的测试（--all 跑全量），最后按测试规则的预算核对耗时。
 * 受影响的测试从 KITE_BASE 起算改动，没有这个变量就看还没提交的改动；依赖或配置变了跑全量。
 * 输出只报结论、失败项和超预算项，完整日志写进 node_modules/.cache/kite-check/。
 */
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

const KITED = join(import.meta.dir, '..');
const LOG_DIR = join(KITED, 'node_modules', '.cache', 'kite-check');
const LOG = join(LOG_DIR, 'last.log');

/** 预算，和 .claude/agents/test-writer.md 里的分层表一致。 */
const LIMIT = { small: 1, medium: 2 };
const MEDIUM_MAX = 8;
const TOTAL_MAX = 15;

/** 这些变了依赖图看不出影响范围，跑全量。 */
const FULL_TRIGGERS = ['kited/package.json', 'kited/bun.lock', 'kited/tsconfig.json', 'kited/bunfig.toml'];

mkdirSync(LOG_DIR, { recursive: true });
writeFileSync(LOG, '');
const log = (text: string) => writeFileSync(LOG, text, { flag: 'a' });

function run(cmd: string[], cwd = KITED): { code: number; out: string } {
  const r = Bun.spawnSync(cmd, { cwd, stdout: 'pipe', stderr: 'pipe' });
  const out = r.stdout.toString() + r.stderr.toString();
  log(`$ ${cmd.join(' ')}\n${out}\n`);
  return { code: r.exitCode, out };
}

function fail(lines: string[]): never {
  console.log([...lines, `完整日志：${LOG}`].join('\n'));
  process.exit(1);
}

// 1. 类型检查
const tsc = run(['bunx', 'tsc', '--noEmit']);
if (tsc.code !== 0) {
  const errors = tsc.out.split('\n').filter((l) => /error TS\d+/.test(l));
  fail([`类型检查没通过，${errors.length} 处错误：`, ...errors.slice(0, 20).map((l) => `  ${l}`)]);
}

// 2. 跑哪些测试
const base = process.env.KITE_BASE;
const root = run(['git', 'rev-parse', '--show-toplevel']).out.trim();
const changed = [
  ...run(['git', 'diff', '--name-only', base ?? 'HEAD'], root).out.split('\n'),
  ...run(['git', 'ls-files', '--others', '--exclude-standard'], root).out.split('\n'),
].filter(Boolean);
const full = process.argv.includes('--all') || changed.some((f) => FULL_TRIGGERS.includes(f));
const scope = full ? '全量' : '受影响的';

// 3. 跑测试。小测试只调 git、互不相干，按文件分到多个进程并行跑；
// 中测试每个都起 Claude Code，并行就是同时起好几个，照旧按顺序跑
type Tier = 'small' | 'medium';
const TIERS: Array<{ tier: Tier; args: string[] }> = [
  { tier: 'small', args: ['--parallel'] },
  { tier: 'medium', args: [] },
];
const unescape = (s: string) => s.replace(/&quot;/g, '"').replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&#10;/g, '\n').replace(/&amp;/g, '&');
interface Case { name: string; file: string; time: number; tier: Tier; failure?: string }
const cases: Case[] = [];
const problems: string[] = [];
const started = performance.now();
for (const { tier, args } of TIERS) {
  const report = join(LOG_DIR, `${tier}.xml`);
  rmSync(report, { force: true });
  const tests = run(['bun', 'test', ...args, ...(full ? [] : [base ? `--changed=${base}` : '--changed']), `test/${tier}`, '--reporter=junit', `--reporter-outfile=${report}`]);
  // 没有受影响的测试时 bun 不写报告，退出码为 0
  if (!existsSync(report)) {
    if (tests.code !== 0) problems.push(`${tier === 'small' ? '小' : '中'}测试没跑起来：`, ...tests.out.trim().split('\n').slice(-15).map((l) => `  ${l}`));
    continue;
  }
  const before = cases.length;
  for (const m of readFileSync(report, 'utf8').matchAll(/<testcase name="([^"]*)"[^>]*? time="([^"]*)" file="([^"]*)"[^>]*?(?:\/>|>([\s\S]*?)<\/testcase>)/g)) {
    // 失败项有时只有 type 没有 message，比如 <failure type="AssertionError" />，细节在日志里
    const tag = m[4] ? /<failure\b([^>]*)>/.exec(m[4])?.[1] : undefined;
    const failure = tag === undefined ? undefined : unescape(/message="([^"]*)"/.exec(tag)?.[1] ?? /type="([^"]*)"/.exec(tag)?.[1] ?? '失败');
    cases.push({ name: unescape(m[1]!), time: Number(m[2]), file: m[3]!, tier, ...(failure !== undefined ? { failure } : {}) });
  }
  // 测试进程报错退出、报告里却没有失败项：比如某个文件加载就出错了
  if (tests.code !== 0 && !cases.slice(before).some((c) => c.failure !== undefined)) {
    problems.push('测试进程出错退出：', ...tests.out.trim().split('\n').slice(-15).map((l) => `  ${l}`));
  }
}
const seconds = (performance.now() - started) / 1000;

// 4. 核对规则和预算
const unlayered = run(['git', 'ls-files', '--cached', '--others', '--exclude-standard', 'test']).out.split('\n')
  .filter((f) => f.endsWith('.test.ts') && !/^test\/(small|medium)\//.test(f));
for (const f of unlayered) problems.push(`没分层：${f} 要放在 test/small/ 或 test/medium/`);
for (const c of cases) {
  if (c.failure !== undefined) problems.push(`失败：${c.file} › ${c.name}\n    ${c.failure.split('\n')[0]}`);
  if (c.time > LIMIT[c.tier]) problems.push(`超时：${c.file} › ${c.name} 用了 ${c.time.toFixed(2)} 秒，${c.tier === 'small' ? '小' : '中'}测试上限 ${LIMIT[c.tier]} 秒`);
}
if (full) {
  const medium = cases.filter((c) => c.tier === 'medium').length;
  if (medium > MEDIUM_MAX) problems.push(`中测试有 ${medium} 个，上限 ${MEDIUM_MAX} 个`);
  if (seconds > TOTAL_MAX) problems.push(`全量用了 ${seconds.toFixed(1)} 秒，上限 ${TOTAL_MAX} 秒`);
}

if (problems.length) fail([`检查没通过（${scope}测试 ${cases.length} 个，${seconds.toFixed(1)} 秒）：`, ...problems.map((p) => `  ${p}`)]);
console.log(cases.length === 0
  ? '检查通过：类型检查通过，这次改动没有影响到任何测试。'
  : `检查通过：类型检查通过，${scope}测试 ${cases.length} 个，${seconds.toFixed(1)} 秒。`);
