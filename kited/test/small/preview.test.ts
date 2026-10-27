/**
 * 预览插件 kite.preview 的网页画面，在工作机上的 Chromium 里看（Playwright 的 headless shell，启动约 0.1 秒；
 * WebKit 启动要几秒，Firefox 在 macOS 27 上起不来，都不用）：设备接入后的逐帧操作。
 * 终端插件起进程用的 shell 换成 bun 跑的网页服务（terminalShell），预览的目标一起来服务就在实例的进程树里监听，端口由系统分配；
 * 探测端口的间隔缩到 20 毫秒（terminalPortScanMs，50 毫秒时认出端口要多等约 30 毫秒）。等画面稳定的节奏缩成
 * 每 10 毫秒截一帧、30 毫秒不变算稳定（previewSettle）：默认的 0.3 秒每个动作要等近半秒，测试放不进 1 秒；
 * 宿主每截一帧要和 Chromium 来回一趟，就算稳定时长取 1 毫秒，从点按到发出稳定的帧也要约 0.1 秒，等的期间再点一下的余量足够。
 */
import { expect, test } from 'bun:test';
// kited 第一次开浏览器时才 import('playwright-core')，在 Bun 里要约 0.1 秒，转译缓存里没有时约 0.2 秒，
// 原来全算在文件里第一个测试上，冷启动时超过小测试的 1 秒。文件加载时先载入，kited 里的 import() 拿到的是同一份模块。
import 'playwright-core';
// 指认脚本由 screen.ts 按路径读进来，不在 import 链上；按文本引入，脚本改动时 .kite/check 才会选中这里。
import '../../../shared/preview-point.js' with { type: 'text' };
import { chmodSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import type { PreviewAction } from '../../src/preview/screen.ts';
import { previewDefinitionId } from '../../src/preview/state.ts';
import { folderWorkspace, machine, startKited, type Kited } from '../harness.ts';
import { makeTemp, newDir } from '../util.ts';

const WAIT_MS = 2_000;

/**
 * 预览进程里跑的网页服务。首页有一个固定在左上角 200×100 的计数按钮，点一下按钮文字和页面标题都变成「点了 N 次」。
 * 按钮带着 code-inspector-plugin 写的位置属性，指认时取得到源码位置；按钮之外是空白。
 */
const SERVER_SCRIPT = String.raw`
const page = ${'`'}<!doctype html><html><head><meta charset="utf-8"><title>点了 0 次</title></head><body style="margin:0">
<button id="count" data-insp-path="src/Counter.tsx:12:3:button" style="position:fixed;left:0;top:0;width:200px;height:100px">点了 0 次</button>
<script>
let clicks = 0;
count.onclick = () => { clicks += 1; count.textContent = document.title = '点了 ' + clicks + ' 次'; };
</script></body></html>${'`'};
const server = Bun.serve({
  hostname: '127.0.0.1', port: 0,
  fetch(request) {
    return new URL(request.url).pathname === '/' ? new Response(page, { headers: { 'content-type': 'text/html; charset=utf-8' } }) : new Response('没有', { status: 404 });
  },
});
console.log('serving ' + server.port);
`;

/** 起一个 kited，起进程用的 shell 换成上面的网页服务。 */
function start(): Kited {
  const root = makeTemp('preview-');
  const server = join(root, 'server.js');
  writeFileSync(server, SERVER_SCRIPT);
  return startKited(undefined, false, {
    root, terminalShell: [process.execPath, server], terminalPortScanMs: 20, previewSettle: { stableMs: 30, pollMs: 10, maxMs: 1_000 },
  });
}

async function operation(k: Kited, workspaceId: string, name: string, body: object): Promise<any> {
  const r = await k.call('POST', `/workspaces/${workspaceId}/operations/${name}`, body);
  expect(r.status).toBe(200);
  return r.body;
}

interface Control { type: string; [key: string]: any }
type Message = { control: Control } | { binary: Uint8Array };

/** tsconfig 带了 DOM，全局 WebSocket 按浏览器的类型检查（第二参数只能是协议）；Bun 的构造另能带请求头。 */
const BunWebSocket = WebSocket as unknown as new (url: string, options: Bun.WebSocketOptions) => WebSocket;

/** 一台设备接在预览上：文本帧解析成控制消息、二进制帧原样，按收到的顺序放进 messages。 */
class Device {
  readonly ws: WebSocket;
  readonly messages: Message[] = [];
  private readonly waiters = new Set<() => void>();

  constructor(url: string, machineId: string, instanceId: string, query: string) {
    this.ws = new BunWebSocket(`${url.replace(/^http/, 'ws')}/instances/${instanceId}/preview?${query}`, { headers: { 'X-Kite-Machine': machineId } });
    this.ws.binaryType = 'arraybuffer';
    this.ws.onmessage = (event) => {
      this.messages.push(typeof event.data === 'string'
        ? { control: JSON.parse(event.data) as Control }
        : { binary: new Uint8Array(event.data as ArrayBuffer) });
      for (const waiter of [...this.waiters]) waiter();
    };
  }

  /** 控制消息的摘要，超时报错时带上。 */
  private seen = () => JSON.stringify(this.messages.map((m) => 'control' in m ? m.control : `二进制 ${m.binary.length} 字节`));

  /** 等 find 有结果（已满足的立即返回），每收到一条消息检查一次。 */
  wait<T>(find: () => T | undefined | null | false, what: string): Promise<T> {
    const now = find();
    if (now) return Promise.resolve(now);
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.waiters.delete(check);
        reject(new Error(`等待超时：${what}；已收到 ${this.seen()}`));
      }, WAIT_MS);
      const check = () => {
        const value = find();
        if (!value) return;
        clearTimeout(timer);
        this.waiters.delete(check);
        resolve(value);
      };
      this.waiters.add(check);
    });
  }

  /** 等 since（messages 下标）之后满足 pred 的控制消息，返回它的下标。 */
  control(pred: (c: Control) => boolean, what: string, since = 0): Promise<number> {
    return this.wait(() => {
      const index = this.messages.findIndex((m, i) => i >= since && 'control' in m && pred(m.control));
      return index >= 0 && index + 1;
    }, what).then((found) => found - 1);
  }

  act(action: PreviewAction) { this.ws.send(JSON.stringify({ type: 'action', action, wait: true })); }
  point(x: number, y: number) { this.ws.send(JSON.stringify({ type: 'point', x, y })); }
  close() { this.ws.close(); }
}

/*
 * 配合：预览进程树的端口探测 → 画面种类认出网页 → 设备接入时才开浏览器页面。
 * 配合：逐帧点按，宿主做完动作等画面稳定再发带 settled 与 point 的一帧和 JPEG；等的期间再来的逐帧点按回 dropped、不执行，
 * 所以点了两下计数只加一。接入后的首帧不带 settled，可能晚于点按才到，所以按 point 认点按之后的那一帧。
 */
test('工作机 Chromium 里的网页：逐帧点按等画面稳定后发带 settled 和 point 的帧，等的期间再点回 dropped、不执行', async () => {
  const k = start();
  let device: Device | undefined;
  try {
    const machineId = (await machine(k.url)).id;
    // 目标只要在、可执行：起它的 shell 换成了网页服务
    const project = newDir(k.root, 'project', { 'README.md': '预览\n', '.kite/preview/web': '#!/bin/sh\n' });
    chmodSync(join(project, '.kite/preview/web'), 0o755);
    const workspaceId = (await folderWorkspace(k, project)).workspace.id;

    const opened = await k.call('POST', `/workspaces/${workspaceId}/instances`, {
      id: crypto.randomUUID(), definitionId: previewDefinitionId, preview: { target: 'web' },
    });
    expect(opened.status).toBe(200);
    const previewId = opened.body.id as string;
    await operation(k, workspaceId, 'preview.select', { operationId: 'chromium', instanceId: previewId, browser: 'chromium' });

    // 设备接入才开页面：进程的网页端口认出来之前接入的，认出来后开
    device = new Device(k.url, machineId, previewId, 'width=400&height=300&mode=step');
    await device.control((c) => c.type === 'state' && c.phase === 'ready', '页面打开');
    const shown = (await operation(k, workspaceId, 'preview.inspect', { instanceId: previewId })).text as string;
    expect(shown).toContain('点了 0 次');

    const since = device.messages.length;
    device.act({ type: 'click', x: 100, y: 50 });
    const waiting = await device.control((c) => c.type === 'waiting', '开始等画面稳定', since);
    device.act({ type: 'click', x: 100, y: 50 });
    const dropped = await device.control((c) => c.type === 'dropped', '等的期间的点按被丢掉', waiting);
    const frame = await device.control((c) => c.type === 'frame' && c.point !== undefined, '点按之后稳定的一帧', waiting);
    expect(dropped).toBeLessThan(frame);
    expect(device.messages[frame]).toEqual({ control: { type: 'frame', width: 400, height: 300, settled: true, point: { x: 100, y: 50 } } });
    const jpeg = await device.wait(() => {
      const next = device!.messages[frame + 1];
      return next && 'binary' in next && next.binary;
    }, '帧后面的 JPEG');
    expect([...jpeg.subarray(0, 3)]).toEqual([0xff, 0xd8, 0xff]);

    const clicked = (await operation(k, workspaceId, 'preview.inspect', { instanceId: previewId })).text as string;
    expect(clicked).toContain('点了 1 次');
    expect(clicked).not.toContain('点了 2 次');
  } finally {
    device?.close();
    await k.stop();
  }
}, 5_000);

/*
 * 配合：kited 按 import.meta.url 的相对路径从 shared/ 读指认脚本，在工作机 Chromium 的页面里执行，
 * 结果经预览的 socket 回给问的设备，x、y 原样带回；两次一起问，按 x、y 各认各的回答。
 * 画面没接上指认、脚本读不到或执行出错时工作机都回 null，所以按钮那一点要取到完整的元素才算接上。
 * 运行时：Chromium 的 elementFromPoint 在页面空白处给的是 html 元素（body 里只有 fixed 的按钮、高度为 0），脚本据此回 null。
 */
test('工作机 Chromium 里的网页：设备问一点，回这一点上元素的位置、种类、文字和位置属性里的源码位置，x、y 原样带回，空白处回 null', async () => {
  const k = start();
  let device: Device | undefined;
  try {
    const machineId = (await machine(k.url)).id;
    const project = newDir(k.root, 'project', { 'README.md': '预览\n', '.kite/preview/web': '#!/bin/sh\n' });
    chmodSync(join(project, '.kite/preview/web'), 0o755);
    const workspaceId = (await folderWorkspace(k, project)).workspace.id;
    const opened = await k.call('POST', `/workspaces/${workspaceId}/instances`, {
      id: crypto.randomUUID(), definitionId: previewDefinitionId, preview: { target: 'web' },
    });
    expect(opened.status).toBe(200);
    const previewId = opened.body.id as string;
    await operation(k, workspaceId, 'preview.select', { operationId: 'chromium', instanceId: previewId, browser: 'chromium' });

    device = new Device(k.url, machineId, previewId, 'width=400&height=300&mode=step');
    const ready = await device.control((c) => c.type === 'state' && c.phase === 'ready', '页面打开');
    device.point(100, 50);
    device.point(300, 200);
    const answer = (x: number, y: number) => device!.control((c) => c.type === 'element' && c.x === x && c.y === y, `(${x}, ${y}) 的指认结果`, ready);
    const [button, blank] = await Promise.all([answer(100, 50), answer(300, 200)]);
    expect(device.messages[button]).toEqual({
      control: {
        type: 'element', x: 100, y: 50,
        element: { x: 0, y: 0, width: 200, height: 100, tag: 'button', text: '点了 0 次', color: '#000000', font: expect.any(String), id: 'count', file: 'src/Counter.tsx', line: 12, page: '/' },
      },
    });
    expect(device.messages[blank]).toEqual({ control: { type: 'element', x: 300, y: 200, element: null } });
  } finally {
    device?.close();
    await k.stop();
  }
}, 5_000);
