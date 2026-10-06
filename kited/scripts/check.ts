/**
 * Kite 仓库的检查命令，由 .kite/check 调用，契约见 kite-onboard skill（.claude/skills/kite-onboard/SKILL.md）。
 * 先同时做类型检查和 lint（App 有改动时加上 App 的编译，App 或工作机有改动时加上解码合同），再跑受影响的测试（--all 跑全量），最后按测试规则的预算核对耗时。
 * 受影响的测试从 KITE_BASE 起算改动，没有这个变量就看还没提交的改动；依赖或配置变了跑全量。
 * 输出只报结论、失败项和超预算项。完整日志写进 KITE_LOG_DIR（Kite 的 check 工具给的目录）；手动跑时没有这个变量，
 * 每次建一个新的临时目录，通过就删掉，没通过就留着并给出路径。
 */
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const KITED = join(import.meta.dir, '..');
// 日志写在哪由调用方定。手动跑时自己建临时目录，不写在固定位置，免得同时跑的检查互相覆盖
const GIVEN = process.env.KITE_LOG_DIR;
const LOG_DIR = GIVEN ?? mkdtempSync(join(tmpdir(), 'kite-check-'));
if (GIVEN) mkdirSync(GIVEN, { recursive: true });
const LOG = join(LOG_DIR, 'log');

/** 预算，和 .claude/agents/test-writer.md 里的分层表一致。 */
const MEDIUM_MAX = 8;
const TOTAL_MAX = 15;

/**
 * 这些变了依赖图看不出影响范围，跑全量。test/setup.ts 是 bunfig.toml 里的 preload，fake-api.ts 是它引的：
 * 测试文件不 import 它们，bun test --changed 看不出所有测试都受影响。
 */
const FULL_TRIGGERS = ['kited/package.json', 'kited/bun.lock', 'kited/tsconfig.json', 'kited/bunfig.toml', 'kited/test/setup.ts', 'kited/test/fake-api.ts', 'kited/scripts/check.ts'];

writeFileSync(LOG, '');
const log = (text: string) => writeFileSync(LOG, text, { flag: 'a' });

async function run(cmd: string[], cwd = KITED): Promise<{ code: number; out: string; stdout: string }> {
  const p = Bun.spawn(cmd, { cwd, env: process.env, stdout: 'pipe', stderr: 'pipe' });
  const [stdout, stderr] = await Promise.all([new Response(p.stdout).text(), new Response(p.stderr).text()]);
  const code = await p.exited;
  log(`$ ${cmd.join(' ')}\n${stdout}${stderr}\n`);
  return { code, out: stdout + stderr, stdout };
}

/** 报告里列前 20 条；没法解析时看输出的最后 15 行。 */
const head = (lines: string[]) => lines.slice(0, 20).map((l) => `  ${l}`);
const tail = (out: string) => out.trim().split('\n').slice(-15).map((l) => `  ${l}`);

interface LintFile { filePath: string; messages: Array<{ line: number; ruleId: string | null; message: string }> }

function fail(lines: string[]): never {
  console.log([...lines, `完整日志：${LOG}`].join('\n'));
  process.exit(1);
}

// 1. 改了哪些文件
const base = process.env.KITE_BASE;
const root = (await run(['git', 'rev-parse', '--show-toplevel'])).out.trim();
const [diff, untracked] = await Promise.all([
  run(['git', 'diff', '--name-only', base ?? 'HEAD'], root),
  run(['git', 'ls-files', '--others', '--exclude-standard'], root),
]);
const changed = [...diff.out.split('\n'), ...untracked.out.split('\n')].filter(Boolean);
const all = process.argv.includes('--all');
const full = all || changed.some((f) => FULL_TRIGGERS.includes(f));
const scope = full ? '全量' : '受影响的';

// 2. 静态检查都是几秒的事，同时跑。lint 只开 TypeScript 查不出来的规则，见 eslint.config.js；
// 用 --bun 在 Bun 里跑，工作机不用另装 Node。App 有改动才编译，Mac 和 iOS 两端一起编。
// 编译缓存用 Xcode 的默认位置：系统框架的预编译模块各工程共用，新工作树第一次编译约 5 秒；
// 关掉索引，每个工作树的缓存约 9 MB，不关约 70 MB
const APP = join(root, 'app');
const buildApp = full || changed.some((f) => f.startsWith('app/') || f.startsWith('kited/web/') || f === 'kited/scripts/build-plugin-web.ts');
// App 与工作机之间的 JSON 字段两边各自手写；这几项用真实的工作机输出编译真实的 Swift 解码代码，各约 2 秒，
// 两边任一处改动都跑。其余需要原生界面或 WebKit 的验证仍在 test/manual/ 手动运行
const CONTRACTS = ['verify-transcript-swift.ts', 'verify-remote-workspace-swift.ts', 'verify-resource-reference-swift.ts'];
const checkContracts = buildApp || changed.some((f) => f.startsWith('kited/src/') || f.startsWith('kited/test/manual/'));
const [tsc, lint, app, ...contracts] = await Promise.all([
  run(['bunx', 'tsc', '--noEmit']),
  run(['bunx', '--bun', 'eslint', '--format', 'json', '.']),
  buildApp ? (async () => {
    const web = await run(['bun', 'scripts/build-plugin-web.ts']);
    if (web.code !== 0) return { ...web, stage: '插件宿主页构建' };
    // 内嵌组网库不入库，首次编译前构建一次，需要 Go，约几分钟。
    if (!existsSync(join(APP, 'Vendor/TailscaleKit.xcframework'))) {
      const kit = await run([join(APP, 'scripts/build-tailscalekit.sh')]);
      if (kit.code !== 0) return { ...kit, stage: 'TailscaleKit 构建' };
    }
    return { ...await run(['xcodebuild', '-project', 'Kite.xcodeproj', '-scheme', 'Kite',
      '-destination', 'generic/platform=macOS', '-destination', 'generic/platform=iOS Simulator',
      'build', '-quiet', 'COMPILER_INDEX_STORE_ENABLE=NO'], APP), stage: 'App 编译' };
  })() : undefined,
  ...(checkContracts ? CONTRACTS.map(async (name) => ({ ...await run(['bun', `test/manual/${name}`]), name })) : []),
]);
const early: string[] = [];
if (tsc.code !== 0) {
  const errors = tsc.out.split('\n').filter((l) => /error TS\d+/.test(l));
  early.push(`类型检查没通过，${errors.length} 处错误：`, ...head(errors));
}
if (lint.code !== 0) {
  let files: LintFile[] | undefined;
  try { files = JSON.parse(lint.stdout) as LintFile[]; } catch { /* 出错时它不输出 JSON */ }
  const found = files?.flatMap((f) => f.messages.map((m) => `${f.filePath.slice(KITED.length + 1)}:${m.line} ${m.message}（${m.ruleId ?? '解析错误'}）`)) ?? [];
  if (found.length) early.push(`lint 没通过，${found.length} 处：`, ...head(found));
  else early.push('lint 没跑起来：', ...tail(lint.out));
}
if (app && app.code !== 0) {
  // 两端各报一遍同样的错，去重
  const errors = [...new Set(app.out.split('\n').filter((l) => l.includes(': error:')).map((l) => l.replace(`${APP}/`, 'app/')))];
  if (errors.length) early.push(`${app.stage}没通过，${errors.length} 处错误：`, ...head(errors));
  else early.push(`${app.stage}没通过：`, ...tail(app.out));
}
for (const contract of contracts) {
  if (contract.code !== 0) early.push(`App 解码合同 ${contract.name} 没通过：`, ...tail(contract.out));
}
if (early.length) fail(early);
const stages = ['类型检查', 'lint', ...(app ? ['App 编译'] : []), ...(contracts.length ? ['解码合同'] : [])].join('、');
const passed = `${stages}${/[a-z]$/i.test(stages) ? ' ' : ''}通过`;

// 3. 跑测试。小测试只调 git、互不相干，按文件分到多个进程并行跑；
// 中测试每个都起 Claude Code，并行就是同时起好几个，照旧按顺序跑
const TIERS = [
  { dir: 'small', name: '小', workers: 2, limit: 1 },
  { dir: 'medium', name: '中', workers: 1, limit: 3 },
];
type Tier = (typeof TIERS)[number];
const unescape = (s: string) => s.replace(/&quot;/g, '"').replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&#10;/g, '\n').replace(/&amp;/g, '&');
const attrs = (tag: string) => Object.fromEntries([...tag.matchAll(/(\w+)="([^"]*)"/g)].map((m) => [m[1]!, unescape(m[2]!)]));
interface Case { name: string; file: string; time: number; tier: Tier; failure?: string }
const cases: Case[] = [];
const problems: string[] = [];
const started = performance.now();
async function runTests(tier: Tier, path: string, index: number): Promise<void> {
  const report = join(LOG_DIR, `${tier.dir}-${index}.xml`);
  const tests = await run(['bun', 'test', ...(full ? [] : [base ? `--changed=${base}` : '--changed']), path, '--reporter=junit', `--reporter-outfile=${report}`]);
  // 没有受影响的测试时 bun 不写报告，退出码为 0
  if (!existsSync(report)) {
    if (tests.code !== 0) problems.push(`${tier.name}测试没跑起来：`, ...tail(tests.out));
    return;
  }
  const xml = readFileSync(report, 'utf8');
  const before = cases.length;
  // 按属性名取，不依赖属性的先后
  for (const m of xml.matchAll(/<testcase\b([^>]*?)(?:\/>|>([\s\S]*?)<\/testcase>)/g)) {
    const a = attrs(m[1]!);
    // 失败项有时只有 type 没有 message，比如 <failure type="AssertionError" />，细节在日志里
    const tag = m[2] ? /<failure\b([^>]*)>/.exec(m[2])?.[1] : undefined;
    const f = tag === undefined ? undefined : attrs(tag);
    const failure = f && (f.message ?? f.type ?? '失败');
    cases.push({ name: a.name ?? '', time: Number(a.time), file: a.file ?? '', tier, ...(failure !== undefined ? { failure } : {}) });
  }
  // 报告里的测试数和读出来的对不上，说明没读全，不能按读出来的判定通过
  const declared = Number(attrs(/<testsuites\b([^>]*)>/.exec(xml)?.[1] ?? '').tests);
  if (declared !== cases.length - before) problems.push(`${tier.name}测试报告有 ${declared} 个测试，读出 ${cases.length - before} 个`);
  // 测试进程报错退出、报告里却没有失败项：比如某个文件加载就出错了
  if (tests.code !== 0 && !cases.slice(before).some((c) => c.failure !== undefined)) {
    problems.push('测试进程出错退出：', ...tail(tests.out));
  }
}
for (const tier of TIERS) {
  const paths = tier.workers === 1 ? [`test/${tier.dir}`]
    : [...new Bun.Glob(`test/${tier.dir}/**/*.test.ts`).scanSync({ cwd: KITED })].sort();
  let next = 0;
  // Bun test 没有 --parallel；独立进程隔离各文件的 preload、环境变量与模块级清理。
  await Promise.all(Array.from({ length: tier.workers }, async () => {
    while (next < paths.length) {
      const index = next++;
      await runTests(tier, paths[index]!, index);
    }
  }));
}
const seconds = (performance.now() - started) / 1000;

// 4. 核对规则和预算
const unlayered = (await run(['git', 'ls-files', '--cached', '--others', '--exclude-standard', 'test'])).out.split('\n')
  .filter((f) => f.endsWith('.test.ts') && !/^test\/(small|medium)\//.test(f));
for (const f of unlayered) problems.push(`没分层：${f} 要放在 test/small/ 或 test/medium/`);
for (const c of cases) {
  if (c.failure !== undefined) problems.push(`失败：${c.file} › ${c.name}\n    ${c.failure.split('\n')[0]}`);
  if (c.time > c.tier.limit) problems.push(`超时：${c.file} › ${c.name} 用了 ${c.time.toFixed(2)} 秒，${c.tier.name}测试上限 ${c.tier.limit} 秒`);
}
if (full) {
  const medium = cases.filter((c) => c.tier.dir === 'medium').length;
  if (medium > MEDIUM_MAX) problems.push(`中测试有 ${medium} 个，上限 ${MEDIUM_MAX} 个`);
  if (seconds > TOTAL_MAX) problems.push(`全量用了 ${seconds.toFixed(1)} 秒，上限 ${TOTAL_MAX} 秒`);
}

if (problems.length) fail([`检查没通过（${scope}测试 ${cases.length} 个，${seconds.toFixed(1)} 秒）：`, ...problems.map((p) => `  ${p}`)]);
if (!GIVEN) rmSync(LOG_DIR, { recursive: true, force: true });
console.log(cases.length === 0
  ? `检查通过：${passed}，这次改动没有影响到任何测试。`
  : `检查通过：${passed}，${scope}测试 ${cases.length} 个，${seconds.toFixed(1)} 秒。`);
