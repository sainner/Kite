/**
 * 性能测量的分析：测量版的报告（app/Kite/Verification/PerfProbe.swift）出表，Time Profiler 的导出按关键词合计。
 * 入口和各列的含义见 README 的「性能测量」。
 */

export interface Mark { wall: number; cpu: number; process: number }
export interface Tick { time: number; wall: number; cpu: number; widths: number[] }
export interface Segment { name: string; index: number; start: Mark; ticks: Tick[]; end?: Mark; settleCpuMs?: number }
export interface Report {
  scene: string;
  run?: string;
  platform: string;
  refreshRate: number;
  active: boolean;
  visible?: boolean;
  frontmost?: string;
  conversations: number;
  stageAtStart?: string[];
  status: string;
  failure?: string;
  segments: Segment[];
  restored: string[];
}

/** Time Profiler 在测量区间里的主线程：合计、按关键词分的各项（见 profile），毫秒；steps 是区间里拖了多少步。 */
export interface Profile { totalMs: number; keywords: Record<string, number>; intervals: number; steps: number }

export interface Run { scene: string; variant: string; repeat: number; dir: string; report?: Report; error?: string; profile?: Profile }

/** 表里的一行：同一场景、同一变体的所有次数合在一起，数值取中位。ranges 是要附上最小到最大的那几项。 */
export interface Row { table: string; scene: string; variant: string; values: Record<string, number>; ranges: Record<string, [number, number]> }

export const median = (xs: number[]) => {
  if (!xs.length) return NaN;
  const sorted = [...xs].sort((a, b) => a - b);
  const middle = Math.floor(sorted.length / 2);
  return sorted.length % 2 ? sorted[middle]! : (sorted[middle - 1]! + sorted[middle]!) / 2;
};
const percentile = (xs: number[], p: number) => {
  if (!xs.length) return NaN;
  const sorted = [...xs].sort((a, b) => a - b);
  return sorted[Math.min(sorted.length - 1, Math.floor(sorted.length * p))]!;
};
const diffs = (xs: number[]) => xs.slice(1).map((x, i) => x - xs[i]!);
const sum = (xs: number[]) => xs.reduce((a, b) => a + b, 0);

/** 拖缝、侧栏的一轮：每步主线程（整轮除以步数）、每帧主线程和帧间隔的分布、超 20ms 的帧、松手后、实际改了宽的步数。 */
function sweep(segment: Segment) {
  const ticks = segment.ticks;
  const steps = Math.max(ticks.length - 1, 1);
  const intervals = diffs(ticks.map((t) => t.time * 1000));
  const cpu = diffs(ticks.map((t) => t.cpu));
  const moved = ticks.slice(1).filter((t, i) => t.widths.join() !== ticks[i]!.widths.join()).length;
  return {
    '每步主线程': (ticks.at(-1)!.cpu - ticks[0]!.cpu) / steps,
    '每帧主线程 p90': percentile(cpu, 0.9),
    '帧间隔中位': median(intervals),
    '帧间隔 p90': percentile(intervals, 0.9),
    '超 20ms 步数': intervals.filter((x) => x > 20).length,
    '松手后主线程': segment.settleCpuMs ?? NaN,
    '改了宽的步数': moved,
  };
}

/** 一次动作到动画走完、逐帧记的段，按表分：iPad、Mac 的缩小恢复，iPhone 的抽屉开合、手指拉抽屉、横滑、键盘升降。 */
const ACTIONS: Record<string, string[]> = {
  '缩小与恢复': ['minimize', 'restore'],
  '抽屉、横滑与键盘': ['sidebar-open', 'sidebar-close', 'actions-open', 'actions-close', 'pull-open', 'pull-close',
    'swipe-next', 'swipe-back', 'keyboard-show', 'keyboard-hide'],
};

/** 缩小、恢复这类的一次：动作到第一帧、这之间的主线程，到动画走完的主线程合计，丢帧（按屏幕刷新间隔算）和最长一帧。 */
function settle(segment: Segment, frame: number) {
  const ticks = segment.ticks;
  const first = ticks[0], last = ticks.at(-1);
  const intervals = diffs(ticks.map((t) => t.time * 1000));
  return {
    '首帧': first ? (first.wall - segment.start.wall) * 1000 : NaN,
    '首帧前主线程': first ? first.cpu - segment.start.cpu : NaN,
    '整段主线程': last ? last.cpu - segment.start.cpu : NaN,
    '丢帧': sum(intervals.map((x) => Math.max(0, Math.round(x / frame) - 1))),
    '最长帧': intervals.length ? Math.max(...intervals) : NaN,
  };
}

function idle(segment: Segment) {
  const end = segment.end!;
  const seconds = end.wall - segment.start.wall;
  return { '主线程 %': (end.cpu - segment.start.cpu) / seconds / 10, '进程 %': (end.process - segment.start.process) / seconds / 10 };
}

function key(segment: Segment) {
  const ticks = segment.ticks;
  const intervals = diffs(ticks.map((t) => t.time * 1000));
  return {
    '每键主线程': ticks.length ? ticks.at(-1)!.cpu - segment.start.cpu : NaN,
    '键后最长帧': intervals.length ? Math.max(...intervals) : NaN,
  };
}

function send(segment: Segment) {
  const ticks = segment.ticks;
  const intervals = diffs(ticks.map((t) => t.time * 1000));
  const early = ticks.filter((t) => t.wall <= segment.start.wall + 0.3).at(-1);
  return {
    '首帧': ticks[0] ? (ticks[0].wall - segment.start.wall) * 1000 : NaN,
    '前 300ms 主线程': early ? early.cpu - segment.start.cpu : NaN,
    '1.5 秒主线程': ticks.length ? ticks.at(-1)!.cpu - segment.start.cpu : NaN,
    '帧间隔中位': median(intervals),
    '最长帧': intervals.length ? Math.max(...intervals) : NaN,
    '超 20ms 帧': intervals.filter((x) => x > 20).length,
  };
}

/** 各项取中位；primary 那几项另附最小到最大。 */
function combine(table: string, scene: string, variant: string, samples: Array<Record<string, number>>, primary: string[], totals: string[] = []): Row {
  const values: Record<string, number> = { '次数': samples.length };
  const ranges: Record<string, [number, number]> = {};
  for (const name of Object.keys(samples[0] ?? {})) {
    const xs = samples.map((s) => s[name]!).filter((x) => !Number.isNaN(x));
    values[name] = totals.includes(name) ? sum(xs) : median(xs);
    if (primary.includes(name) && xs.length > 1) ranges[name] = [Math.min(...xs), Math.max(...xs)];
  }
  return { table, scene, variant, values, ranges };
}

/** 把所有次数按场景、变体合成表行；没出报告、失败的（error）不算，由调用方另行列出。 */
export function summarize(runs: Run[]): Row[] {
  const rows: Row[] = [];
  const groups = new Map<string, Run[]>();
  for (const run of runs) {
    if (run.report?.status !== 'completed' || run.error) continue;
    const id = `${run.scene}\u0000${run.variant}`;
    groups.set(id, [...groups.get(id) ?? [], run]);
  }
  for (const group of groups.values()) {
    const { scene, variant } = group[0]!;
    const segments = group.flatMap((run) => run.report!.segments);
    const frame = 1000 / (group[0]!.report!.refreshRate || 60);
    const named = (name: string) => segments.filter((s) => s.name === name);
    if (named('drag').length || named('sidebar').length) {
      rows.push(combine('拖缝与侧栏', scene, variant, [...named('drag'), ...named('sidebar')].map(sweep), ['每步主线程']));
    }
    for (const [table, names] of Object.entries(ACTIONS)) {
      for (const name of names) {
        if (named(name).length) rows.push(combine(table, `${scene} ${name}`, variant, named(name).map((s) => settle(s, frame)), ['整段主线程']));
      }
    }
    if (named('idle').length) rows.push(combine('静息占用', scene, variant, named('idle').map(idle), ['主线程 %']));
    if (named('key').length) {
      const keys = named('key').map(key);
      const row = combine('打字', scene, variant, keys, ['每键主线程']);
      row.values['每键主线程 p90'] = percentile(keys.map((k) => k['每键主线程']), 0.9);
      row.values['键后超 20ms 的键'] = keys.filter((k) => k['键后最长帧'] > 20).length;
      rows.push(row);
    }
    if (named('send').length) rows.push(combine('发送', scene, variant, named('send').map(send), ['1.5 秒主线程'], ['超 20ms 帧']));
    const profiles = group.flatMap((run) => run.profile ? [run.profile] : []);
    if (profiles.length) {
      // 拖缝、侧栏按每步算，别的按每次测量区间合计
      const per = (p: Profile) => p.steps || p.intervals || 1;
      const values: Record<string, number> = { '次数': profiles.length, '主线程': median(profiles.map((p) => p.totalMs / per(p))) };
      for (const name of Object.keys(profiles[0]!.keywords)) values[name] = median(profiles.map((p) => p.keywords[name]! / per(p)));
      rows.push({ table: profiles[0]!.steps ? 'Time Profiler（每步毫秒）' : 'Time Profiler（每段毫秒）', scene, variant, values, ranges: {} });
    }
  }
  return rows;
}

const format = (x: number) => Number.isNaN(x) ? '—' : Number.isInteger(x) ? String(x) : x.toFixed(1);

/** 每张表一段 Markdown。 */
export function render(rows: Row[]): string {
  const tables = [...new Set(rows.map((r) => r.table))];
  return tables.map((table) => {
    const members = rows.filter((r) => r.table === table);
    const columns = [...new Set(members.flatMap((r) => Object.keys(r.values)))];
    const lines = [`### ${table}`, '', `| 场景 | 变体 | ${columns.join(' | ')} |`, `|${' --- |'.repeat(columns.length + 2)}`];
    for (const row of members) {
      const cells = columns.map((c) => {
        const range = row.ranges[c];
        return format(row.values[c] ?? NaN) + (range ? `（${format(range[0])}–${format(range[1])}）` : '');
      });
      lines.push(`| ${row.scene} | ${row.variant} | ${cells.join(' | ')} |`);
    }
    return lines.join('\n');
  }).join('\n\n');
}

/** 和之前的结果比：同一张表、同一场景和变体的各项，之前 → 这次（变化）。 */
export function compare(before: Row[], now: Row[]): string {
  const lines = ['### 和之前比', '', '| 表 | 场景 | 变体 | 项 | 之前 | 这次 | 变化 |', '| --- | --- | --- | --- | --- | --- | --- |'];
  for (const row of now) {
    const old = before.find((r) => r.table === row.table && r.scene === row.scene && r.variant === row.variant);
    if (!old) continue;
    for (const [name, value] of Object.entries(row.values)) {
      const previous = old.values[name];
      if (name === '次数' || previous === undefined || Number.isNaN(previous) || Number.isNaN(value)) continue;
      const change = previous === 0 ? '' : `${value >= previous ? '+' : ''}${((value / previous - 1) * 100).toFixed(0)}%`;
      lines.push(`| ${row.table} | ${row.scene} | ${row.variant} | ${name} | ${format(previous)} | ${format(value)} | ${change} |`);
    }
  }
  return lines.length > 4 ? lines.join('\n') : '### 和之前比\n\n没有能对上的场景和变体。';
}

// MARK: - Time Profiler

interface XmlNode { tag: string; attrs: Record<string, string>; text: string; children: XmlNode[] }

const entity = (s: string) => s.replace(/&(lt|gt|amp|quot|apos|#\d+|#x[0-9a-f]+);/gi, (_, e: string) => {
  switch (e) {
    case 'lt': return '<';
    case 'gt': return '>';
    case 'amp': return '&';
    case 'quot': return '"';
    case 'apos': return '\'';
    default: return String.fromCodePoint(e[1] === 'x' ? parseInt(e.slice(2), 16) : Number(e.slice(1)));
  }
});

/**
 * xctrace export 的表逐行读出来：每个 row 是一棵小树，ref 换成前面带同一 id 定义的那个元素（导出里同样的值只写一次，后面都引用它）。
 */
export function* xmlRows(xml: string): Generator<XmlNode> {
  const ids = new Map<string, XmlNode>();
  const stack: XmlNode[] = [];
  const pattern = /<(\/?)([A-Za-z][\w.-]*)((?:\s+[\w:.-]+=(?:"[^"]*"|'[^']*'))*)\s*(\/?)>|([^<]+)|<[^>]*>/g;
  for (const m of xml.matchAll(pattern)) {
    if (m[5] !== undefined) {
      const top = stack.at(-1);
      if (top) top.text += entity(m[5]);
      continue;
    }
    if (m[2] === undefined) continue;
    if (m[1]) {
      const node = stack.pop();
      if (!node) continue;
      if (node.attrs.id !== undefined) ids.set(node.attrs.id, node);
      if (node.tag === 'row') yield node;
      continue;
    }
    const attrs: Record<string, string> = {};
    for (const a of m[3]!.matchAll(/([\w:.-]+)=(?:"([^"]*)"|'([^']*)')/g)) attrs[a[1]!] = entity(a[2] ?? a[3] ?? '');
    const node = attrs.ref !== undefined ? ids.get(attrs.ref) ?? { tag: m[2], attrs, text: '', children: [] } : { tag: m[2], attrs, text: '', children: [] };
    stack.at(-1)?.children.push(node);
    if (!m[4] && attrs.ref === undefined) stack.push(node);
    else if (!m[4]) stack.push({ tag: m[2], attrs, text: '', children: [] });
  }
}

const child = (node: XmlNode, tag: string) => node.children.find((c) => c.tag === tag);

export interface Sample { time: number; weight: number; frames: string[] }

/** time-profile 表里主线程在跑的样本：时间（秒，从录制开始）、权重（毫秒）、栈上各帧的名字。 */
export function mainThreadSamples(xml: string): Sample[] {
  const samples: Sample[] = [];
  const frameCache = new Map<XmlNode, string[]>();
  const frames = (node: XmlNode): string[] => {
    const cached = frameCache.get(node);
    if (cached) return cached;
    const direct = node.children.filter((c) => c.tag === 'frame');
    const nested = node.children.find((c) => c.tag === 'backtrace' || c.tag === 'tagged-backtrace');
    const names = direct.length ? direct.map((f) => f.attrs.name ?? '?') : nested ? frames(nested) : [];
    frameCache.set(node, names);
    return names;
  };
  for (const row of xmlRows(xml)) {
    const thread = child(row, 'thread');
    if (!thread?.attrs.fmt?.includes('Main Thread')) continue;
    const state = child(row, 'thread-state');
    if (state && state.attrs.fmt !== undefined && state.attrs.fmt !== 'Running') continue;
    const backtrace = child(row, 'tagged-backtrace') ?? child(row, 'backtrace');
    const time = child(row, 'sample-time');
    if (!backtrace || !time) continue;
    const weight = child(row, 'weight');
    samples.push({ time: Number(time.text) / 1e9, weight: weight ? Number(weight.text) / 1e6 : 1, frames: frames(backtrace) });
  }
  return samples;
}

/** os-signpost 表里测量版打的区间（PerfProbe.measuring）：开始、结束（秒，从录制开始）。 */
export function measureIntervals(xml: string): Array<[number, number]> {
  const begins = new Map<string, number>();
  const intervals: Array<[number, number]> = [];
  for (const row of xmlRows(xml)) {
    const name = child(row, 'name') ?? child(row, 'signpost-name');
    if (name?.attrs.fmt !== 'measure' && name?.text !== 'measure') continue;
    const time = Number(child(row, 'event-time')?.text ?? child(row, 'start-time')?.text) / 1e9;
    const type = child(row, 'event-type')?.attrs.fmt ?? child(row, 'event-type')?.text ?? '';
    const id = child(row, 'identifier')?.attrs.fmt ?? child(row, 'signpost-id')?.attrs.fmt ?? '';
    if (/begin/i.test(type)) begins.set(id, time);
    else if (/end/i.test(type) && begins.has(id)) {
      intervals.push([begins.get(id)!, time]);
      begins.delete(id);
    }
  }
  // 同一个区间会出现在好几张 os-signpost 表里
  const unique = new Map(intervals.map((i) => [i.join(), i]));
  return [...unique.values()].sort((a, b) => a[0] - b[0]);
}

/**
 * 区间里的主线程合计，按关键词分：每个样本归到栈里（从里往外）先出现、给的次序里靠前的那个关键词，都没有的归「其他」，
 * 各项加起来等于合计。显示周期、CA 提交这类外层的帧几乎包着所有布局，放在最后，只收布局以外的。没有区间时按整段录制算。
 */
export function profile(samples: Sample[], intervals: Array<[number, number]>, keywords: string[], steps: number): Profile {
  const inside = intervals.length ? samples.filter((s) => intervals.some(([a, b]) => s.time >= a && s.time <= b)) : samples;
  const result: Profile = { totalMs: sum(inside.map((s) => s.weight)), keywords: Object.fromEntries([...keywords, '其他'].map((k) => [k, 0])), intervals: intervals.length, steps };
  for (const sample of inside) {
    const owner = keywords.find((k) => sample.frames.some((f) => f.includes(k))) ?? '其他';
    result.keywords[owner]! += sample.weight;
  }
  return result;
}
