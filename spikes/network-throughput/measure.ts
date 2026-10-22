#!/usr/bin/env bun
/**
 * 网速实验：分层测「kited 取文件接口 → kite-net 组网 → 两端公网出口」的吞吐、首字节与波动，用法见 README。
 *
 * 取文件用自动更新的 POST /update/<build>/runtime/files：只读、peerOnly，两台工作机跑同一版时给的是同样的文件，
 * 本机回环与经组网拉对端用同一个接口，差别只在路径。上传向同一接口发非 JSON 的请求体，对端读完后以 400 拒绝，不留任何东西。
 */
import { appendFileSync, mkdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';

const args = process.argv.slice(2);
const flag = (name: string, fallback: string) => {
  const i = args.indexOf(`--${name}`);
  if (i < 0) return fallback;
  const value = args[i + 1]!;
  args.splice(i, 2);
  return value;
};
const KITED = `http://127.0.0.1:${flag('kited', '5483')}`;
const OUT = flag('out', join(tmpdir(), 'kite-network-throughput'));
const RUNS = Number(flag('runs', '3'));
const MAX_TIME = Number(flag('max-time', '180'));
const LABEL = flag('label', '');
const LATENCY_RUNS = Number(flag('n', '20'));
mkdirSync(OUT, { recursive: true });
const RESULTS = join(OUT, 'results.jsonl');

/** 取文件的几档大小，都是运行目录里的文件，两台同版本的工作机上都有。 */
const PAYLOADS: Record<string, string[]> = {
  '1m': ['kited/node_modules/gpt-tokenizer/src/bpeRanks/cl100k_base.js'],
  '2m': ['kited/node_modules/gpt-tokenizer/src/bpeRanks/o200k_base.js'],
  '4m': ['bin/rg'],
  '30m': ['kited/net/bin/kite-net'],
  '100m': ['bin/bun', 'kited/net/bin/kite-net', 'bin/rg'],
};
const BYTES: Record<string, number> = { '1m': 1 << 20, '2m': 2 << 20, '4m': 4 << 20, '10m': 10 << 20, '16m': 16 << 20, '30m': 30 << 20, '100m': 100 << 20 };

// ---- 本机 kited 与 kite-net ----

const localMachine = (await (await fetch(`${KITED}/machine`)).json()) as { id: string; version: { build: string } };
async function network(): Promise<{ ips: string[]; socksPort: number; httpProxyPort: number; endpoints: string[]; channel?: unknown;
  peers: Array<{ name: string; ip: string; os: string; online: boolean; connection: string; endpoint?: string }> }> {
  return (await fetch(`${KITED}/network`, { headers: { 'X-Kite-Machine': localMachine.id } })).json() as never;
}
const net = await network();

interface Target { name: string; base: string; via: string[]; ip?: string }
/** local：直连本机 kited；self：经 kite-net 的 HTTP 代理访问本机自己的组网地址；其他是对端的节点名或组网 IP，加 socks: 前缀改走 SOCKS5。 */
function target(spec: string): Target {
  const socks = spec.startsWith('socks:');
  const name = socks ? spec.slice(6) : spec;
  if (name === 'local') return { name: spec, base: KITED, via: [] };
  const ip = name === 'self' ? net.ips[0]! : net.peers.find((peer) => peer.name === name || peer.ip === name)?.ip ?? name;
  const via = socks ? ['--socks5-hostname', `127.0.0.1:${net.socksPort}`] : ['-x', `http://127.0.0.1:${net.httpProxyPort}`];
  return { name: spec, base: `http://${ip}:5483`, via, ip };
}

async function peerState(t: Target) {
  if (!t.ip) return undefined;
  const peer = (await network()).peers.find((p) => p.ip === t.ip);
  return peer && { connection: peer.connection, endpoint: peer.endpoint, online: peer.online };
}

// ---- curl ----

async function curl(argv: string[], stdin?: Uint8Array) {
  const child = Bun.spawn(['curl', '-s', '-o', '/dev/null', '-w', '%{json}', '--max-time', String(MAX_TIME), ...argv],
    { stdin: stdin ? new Blob([stdin]) : 'ignore', stdout: 'pipe', stderr: 'pipe', env: { PATH: '/usr/bin:/bin' } });
  const [code, out] = await Promise.all([child.exited, new Response(child.stdout).text()]);
  const m = JSON.parse(out || '{}');
  return { exit: code, http: m.http_code, connect: m.time_connect, ttfb: m.time_starttransfer, total: m.time_total,
    down: m.size_download, up: m.size_upload, downBps: m.speed_download, upBps: m.speed_upload };
}

const machineIds = new Map<string, string>();
/** 对端的机器 ID 只取一次：watch 的 cold 要是闲置后的第一个请求，不能先被这个小请求唤醒。 */
async function machineId(t: Target): Promise<string> {
  if (!t.ip) return localMachine.id;
  const known = machineIds.get(t.ip);
  if (known) return known;
  const child = Bun.spawn(['curl', '-s', '--max-time', '30', ...t.via, `${t.base}/machine`], { stdout: 'pipe', env: { PATH: '/usr/bin:/bin' } });
  const id = (JSON.parse(await new Response(child.stdout).text()) as { id: string }).id;
  machineIds.set(t.ip, id);
  return id;
}

/** 本机 UDP 因接收缓冲满丢的包，前后相减看传输期间有没有丢在本机。 */
function udpDrops(): number {
  const out = Bun.spawnSync(['netstat', '-s', '-p', 'udp'], { env: { PATH: '/usr/bin:/bin:/usr/sbin' } }).stdout.toString();
  return Number(/(\d+) dropped due to full socket buffers/.exec(out)?.[1] ?? NaN);
}

function record(entry: Record<string, unknown>) {
  const line = { at: new Date().toISOString(), label: LABEL || undefined, ...entry };
  appendFileSync(RESULTS, `${JSON.stringify(line)}\n`);
  console.log(JSON.stringify(line));
}

// ---- 各项 ----

async function latency(spec: string) {
  const t = target(spec);
  for (let i = 0; i < LATENCY_RUNS; i++) {
    record({ kind: 'latency', target: t.name, run: i, peer: i === 0 ? await peerState(t) : undefined, ...await curl([...t.via, `${t.base}/machine`]) });
  }
}

async function down(spec: string, sizes: string[]) {
  const t = target(spec);
  const id = await machineId(t);
  const build = localMachine.version.build;
  for (const size of sizes) {
    const paths = PAYLOADS[size];
    if (!paths) throw new Error(`没有 ${size} 这一档，可选 ${Object.keys(PAYLOADS).join(' ')}`);
    for (let i = 0; i < RUNS; i++) {
      const peer = await peerState(t);
      const drops = udpDrops();
      const result = await curl([...t.via, '-H', `X-Kite-Machine: ${id}`, '-H', 'content-type: application/json', '--data-binary', '@-',
        `${t.base}/update/${build}/runtime/files`], new TextEncoder().encode(JSON.stringify({ paths })));
      record({ kind: 'down', target: t.name, size, run: i, peer, udpDrops: udpDrops() - drops, ...result });
    }
  }
}

/** 文件插件取原始字节的接口 GET /workspaces/:id/files/content，按 Range 取前若干字节；all 取整份。App 看文件走的就是它。 */
async function file(spec: string, workspace: string, path: string, sizes: string[]) {
  const t = target(spec);
  const id = await machineId(t);
  const url = `${t.base}/workspaces/${workspace}/files/content?path=${encodeURIComponent(path)}`;
  for (const size of sizes) {
    const range = size === 'all' ? [] : ['-H', `Range: bytes=0-${BYTES[size]! - 1}`];
    for (let i = 0; i < RUNS; i++) {
      const peer = await peerState(t);
      const drops = udpDrops();
      const result = await curl([...t.via, '-H', `X-Kite-Machine: ${id}`, ...range, url]);
      record({ kind: 'file', target: t.name, size, run: i, peer, udpDrops: udpDrops() - drops, ...result });
    }
  }
}

async function up(spec: string, sizes: string[]) {
  const t = target(spec);
  const id = await machineId(t);
  for (const size of sizes) {
    const body = new Uint8Array(BYTES[size]!).fill(0x78);
    for (let i = 0; i < RUNS; i++) {
      const peer = await peerState(t);
      const result = await curl([...t.via, '-H', `X-Kite-Machine: ${id}`, '-H', 'content-type: application/octet-stream', '--data-binary', '@-',
        `${t.base}/update/${localMachine.version.build}/runtime/files`], body);
      record({ kind: 'up', target: t.name, size, run: i, peer, ...result });
    }
  }
}

/** 逐块记下到达时刻，看是匀速慢还是一阵一阵、中间停顿；只支持 HTTP 代理。 */
async function timeline(spec: string, size: string, extra: Record<string, unknown> = {}) {
  const t = target(spec);
  const id = await machineId(t);
  const started = performance.now();
  const response = await fetch(`${t.base}/update/${localMachine.version.build}/runtime/files`, {
    method: 'POST', body: JSON.stringify({ paths: PAYLOADS[size] }), signal: AbortSignal.timeout(MAX_TIME * 1000),
    headers: { 'X-Kite-Machine': id, 'content-type': 'application/json' },
    ...(t.ip ? { proxy: `http://127.0.0.1:${net.httpProxyPort}` } : {}),
  } as RequestInit);
  const ttfb = performance.now() - started;
  const chunks: Array<[number, number]> = [];
  let received = 0;
  try {
    for await (const chunk of response.body as unknown as AsyncIterable<Uint8Array>) {
      received += chunk.byteLength;
      chunks.push([Math.round(performance.now() - started), chunk.byteLength]);
    }
  } catch (error) { console.error(`中断：${(error as Error).message}`); }
  const gaps = chunks.slice(1).map(([at], i) => at - chunks[i]![0]).filter((gap) => gap >= 300);
  const perSecond: number[] = [];
  for (const [at, bytes] of chunks) perSecond[Math.floor(at / 1000)] = (perSecond[Math.floor(at / 1000)] ?? 0) + bytes;
  record({ kind: 'timeline', target: t.name, size, ...extra, ttfb: Math.round(ttfb), received, total: chunks.at(-1)?.[0], chunks: chunks.length,
    stalls300ms: gaps.length, longestStall: Math.max(0, ...gaps), stallSeconds: gaps.reduce((a, b) => a + b, 0) / 1000,
    perSecondKB: Array.from(perSecond, (v) => Math.round((v ?? 0) / 1024)) });
}

/**
 * 隔一阵测一次，看同一条路径随时间怎么变：闲置一阵后先取 2m（cold），紧接着再取一次（warm），再发 1m。
 * cold 与 warm 对比用来看「闲置后第一次传得慢」是不是普遍现象。
 */
async function watch(spec: string) {
  const every = Number(flag('every', '90')) * 1000;
  const until = Date.now() + Number(flag('for', '1800')) * 1000;
  const t = target(spec);
  const id = await machineId(t);
  for (let tick = 0; Date.now() < until; tick++) {
    const started = Date.now();
    const peer = await peerState(t);
    await timeline(spec, '2m', { tick, phase: 'cold', peer });
    await timeline(spec, '2m', { tick, phase: 'warm' });
    record({ kind: 'watch-up', target: t.name, size: '1m', tick, ...await curl([...t.via, '-H', `X-Kite-Machine: ${id}`,
      '-H', 'content-type: application/octet-stream', '--data-binary', '@-', `${t.base}/update/${localMachine.version.build}/runtime/files`],
      new Uint8Array(BYTES['1m']!).fill(0x78)) });
    await Bun.sleep(Math.max(0, every - (Date.now() - started)));
  }
}

/**
 * 连取几次 2m，同时每 0.5 秒读一次 /network 里这台对端的连接方式与端点，每 0.2 秒 ping 一次默认网关；
 * 每次取完记下这段时间里见过的连接方式、端点和网关丢包，用来区分慢的时候是换了路径、本机局域网丢包，还是路上的事。
 */
async function probe(spec: string) {
  const t = target(spec);
  await machineId(t);
  const gateway = flag('gateway', '192.168.31.1');
  const states: Array<{ at: number; connection?: string; endpoint?: string }> = [];
  const sampler = setInterval(async () => {
    const peer = await peerState(t).catch(() => undefined);
    states.push({ at: Date.now(), connection: peer?.connection, endpoint: peer?.endpoint });
  }, 500);
  const pings: Array<{ at: number; ok: boolean }> = [];
  const ping = Bun.spawn(['ping', '-i', '0.2', gateway], { stdout: 'pipe', stderr: 'ignore', env: { PATH: '/sbin:/usr/bin:/bin' } });
  void (async () => {
    let buffer = '';
    for await (const chunk of ping.stdout as unknown as AsyncIterable<Uint8Array>) {
      buffer += new TextDecoder().decode(chunk);
      const lines = buffer.split('\n');
      buffer = lines.pop()!;
      for (const line of lines) {
        if (line.includes('bytes from')) pings.push({ at: Date.now(), ok: true });
        else if (line.includes('Request timeout')) pings.push({ at: Date.now(), ok: false });
      }
    }
  })();
  for (let i = 0; i < LATENCY_RUNS; i++) {
    const started = Date.now();
    await timeline(spec, '2m', { probe: i });
    const ended = Date.now();
    const seen = states.filter((s) => s.at >= started && s.at <= ended);
    const window = pings.filter((p) => p.at >= started && p.at <= ended);
    record({ kind: 'probe', target: t.name, probe: i, seconds: (ended - started) / 1000,
      connections: [...new Set(seen.map((s) => s.connection))], endpoints: [...new Set(seen.map((s) => s.endpoint))],
      gatewayPings: window.length, gatewayLost: window.filter((p) => !p.ok).length });
  }
  clearInterval(sampler);
  ping.kill();
}

/** 经 HTTP 代理取一次 payload，返回耗时、字节数与 300 ms 以上的停顿；可以中途取消。 */
async function pull(t: Target, size: string, signal: AbortSignal) {
  const started = performance.now();
  let received = 0, last = started, stalls = 0, longest = 0, aborted = false;
  try {
    const response = await fetch(`${t.base}/update/${localMachine.version.build}/runtime/files`, {
      method: 'POST', body: JSON.stringify({ paths: PAYLOADS[size] }), signal,
      headers: { 'X-Kite-Machine': await machineId(t), 'content-type': 'application/json' },
      ...(t.ip ? { proxy: `http://127.0.0.1:${net.httpProxyPort}` } : {}),
    } as RequestInit);
    for await (const chunk of response.body as unknown as AsyncIterable<Uint8Array>) {
      const now = performance.now();
      if (now - last >= 300) { stalls++; longest = Math.max(longest, now - last); }
      last = now;
      received += chunk.byteLength;
    }
  } catch { aborted = true; }
  return { ms: Math.round(performance.now() - started), received, stalls, longest: Math.round(longest), aborted };
}

/**
 * 判断慢是整条路径的事还是单条连接的事：先开一条 A 取 2m，5 秒还没取完（落进了慢的状态）就另开一条 B 同时取 2m。
 * B 照样快，说明这段时间路径本身能跑快，慢的是 A 这条连接；B 也慢，说明是路径。B 取完就取消 A。
 */
async function overlap(spec: string) {
  const t = target(spec);
  await machineId(t);
  for (let i = 0; i < LATENCY_RUNS; i++) {
    const abortA = new AbortController();
    const a = pull(t, '2m', abortA.signal);
    const first = await Promise.race([a.then(() => 'done'), Bun.sleep(5000).then(() => 'slow')]);
    if (first === 'done') { record({ kind: 'overlap', target: t.name, attempt: i, a: await a }); continue; }
    const b = await pull(t, '2m', AbortSignal.timeout(MAX_TIME * 1000));
    abortA.abort();
    record({ kind: 'overlap', target: t.name, attempt: i, a: await a, b });
  }
}

/**
 * 比较三种取法在同一段时间里的总耗时，每轮随机排序、轮流跑：
 * single 一条连接取到底（现在的做法）；sequential 分成约 1 MB 的段依次取，一段 stall 毫秒没有新数据就断开、换条连接重取这一段；
 * parallel 同样分段、同样卡住重取，4 路同时取。对端没有工作区可按 Range 续取，这里用一组组文件当段，效果等同按段续传。
 */
async function strategies(spec: string) {
  const t = target(spec);
  const id = await machineId(t);
  const stallMs = Number(flag('stall', '2000'));
  const totalBytes = BYTES[flag('size', '16m')] ?? 16 << 20;
  const { files } = await (await fetch(`${KITED}/update/${localMachine.version.build}/runtime`, { headers: { 'X-Kite-Machine': localMachine.id } }))
    .json() as { files: Array<{ path: string; size: number; sha256?: string }> };
  const picked = files.filter((f) => f.sha256 && f.size >= 100_000 && f.size <= 1_000_000).sort((a, b) => a.path.localeCompare(b.path));
  const segments: string[][] = [];
  let sum = 0, current: string[] = [], currentBytes = 0;
  for (const f of picked) {
    if (sum >= totalBytes) break;
    current.push(f.path); currentBytes += f.size; sum += f.size;
    if (currentBytes >= 1 << 20) { segments.push(current); current = []; currentBytes = 0; }
  }
  if (current.length) segments.push(current);
  const url = `${t.base}/update/${localMachine.version.build}/runtime/files`;
  const headers = { 'X-Kite-Machine': id, 'content-type': 'application/json' };
  const proxy = t.ip ? { proxy: `http://127.0.0.1:${net.httpProxyPort}` } : {};

  /** 取一段；stall 为 0 时不管卡不卡，一直等到底。 */
  async function fetchSegment(paths: string[], stall: number, deadline: number): Promise<{ bytes: number; retries: number }> {
    for (let retries = 0; ; retries++) {
      if (Date.now() > deadline) throw new Error('超时');
      const abort = new AbortController();
      let timer: ReturnType<typeof setTimeout> | undefined;
      const arm = () => { clearTimeout(timer); if (stall) timer = setTimeout(() => abort.abort(), stall); };
      arm();
      try {
        const response = await fetch(url, { method: 'POST', body: JSON.stringify({ paths }), headers, ...proxy,
          signal: AbortSignal.any([abort.signal, AbortSignal.timeout(Math.max(1, deadline - Date.now()))]) } as RequestInit);
        if (!response.ok) throw new Error(`HTTP ${response.status}`);
        let bytes = 0;
        for await (const chunk of response.body as unknown as AsyncIterable<Uint8Array>) { arm(); bytes += chunk.byteLength; }
        clearTimeout(timer);
        return { bytes, retries };
      } catch (error) {
        clearTimeout(timer);
        if (!abort.signal.aborted || Date.now() > deadline) throw error;
      }
    }
  }

  async function run(strategy: string) {
    const started = Date.now();
    const deadline = started + MAX_TIME * 1000;
    let bytes = 0, retries = 0, ok = true;
    try {
      if (strategy === 'single') {
        bytes = (await fetchSegment(segments.flat(), 0, deadline)).bytes;
      } else {
        const queue = [...segments];
        const workers = strategy === 'parallel' ? 4 : 1;
        await Promise.all(Array.from({ length: workers }, async () => {
          for (let next = queue.shift(); next; next = queue.shift()) {
            const result = await fetchSegment(next, stallMs, deadline);
            bytes += result.bytes; retries += result.retries;
          }
        }));
      }
    } catch { ok = false; }
    return { ms: Date.now() - started, bytes, retries, ok };
  }

  const every = Number(flag('every', '0')) * 1000;
  for (let round = 0; round < LATENCY_RUNS; round++) {
    const started = Date.now();
    const order = ['single', 'sequential', 'parallel'].sort(() => Math.random() - 0.5);
    for (const strategy of order) {
      record({ kind: 'strategy', target: t.name, round, strategy, segments: segments.length, stallMs, ...await run(strategy) });
    }
    await Bun.sleep(Math.max(0, every - (Date.now() - started)));
  }
}

/** 本机经公网出口：Cloudflare 测速点（TCP），另用系统的 networkQuality 分别强制 HTTP/2（TCP）与 HTTP/3（QUIC，走 UDP）。 */
async function publicEgress() {
  const trace = await (await fetch('https://speed.cloudflare.com/cdn-cgi/trace')).text();
  record({ kind: 'egress', tcp: Object.fromEntries(trace.trim().split('\n').map((line) => line.split('=')).filter(([k]) => ['ip', 'colo', 'loc'].includes(k!))),
    udp: net.endpoints });
  for (const size of ['1m', '10m']) for (let i = 0; i < RUNS; i++) {
    record({ kind: 'public-down', target: 'cloudflare', size, run: i, ...await curl([`https://speed.cloudflare.com/__down?bytes=${BYTES[size]}`]) });
  }
  for (const size of ['1m', '10m']) for (let i = 0; i < RUNS; i++) {
    record({ kind: 'public-up', target: 'cloudflare', size, run: i,
      ...await curl(['--data-binary', '@-', 'https://speed.cloudflare.com/__up'], new Uint8Array(BYTES[size]!).fill(0x78)) });
  }
  for (const protocol of ['h2', 'h3']) {
    const child = Bun.spawn(['networkQuality', '-c', '-s', '-f', protocol, '-M', '20'], { stdout: 'pipe', stderr: 'pipe', env: { PATH: '/usr/bin:/bin' } });
    const out = await new Response(child.stdout).text();
    try {
      const m = JSON.parse(out);
      record({ kind: 'networkQuality', target: 'apple', protocol, downMbps: m.dl_throughput / 1e6, upMbps: m.ul_throughput / 1e6,
        responsiveness: m.responsiveness, baseRtt: m.base_rtt, interface: m.interface_name, error: m.error_code });
    } catch { record({ kind: 'networkQuality', target: 'apple', protocol, error: out.slice(0, 200) }); }
  }
}

/**
 * 把跨机传输整理成一张按北京时间排列的表，给网络管理员拿去和路由器侧的抓包对照：起止时间、方向、连接数、字节、速度，
 * 逐块记录过的（timeline、watch、probe）另列停顿区间，按秒取整，是整秒一个字节都没收到的区间。
 */
function exportCsv() {
  const rows = readFileSync(RESULTS, 'utf8').trim().split('\n').map((line) => JSON.parse(line));
  const beijing = (ms: number) => new Date(ms + 8 * 3600_000).toISOString().slice(11, 23);
  const out: Array<[number, string]> = [];
  const add = (start: number, end: number, direction: string, connections: number, bytes: number, kind: string, stalls = '') => {
    const seconds = (end - start) / 1000;
    out.push([start, [beijing(start), beijing(end), direction, connections, bytes, seconds.toFixed(2), (bytes / 1024 / seconds).toFixed(1), stalls,
      `${kind}${direction === '' ? '' : ''}`].join(',')]);
  };
  for (const r of rows) {
    if (!String(r.target ?? '').includes('kite-workstation')) continue;
    const end = Date.parse(r.at);
    if (r.kind === 'timeline') {
      const start = end - r.total;
      const zero: string[] = [];
      const perSecond: number[] = r.perSecondKB ?? [];
      for (let i = 0; i < perSecond.length; i++) {
        if (perSecond[i] !== 0) continue;
        let j = i;
        while (j + 1 < perSecond.length && perSecond[j + 1] === 0) j++;
        zero.push(`${beijing(start + i * 1000).slice(0, 8)}~${beijing(start + (j + 1) * 1000).slice(0, 8)}`);
        i = j;
      }
      add(start, end, '对端→Mac mini', 1, r.received, `逐块记录${r.phase ? `-${r.phase}` : ''}`, `"${zero.join(' ')}"`);
    } else if (r.kind === 'down' && r.http === 200) {
      add(end - r.total * 1000, end, '对端→Mac mini', 1, r.down, `取文件${r.target.startsWith('socks:') ? '-SOCKS5' : ''}`);
    } else if ((r.kind === 'up' || r.kind === 'watch-up') && r.http === 400) {
      add(end - r.total * 1000, end, 'Mac mini→对端', 1, r.up, '发文件');
    } else if (r.kind === 'strategy') {
      add(end - r.ms, end, '对端→Mac mini', r.strategy === 'parallel' ? 4 : 1, r.bytes,
        `取法-${{ single: '一条连接取到底', sequential: '分段依次取', parallel: '分段4路并行' }[r.strategy as string]}${r.retries ? `-卡住换连接${r.retries}次` : ''}${r.ok ? '' : '-超时'}`);
    } else if (r.kind === 'overlap') {
      const startA = r.b ? end - 5000 - r.b.ms : end - r.a.ms;
      add(startA, startA + r.a.ms, '对端→Mac mini', 1, r.a.received, `并开对照-A${r.a.aborted ? '-B取完后取消' : ''}`);
      if (r.b) add(startA + 5000, startA + 5000 + r.b.ms, '对端→Mac mini', 1, r.b.received, '并开对照-B');
    }
  }
  console.log('开始（北京时间）,结束（北京时间）,方向,同时连接数,字节,耗时秒,平均KB/s,停顿区间（整秒无数据，北京时间）,测量项');
  for (const [, line] of out.sort((a, b) => a[0] - b[0])) console.log(line);
}

function median(values: number[]) {
  const sorted = values.filter(Number.isFinite).sort((a, b) => a - b);
  return sorted.length ? sorted[Math.floor((sorted.length - 1) / 2)]! : NaN;
}

function summary() {
  const rows = readFileSync(RESULTS, 'utf8').trim().split('\n').map((line) => JSON.parse(line));
  const groups = new Map<string, Array<Record<string, number>>>();
  for (const row of rows) {
    if (!['down', 'file', 'up', 'latency', 'watch-up', 'public-down', 'public-up'].includes(row.kind)) continue;
    const key = [row.label ?? '', row.kind, row.target, row.size ?? ''].join(' | ');
    groups.set(key, [...groups.get(key) ?? [], row]);
  }
  const kb = (v: number) => Number.isFinite(v) ? (v / 1024).toFixed(v < 102400 ? 1 : 0) : '-';
  const ms = (v: number) => Number.isFinite(v) ? Math.round(v * 1000).toString() : '-';
  console.log('| 标签 | 项目 | 目标 | 大小 | 次数 | 完成 | 速度 KB/s 中位（最小～最大） | 首字节 ms 中位（最小～最大） | 总时长 s 中位 |');
  console.log('|---|---|---|---|---|---|---|---|---|');
  for (const [key, list] of groups) {
    const speed = list.map((r) => ['up', 'watch-up', 'public-up'].includes(r.kind as never) ? r.upBps! : r.downBps!);
    const ttfb = list.map((r) => r.ttfb!);
    const done = list.filter((r) => r.exit === 0 && (['up', 'watch-up'].includes(r.kind as never) ? r.http === 400 : r.http === 200 || r.http === 206)).length;
    console.log(`| ${key} | ${list.length} | ${done} | ${kb(median(speed))}（${kb(Math.min(...speed))}～${kb(Math.max(...speed))}） | `
      + `${ms(median(ttfb))}（${ms(Math.min(...ttfb))}～${ms(Math.max(...ttfb))}） | ${median(list.map((r) => r.total!)).toFixed(1)} |`);
  }
}

const [command, spec, ...rest] = args;
switch (command) {
  case 'env': console.log(JSON.stringify({ machine: localMachine, network: { ...net, peers: net.peers } }, null, 1)); break;
  case 'latency': await latency(spec!); break;
  case 'down': await down(spec!, rest); break;
  case 'up': await up(spec!, rest); break;
  case 'file': await file(spec!, rest[0]!, rest[1]!, rest.slice(2)); break;
  case 'timeline': await timeline(spec!, rest[0] ?? '2m'); break;
  case 'watch': await watch(spec!); break;
  case 'probe': await probe(spec!); break;
  case 'overlap': await overlap(spec!); break;
  case 'strategies': await strategies(spec!); break;
  case 'public': await publicEgress(); break;
  case 'summary': summary(); break;
  case 'export': exportCsv(); break;
  default: console.error('用法：bun measure.ts env | latency <目标> | down <目标> <大小…> | file <目标> <工作区 ID> <路径> <大小…> | up <目标> <大小…> | timeline <目标> <大小> | watch <目标> [--every 秒 --for 秒] | probe <目标> [--n 次数 --gateway 网关] | overlap <目标> [--n 次数] | strategies <目标> [--n 轮数 --every 秒 --stall 毫秒 --size 16m] | public | summary | export');
}
