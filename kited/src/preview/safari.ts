/**
 * 工作机上真的 Safari，经系统自带的 safaridriver（WebDriver）驱动。Safari 没有无界面模式：每个预览是工作机桌面上一个 Safari 的自动化窗口
 * （地址栏带橙色条纹，人在窗口上直接操作会被拦下），开会话时 Safari 会到前台。Safari 同时只认一个 WebDriver 会话，所有 Safari 预览共用一个、
 * 各开一个窗口，命令一条接一条，先切到那个窗口再做；没有预览了就结束会话、停掉 safaridriver。会话的浏览数据用完即丢，不带用户的登录状态。
 * 画面用 WebDriver 的截图（PNG，按设备像素），在这里转成 JPEG；输入用 WebDriver 的动作。要用户在 Safari 的设置里打开一次「允许远程自动化」。
 */
import { createServer } from 'node:net';
import { KiteError } from '../errors.ts';
import { pathOn, type BrowserOptions } from './browsers.ts';
import { pointScript, type Frame, type PointedElement, type PreviewAction, type Screen, type ScreenInfo } from './screen.ts';

const SAFARIDRIVER = '/usr/bin/safaridriver';
const START_TIMEOUT_MS = 10_000;
const NAVIGATION_TIMEOUT_MS = 15_000;

/** Playwright 的键名换成 WebDriver 的键码。 */
const keyCodes: Record<string, string> = {
  enter: '', tab: '', backspace: '', escape: '', delete: '', space: ' ',
  arrowleft: '', arrowup: '', arrowright: '', arrowdown: '', home: '', end: '', pageup: '', pagedown: '',
  shift: '', control: '', alt: '', meta: '',
};

/** 网页的界面结构：标题、链接、按钮、输入框、图片和成段的文字，一行一个，缩进表示层级。同 Playwright 的无障碍树，但只是近似。 */
const OUTLINE_SCRIPT = `
const out = [];
const roles = { A: 'link', BUTTON: 'button', INPUT: 'textbox', TEXTAREA: 'textbox', SELECT: 'combobox', IMG: 'img', H1: 'heading', H2: 'heading', H3: 'heading',
  H4: 'heading', H5: 'heading', H6: 'heading', NAV: 'navigation', MAIN: 'main', HEADER: 'banner', FOOTER: 'contentinfo', FORM: 'form', UL: 'list', OL: 'list', LI: 'listitem',
  TABLE: 'table', P: 'paragraph', LABEL: 'label', DIALOG: 'dialog' };
const visible = (el) => { const style = getComputedStyle(el); return style.display !== 'none' && style.visibility !== 'hidden'; };
const text = (s) => s.replace(/\\s+/g, ' ').trim().slice(0, 200);
function walk(el, depth) {
  if (out.length > 800 || !visible(el)) return;
  let role = el.getAttribute('role') || roles[el.tagName];
  if (el.tagName === 'INPUT' && ['checkbox', 'radio', 'button', 'submit'].includes(el.type)) role = el.type === 'submit' ? 'button' : el.type;
  let next = depth;
  if (role) {
    const name = text(el.getAttribute('aria-label') || el.getAttribute('alt') || el.getAttribute('placeholder') || el.title || (['link', 'button', 'heading', 'label', 'paragraph', 'listitem'].includes(role) ? el.innerText || '' : ''));
    const value = 'value' in el && el.value && !['button', 'submit'].includes(el.type) ? ' value=' + text(String(el.value)) : '';
    const r = el.getBoundingClientRect();
    out.push('  '.repeat(depth) + '- ' + role + (name ? ' "' + name + '"' : '') + value + (el.tagName === 'A' && el.getAttribute('href') ? ' href=' + el.getAttribute('href') : '') +
      ' (' + Math.round(r.x) + ',' + Math.round(r.y) + ' ' + Math.round(r.width) + 'x' + Math.round(r.height) + ')');
    if (['link', 'button', 'heading', 'paragraph', 'label'].includes(role)) return;
    next = depth + 1;
  }
  for (const child of el.children) walk(child, next);
}
walk(document.body, 0);
return out.join('\\n');`;

interface Command { method: string; path: string; body?: unknown }

/** 一个 safaridriver 进程和它的会话；几个 Safari 预览共用。 */
export class SafariDriver {
  private child?: Bun.Subprocess;
  private base?: string;
  private session?: Promise<{ id: string; first: string }>;
  /** 会话一开就有的那个窗口，第一个预览直接用。 */
  private spare?: string;
  private windows = new Set<string>();
  private current?: string;
  private queue: Promise<unknown> = Promise.resolve();

  /** env 是起 safaridriver 用的环境，显式给出。 */
  constructor(private env: Record<string, string>) {}

  /** 开一个预览的窗口：打开首页（打不开也返回，页面上显示错误）。 */
  async open(options: BrowserOptions): Promise<Screen> {
    if (process.platform !== 'darwin') throw new KiteError('只有 Mac 工作机有 Safari', 503);
    const handle = await this.queued(async () => {
      const { first } = await this.started();
      if (this.spare === first && !this.windows.has(first)) { this.spare = undefined; this.windows.add(first); return first; }
      const created = await this.send<{ handle: string }>({ method: 'POST', path: '/window/new', body: { type: 'window' } });
      this.windows.add(created.handle);
      return created.handle;
    });
    const screen = new SafariScreen(this, handle, options.url);
    try {
      await screen.resize(options.width, options.height);
      await screen.goto(options.url);
      return screen;
    } catch (error) {
      await screen.close();
      throw error;
    }
  }

  /** 起 safaridriver、建会话；几个预览同时要时只起一次。 */
  private started(): Promise<{ id: string; first: string }> {
    this.session ??= (async () => {
      const port = await freePort();
      this.child = Bun.spawn([SAFARIDRIVER, '-p', String(port)], { env: this.env, stdout: 'ignore', stderr: 'ignore' });
      this.base = `http://127.0.0.1:${port}`;
      const deadline = Date.now() + START_TIMEOUT_MS;
      while (!await fetch(`${this.base}/status`).then((res) => res.ok, () => false)) {
        if (Date.now() > deadline || this.child.exitCode !== null) throw new KiteError('Safari 的 WebDriver（safaridriver）没有起来', 503);
        await Bun.sleep(100);
      }
      const res = await fetch(`${this.base}/session`, { method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ capabilities: { alwaysMatch: { browserName: 'safari', acceptInsecureCerts: true } } }) });
      const json = await res.json() as { value: { sessionId?: string; message?: string } };
      if (!json.value.sessionId) {
        const message = json.value.message ?? `HTTP ${res.status}`;
        throw new KiteError(/remote automation/i.test(message)
          ? 'Safari 没有打开远程自动化：在工作机 Safari 的「设置 → 开发者」里勾上「允许远程自动化」（看不到这一页先在「高级」里打开网页开发者功能）'
          : `Safari 没有启动：${message}`, 503);
      }
      const id = json.value.sessionId;
      const first = await this.raw<string>(id, { method: 'GET', path: '/window' });
      this.spare = first;
      this.current = first;
      return { id, first };
    })();
    // 起不来的不留着，下次重试
    this.session.catch(() => this.stop());
    return this.session;
  }

  private async raw<T>(id: string, command: Command): Promise<T> {
    const res = await fetch(`${this.base}/session/${id}${command.path}`, { method: command.method, headers: { 'Content-Type': 'application/json' },
      ...(command.body !== undefined ? { body: JSON.stringify(command.body) } : command.method === 'POST' ? { body: '{}' } : {}),
      signal: AbortSignal.timeout(NAVIGATION_TIMEOUT_MS + 5000) });
    const json = await res.json().catch(() => ({ value: null })) as { value: T & { error?: string; message?: string } };
    if (!res.ok) {
      // 会话没了（Safari 被退出）：丢掉，下次重开
      if (json.value?.error === 'invalid session id') this.stop();
      throw new KiteError(`Safari：${json.value?.message || json.value?.error || `HTTP ${res.status}`}`, 409);
    }
    return json.value;
  }

  private async send<T>(command: Command): Promise<T> {
    const { id } = await this.started();
    return this.raw<T>(id, command);
  }

  private queued<T>(run: () => Promise<T>): Promise<T> {
    const task = this.queue.then(run, run);
    this.queue = task.catch(() => {});
    return task;
  }

  /** 在这个预览的窗口里做一串命令：先切到它，做完前别的预览插不进来。 */
  in<T>(handle: string, run: (send: <R>(command: Command) => Promise<R>) => Promise<T>): Promise<T> {
    return this.queued(async () => {
      if (!this.windows.has(handle)) throw new KiteError('Safari 的窗口已经关了', 409);
      if (this.current !== handle) {
        await this.send({ method: 'POST', path: '/window', body: { handle } });
        this.current = handle;
      }
      return run((command) => this.send(command));
    });
  }

  alive(handle: string): boolean { return !!this.session && this.windows.has(handle); }

  /** 关掉这个预览的窗口；没有窗口了就结束会话、停掉 safaridriver。 */
  close(handle: string): Promise<void> {
    return this.queued(async () => {
      if (!this.windows.delete(handle)) return;
      if (!this.windows.size) { await this.end(); return; }
      await this.send({ method: 'POST', path: '/window', body: { handle } }).catch(() => {});
      await this.send({ method: 'DELETE', path: '/window' }).catch(() => {});
      this.current = undefined;
    });
  }

  private async end(): Promise<void> {
    const session = this.session;
    if (session) await session.then(({ id }) => this.raw(id, { method: 'DELETE', path: '' })).catch(() => {});
    this.stop();
  }

  private stop(): void {
    this.child?.kill();
    this.child = this.session = this.base = this.spare = this.current = undefined;
    this.windows.clear();
  }

  async shutdown(): Promise<void> {
    await this.queued(() => this.end());
  }
}

class SafariScreen implements Screen {
  private closed = false;
  /** 视口的 CSS 像素尺寸。 */
  private viewport = { width: 0, height: 0 };
  /** 窗口比视口多出来的工具栏、边框。 */
  private chrome?: { width: number; height: number };
  /** 上次给设备、给模型截的帧和它的原图。 */
  private frames: [{ png: string; frame: Frame }?, { png: string; frame: Frame }?] = [];

  constructor(private driver: SafariDriver, private handle: string, private readonly root: string) {}

  async goto(url: string): Promise<void> {
    await this.driver.in(this.handle, (send) => send({ method: 'POST', path: '/url', body: { url } })).catch(() => {});
  }

  async capture(forModel = false): Promise<Frame> {
    const png = await this.driver.in(this.handle, (send) => send<string>({ method: 'GET', path: '/screenshot' }));
    // 画面没变时 WebDriver 给的 PNG 一字不差：不再解码、重编
    const last = this.frames[forModel ? 1 : 0];
    if (last?.png === png && last.frame.width === this.viewport.width && last.frame.height === this.viewport.height) return last.frame;
    const { width, height } = this.viewport;
    let image = new Bun.Image(Buffer.from(png, 'base64'));
    if (forModel) image = image.resize(width, height, { fit: 'inside' });
    const frame = { data: await image.jpeg({ quality: forModel ? 70 : 60 }).bytes(), width, height };
    this.frames[forModel ? 1 : 0] = { png, frame };
    return frame;
  }

  private script<T>(send: <R>(command: Command) => Promise<R>, script: string, args: unknown[] = []): Promise<T> {
    return send<T>({ method: 'POST', path: '/execute/sync', body: { script, args } });
  }

  private pointer(actions: object[], button = 0) {
    return { type: 'pointer', id: 'mouse', parameters: { pointerType: 'mouse' },
      actions: actions.map((action) => ('button' in action ? { ...action, button } : action)) };
  }

  async act(action: PreviewAction): Promise<void> {
    const at = (x: number, y: number, duration = 0) => ({ type: 'pointerMove', x: Math.round(x), y: Math.round(y), origin: 'viewport', duration });
    const perform = (actions: object[]) => this.driver.in(this.handle, async (send) => {
      await send({ method: 'POST', path: '/actions', body: { actions } });
      await send({ method: 'DELETE', path: '/actions' });
    });
    // 移动、按下、抬起之间不停一下的话，刚用键盘打过字后的点按会丢（实测 Safari 27）
    const pause = { type: 'pause', duration: 50 };
    switch (action.type) {
      case 'click': {
        const clicks = Array.from({ length: action.count ?? 1 }, () => [pause, { type: 'pointerDown', button: 0 }, pause, { type: 'pointerUp', button: 0 }]).flat();
        return perform([this.pointer([at(action.x, action.y), ...clicks], action.button === 'right' ? 2 : 0)]);
      }
      case 'drag':
        return perform([this.pointer([at(action.from.x, action.from.y), pause, { type: 'pointerDown', button: 0 }, at(action.to.x, action.to.y, 300), pause,
          { type: 'pointerUp', button: 0 }])]);
      case 'long_press':
        return perform([this.pointer([at(action.x, action.y), { type: 'pointerDown', button: 0 }, { type: 'pause', duration: Math.round((action.duration ?? 1) * 1000) },
          { type: 'pointerUp', button: 0 }])]);
      case 'scroll':
        return perform([{ type: 'wheel', id: 'wheel', actions: [{ type: 'scroll', x: Math.round(action.x), y: Math.round(action.y), deltaX: Math.round(action.dx), deltaY: Math.round(action.dy), origin: 'viewport' }] }]);
      case 'type': {
        const characters = [...new Intl.Segmenter().segment(action.text)].map((part) => part.segment === '\n' ? keyCodes.enter! : part.segment);
        return perform([{ type: 'key', id: 'keyboard', actions: characters.flatMap((value) => [{ type: 'keyDown', value }, { type: 'keyUp', value }]) }]);
      }
      case 'key': {
        const parts = action.key.split('+').map((part) => keyCodes[part.toLowerCase()] ?? (part.length === 1 ? part : undefined));
        if (parts.some((part) => part === undefined)) throw new KiteError(`不认识这个键：${action.key}`, 400);
        const keys = parts as string[];
        return perform([{ type: 'key', id: 'keyboard', actions: [...keys.map((value) => ({ type: 'keyDown', value })), ...keys.reverse().map((value) => ({ type: 'keyUp', value }))] }]);
      }
      case 'navigate': return this.goto(pathOn(this.root, action.path));
      case 'back': case 'forward':
        await this.driver.in(this.handle, (send) => send({ method: 'POST', path: `/${action.type}` })).catch(() => {});
        return;
      case 'reload':
        await this.driver.in(this.handle, (send) => send({ method: 'POST', path: '/refresh' })).catch(() => {});
        return;
      case 'pinch': case 'home': throw new KiteError('网页预览没有这个动作', 400);
    }
  }

  inspect(): Promise<string> {
    return this.driver.in(this.handle, (send) => this.script<string>(send, OUTLINE_SCRIPT));
  }

  point(x: number, y: number): Promise<PointedElement | null> {
    return this.driver.in(this.handle, (send) => this.script<PointedElement | null>(send, `return (${pointScript()})(arguments[0], arguments[1]);`, [x, y]));
  }

  alive(): boolean { return !this.closed && this.driver.alive(this.handle); }

  async info(): Promise<ScreenInfo> {
    return this.driver.in(this.handle, async (send) => ({ url: await send<string>({ method: 'GET', path: '/url' }), pageTitle: await send<string>({ method: 'GET', path: '/title' }) }))
      .catch(() => ({}));
  }

  /** 让视口是这个尺寸：窗口按视口加上工具栏、边框算，量一次记下。 */
  async resize(width: number, height: number): Promise<void> {
    if (this.viewport.width === width && this.viewport.height === height) return;
    await this.driver.in(this.handle, async (send) => {
      const setRect = (w: number, h: number) => send({ method: 'POST', path: '/window/rect', body: { width: w, height: h } });
      if (!this.chrome) {
        await setRect(width, height);
        const [outerWidth, outerHeight, innerWidth, innerHeight] = await this.script<number[]>(send, 'return [outerWidth, outerHeight, innerWidth, innerHeight]');
        this.chrome = { width: outerWidth! - innerWidth!, height: outerHeight! - innerHeight! };
      }
      await setRect(width + this.chrome.width, height + this.chrome.height);
      // 屏幕放不下时窗口会被缩小：按实际的视口算
      const [innerWidth, innerHeight] = await this.script<number[]>(send, 'return [innerWidth, innerHeight]');
      this.viewport = { width: innerWidth!, height: innerHeight! };
    });
  }

  async close(): Promise<void> {
    if (this.closed) return;
    this.closed = true;
    await this.driver.close(this.handle);
  }
}

/** 本机一个空着的端口，给 safaridriver 监听。 */
function freePort(): Promise<number> {
  return new Promise((resolve, reject) => {
    const server = createServer();
    server.once('error', reject);
    server.listen(0, '127.0.0.1', () => {
      const address = server.address();
      server.close(() => (typeof address === 'object' && address ? resolve(address.port) : reject(new Error('没有空闲端口'))));
    });
  });
}
