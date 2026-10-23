/**
 * 工作机之间的自动更新（src/update/updates.ts，规则见 docs/macOS安装与打包.md「自动更新」）：两台本进程 kited 都当安装版，
 * 各有安装目录和一个假的运行目录（带打包写的 manifest.json、files.json）。A 的安装目录留着手动安装的发布标记，
 * B 的换版换成记录调用的钩子，不起 launchd 的安装进程；只有最后一个测试不换，走真实的起进程，暂存目录里没有 bin/bun，起不来。
 */
import { afterEach, expect, test } from 'bun:test';
import { randomBytes } from 'node:crypto';
import { chmodSync, lstatSync, mkdirSync, readdirSync, readFileSync, readlinkSync, symlinkSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { SEGMENT_BYTES } from '../../src/peer-fetch.ts';
import type { UpdateState, UpdateStatus } from '../../src/update/updates.ts';
import { buildOf, type FileEntry, listFiles, unlisted } from '../../src/update/files.ts';
import { PROTOCOL, type RuntimeManifest } from '../../src/version.ts';
import { connect, folderWorkspace, type Kited, openAgent, startKited } from '../harness.ts';
import { ManualModel } from '../harness-loop.ts';
import { makeTemp, newDir, until } from '../util.ts';

const kiteds: Kited[] = [];
const proxies: Array<{ stop(): void }> = [];
afterEach(async () => {
  for (const k of kiteds.splice(0)) await k.stop();
  for (const proxy of proxies.splice(0)) proxy.stop();
});

interface Install { root: string; runtime: string; build: string }

/**
 * 在 parent/install 下建安装目录，runtime/ 是运行目录：写入 files，executable 里的设成可执行，links 建成符号链接，
 * 再像打包那样写 files.json（不含它自己与 manifest.json）和带构建号的 manifest.json。
 */
async function install(parent: string, files: Record<string, string | Uint8Array>, executable: string[], links: Record<string, string>): Promise<Install> {
  const root = join(parent, 'install');
  const runtime = join(root, 'runtime');
  for (const [path, content] of Object.entries(files)) {
    mkdirSync(dirname(join(runtime, path)), { recursive: true });
    writeFileSync(join(runtime, path), content);
  }
  for (const path of executable) chmodSync(join(runtime, path), 0o755);
  for (const [path, target] of Object.entries(links)) symlinkSync(target, join(runtime, path));
  const listing = await listFiles(runtime, unlisted);
  const build = buildOf(listing);
  const manifest: RuntimeManifest = {
    platform: process.platform, arch: process.arch, bun: Bun.version, builtAt: new Date().toISOString(),
    build, protocol: PROTOCOL, commit: 'test-commit',
  };
  writeFileSync(join(runtime, 'files.json'), JSON.stringify(listing));
  writeFileSync(join(runtime, 'manifest.json'), JSON.stringify(manifest));
  return { root, runtime, build };
}

/**
 * A 与 B 的运行目录：bin/tool、lib/shared.js 内容相同（前者可执行），其余内容不同或只有一边有，bin/kite-link 两边指向不同。
 * A 另有一个比一段（SEGMENT_BYTES）大、不是整段的二进制文件 lib/big.bin，B 没有，拉取方按段取。
 */
const SHARED = { 'bin/tool': '#!/bin/sh\necho tool\n', 'lib/shared.js': 'export const shared = 1;\n' };
const BIG = 'lib/big.bin';
const bigContent = randomBytes(2.5 * SEGMENT_BYTES + 3);
const installA = (parent: string) => install(parent, {
  ...SHARED, 'bin/kite': '#!/bin/sh\necho A\n', 'lib/changed.js': 'export const side = "A";\n', 'lib/only a.js': 'export const only = "A";\n',
  [BIG]: bigContent,
}, ['bin/tool', 'bin/kite'], { 'bin/kite-link': 'kite' });
const installB = (parent: string) => install(parent, {
  ...SHARED, 'bin/kite': '#!/bin/sh\necho B\n', 'lib/changed.js': 'export const side = "B";\n', 'lib/only-b.js': 'export const only = "B";\n',
}, ['bin/tool', 'bin/kite'], { 'bin/kite-link': 'tool' });

/** 目录下每一项：普通文件记内容字节与可执行位，符号链接记目标。 */
function tree(dir: string): Record<string, { bytes: Buffer; executable: boolean } | { link: string }> {
  const out: Record<string, { bytes: Buffer; executable: boolean } | { link: string }> = {};
  const walk = (rel: string) => {
    for (const name of readdirSync(join(dir, rel))) {
      const path = rel ? `${rel}/${name}` : name;
      const stat = lstatSync(join(dir, path));
      if (stat.isSymbolicLink()) out[path] = { link: readlinkSync(join(dir, path)) };
      else if (stat.isDirectory()) walk(path);
      else out[path] = { bytes: readFileSync(join(dir, path)), executable: (stat.mode & 0o111) !== 0 };
    }
  };
  walk('');
  return out;
}

/**
 * 转发到 target 的 HTTP 代理，记下经过的请求（含查询参数与 Range 头），用来看 B 向 A 要了哪些文件。
 * old 时扮演旧版的 A：转发前去掉 Range 头（旧版不认 Range，整份给），取单个文件的 /update/:build/:payload/file 按旧版没有这个接口回 404。
 */
function recordingProxy(target: string, old = false) {
  const requests: Array<{ method: string; path: string; query: string; range: string | null; body?: string }> = [];
  const server = Bun.serve({
    hostname: '127.0.0.1', port: 0, idleTimeout: 0,
    async fetch(req) {
      const url = new URL(req.url);
      const body = req.method === 'GET' || req.method === 'HEAD' ? undefined : await req.text();
      requests.push({ method: req.method, path: url.pathname, query: url.search, range: req.headers.get('range'), ...(body === undefined ? {} : { body }) });
      const headers = new Headers(req.headers);
      if (old) {
        if (/^\/update\/[^/]+\/[^/]+\/file$/.test(url.pathname)) return Response.json({ error: '没有这个接口' }, { status: 404 });
        headers.delete('range');
      }
      // 测试结束时 A 先停，B 经代理挂着的长轮询连不上 A，按网关错误答回去，不留未处理的拒绝。
      try { return await fetch(target + url.pathname + url.search, { method: req.method, headers, body, signal: req.signal }); }
      catch { return new Response(null, { status: 502 }); }
    },
  });
  const proxy = { url: `http://127.0.0.1:${server.port}`, requests, stop: () => { void server.stop(true); } };
  proxies.push(proxy);
  return proxy;
}

/** 等 k 的更新状态到 state；超时报出当时的状态。 */
async function reach(k: Kited, state: UpdateState['state'], timeoutMs = 700): Promise<UpdateStatus> {
  try {
    return await until(() => { const status = k.daemon.kite.updates.status(); return status.state === state && status; }, state, timeoutMs);
  } catch {
    throw new Error(`更新状态没到 ${state}：${JSON.stringify(k.daemon.kite.updates.status())}`);
  }
}

// 要几样东西配合起来才成：A 按发布标记把版本写进账号级数据并同步到 B；B 读 A 的 /machine 记下它在跑这一版；
// B 经 HTTP 按段取清单，本机运行目录里内容相同的直接复用，其余小文件凑成几批同时向 A 要 tar 流（A 用 /usr/bin/tar 经 Bun.spawn 管道打包，
// B 同样解开），比一段大的文件按段向 A 取、几段写进同一个文件，逐个校验哈希后放进暂存目录；B 空闲就换。
// tar 的参数、管道、路径（含空格）、可执行位、符号链接、各段的位置任何一环错了，暂存的树就和 A 的不一样或根本组不出来，只有跑起来才知道。
test('A 手动安装即发布，B 同步后从 A 取文件，只传本机没有的内容、大文件按段取，暂存出与 A 运行目录逐字节相同的树，空闲就换上', async () => {
  const rootA = makeTemp('kited-');
  const rootB = makeTemp('kited-');
  const a = await installA(rootA);
  const b = await installB(rootB);
  writeFileSync(join(a.root, 'publish'), a.build);
  const applied: string[] = [];
  const kA = startKited(undefined, false, { root: rootA, install: { root: a.root, runtime: a.runtime, publishDelayMs: 0 } });
  kiteds.push(kA);
  const kB = startKited(undefined, false, { root: rootB, install: { root: b.root, runtime: b.runtime, apply: (staged) => { applied.push(staged); } } });
  kiteds.push(kB);
  expect(a.build).not.toBe(b.build);

  // B 经代理访问 A，看得到向 A 要了哪些文件；A 直接访问 B。代理原样转发，对两边和 connect 一样。
  const proxy = recordingProxy(kA.url);
  kA.candidates.push({ address: kB.url, online: true });
  kB.candidates.push({ address: proxy.url, online: true });
  await Promise.all([kA.daemon.kite.directory.refresh(), kB.daemon.kite.directory.refresh()]);

  const staged = join(b.root, 'updates', a.build, 'runtime');
  const status = await reach(kB, 'installing');
  expect(applied).toEqual([staged]);
  expect(tree(staged)).toEqual(tree(a.runtime));

  const requested = proxy.requests.filter((r) => r.method === 'POST' && r.path === `/update/${a.build}/runtime/files`)
    .flatMap((r) => JSON.parse(r.body!).paths as string[]);
  expect(requested).toContain('bin/kite');
  expect(requested).not.toContain('bin/tool');
  expect(requested).not.toContain('lib/shared.js');
  expect(requested).not.toContain(BIG);
  // 大文件走取单个文件的接口，每个请求带 Range，三段（2.5 段）都取到。
  const big = proxy.requests.filter((r) => r.method === 'GET' && r.path === `/update/${a.build}/runtime/file`);
  expect(big.map((r) => new URLSearchParams(r.query).get('path'))).toEqual(big.map(() => BIG));
  const starts = big.map((r) => Number(/^bytes=(\d+)-\d+$/.exec(r.range ?? '')?.[1]));
  expect([...new Set(starts)].sort((x, y) => x - y)).toEqual([0, SEGMENT_BYTES, 2 * SEGMENT_BYTES]);

  expect(status).toMatchObject({ version: { build: b.build }, release: { build: a.build, protocol: PROTOCOL } });
  expect((await kB.call('GET', '/update')).body).toMatchObject({ state: 'installing', version: { build: b.build }, release: { build: a.build } });
  expect((await kA.call('GET', '/update')).body).toMatchObject({ state: 'current', version: { build: a.build }, release: { build: a.build } });
}, 1000);

/**
 * A 发布、B 有一个正在进行的回合（模型请求挂着不答）时接上两台，等 B 的新版备好：此时 B 一定在忙。
 * 返回 B、它挂着的那次模型请求、线程 ID 和换版钩子收到的参数。
 */
async function readyWhileBusy() {
  const rootA = makeTemp('kited-');
  const rootB = makeTemp('kited-');
  const a = await installA(rootA);
  const b = await installB(rootB);
  writeFileSync(join(a.root, 'publish'), a.build);
  const applied: string[] = [];
  const model = new ManualModel();
  const kA = startKited(undefined, false, { root: rootA, install: { root: a.root, runtime: a.runtime, publishDelayMs: 0 } });
  kiteds.push(kA);
  const kB = startKited(() => model, false, { root: rootB, install: { root: b.root, runtime: b.runtime, apply: (staged) => { applied.push(staged); } } });
  kiteds.push(kB);

  const checkout = await folderWorkspace(kB, newDir(kB.root, 'project', { 'base.txt': '原始\n' }));
  const id = await openAgent(kB.call, checkout.workspace.id);
  expect((await kB.call('POST', `/threads/${id}/messages`, { text: '干活' })).status).toBe(200);
  const turn = await model.call(1);
  await connect(kA, kB);

  const ready = await reach(kB, 'ready');
  expect(ready.state === 'ready' && ready.waiting).toContainEqual(expect.stringMatching(/回合正在进行/));
  expect(applied).toEqual([]);
  return { kB, id, turn, applied, staged: join(b.root, 'updates', a.build, 'runtime'), release: a.build };
}

// 忙闲来自运行器的状态：新版备好时 B 有回合在跑，要停在 ready 并说明在等什么，不能自己换；
// 手动现在更新时才换，状态从 ready 走到 installing。运行器、更新状态的流转与 HTTP 接口要合起来看。
test('新版备好时 B 有回合正在进行就停在 ready 并列出在等回合，不自己换；POST /update/apply 才换上', async () => {
  const { kB, turn, applied, staged, release } = await readyWhileBusy();

  // 现在更新只记下这一版，交给下一遍判断去换，接口返回时多半还在 ready，等状态到 installing。
  const now = await kB.call('POST', '/update/apply');
  expect(now.status).toBe(200);
  expect(now.body).toMatchObject({ release: { build: release } });
  await reach(kB, 'installing', 300);
  expect(applied).toEqual([staged]);
  expect((await kB.call('GET', '/update')).body.state).toBe('installing');
  turn.response.complete();
}, 1000);

// 真实出过的 bug：回合结束后更新不会重新判断忙闲，停在 ready 且 waiting 已空，要等 30 秒一次的定时才换。
// 运行器回合结束的事件要接到更新的重新判断上，两部分合起来才看得出。
test('新版备好时 B 在忙停在 ready，回合结束后不用任何操作、不等定时就自己换上', async () => {
  const { kB, id, turn, applied, staged } = await readyWhileBusy();

  turn.response.complete();
  await kB.waitEvent((e) => e.type === 'idle' && e.threadId === id);
  await reach(kB, 'installing', 300);
  expect(applied).toEqual([staged]);
}, 1000);

// 真实出过的 bug：起安装进程失败（暂存目录里没有可执行的 bin/bun）时状态永远停在 installing，之后不重启 kited 就再也不更新。
// 依赖 Bun 的行为：node:child_process 的 spawn 找不到可执行文件时只发 error（和 close），不发 exit；只接 exit 就复位不了。
// 这里 B 不换掉换版，暂存的运行目录取自 A 的假运行目录，本来就没有 bin/bun，起进程以 ENOENT 失败。
test('B 起安装进程失败时状态从 installing 回到 ready，不停在 installing，仍跑着旧版', async () => {
  const rootA = makeTemp('kited-');
  const rootB = makeTemp('kited-');
  const a = await installA(rootA);
  const b = await installB(rootB);
  writeFileSync(join(a.root, 'publish'), a.build);
  const kA = startKited(undefined, false, { root: rootA, install: { root: a.root, runtime: a.runtime, publishDelayMs: 0 } });
  kiteds.push(kA);
  const kB = startKited(undefined, false, { root: rootB, install: { root: b.root, runtime: b.runtime } });
  kiteds.push(kB);

  // installing 到失败复位可能只隔一轮事件循环，轮询看不到；每次 update.changed 时同步记下当时的状态。
  const states: string[] = [];
  kB.daemon.kite.bus.subscribe((e) => e.type === 'update.changed', () => { states.push(kB.daemon.kite.updates.status().state); });
  await connect(kA, kB);

  try {
    await until(() => states.includes('installing') && states.slice(states.indexOf('installing') + 1).includes('ready'), 'installing 之后回到 ready', 700);
  } catch {
    throw new Error(`更新状态没有从 installing 回到 ready：${JSON.stringify(states)}，现在 ${JSON.stringify(kB.daemon.kite.updates.status())}`);
  }
  expect((await kB.call('GET', '/update')).body).toMatchObject({ state: 'ready', version: { build: b.build }, release: { build: a.build } });
}, 1000);

// 跨版本兼容：/update 系列要让新旧版本互相取得到，新旧版本靠它收敛。旧版的提供方只能模拟：代理去掉发往 A 的 Range 头，
// A 的清单就整份回 200；取单个文件的接口回 404，像旧版没有它。B 要用整份清单、小文件照常按批取 tar，大文件退回打成 tar 一个一批，
// 取到的树仍与 A 逐字节相同。旧版的拉取方直接向 A 要不带 Range 的清单，要拿到 200 和整份 JSON。
test('新版向旧版取（清单不认 Range、没有取单个文件的接口）时大文件退回按 tar 取，暂存出逐字节相同的树；旧版向新版不带 Range 取清单拿到整份', async () => {
  const rootA = makeTemp('kited-');
  const rootB = makeTemp('kited-');
  const a = await installA(rootA);
  const b = await installB(rootB);
  writeFileSync(join(a.root, 'publish'), a.build);
  const applied: string[] = [];
  const kA = startKited(undefined, false, { root: rootA, install: { root: a.root, runtime: a.runtime, publishDelayMs: 0 } });
  kiteds.push(kA);
  const kB = startKited(undefined, false, { root: rootB, install: { root: b.root, runtime: b.runtime, apply: (staged) => { applied.push(staged); } } });
  kiteds.push(kB);

  const proxy = recordingProxy(kA.url, true);
  kA.candidates.push({ address: kB.url, online: true });
  kB.candidates.push({ address: proxy.url, online: true });
  await Promise.all([kA.daemon.kite.directory.refresh(), kB.daemon.kite.directory.refresh()]);

  const staged = join(b.root, 'updates', a.build, 'runtime');
  await reach(kB, 'installing');
  expect(applied).toEqual([staged]);
  expect(tree(staged)).toEqual(tree(a.runtime));
  const requested = proxy.requests.filter((r) => r.method === 'POST' && r.path === `/update/${a.build}/runtime/files`)
    .flatMap((r) => JSON.parse(r.body!).paths as string[]);
  expect(requested).toContain(BIG);
  expect(requested).toContain('bin/kite');

  const listing = await kA.call('GET', `/update/${a.build}/runtime`);
  expect(listing.status).toBe(200);
  const byPath = (x: FileEntry, y: FileEntry) => (x.path < y.path ? -1 : x.path > y.path ? 1 : 0);
  expect([...listing.body.files as FileEntry[]].sort(byPath)).toEqual((await listFiles(a.runtime)).sort(byPath));
}, 1000);
