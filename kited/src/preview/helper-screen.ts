/**
 * Mac App 的窗口经常驻的辅助程序 kite-window（源码 kite-window.m）取画面与输入，首次使用时按源码哈希编译到用户临时目录（见 compiledHelper）。
 * 每个在看的 App 一个进程，只截它的窗口、只向它发输入；命令按顺序一问一答，协议见 kite-window.m 开头。
 */
import { fileURLToPath } from 'node:url';
import { KiteError } from '../errors.ts';
import { compiledHelper } from '../system-command.ts';
import type { Frame, PreviewAction, Screen } from './screen.ts';

const WINDOW_SOURCE = fileURLToPath(new URL('./kite-window.m', import.meta.url));

/**
 * 编译辅助程序（见 compiledHelper）；要 Xcode 的命令行工具，没有时报错。找 App 每两秒要用一次，编好的路径留着，不每次再读源码算哈希；
 * 源码改了要重启 kited 才换。
 */
let helper: Promise<string> | undefined;
export function windowHelper(env: Record<string, string>): Promise<string> {
  helper ??= compiledHelper({ source: WINDOW_SOURCE, name: 'kite-window', env, status: 503, failure: 'App 窗口的辅助程序编译失败，需要 Xcode 命令行工具',
    compile: (output) => ['/usr/bin/clang', '-fobjc-arc', '-O2', ...['AppKit', 'ApplicationServices', 'ScreenCaptureKit', 'ImageIO', 'UniformTypeIdentifiers']
      .flatMap((framework) => ['-framework', framework]), WINDOW_SOURCE, '-o', output] });
  helper.catch(() => { helper = undefined; });
  return helper;
}

type Reply = Record<string, unknown> & { id: number; error?: string };
/**
 * 一条命令最多等这么久：辅助程序一次只做一条，卡住的（等送出输入）会挡住后面所有截图。
 * 超时就杀掉它，画面断开，下次要用时重开。长按最多 10 秒，在这之内。
 */
const REQUEST_TIMEOUT_MS = 60_000;

/** 打开这个 App 进程最前面那个窗口的画面；起不来时辅助程序写的原因作为错误。 */
export async function openWindowScreen(pid: number, env: Record<string, string>): Promise<Screen> {
  const child = Bun.spawn([await windowHelper(env), String(pid)], { env, stdin: 'pipe', stdout: 'pipe', stderr: 'pipe' });
  const screen = new HelperProcess(child);
  // 第一条命令回来才算起好；起不来时辅助程序往标准错误写原因后退出，回了错误的（App 没有窗口）这里收掉它
  try { await screen.request({ cmd: 'info' }); }
  catch (error) { await screen.close(); throw error; }
  return screen;
}

class HelperProcess implements Screen {
  private readonly exited: Promise<void>;
  private nextId = 1;
  private waiting = new Map<number, { resolve(reply: Reply & { jpeg?: Uint8Array }): void; reject(error: Error): void }>();
  private dead?: string;
  private errors = '';

  constructor(private child: Bun.Subprocess<'pipe', 'pipe', 'pipe'>) {
    void this.read();
    const drained = (async () => {
      const decoder = new TextDecoder();
      for await (const chunk of child.stderr) this.errors = (this.errors + decoder.decode(chunk, { stream: true })).slice(-2048);
    })().catch(() => {});
    // 退出的原因（比如还没允许录屏）是最后写的那行：读完标准错误再报
    this.exited = Promise.all([child.exited, drained]).then(() => {
      this.dead = this.errors.trim().split('\n').at(-1) || 'App 窗口的画面断开了';
      for (const { reject } of this.waiting.values()) reject(new KiteError(this.dead, 503));
      this.waiting.clear();
    });
  }

  /** 读一条条消息：1 字节类型、4 字节大端长度、内容；说明里带 bytes 的，紧跟的 B 消息是它的 JPEG。收到的块先攒着，凑够一条才拼。 */
  private async read(): Promise<void> {
    const decoder = new TextDecoder();
    let chunks: Uint8Array[] = [];
    let buffered = 0;
    let frameOf: Reply | undefined;
    const take = (length: number): Uint8Array => {
      const out = new Uint8Array(length);
      let offset = 0;
      while (offset < length) {
        const chunk = chunks[0]!, used = Math.min(chunk.length, length - offset);
        out.set(chunk.subarray(0, used), offset);
        offset += used;
        if (used === chunk.length) chunks.shift(); else chunks[0] = chunk.subarray(used);
      }
      buffered -= length;
      return out;
    };
    for await (const chunk of this.child.stdout) {
      chunks.push(chunk);
      buffered += chunk.length;
      while (buffered >= 5) {
        // 消息头跨了块：先并成一块
        if (chunks[0]!.length < 5) { const joined = take(buffered); chunks = [joined]; buffered = joined.length; }
        const head = chunks[0]!;
        const length = new DataView(head.buffer, head.byteOffset + 1, 4).getUint32(0);
        if (buffered < 5 + length) break;
        const message = take(5 + length);
        const type = String.fromCharCode(message[0]!), body = message.subarray(5);
        if (type === 'B' && frameOf) { this.answer({ ...frameOf, jpeg: body }); frameOf = undefined; continue; }
        if (type !== 'J') continue;
        const reply = JSON.parse(decoder.decode(body)) as Reply;
        if (typeof reply.bytes === 'number') frameOf = reply;
        else this.answer(reply);
      }
    }
  }

  private answer(reply: Reply & { jpeg?: Uint8Array }): void {
    const waiter = this.waiting.get(reply.id);
    if (!waiter) return;
    this.waiting.delete(reply.id);
    if (reply.error) waiter.reject(new KiteError(reply.error, 409));
    else waiter.resolve(reply);
  }

  request(command: Record<string, unknown>): Promise<Reply & { jpeg?: Uint8Array }> {
    if (this.dead) return Promise.reject(new KiteError(this.dead, 503));
    const id = this.nextId++;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        if (!this.waiting.has(id)) return;
        this.errors += '\n画面的辅助程序没有响应';
        this.child.kill();
      }, REQUEST_TIMEOUT_MS);
      timer.unref();
      const settled = <T>(done: (value: T) => void) => (value: T) => { clearTimeout(timer); done(value); };
      this.waiting.set(id, { resolve: settled(resolve), reject: settled(reject) });
      void Promise.resolve(this.child.stdin.write(`${JSON.stringify({ ...command, id })}\n`)).then(() => this.child.stdin.flush())
        .catch(() => reject(new KiteError('画面断开了', 503)));
    });
  }

  alive(): boolean { return !this.dead; }

  async capture(forModel = false): Promise<Frame> {
    const reply = await this.request({ cmd: 'frame', model: forModel });
    if (!reply.jpeg) throw new KiteError('没有截到画面', 503);
    return { data: reply.jpeg, width: Number(reply.width), height: Number(reply.height) };
  }

  async act(action: PreviewAction): Promise<void> {
    switch (action.type) {
      case 'click': await this.request({ cmd: 'tap', x: action.x, y: action.y, count: action.count ?? 1, ...(action.button === 'right' ? { button: 'right' } : {}) }); return;
      case 'drag': await this.request({ cmd: 'drag', from: action.from, to: action.to }); return;
      case 'scroll': await this.request({ cmd: 'scroll', x: action.x, y: action.y, dx: action.dx, dy: action.dy }); return;
      case 'type': await this.request({ cmd: 'type', text: action.text }); return;
      case 'key': await this.request({ cmd: 'key', key: action.key }); return;
      case 'long_press': await this.request({ cmd: 'longpress', x: action.x, y: action.y, seconds: action.duration ?? 1 }); return;
      case 'pinch': case 'home': case 'navigate': case 'back': case 'forward': case 'reload': throw new KiteError('App 窗口没有这个动作', 400);
    }
  }

  async inspect(): Promise<string> {
    return String((await this.request({ cmd: 'ax' })).text ?? '');
  }

  async info() { return {}; }

  async close(): Promise<void> {
    this.child.kill();
    await this.exited;
  }
}
