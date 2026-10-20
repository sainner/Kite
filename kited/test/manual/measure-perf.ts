/**
 * 性能测量：编测量版、在真实 App 里自动跑场景、收结果、出表。用法和各场景量什么见 README 的「性能测量」。
 *
 *   bun kited/test/manual/measure-perf.ts mac [场景...] [选项]
 *   bun kited/test/manual/measure-perf.ts ipad --device <设备 ID> [场景...] [选项]
 *   bun kited/test/manual/measure-perf.ts iphone --device <设备 ID> [场景...] [选项]
 *
 * App 里的那一半是 app/Kite/Verification/PerfProbe.swift；分析在 perf-analysis.ts。
 */
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { command } from './command.ts';
import { compare, mainThreadSamples, measureIntervals, profile, render, summarize, type Report, type Row, type Run } from './perf-analysis.ts';

const MAC_SCENES = ['drag-bottom', 'drag-work', 'drag-long', 'drag-fold', 'drag-running', 'drag-actions', 'sidebar', 'toggle', 'motion',
  'reopen', 'enter', 'idle-normal', 'idle-empty', 'idle-ring', 'idle-pulse', 'idle-sweep', 'type', 'send'];
const IPAD_SCENES = ['drag-bottom', 'sidebar', 'toggle', 'motion', 'reopen', 'enter'];
const IPHONE_SCENES = ['drawer', 'pull', 'swipe', 'keyboard'];
/**
 * Time Profiler 默认按这些关键词分主线程：每个样本归到给的次序里第一个在栈上出现的（见 perf-analysis.ts 的 profile），
 * 所以里层的放前面，显示周期、CA 提交这些包着一切的放最后。
 */
const KEYWORDS = {
  mac: ['PerfProbe', 'TranscriptListView.layout', 'ProseTextView', 'ThreadIsland.layout', 'ControlsBarView', 'ThreadWindowView.layout',
    'CardView', 'StageView.layout', 'NSHostingView', 'ViewGraphRootValueUpdater', '_layoutViewTree', 'NSDisplayCycleFlush', 'CA::Transaction::commit'],
  ipad: ['PerfProbe', 'PhoneTranscriptView', 'PhoneProseTextView', 'UIHostingView', 'ViewGraphRootValueUpdater', 'layoutSubviews',
    'CA::Transaction::commit'],
  iphone: ['PerfProbe', 'PhoneTranscriptView', 'PhoneProseTextView', 'UIHostingView', 'ViewGraphRootValueUpdater', 'layoutSubviews',
    'CA::Transaction::commit'],
};
const BUNDLE = 'com.sainner.kite';
const runID = (run: Run) => `${stamp}/${run.scene}/${run.variant}-${run.repeat}`;

const USAGE = `用法：
  bun kited/test/manual/measure-perf.ts mac [场景...] [选项]
  bun kited/test/manual/measure-perf.ts ipad --device <设备 ID> [场景...] [选项]
  bun kited/test/manual/measure-perf.ts iphone --device <设备 ID> [场景...] [选项]
Mac 场景：${MAC_SCENES.join(' ')}
iPad 场景：${IPAD_SCENES.join(' ')}
iPhone 场景：${IPHONE_SCENES.join(' ')}
不给场景时跑全部。选项：
  --repeat N            每个场景、每个变体启动几次，默认 1
  --variant 名=参数     加一个对照变体：同一个测量版带这些启动参数（空格分开），和默认变体交替跑，如 --variant 'top=-perfScrollTop 0'
  --base <检出目录>     加一个对照变体 base：用那个检出编一份测量版，交替跑
  --trace               每次附一份 Time Profiler，按关键词合计测量区间里的主线程
  --keywords a,b        Time Profiler 合计的关键词，默认按平台给一组
  --lock <文件>         编译和测量都用 lockf 拿着这把锁，与同时编译、测量的其他检出排队
  --workspace <ID>      临时切到这个工作区再测（不存盘）
  --enter <ID>          enter 场景切过去的工作区，默认同一台工作机上台面摆着窗口的另一个
  --threads a,b         台面上只摆这几个会话（会话 id，按次序从停靠栏恢复），测完写回
  --window 宽x高        Mac 测量窗口的大小，默认 1200x924
  --rounds N            每次启动测几轮（拖缝、侧栏默认 Mac 2、iPad 3）
  --pairs N             缩小恢复、打开关闭、切工作区、iPhone 各场景每次启动做几次（默认 4）
  --no-build            用上次编好的测量版
  --compare <结果目录>  和之前一次的结果对比
  --out <目录>          结果放哪，默认 build/perf/<平台>-<时间>`;

// MARK: - 参数

const argv = process.argv.slice(2);
const platform = argv.shift();
if (platform !== 'mac' && platform !== 'ipad' && platform !== 'iphone') {
  console.error(USAGE);
  process.exit(2);
}
const options = { repeat: 1, variants: [] as Array<{ name: string; args: string[] }>, base: undefined as string | undefined, trace: false,
  keywords: KEYWORDS[platform], lock: undefined as string | undefined, workspace: undefined as string | undefined, enter: undefined as string | undefined, threads: undefined as string | undefined, window: '1200x924',
  rounds: undefined as string | undefined, pairs: undefined as string | undefined, build: true, compare: undefined as string | undefined, out: undefined as string | undefined,
  device: undefined as string | undefined };
const scenes: string[] = [];
for (let i = 0; i < argv.length; i++) {
  const arg = argv[i]!;
  const value = () => {
    const next = argv[++i];
    if (next === undefined) throw new Error(`${arg} 缺参数\n${USAGE}`);
    return next;
  };
  switch (arg) {
    case '--repeat': options.repeat = Number(value()); break;
    case '--variant': {
      const [name, ...rest] = value().split('=');
      options.variants.push({ name: name!, args: rest.join('=').split(/\s+/).filter(Boolean) });
      break;
    }
    case '--base': options.base = resolve(value()); break;
    case '--trace': options.trace = true; break;
    case '--keywords': options.keywords = value().split(',').filter(Boolean); break;
    case '--lock': options.lock = resolve(value()); break;
    case '--workspace': options.workspace = value(); break;
    case '--enter': options.enter = value(); break;
    case '--threads': options.threads = value(); break;
    case '--window': options.window = value(); break;
    case '--rounds': options.rounds = value(); break;
    case '--pairs': options.pairs = value(); break;
    case '--no-build': options.build = false; break;
    case '--compare': options.compare = resolve(value()); break;
    case '--out': options.out = resolve(value()); break;
    case '--device': options.device = value(); break;
    default:
      if (arg.startsWith('-')) throw new Error(`不认识的选项 ${arg}\n${USAGE}`);
      scenes.push(arg);
  }
}
const known = platform === 'mac' ? MAC_SCENES : platform === 'ipad' ? IPAD_SCENES : IPHONE_SCENES;
if (!scenes.length) scenes.push(...known);
for (const scene of scenes) if (!known.includes(scene)) throw new Error(`${platform} 没有场景 ${scene}\n${USAGE}`);
if (platform !== 'mac' && !options.device) throw new Error(`${platform === 'ipad' ? 'iPad' : 'iPhone'} 要给 --device\n${USAGE}`);

const ROOT = resolve(import.meta.dir, '..', '..', '..');
const now = new Date();
const two = (n: number) => String(n).padStart(2, '0');
const stamp = `${now.getFullYear()}${two(now.getMonth() + 1)}${two(now.getDate())}-${two(now.getHours())}${two(now.getMinutes())}${two(now.getSeconds())}`;
const OUT = options.out ?? join(ROOT, 'build', 'perf', `${platform}-${stamp}`);
mkdirSync(OUT, { recursive: true });
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
const log = (text: string) => console.log(`[${new Date().toTimeString().slice(0, 8)}] ${text}`);

// MARK: - 锁

/**
 * 拿着锁做 body：起一个 lockf 子进程，拿到锁后它打一行字、等着读 stdin；body 做完关掉 stdin，它退出、锁就放了。
 * 本进程意外退出时管道也会关上，锁不会一直占着。
 */
async function locked<T>(body: () => Promise<T>): Promise<T> {
  if (!options.lock) return body();
  const holder = Bun.spawn(['lockf', '-k', options.lock, '/bin/sh', '-c', 'echo locked; read _'], {
    env: { ...process.env as Record<string, string> }, stdin: 'pipe', stdout: 'pipe', stderr: 'inherit',
  });
  const reader = holder.stdout.getReader();
  let seen = '';
  while (!seen.includes('locked')) {
    const { value, done } = await reader.read();
    if (done) throw new Error(`没拿到锁 ${options.lock}`);
    seen += new TextDecoder().decode(value);
  }
  try {
    return await body();
  } finally {
    await holder.stdin.end();
    await holder.exited;
  }
}

// MARK: - 编译

interface Build { variant: string; app: string; executable: string; args: string[] }

/** 编测量版：-O、KITE_LAYOUT_AUDIT，单独的 derivedDataPath，不搅日常的增量缓存。 */
async function build(checkout: string): Promise<string> {
  const app = join(checkout, 'app');
  if (!existsSync(join(app, 'Vendor', 'TailscaleKit.xcframework'))) {
    throw new Error(`${app}/Vendor/TailscaleKit.xcframework 不在：先跑 app/scripts/build-tailscalekit.sh，或从主检出链过来`);
  }
  const derived = join(checkout, 'build', platform === 'mac' ? 'perf-mac' : 'perf-ios');
  const destination = platform === 'mac' ? ['-destination', 'generic/platform=macOS'] : ['-destination', `id=${options.device!}`, '-allowProvisioningUpdates'];
  const products = join(derived, 'Build', 'Products', platform === 'mac' ? 'Debug' : 'Debug-iphoneos', 'Kite.app');
  if (!options.build) {
    if (!existsSync(products)) throw new Error(`没有编好的测量版：${products}`);
    return products;
  }
  log(`编测量版：${checkout}`);
  await locked(() => command(['xcodebuild', '-project', 'Kite.xcodeproj', '-scheme', 'Kite', '-configuration', 'Debug', ...destination,
    '-derivedDataPath', derived, 'SWIFT_OPTIMIZATION_LEVEL=-O', 'KITE_PREVIEW_FLAGS=KITE_LAYOUT_AUDIT', 'COMPILER_INDEX_STORE_ENABLE=NO',
    'build', '-quiet'], app, 30 * 60_000));
  return products;
}

const builds: Build[] = [];
{
  const own = await build(ROOT);
  const executable = join(own, 'Contents', 'MacOS', 'Kite');
  builds.push({ variant: 'main', app: own, executable, args: [] });
  for (const variant of options.variants) builds.push({ variant: variant.name, app: own, executable, args: variant.args });
  if (options.base) {
    const base = await build(options.base);
    builds.push({ variant: 'base', app: base, executable: join(base, 'Contents', 'MacOS', 'Kite'), args: [] });
  }
}

/** 传给测量版的参数（UserDefaults 的参数域，不存盘）。-perfRun 是这一次的编号，报告里带回来。 */
function appArgs(run: Run, variant: Build): string[] {
  return ['-perfScene', run.scene, '-perfRun', runID(run), '-perfAutoStart', '8',
    ...(options.workspace ? ['-perfWorkspace', options.workspace] : []),
    ...(options.enter ? ['-perfEnter', options.enter] : []),
    ...(options.threads ? ['-perfThreads', options.threads] : []),
    ...(options.rounds ? ['-perfRounds', options.rounds] : []),
    ...(options.pairs ? ['-perfPairs', options.pairs] : []),
    ...(platform === 'mac' ? ['-perfWindowSize', options.window] : []),
    ...variant.args];
}

// MARK: - Time Profiler

async function exportProfile(trace: string, steps: number): Promise<Run['profile']> {
  const table = (xpath: string, name: string) => command(['xcrun', 'xctrace', 'export', '--input', trace, '--xpath', xpath,
    '--output', join(trace, '..', name)], ROOT, 10 * 60_000).then(() => readFileSync(join(trace, '..', name), 'utf8'));
  const samples = mainThreadSamples(await table('/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]', 'time-profile.xml'));
  const signposts = await table('/trace-toc/run[@number="1"]/data/table[@schema="os-signpost"]', 'os-signpost.xml').catch(() => '');
  const intervals = measureIntervals(signposts);
  if (!intervals.length) log('  Time Profiler 里没找到测量区间，按整段录制合计');
  return profile(samples, intervals, options.keywords, steps);
}

/** 拖缝、侧栏的步数（Time Profiler 按每步摊）；别的场景为 0，按每段算。 */
const stepsOf = (report: Report | undefined) => (report?.segments ?? [])
  .filter((s) => s.name === 'drag' || s.name === 'sidebar').reduce((n, s) => n + Math.max(s.ticks.length - 1, 0), 0);

// MARK: - Mac

/** 本机收测量版的结果：报到（ready.json）、放行（GET /go）、各个文件（POST /<名字>）写进这一次的目录。 */
const receiver = {
  dir: '',
  go: false,
  pid: undefined as number | undefined,
  received: new Set<string>(),
};
const server = platform === 'mac' ? Bun.serve({
  hostname: '127.0.0.1',
  port: 0,
  async fetch(request) {
    const name = new URL(request.url).pathname.slice(1).replace(/[^\w.-]/g, '_');
    if (request.method === 'GET') return new Response(null, { status: name === 'go' && receiver.go ? 200 : 204 });
    const body = new Uint8Array(await request.arrayBuffer());
    if (receiver.dir) writeFileSync(join(receiver.dir, name), body);
    if (name === 'ready.json') receiver.pid = (JSON.parse(new TextDecoder().decode(body)) as { pid: number }).pid;
    receiver.received.add(name);
    return new Response('ok');
  },
}) : undefined;

/** 等这一次收到 names 里的某个文件，返回先到的那个；超时返回 undefined。 */
async function arrival(names: string[], timeoutMs: number): Promise<string | undefined> {
  for (const deadline = Date.now() + timeoutMs; Date.now() < deadline; await sleep(200)) {
    const name = names.find((n) => receiver.received.has(n));
    if (name) return name;
  }
  return undefined;
}

/** 进程还在、而且确实是这个测量版（按可执行文件路径认），才算自己启动的。 */
async function ownProcess(pid: number, executable: string): Promise<boolean> {
  const args = await command(['ps', '-p', String(pid), '-o', 'args='], ROOT).catch(() => '');
  return args.startsWith(executable);
}

/** 只请自己启动的测量版退出：先按进程号正常退出（同 preview-mac.sh），20 秒还在就强退。 */
async function stop(pid: number, executable: string) {
  for (let i = 0; i < 40; i++) {
    if (!await ownProcess(pid, executable)) return;
    if (i === 0) {
      await command(['osascript', '-l', 'JavaScript', '-e',
        `ObjC.import('AppKit'); $.NSRunningApplication.runningApplicationWithProcessIdentifier(${pid}).terminate`], ROOT).catch(() => '');
    }
    await sleep(500);
  }
  if (await ownProcess(pid, executable)) process.kill(pid, 'SIGKILL');
}

/** 上次中途出事留下的同一个测量版（同一个可执行文件路径）先请走；别的检出、用户的 Kite 不碰。 */
async function stopLeftovers(executable: string) {
  const list = await command(['ps', '-axo', 'pid=,args='], ROOT);
  for (const line of list.split('\n')) {
    const match = /^\s*(\d+)\s+(.*)$/.exec(line);
    if (match && match[2]!.startsWith(executable)) await stop(Number(match[1]), executable);
  }
}

/** 测量版要在最前，系统才正常出图：不在就按进程号请它到前面（不用辅助功能权限），测量版开测时自己再查一次、写进报告。 */
async function bringToFront(pid: number) {
  const front = async () => /pid\s*=\s*(\d+)/.exec(await command(['lsappinfo', 'info', '-only', 'pid', await command(['lsappinfo', 'front'], ROOT)], ROOT))?.[1];
  for (let i = 0; i < 3 && await front() !== String(pid); i++) {
    await command(['osascript', '-l', 'JavaScript', '-e',
      `ObjC.import('AppKit'); $.NSRunningApplication.runningApplicationWithProcessIdentifier(${pid}).activateWithOptions(0)`], ROOT).catch(() => '');
    await sleep(1000);
  }
}

/** 等别的检出编完（最多 3 分钟）：编译占满 CPU 时测出来的不算数。 */
async function quiet() {
  for (let i = 0; i < 36; i++) {
    const busy = await command(['pgrep', '-x', 'swift-frontend'], ROOT).then(() => true, () => false);
    if (!busy) return;
    if (i === 0) log('  有别的编译在跑，等它编完');
    await sleep(5000);
  }
  log('  3 分钟还没编完，照样测');
}

async function measureMac(run: Run, variant: Build): Promise<void> {
  await locked(async () => {
    await quiet();
    await stopLeftovers(variant.executable);
    receiver.dir = run.dir;
    receiver.go = false;
    receiver.pid = undefined;
    receiver.received.clear();
    const load = (await command(['sysctl', '-n', 'vm.loadavg'], ROOT)).trim();
    writeFileSync(join(run.dir, 'load.txt'), `${load}\n`);
    await command(['open', '-n', variant.app, '--args', ...appArgs(run, variant), '-perfPort', String(server!.port)], ROOT);
    // 开测前就失败的（比如没有宽屏工作区）不报到，直接交报告
    const first = await arrival(['ready.json', 'report.json'], 180_000);
    if (first === 'report.json') {
      run.report = JSON.parse(readFileSync(join(run.dir, 'report.json'), 'utf8')) as Report;
      await sleep(3000);
      await stopLeftovers(variant.executable);
      return;
    }
    if (!first || receiver.pid === undefined) {
      await stopLeftovers(variant.executable);
      throw new Error('测量版 3 分钟内没有报到');
    }
    const pid = receiver.pid;
    try {
      const trace = join(run.dir, 'profile.trace');
      const tracer = options.trace
        ? Bun.spawn(['xcrun', 'xctrace', 'record', '--template', 'Time Profiler', '--attach', String(pid), '--time-limit', '600s',
          '--output', trace], { env: { ...process.env as Record<string, string> }, stdout: 'pipe', stderr: 'pipe' })
        : undefined;
      if (tracer) {
        // 挂上要几秒：等它说开始录了再放行
        const started = (async () => {
          const reader = tracer.stdout.getReader();
          let text = '';
          while (!/Starting recording|Ctrl-C/i.test(text)) {
            const { value, done } = await reader.read();
            if (done) return;
            text += new TextDecoder().decode(value);
          }
        })();
        await Promise.race([started, sleep(15_000)]);
        await sleep(1000);
      }
      await bringToFront(pid);
      receiver.go = true;
      if (!await arrival(['report.json'], 600_000)) throw new Error('10 分钟内没有出报告');
      // 测量版测完写回设置后自己退出
      for (let i = 0; i < 60 && await ownProcess(pid, variant.executable); i++) await sleep(500);
      if (tracer) {
        const exited = await Promise.race([tracer.exited.then(() => true), sleep(60_000).then(() => false)]);
        if (!exited) {
          tracer.kill('SIGINT');
          await tracer.exited;
        }
      }
      run.report = JSON.parse(readFileSync(join(run.dir, 'report.json'), 'utf8')) as Report;
      if (tracer && existsSync(trace)) run.profile = await exportProfile(trace, stepsOf(run.report));
    } finally {
      await stop(pid, variant.executable);
      receiver.dir = '';
    }
  });
}

// MARK: - iPad、iPhone

const device = options.device!;
const deviceName = platform === 'ipad' ? 'iPad' : 'iPhone';
const devicectl = (args: string[], timeoutMs = 120_000) => command(['xcrun', 'devicectl', ...args], ROOT, timeoutMs);

async function unlocked(): Promise<boolean> {
  const out = join(OUT, 'lock-state.json');
  await devicectl(['device', 'info', 'lockState', '--device', device, '-j', out]);
  const state = JSON.parse(readFileSync(out, 'utf8')) as { result: { passcodeRequired: boolean } };
  return !state.result.passcodeRequired;
}

/** 取回 Library/Caches/perf/ 下的一个文件；没有就返回 undefined。 */
async function fetchFile(name: string, destination: string): Promise<string | undefined> {
  rmSync(destination, { force: true });
  await devicectl(['device', 'copy', 'from', '--device', device, '--domain-type', 'appDataContainer', '--domain-identifier', BUNDLE,
    '--source', `Library/Caches/perf/${name}`, '--destination', destination], 60_000).catch(() => '');
  return existsSync(destination) ? readFileSync(destination, 'utf8') : undefined;
}

async function measureDevice(run: Run, variant: Build): Promise<void> {
  const args = appArgs(run, variant);
  const trace = join(run.dir, 'profile.trace');
  const tracer = options.trace
    ? Bun.spawn(['xcrun', 'xctrace', 'record', '--template', 'Time Profiler', '--device', device, '--time-limit', '240s', '--output', trace,
      '--launch', '--', BUNDLE, ...args], { env: { ...process.env as Record<string, string> }, stdout: 'ignore', stderr: 'ignore' })
    : undefined;
  if (!tracer) await devicectl(['device', 'process', 'launch', '--device', device, '--terminate-existing', BUNDLE, '--', ...args]);
  // 报告里带着这一次的 -perfRun，认得出不是上一次留下的
  const destination = join(run.dir, 'report.json');
  for (let waited = 0; waited < 600; waited += 5) {
    await sleep(5000);
    const text = await fetchFile('report.json', destination);
    const report = text ? JSON.parse(text) as Report : undefined;
    if (report?.run === runID(run) && report.status !== 'running') {
      run.report = report;
      break;
    }
  }
  if (!run.report) throw new Error('10 分钟内没有取回这一次的报告');
  if (tracer) {
    tracer.kill('SIGINT');
    await tracer.exited;
    if (existsSync(trace)) run.profile = await exportProfile(trace, stepsOf(run.report));
  }
}

// MARK: - 跑

const runs: Run[] = [];
async function measureAll() {
  for (const scene of scenes) {
    for (let repeat = 1; repeat <= options.repeat; repeat++) {
      // 变体交替跑：同一时段的负载对各变体一样
      for (const variant of builds) {
        const dir = join(OUT, scene, `${variant.variant}-${repeat}`);
        mkdirSync(dir, { recursive: true });
        const run: Run = { scene, variant: variant.variant, repeat, dir };
        runs.push(run);
        log(`${scene} · ${variant.variant} · 第 ${repeat} 次`);
        try {
          if (platform === 'mac') await measureMac(run, variant);
          else await measureDevice(run, variant);
          if (run.report?.status !== 'completed') run.error = run.report?.failure ?? '没有完成';
          else if (!run.report.active || run.report.visible === false) {
            run.error = `测量版不在最前或窗口被挡住（最前的是 ${run.report.frontmost ?? '?'}），系统不正常出图，不算数`;
          }
        } catch (error) {
          run.error = error instanceof Error ? error.message : String(error);
        }
        if (run.error) log(`  失败：${run.error}`);
      }
    }
  }
}

if (platform === 'mac') {
  await measureAll();
  await server!.stop(true);
} else {
  // 整套设备操作（装、开、测、取回、重开）拿着同一把锁
  await locked(async () => {
    if (!await unlocked()) {
      log(`${deviceName} 锁着屏，跳过`);
      process.exit(3);
    }
    const apps = new Set(builds.map((b) => b.app));
    if (apps.size > 1) throw new Error(`${deviceName} 一次只装一份测量版：--base 请分开跑`);
    log('装测量版');
    await devicectl(['device', 'install', 'app', '--device', device, builds[0]!.app], 10 * 60_000);
    try {
      await measureAll();
    } finally {
      // 不带测量参数照常打开 Kite：用户的 iPad、iPhone 靠它防锁屏
      await devicectl(['device', 'process', 'launch', '--device', device, '--terminate-existing', BUNDLE]).catch((e: unknown) => log(`重开 Kite 失败：${String(e)}`));
    }
  });
}

// MARK: - 出表

const rows = summarize(runs);
const failures = runs.filter((r) => r.error).map((r) => `- ${r.scene} · ${r.variant} · 第 ${r.repeat} 次：${r.error}`);
const restored = [...new Set(runs.flatMap((r) => r.report?.restored ?? []))];
let markdown = `# 性能测量 ${platform} ${stamp}\n\n${runs.find((r) => r.report)?.report?.platform ?? ''}，刷新率 ${runs.find((r) => r.report)?.report?.refreshRate ?? '?'} Hz\n\n${render(rows)}\n`;
if (options.compare) {
  const before = JSON.parse(readFileSync(join(options.compare, 'summary.json'), 'utf8')) as { rows: Row[] };
  markdown += `\n${compare(before.rows, rows)}\n`;
}
if (failures.length) markdown += `\n### 没测成的\n\n${failures.join('\n')}\n`;
if (restored.length) markdown += `\n测完写回的设置：${restored.join('、')}\n`;
writeFileSync(join(OUT, 'summary.md'), markdown);
writeFileSync(join(OUT, 'summary.json'), `${JSON.stringify({ platform, stamp, scenes, variants: builds.map((b) => b.variant), rows }, null, 2)}\n`);
console.log(`\n${markdown}\n结果：${OUT}`);
process.exit(failures.length ? 1 : 0);
