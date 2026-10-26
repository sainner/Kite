/**
 * 工作机上的浏览器：WebKit、Chromium、Firefox 用 Playwright 无界面运行，每种一个浏览器进程，每个预览一个独立的浏览器上下文（Cookie、存储互不相通，
 * 不带用户的登录状态）；真的 Safari 经 safaridriver 驱动，见 safari.ts。联网不另设限制，同用户在工作机上自己开的浏览器；管住的是 agent 去哪（navigate 只开本端口上的路径），
 * kited 的接口自己挡浏览器里的页面（只认本机主机名、要自定义请求头、不开放跨源）。
 * 浏览器第一次用时没装就下载到 Playwright 的默认缓存目录（~/Library/Caches/ms-playwright），要几分钟。
 */
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import type { Browser, BrowserContext, Page } from 'playwright-core';
import { KiteError } from '../errors.ts';
import { SafariDriver } from './safari.ts';
import { pointScript, type PointedElement, type PreviewAction, type Screen, type ScreenInfo } from './screen.ts';
import type { WorkstationBrowser } from './state.ts';

/** 用 Playwright 跑的浏览器。 */
type PlaywrightBrowser = Exclude<WorkstationBrowser, 'safari'>;
const browserTitles: Record<PlaywrightBrowser, string> = { webkit: 'WebKit', chromium: 'Chromium', firefox: 'Firefox' };
/** 没有预览用了，浏览器进程再留这么久，接着开的预览不用重新启动。 */
const IDLE_CLOSE_MS = 30_000;
const NAVIGATION_TIMEOUT_MS = 15_000;
const INSTALL_TIMEOUT_MS = 15 * 60_000;
/** 页面的设备像素比：给设备看的帧按它截，在 Retina 屏上清楚；给模型的按 CSS 像素截。 */
const DEVICE_SCALE = 2;

/** 本端口上的路径换成完整地址；写成别处的地址不行。 */
export function pathOn(root: string, path: string): string {
  let url: URL;
  try { url = new URL(path, root); } catch { throw new KiteError(`地址无效：${path}`, 400); }
  if (url.origin !== new URL(root).origin) throw new KiteError(`只能打开本端口上的路径，不能打开 ${path}`, 400);
  return url.href;
}

export interface BrowserOptions {
  /** 首页，本机地址加端口。 */
  url: string;
  width: number;
  height: number;
}

interface Running { browser: Promise<Browser>; users: number; idle?: ReturnType<typeof setTimeout> }

export class Browsers {
  private running = new Map<PlaywrightBrowser, Running>();
  private installing = new Map<PlaywrightBrowser, Promise<void>>();
  private safari: SafariDriver;

  /** env 是起浏览器与下载程序用的环境，显式给出。 */
  constructor(private env: Record<string, string>) {
    this.safari = new SafariDriver(env);
  }

  /** 开一个预览的页面：新的浏览器上下文（Safari 是新窗口），打开首页（打不开也返回，页面上显示错误）。 */
  async open(name: WorkstationBrowser, options: BrowserOptions): Promise<Screen> {
    if (name === 'safari') return this.safari.open(options);
    const entry = this.acquire(name);
    let context: BrowserContext | undefined;
    try {
      context = await (await entry.browser).newContext({ viewport: { width: options.width, height: options.height }, deviceScaleFactor: DEVICE_SCALE,
        serviceWorkers: 'block', ignoreHTTPSErrors: true });
      const page = await context.newPage();
      const screen = new BrowserScreen(context, page, options.url, () => this.release(name, entry));
      await screen.goto(options.url);
      return screen;
    } catch (error) {
      await context?.close().catch(() => {});
      this.release(name, entry);
      throw error;
    }
  }

  private acquire(name: PlaywrightBrowser): Running {
    let entry = this.running.get(name);
    if (!entry) {
      entry = { browser: this.launch(name), users: 0 };
      this.running.set(name, entry);
      const current = entry;
      const forget = () => { if (this.running.get(name) === current) this.running.delete(name); };
      // 起不来的、崩了的不留着，下次重新启动
      current.browser.then((browser) => browser.on('disconnected', forget), forget);
    }
    clearTimeout(entry.idle);
    entry.users++;
    return entry;
  }

  /** 记着的是哪个浏览器进程：崩了以后重新启动的那个另算。 */
  private release(name: PlaywrightBrowser, entry: Running): void {
    if (--entry.users > 0) return;
    entry.idle = setTimeout(() => {
      if (this.running.get(name) !== entry || entry.users > 0) return;
      this.running.delete(name);
      void entry.browser.then((browser) => browser.close()).catch(() => {});
    }, IDLE_CLOSE_MS);
    entry.idle.unref();
  }

  private async launch(name: PlaywrightBrowser): Promise<Browser> {
    const playwright = await import('playwright-core');
    const options = { headless: true, env: this.env };
    try { return await playwright[name].launch(options); }
    catch (error) {
      if (!/Executable doesn't exist|download new browsers/i.test(String(error))) throw new KiteError(`${browserTitles[name]} 没有启动：${firstLine(error)}`, 503);
      await this.install(name);
      try { return await playwright[name].launch(options); }
      catch (retry) { throw new KiteError(`${browserTitles[name]} 没有启动：${firstLine(retry)}`, 503); }
    }
  }

  /** 用 Playwright 自带的下载程序装这个浏览器；几个预览同时要时只下一次。 */
  private install(name: PlaywrightBrowser): Promise<void> {
    const existing = this.installing.get(name);
    if (existing) return existing;
    const cli = join(dirname(fileURLToPath(import.meta.resolve('playwright-core/package.json'))), 'cli.js');
    const task = (async () => {
      const child = Bun.spawn([process.execPath, cli, 'install', name === 'chromium' ? 'chromium-headless-shell' : name],
        { env: this.env, stdout: 'ignore', stderr: 'pipe' });
      const timer = setTimeout(() => child.kill(), INSTALL_TIMEOUT_MS);
      try {
        const [code, stderr] = await Promise.all([child.exited, new Response(child.stderr).text()]);
        if (code !== 0) throw new KiteError(`${browserTitles[name]} 下载失败：${stderr.trim().split('\n').at(-1) ?? `退出码 ${code}`}`, 503);
      } finally { clearTimeout(timer); }
    })().finally(() => this.installing.delete(name));
    this.installing.set(name, task);
    return task;
  }

  async close(): Promise<void> {
    const entries = [...this.running.values()];
    this.running.clear();
    await Promise.all([this.safari.shutdown(), ...entries.map(async (entry) => {
      clearTimeout(entry.idle);
      await entry.browser.then((browser) => browser.close()).catch(() => {});
    })]);
  }
}

const firstLine = (error: unknown) => (error instanceof Error ? error.message : String(error)).split('\n')[0];

class BrowserScreen implements Screen {
  private closed = false;

  constructor(private context: BrowserContext, private page: Page, private readonly root: string, private release: () => void) {}

  /** 打开一个地址，等到文档开始解析；开发服务器首次编译慢、打不开时不报错，画面上就是当时的样子。 */
  async goto(url: string): Promise<void> {
    await this.page.goto(url, { waitUntil: 'domcontentloaded', timeout: NAVIGATION_TIMEOUT_MS }).catch(() => {});
  }

  async capture(forModel = false) {
    const data = await this.page.screenshot({ type: 'jpeg', quality: forModel ? 70 : 60, scale: forModel ? 'css' : 'device' });
    const { width, height } = this.page.viewportSize()!;
    return { data, width, height };
  }

  async act(action: PreviewAction): Promise<void> {
    const { mouse, keyboard } = this.page;
    switch (action.type) {
      case 'click': return mouse.click(action.x, action.y, { button: action.button ?? 'left', clickCount: action.count ?? 1 });
      case 'drag':
        await mouse.move(action.from.x, action.from.y);
        await mouse.down();
        await mouse.move(action.to.x, action.to.y, { steps: 12 });
        return mouse.up();
      case 'scroll':
        await mouse.move(action.x, action.y);
        return mouse.wheel(action.dx, action.dy);
      case 'type': return keyboard.type(action.text);
      case 'key': return keyboard.press(action.key);
      case 'long_press':
        await mouse.move(action.x, action.y);
        await mouse.down();
        await Bun.sleep((action.duration ?? 1) * 1000);
        return mouse.up();
      case 'navigate': return this.goto(pathOn(this.root, action.path));
      case 'back': await this.page.goBack({ waitUntil: 'commit', timeout: NAVIGATION_TIMEOUT_MS }).catch(() => {}); return;
      case 'forward': await this.page.goForward({ waitUntil: 'commit', timeout: NAVIGATION_TIMEOUT_MS }).catch(() => {}); return;
      case 'reload': await this.page.reload({ waitUntil: 'commit', timeout: NAVIGATION_TIMEOUT_MS }).catch(() => {}); return;
      case 'pinch':
      case 'home': throw new KiteError('网页预览没有这个动作', 400);
    }
  }

  inspect(): Promise<string> { return this.page.ariaSnapshot(); }

  point(x: number, y: number): Promise<PointedElement | null> {
    return this.page.evaluate(`(${pointScript()})(${x}, ${y})`) as Promise<PointedElement | null>;
  }

  alive(): boolean { return !this.closed && !this.page.isClosed(); }

  async info(): Promise<ScreenInfo> {
    return { url: this.page.url(), pageTitle: await this.page.title().catch(() => '') };
  }

  async resize(width: number, height: number): Promise<void> {
    const current = this.page.viewportSize();
    if (current?.width !== width || current.height !== height) await this.page.setViewportSize({ width, height });
  }

  async close(): Promise<void> {
    if (this.closed) return;
    this.closed = true;
    await this.context.close().catch(() => {});
    this.release();
  }
}
