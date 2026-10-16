/**
 * 自动更新：一台工作机手动安装即发布，其他工作机从正在运行这一版的工作机取运行文件，空闲时换上，
 * 见 docs/macOS安装与打包.md「自动更新」。只有安装版参与（有安装目录，运行目录带构建号）；源码运行的 kited 报告 dev。
 *
 * 安装目录（KITE_INSTALL_ROOT）里：runtime/ 是正在运行的运行目录；publish 是手动安装留下的发布标记，内容是构建号；
 * install.json 是安装记录，由 App 装上的服务在 app 记着 App 的位置；updates/<构建号>/ 暂存新版（runtime/、Kite.app、install.log），
 * updates/failed.json 记着换不上的那一版。换版由 scripts/install-macos.ts 的 update 命令完成。
 */
import { spawn } from 'node:child_process';
import { closeSync, constants, copyFileSync, chmodSync, existsSync, lstatSync, mkdirSync, openSync, readdirSync, readFileSync,
  renameSync, rmSync, symlinkSync } from 'node:fs';
import { homedir, userInfo } from 'node:os';
import { dirname, join } from 'node:path';
import { z } from 'zod';
import type { AccountData } from '../account-data/store.ts';
import { KiteError } from '../errors.ts';
import { peerJSON, type Peer, type PeerFetch } from '../peer-fetch.ts';
import { readManifest, versionOf, type RuntimeManifest, type Version } from '../version.ts';
import { buildOf, fileEntry, hashFile, listFiles, MANIFEST_FILES, unlisted, unsafeEntry, type FileEntry, type RegularEntry } from './files.ts';

/** 账号级数据里的发布记录：最近一次手动安装的版本，后写的为准。 */
export const releaseSchema = z.object({
  build: z.string().regex(/^[0-9a-f]{16}$/), protocol: z.number().int(), builtAt: z.string(), commit: z.string(),
  platform: z.string(), arch: z.string(), by: z.string(),
});
export type Release = z.infer<typeof releaseSchema>;
const RELEASE_ID = 'kite';

export type UpdateState =
  | { state: 'dev' }
  | { state: 'current' }
  | { state: 'unsupported'; reason: string }
  | { state: 'waiting-source' }
  | { state: 'downloading'; done: number; total: number }
  | { state: 'ready'; waiting: string[] }
  | { state: 'installing' }
  | { state: 'failed'; error: string; retry: boolean };
export type UpdateStatus = UpdateState & { version: Version; release: Release | null; app?: { build: string; path: string } };

export type Payload = 'runtime' | 'app';
/** Mac App 里放运行目录的位置；App 的清单不含它，拉取方用本机的同一版运行目录补上。 */
const APP_RUNTIME = 'Contents/Resources/Service/runtime';
/** 一次 tar 最多带这么多文件、这么多字节；断了只重取没到的。提供方的 Bun 会把整批 tar 输出读进内存，批不宜大。 */
const BATCH_FILES = 2_000;
const BATCH_BYTES = 16 * 1024 * 1024;
/** 这么久没收到数据就当对方没了。 */
const STALL_MS = 60_000;
const TICK_MS = 30_000;
const PUBLISH_DELAY_MS = 30_000;
const RETRY_MIN_MS = 60_000;
const RETRY_MAX_MS = 30 * 60_000;
/** 安装进程没换成就退出（例如另一个安装正在进行）后，隔这么久再试。 */
const REAPPLY_MS = 5 * 60_000;

export interface UpdatesOptions {
  /** 安装目录；源码运行时没有，不发布也不更新。 */
  root: string;
  /** 正在运行的运行目录，默认 root/runtime。 */
  runtime?: string;
  /** 测试里换掉换版：默认起脱离服务进程组的安装进程。 */
  apply?(staged: string): void;
  /** 测试里缩短手动安装后到发布的等待（毫秒），默认 30 秒。 */
  publishDelayMs?: number;
}

export class Updates {
  readonly version: Version;
  private manifest?: RuntimeManifest;
  private runtime?: string;
  private state: UpdateState;
  private timer?: ReturnType<typeof setInterval>;
  private publishTimer?: ReturnType<typeof setTimeout>;
  private unsubscribe?: () => void;
  private running?: Promise<void>;
  private again = false;
  private started = false;
  private closed = false;
  private abort = new AbortController();
  /** 取某一版的文件失败后，那一版隔一阵再取；换了发布就不等。 */
  private backoff?: { build: string; at: number; delay: number; error: string };
  /** 安装进程没换成就退出后，那一版隔一阵再换。 */
  private reapply?: { build: string; at: number };
  /** 用户选了现在更新的那一版：不等空闲。 */
  private forced?: string;
  /** 各版本上次取 Mac App 失败的时刻；隔一阵再试，不影响服务本身换版。 */
  private appAttempts = new Map<string, number>();
  private progressAt = 0;
  private listings = new Map<string, Promise<FileEntry[]>>();

  constructor(private deps: {
    data: AccountData;
    machineId: string;
    /** 在线的其他工作机，带各自正在运行的构建号。 */
    peers(): Array<Peer & { build?: string }>;
    fetch: PeerFetch;
    /** 这台工作机还在忙的事项；空时可以换版。 */
    busy(): string[];
    changed(): void;
  }, private options?: UpdatesOptions) {
    this.runtime = options && (options.runtime ?? join(options.root, 'runtime'));
    this.manifest = this.runtime ? readManifest(this.runtime) : undefined;
    this.version = versionOf(this.manifest);
    this.state = this.installed ? { state: 'current' } : { state: 'dev' };
  }

  /** 安装版才发布与更新：有安装目录，运行目录带构建号。 */
  private get installed(): boolean { return !!this.options && !!this.manifest; }
  private get root(): string { return this.options!.root; }
  private get updates(): string { return join(this.root, 'updates'); }

  start(): void {
    if (!this.installed) return;
    this.started = true;
    this.unsubscribe = this.deps.data.subscribe((changed) => { if (changed.some((entry) => entry.kind === 'release')) this.evaluate(); });
    // 新装的服务稳定跑一阵再发布，起不来或马上退出的版本不会传给其他工作机。
    this.publishTimer = setTimeout(() => { this.publish(); this.evaluate(); }, this.options!.publishDelayMs ?? PUBLISH_DELAY_MS);
    this.publishTimer.unref?.();
    this.timer = setInterval(() => this.evaluate(), TICK_MS);
    this.timer.unref?.();
    this.evaluate();
  }

  async close(): Promise<void> {
    this.closed = true;
    clearInterval(this.timer);
    clearTimeout(this.publishTimer);
    this.unsubscribe?.();
    this.abort.abort();
    await this.running?.catch(() => {});
  }

  release(): Release | undefined {
    const parsed = releaseSchema.safeParse(this.deps.data.get('release', RELEASE_ID)?.body);
    return parsed.success ? parsed.data : undefined;
  }

  status(): UpdateStatus {
    const state = this.state.state === 'ready' ? { state: 'ready' as const, waiting: this.deps.busy() } : this.state;
    const release = this.release();
    // 只报本机服务已经换上的那一版 App：服务还在等空闲或没换成时重启 App，新 App 会用自己带的服务覆盖安装，绕过等空闲与失败记录。
    const app = this.installed ? this.stagedApp(this.version.build) : undefined;
    return { ...state, version: this.version, release: release ?? null, ...(app ? { app } : {}) };
  }

  /** 用户选择现在更新：不等空闲。换版交给正在走或下一遍的 step，不与它并行。 */
  applyNow(): UpdateStatus {
    const release = this.release();
    if (this.state.state !== 'ready' || !release || !existsSync(join(this.updates, release.build, 'runtime', 'manifest.json'))) {
      throw new KiteError('没有准备好的新版本', 409);
    }
    this.forced = release.build;
    this.evaluate();
    return this.status();
  }

  /** 这台工作机的忙闲可能变了（回合结束、工作区或检出有变化）：新版在等空闲时马上再看，不等定时；等当前事件处理完再看。 */
  nudge(): void {
    if (this.state.state === 'ready') setTimeout(() => this.evaluate(), 0);
  }

  /** 发布记录、对端或忙闲变了：重新看一遍。同一时刻只走一遍，期间又有变化就接着再走一遍。 */
  evaluate(): void {
    if (this.closed || !this.started) return;
    if (this.running) { this.again = true; return; }
    this.running = this.step().catch((error: unknown) => console.error(`[更新] ${(error as Error).message}`)).finally(() => {
      this.running = undefined;
      if (this.again) { this.again = false; this.evaluate(); }
    });
  }

  /** 手动安装留下的发布标记：是本机正在运行的这一版就写进账号级数据。 */
  private publish(): void {
    const marker = join(this.root, 'publish');
    if (!existsSync(marker)) return;
    const build = readFileSync(marker, 'utf8').trim();
    rmSync(marker, { force: true });
    if (build !== this.version.build) return;
    const manifest = this.manifest!;
    this.deps.data.put('release', RELEASE_ID, { build, protocol: this.version.protocol, builtAt: manifest.builtAt, commit: manifest.commit,
      platform: manifest.platform, arch: manifest.arch, by: this.deps.machineId } satisfies Release);
    console.log(`[更新] 已发布 ${build}`);
  }

  private async step(): Promise<void> {
    // 刚手动装上、还没发布：这时的发布记录是旧的，不能跟着它换回去。
    if (existsSync(join(this.root, 'publish'))) { this.set({ state: 'current' }); return; }
    if (this.state.state === 'installing') return;
    const release = this.release();
    if (!release || release.build === this.version.build) {
      this.cleanup(this.version.build, true);
      // 取 App 时状态显示为取文件中，取完回到 current。
      if (release) await this.ensureApp(release);
      this.set({ state: 'current' });
      return;
    }
    const manifest = this.manifest!;
    if (release.platform !== manifest.platform || release.arch !== manifest.arch) {
      this.set({ state: 'unsupported', reason: `新版本是 ${release.platform} ${release.arch}，这台工作机是 ${manifest.platform} ${manifest.arch}，需要在这台工作机上手动安装` });
      return;
    }
    const failed = this.failed();
    if (failed?.build === release.build) { this.set({ state: 'failed', error: failed.error, retry: false }); return; }
    this.cleanup(release.build, false);
    const staged = join(this.updates, release.build, 'runtime');
    if (!existsSync(join(staged, 'manifest.json'))) {
      const backoff = this.backoff?.build === release.build ? this.backoff : undefined;
      if (backoff && Date.now() < backoff.at) { this.set({ state: 'failed', error: backoff.error, retry: true }); return; }
      const source = this.sources(release)[0];
      if (!source) { this.set({ state: 'waiting-source' }); return; }
      try {
        await this.fetchRuntime(source, release.build);
        this.backoff = undefined;
      } catch (error) {
        if (this.closed) return;
        const delay = backoff?.delay ?? RETRY_MIN_MS;
        const message = `取新版本没成：${(error as Error).message}`;
        this.backoff = { build: release.build, at: Date.now() + delay, delay: Math.min(delay * 2, RETRY_MAX_MS), error: message };
        this.set({ state: 'failed', error: message, retry: true });
        return;
      }
    }
    await this.ensureApp(release);
    // 取文件期间又有了新的发布：不换上已经过时的这一版，再看一遍。
    if (this.closed || this.release()?.build !== release.build) { this.again = true; return; }
    const waiting = this.deps.busy();
    this.set({ state: 'ready', waiting });
    const held = this.reapply?.build === release.build && Date.now() < this.reapply.at;
    if (this.forced === release.build || (!waiting.length && !held)) this.install(release.build);
  }

  private set(state: UpdateState): void {
    const before = JSON.stringify(this.state);
    this.state = state;
    // 下载进度最多每秒报一次。
    if (state.state === 'downloading' && Date.now() - this.progressAt < 1_000) return;
    this.progressAt = Date.now();
    if (JSON.stringify(state) !== before) this.deps.changed();
  }

  /** 取新版的对端：在线、正在运行这一版；发布它的那台在前。 */
  private sources(release: Release): Peer[] {
    return this.deps.peers().filter((peer) => peer.build === release.build)
      .sort((a, b) => Number(b.id === release.by) - Number(a.id === release.by));
  }

  private failed(): { build: string; error: string } | undefined {
    try { return z.object({ build: z.string(), error: z.string() }).parse(JSON.parse(readFileSync(join(this.updates, 'failed.json'), 'utf8'))); }
    catch { return undefined; }
  }

  /** 清掉不再需要的暂存：别的版本整个删；current 时连这一版的运行目录与半成品也删，只留 Mac App 与日志。 */
  private cleanup(keep: string, current: boolean): void {
    if (!existsSync(this.updates)) return;
    for (const name of readdirSync(this.updates)) {
      const path = join(this.updates, name);
      if (name === 'failed.json') { if (this.failed()?.build !== keep || current) rmSync(path, { force: true }); continue; }
      if (name !== keep) { rmSync(path, { recursive: true, force: true }); continue; }
      if (current) for (const sub of ['runtime', 'runtime.partial', 'app.partial']) rmSync(join(path, sub), { recursive: true, force: true });
    }
  }

  /** 交给安装进程换版：它停掉本服务、换上运行目录、再启动，失败时恢复旧版并写 failed.json。 */
  private install(build: string): void {
    if (this.state.state === 'installing') return;
    this.forced = undefined;
    const dir = join(this.updates, build);
    const staged = join(dir, 'runtime');
    this.set({ state: 'installing' });
    console.log(`[更新] 换上 ${build}`);
    if (this.options!.apply) { this.options!.apply(staged); return; }
    // 本服务还在时安装进程就结束了或根本没起来，说明没换成（例如另一个安装正在进行）；失败记录由安装进程写，这一版过一阵再换。
    // 起不来时只有 error、没有 exit，两个都要接。
    let ended = false;
    const end = (error?: Error) => {
      if (ended || this.closed) return;
      ended = true;
      if (error) console.error(`[更新] 起安装进程失败：${error.message}`);
      this.state = { state: 'current' };
      this.reapply = { build, at: Date.now() + REAPPLY_MS };
      this.evaluate();
    };
    try {
      const log = openSync(join(dir, 'install.log'), 'a');
      const user = userInfo().username;
      try {
        // 脱离服务的进程组：launchd 停掉服务时不会连它一起结束。
        const child = spawn(join(staged, 'bin/bun'), ['run', '--no-env-file', '--no-install', join(staged, 'kited/scripts/install-macos.ts'), 'update', staged], {
          detached: true, stdio: ['ignore', log, log],
          env: { HOME: homedir(), USER: user, LOGNAME: user, LANG: 'en_US.UTF-8', PATH: '/usr/bin:/bin:/usr/sbin:/sbin', KITE_INSTALL_ROOT: this.root },
        });
        child.on('exit', () => end());
        child.on('error', end);
        child.unref();
      } finally { closeSync(log); }
    } catch (error) { end(error as Error); }
  }

  // ---- 取文件 ----

  private async fetchRuntime(source: Peer, build: string): Promise<void> {
    const listing = await this.listingFrom(source, build, 'runtime');
    const body = listing.filter((entry) => !unlisted(entry.path));
    if (buildOf(body) !== build) throw new Error('对方给的清单与构建号不符');
    const dir = join(this.updates, build);
    const partial = join(dir, 'runtime.partial');
    // 本机正在运行的运行目录按 files.json 复用；内容最后统一校验。
    const local = new Map<string, string>();
    for (const entry of this.runtimeFiles()) if ('sha256' in entry) local.set(entry.sha256, join(this.runtime!, entry.path));
    await this.assemble(source, build, 'runtime', listing, partial, local);
    if (readManifest(partial)?.build !== build) throw new Error('取到的运行目录构建号不符');
    rmSync(join(dir, 'runtime'), { recursive: true, force: true });
    renameSync(partial, join(dir, 'runtime'));
  }

  /** 服务由 App 装上、App 不是这一版时，从对端取这一版的 App，组好放进暂存目录，等 App 提示重启以更新。 */
  private async ensureApp(release: Release): Promise<void> {
    const { build } = release;
    const app = this.localApp();
    if (!app || this.appBuild(app) === build || this.stagedApp(build)) return;
    if (Date.now() - (this.appAttempts.get(build) ?? 0) < RETRY_MAX_MS) return;
    const sources = this.sources(release);
    if (!sources.length) return;
    this.appAttempts.set(build, Date.now());
    // 运行这一版的工作机不一定有这一版的 App（服务可能是用仅服务的安装包装的），挨个试。
    for (const source of sources) {
      try {
        await this.fetchApp(source, build, app);
        this.deps.changed();
        return;
      } catch (error) {
        if (this.closed) return;
        console.warn(`[更新] 没从 ${source.id} 取到 ${build} 的 App：${(error as Error).message}`);
      }
    }
  }

  private async fetchApp(source: Peer, build: string, installed: string): Promise<void> {
    const listing = await this.listingFrom(source, build, 'app');
    const dir = join(this.updates, build);
    const work = join(dir, 'app.partial');
    const app = join(work, 'Kite.app');
    rmSync(work, { recursive: true, force: true });
    mkdirSync(join(app, dirname(APP_RUNTIME)), { recursive: true });
    // 运行目录用本机的同一版（正在运行的，或刚暂存的）整个克隆进去，App 只传其余部分。
    const runtime = this.version.build === build ? this.runtime! : join(dir, 'runtime');
    await command(['/bin/cp', '-c', '-R', runtime, join(app, APP_RUNTIME)]);
    const local = new Map<string, string>();
    for (const entry of await listFiles(installed, (path) => path === APP_RUNTIME)) {
      if ('sha256' in entry) local.set(entry.sha256, join(installed, entry.path));
    }
    await this.assemble(source, build, 'app', listing, app, local);
    await command(['/usr/bin/codesign', '--verify', '--deep', '--strict', app]);
    rmSync(join(dir, 'Kite.app'), { recursive: true, force: true });
    renameSync(app, join(dir, 'Kite.app'));
    rmSync(work, { recursive: true, force: true });
  }

  private async listingFrom(source: Peer, build: string, payload: Payload): Promise<FileEntry[]> {
    const body = await peerJSON<{ files: unknown }>(this.deps.fetch, source, `/update/${build}/${payload}`, { signal: this.abort.signal, stallMs: 5 * 60_000 });
    const files = z.array(fileEntry).parse(body.files);
    const unsafe = unsafeEntry(files);
    if (unsafe !== undefined) throw new Error(`清单里有不安全的条目：${unsafe}`);
    return files;
  }

  /**
   * 按清单在 target 组出文件树：已在的（上次没取完留下的）照用，本机有相同内容的复制过来，其余成批从对端取；
   * 最后逐个校验，不符的再从对端取一次，仍不符就放弃。
   */
  private async assemble(source: Peer, build: string, payload: Payload, files: FileEntry[], target: string, local: Map<string, string>): Promise<void> {
    mkdirSync(target, { recursive: true });
    const missing: RegularEntry[] = [];
    for (const entry of files) {
      const path = join(target, entry.path);
      mkdirSync(dirname(path), { recursive: true });
      if ('link' in entry) {
        rmSync(path, { recursive: true, force: true });
        symlinkSync(entry.link, path);
        continue;
      }
      if (existsSync(path) && lstatSync(path).isFile() && lstatSync(path).size === entry.size) continue;
      const reuse = local.get(entry.sha256);
      if (reuse && existsSync(reuse)) {
        rmSync(path, { force: true });
        copyFileSync(reuse, path, constants.COPYFILE_FICLONE);
      } else missing.push(entry);
    }
    const total = missing.reduce((sum, entry) => sum + entry.size, 0);
    let done = 0;
    const progress = (bytes: number) => { done += bytes; this.set({ state: 'downloading', done, total }); };
    this.set({ state: 'downloading', done, total });
    await this.transfer(source, build, payload, missing, target, progress);
    const bad: RegularEntry[] = [];
    for (const entry of files) {
      if (!('sha256' in entry)) continue;
      const path = join(target, entry.path);
      if (!existsSync(path) || await hashFile(path) !== entry.sha256) bad.push(entry);
    }
    if (bad.length) {
      await this.transfer(source, build, payload, bad, target, () => {});
      for (const entry of bad) {
        if (await hashFile(join(target, entry.path)) !== entry.sha256) throw new Error(`文件校验不符：${entry.path}`);
      }
    }
    for (const entry of files) if ('sha256' in entry) chmodSync(join(target, entry.path), entry.executable ? 0o755 : 0o644);
  }

  /** 成批取文件：对端给 tar 流，本机用 tar 解进 target。 */
  private async transfer(source: Peer, build: string, payload: Payload, entries: RegularEntry[], target: string, progress: (bytes: number) => void): Promise<void> {
    for (let start = 0; start < entries.length;) {
      let end = start;
      let bytes = 0;
      while (end < entries.length && end - start < BATCH_FILES && (end === start || bytes + entries[end]!.size <= BATCH_BYTES)) bytes += entries[end++]!.size;
      await this.batch(source, build, payload, entries.slice(start, end).map((entry) => entry.path), target, progress);
      start = end;
    }
  }

  private async batch(source: Peer, build: string, payload: Payload, paths: string[], target: string, progress: (bytes: number) => void): Promise<void> {
    const stalled = new AbortController();
    let timer: ReturnType<typeof setTimeout> | undefined;
    const alive = () => { clearTimeout(timer); timer = setTimeout(() => stalled.abort(new Error(`工作机 ${source.id} 超过 ${STALL_MS / 1000} 秒没有传来数据`)), STALL_MS); };
    alive();
    const tar = Bun.spawn(['/usr/bin/tar', '-x', '-f', '-', '-C', target], { stdin: 'pipe', stdout: 'ignore', stderr: 'pipe', env: { PATH: '/usr/bin:/bin' } });
    try {
      const response = await this.deps.fetch(source.address, `/update/${build}/${payload}/files`, {
        method: 'POST', body: JSON.stringify({ paths }), signal: AbortSignal.any([this.abort.signal, stalled.signal]),
        headers: { 'content-type': 'application/json', 'X-Kite-Machine': source.id },
      });
      if (!response.ok || !response.body) throw new Error(`工作机 ${source.id} 返回 ${response.status}`);
      for await (const chunk of response.body) {
        alive();
        await tar.stdin.write(chunk);
        progress(chunk.byteLength);
      }
      await tar.stdin.end();
      const [code, error] = await Promise.all([tar.exited, new Response(tar.stderr).text()]);
      if (code !== 0) throw new Error(`解开文件失败：${error.trim()}`);
    } catch (error) {
      tar.kill();
      throw stalled.signal.aborted ? stalled.signal.reason : error;
    } finally { clearTimeout(timer); }
  }

  // ---- 给其他工作机提供文件 ----

  /** 这一版某份内容的清单；本机没在运行这一版或没有这份内容时 404。 */
  async listing(build: string, payload: Payload): Promise<{ files: FileEntry[] }> {
    if (!this.installed || build !== this.version.build) throw new KiteError('这台工作机没在运行这个版本', 404);
    const key = `${payload}\n${build}`;
    let pending = this.listings.get(key);
    if (!pending) {
      pending = this.compute(payload);
      this.listings.set(key, pending);
      pending.catch(() => this.listings.delete(key));
    }
    return { files: await pending };
  }

  private async compute(payload: Payload): Promise<FileEntry[]> {
    if (payload === 'runtime') {
      const extra = await Promise.all(MANIFEST_FILES.map(async (path) => {
        const file = join(this.runtime!, path);
        return { path, sha256: await hashFile(file), size: lstatSync(file).size, executable: false };
      }));
      return [...this.runtimeFiles(), ...extra];
    }
    const app = this.localApp();
    if (!app || this.appBuild(app) !== this.version.build) throw new KiteError('这台工作机没有这个版本的 App', 404);
    return listFiles(app, (path) => path === APP_RUNTIME);
  }

  /** 清单里有的文件打成 tar 流；只给清单里的路径，不能借此读别的文件。请求方断开就不再打包。 */
  async files(build: string, payload: Payload, paths: unknown, signal?: AbortSignal): Promise<Response> {
    const parsed = z.array(z.string()).min(1).max(BATCH_FILES).safeParse(paths);
    if (!parsed.success) throw new KiteError(`paths 要写 1～${BATCH_FILES} 个路径`);
    const { files } = await this.listing(build, payload);
    const known = new Set(files.filter((entry) => 'sha256' in entry).map((entry) => entry.path));
    const unknown = parsed.data.find((path) => !known.has(path));
    if (unknown) throw new KiteError(`清单里没有 ${unknown}`, 404);
    const root = payload === 'runtime' ? this.runtime! : this.localApp()!;
    const tar = Bun.spawn(['/usr/bin/tar', '-c', '-f', '-', '--no-mac-metadata', '-C', root, '--null', '-T', '-'],
      { stdin: 'pipe', stdout: 'pipe', stderr: 'ignore', env: { PATH: '/usr/bin:/bin', COPYFILE_DISABLE: '1' } });
    signal?.addEventListener('abort', () => tar.kill(), { once: true });
    await tar.stdin.write(parsed.data.join('\0'));
    await tar.stdin.end();
    return new Response(tar.stdout, { headers: { 'content-type': 'application/x-tar' } });
  }

  // ---- 本机文件 ----

  private runtimeFiles(): FileEntry[] {
    try { return z.array(fileEntry).parse(JSON.parse(readFileSync(join(this.runtime!, 'files.json'), 'utf8'))); }
    catch { return []; }
  }

  /** 装上这个服务的 Mac App（安装记录里的 app），还在原处才算。 */
  private localApp(): string | undefined {
    try {
      const app = z.object({ app: z.string().optional() }).parse(JSON.parse(readFileSync(join(this.root, 'install.json'), 'utf8'))).app;
      return app && existsSync(join(app, APP_RUNTIME, 'manifest.json')) ? app : undefined;
    } catch { return undefined; }
  }

  private appBuild(app: string): string | undefined { return readManifest(join(app, APP_RUNTIME))?.build; }

  private stagedApp(build: string): { build: string; path: string } | undefined {
    const path = join(this.updates, build, 'Kite.app');
    return existsSync(join(path, APP_RUNTIME, 'manifest.json')) ? { build, path } : undefined;
  }
}

async function command(args: string[]): Promise<void> {
  const child = Bun.spawn(args, { stdout: 'ignore', stderr: 'pipe', env: { PATH: '/usr/bin:/bin' } });
  const [code, error] = await Promise.all([child.exited, new Response(child.stderr).text()]);
  if (code !== 0) throw new Error(`${args[0]} 失败：${error.trim()}`);
}
