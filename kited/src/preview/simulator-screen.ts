/**
 * 模拟器的画面与输入：每台启动着的模拟器一个常驻的 kite-sim 进程（源码 kite-sim.m，首次使用时按源码哈希编译到用户临时目录）。
 * 它一直拿着模拟器里输入服务的连接：刚连上的第一个输入多半会丢，连接要常驻。命令按顺序一问一答，协议见 kite-sim.m。
 * 画面没变时（模拟器没有呈现新的一帧）它不重新编码，这里用上次那帧。
 */
import { fileURLToPath } from 'node:url';
import { KiteError } from '../errors.ts';
import { compiledHelper } from '../system-command.ts';
import type { Frame, PreviewAction, Screen } from './screen.ts';

const SOURCE = fileURLToPath(new URL('./kite-sim.m', import.meta.url));
const FRAMEWORKS = ['Foundation', 'CoreGraphics', 'ImageIO', 'IOSurface', 'UniformTypeIdentifiers'];

/** 编译 kite-sim（见 compiledHelper）；要 Xcode（私有框架在 Xcode 里），没有时报错。 */
const helper = (env: Record<string, string>) => compiledHelper({ source: SOURCE, name: 'kite-sim', env, status: 503,
  failure: '模拟器的辅助程序编译失败，需要 Xcode',
  compile: (output) => ['/usr/bin/clang', '-fobjc-arc', '-O2', ...FRAMEWORKS.flatMap((name) => ['-framework', name]), SOURCE, '-o', output] });

type Reply = Record<string, unknown> & { id: number; error?: string };
/**
 * 一条命令最多等这么久：kite-sim 一次只做一条，卡住的（等输入服务连上、等送出输入）会挡住后面所有截图。
 * 超时就杀掉它，画面断开，下次要用时重开。刚连上时等输入服务约 35 秒，长按最多 10 秒，都在这之内。
 */
const REQUEST_TIMEOUT_MS = 60_000;

/** 一台模拟器的画面，exited 在 kite-sim 退出（模拟器关了、被删了）时兑现。 */
export interface SimulatorScreen extends Screen {
  exited: Promise<void>;
}

export async function openSimulatorScreen(udid: string, env: Record<string, string>): Promise<SimulatorScreen> {
  const binary = await helper(env);
  const child = Bun.spawn([binary, udid], { env, stdin: 'pipe', stdout: 'pipe', stderr: 'pipe' });
  const screen = new KiteSim(child);
  // 第一条命令回来才算起好；起不来时 kite-sim 往标准错误写原因后退出
  await screen.request({ cmd: 'info' });
  return screen;
}

class KiteSim implements SimulatorScreen {
  readonly exited: Promise<void>;
  private nextId = 1;
  private waiting = new Map<number, { resolve(reply: Reply & { jpeg?: Uint8Array }): void; reject(error: Error): void }>();
  private dead?: string;
  private errors = '';
  /** 上次截给设备、给模型的帧；kite-sim 说没变时用它。 */
  private frames: [Frame?, Frame?] = [];

  constructor(private child: Bun.Subprocess<'pipe', 'pipe', 'pipe'>) {
    void this.read();
    void (async () => {
      const decoder = new TextDecoder();
      for await (const chunk of child.stderr) this.errors = (this.errors + decoder.decode(chunk, { stream: true })).slice(-2048);
    })().catch(() => {});
    this.exited = child.exited.then(() => {
      this.dead = this.errors.trim().split('\n').at(-1) || '模拟器的画面断开了';
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
        if (type === 'B' && frameOf) { this.settle({ ...frameOf, jpeg: body }); frameOf = undefined; continue; }
        if (type !== 'J') continue;
        const reply = JSON.parse(decoder.decode(body)) as Reply;
        if (typeof reply.bytes === 'number') frameOf = reply;
        else this.settle(reply);
      }
    }
  }

  private settle(reply: Reply & { jpeg?: Uint8Array }): void {
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
        this.errors += '\n模拟器的辅助程序没有响应';
        this.child.kill();
      }, REQUEST_TIMEOUT_MS);
      timer.unref();
      const settled = <T>(done: (value: T) => void) => (value: T) => { clearTimeout(timer); done(value); };
      this.waiting.set(id, { resolve: settled(resolve), reject: settled(reject) });
      void Promise.resolve(this.child.stdin.write(`${JSON.stringify({ ...command, id })}\n`)).then(() => this.child.stdin.flush())
        .catch(() => reject(new KiteError('模拟器的画面断开了', 503)));
    });
  }

  alive(): boolean { return !this.dead; }

  async capture(forModel = false): Promise<Frame> {
    const slot = forModel ? 1 : 0;
    const cached = this.frames[slot];
    const reply = await this.request({ cmd: 'frame', model: forModel, cached: !!cached });
    // 没变是相对于 kite-sim 最近截的那帧：同时有几个截图时，那帧可能是别的调用刚记下的
    if (reply.unchanged && this.frames[slot]) return this.frames[slot];
    if (!reply.jpeg) throw new KiteError('模拟器没有给出画面', 503);
    const frame = { data: reply.jpeg, width: Number(reply.width), height: Number(reply.height) };
    this.frames[slot] = frame;
    return frame;
  }

  async act(action: PreviewAction): Promise<void> {
    switch (action.type) {
      case 'click':
        if (action.button === 'right') throw new KiteError('模拟器没有右键，用长按', 400);
        await this.request({ cmd: 'tap', x: action.x, y: action.y, count: action.count ?? 1 });
        return;
      case 'drag': await this.request({ cmd: 'drag', from: action.from, to: action.to }); return;
      case 'scroll': await this.request({ cmd: 'scroll', x: action.x, y: action.y, dx: action.dx, dy: action.dy }); return;
      case 'type': await this.request({ cmd: 'type', text: action.text }); return;
      case 'key': await this.request({ cmd: 'key', key: action.key }); return;
      case 'long_press': await this.request({ cmd: 'longpress', x: action.x, y: action.y, seconds: action.duration ?? 1 }); return;
      case 'pinch': await this.request({ cmd: 'pinch', x: action.x, y: action.y, scale: action.scale }); return;
      case 'home': await this.request({ cmd: 'home' }); return;
      case 'navigate': case 'back': case 'forward': case 'reload': throw new KiteError('模拟器预览没有这个动作', 400);
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
