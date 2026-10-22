/**
 * 预览插件 kite.preview 的网页部分，在工作机上的 Chromium 里看（Playwright 的 headless shell，启动约 0.1 秒；
 * WebKit 启动要几秒，Firefox 在 macOS 27 上起不来，都不用）：
 * 一、设备接入后的逐帧操作；
 * 二、代理用 preview_* 工具开、点、读、列、关。
 * 终端的 shell 换成 bun 跑的网页服务（terminalShell），终端一起来服务就在终端的进程树里监听，端口由系统分配；
 * 探测端口的间隔缩到 50 毫秒。等画面稳定的节奏缩成每 20 毫秒截一帧、60 毫秒不变算稳定（previewSettle），
 * 默认的 0.3 秒每个动作要等近半秒，两个测试都放不进 1 秒。
 */
import { expect, test } from 'bun:test';
import { writeFileSync } from 'node:fs';
import { join } from 'node:path';
import type { Json, ModelItem, ModelRequest, ToolResult } from '../../src/harness/types.ts';
import type { WorkspaceModel } from '../../src/model.ts';
import type { PreviewAction } from '../../src/preview/screen.ts';
import { previewDefinitionId } from '../../src/preview/state.ts';
import { terminalState } from '../../src/terminal/state.ts';
import { terminalDefinitionId } from '../../src/terminal/terminals.ts';
import { after, folderWorkspace, machine, mark, startKited, waitIdle, type Kited } from '../harness.ts';
import { item, ManualModel } from '../harness-loop.ts';
import { imageSize, makeTemp, newDir } from '../util.ts';

const WAIT_MS = 2_000;

/** 终端里跑的网页服务。首页有一个固定在左上角 200×100 的计数按钮，点一下按钮文字和页面标题都变成「点了 N 次」。 */
const SERVER_SCRIPT = String.raw`
const page = ${'`'}<!doctype html><html><head><meta charset="utf-8"><title>点了 0 次</title></head><body style="margin:0">
<button id="count" style="position:fixed;left:0;top:0;width:200px;height:100px">点了 0 次</button>
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

/** 起一个 kited，终端的 shell 换成上面的网页服务。 */
function start(model?: ManualModel): Kited {
  const root = makeTemp('preview-');
  const server = join(root, 'server.js');
  writeFileSync(server, SERVER_SCRIPT);
  return startKited(model && (() => model), false, {
    root, terminalShell: [process.execPath, server], terminalPortScanMs: 50, previewSettle: { stableMs: 60, pollMs: 20, maxMs: 1_000 },
  });
}

async function aggregate(k: Kited, workspaceId: string): Promise<WorkspaceModel> {
  const r = await k.call('GET', `/workspaces/${workspaceId}`);
  expect(r.status).toBe(200);
  return r.body as WorkspaceModel;
}

/** 等工作区聚合满足 find：先读一次，不满足就等这次读之后的 workspace.changed 再读。 */
async function workspaceUntil<T>(k: Kited, workspaceId: string, find: (model: WorkspaceModel) => T | undefined | false, what: string): Promise<T> {
  while (true) {
    const since = mark(k);
    const hit = find(await aggregate(k, workspaceId));
    if (hit) return hit;
    const isAfter = after(k, since);
    await k.waitEvent((e) => e.type === 'workspace.changed' && e.workspaceId === workspaceId && isAfter(e), WAIT_MS)
      .catch(() => { throw new Error(`等待超时：${what}`); });
  }
}

/** 开一个终端窗口（里面就是网页服务），等终端状态里出现能用 HTTP 打开的端口。 */
async function serve(k: Kited, workspaceId: string): Promise<number> {
  const opened = await k.call('POST', `/workspaces/${workspaceId}/windows`, {
    id: crypto.randomUUID(), content: { kind: 'create', definitionId: terminalDefinitionId },
  });
  expect(opened.status).toBe(200);
  const instanceId = opened.body.target.instanceId as string;
  return workspaceUntil(k, workspaceId, (model) => {
    const instance = model.instances.find((i) => i.id === instanceId);
    return instance && terminalState(instance)?.ports?.find((p) => p.http)?.port;
  }, '终端里的网页服务端口认出为 http');
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
  close() { this.ws.close(); }
}

/*
 * 配合：终端的进程树端口探测 → 新建预览时核对端口 → 设备接入时才开浏览器页面。
 * 配合：逐帧点按，宿主做完动作等画面稳定再发带 settled 与 point 的一帧和 JPEG；等的期间再来的逐帧点按回 dropped、不执行，
 * 所以点了两下计数只加一。接入后的首帧不带 settled，可能晚于点按才到，所以按 point 认点按之后的那一帧。
 */
test('工作机 Chromium 里的网页：逐帧点按等画面稳定后发带 settled 和 point 的帧，等的期间再点回 dropped、不执行', async () => {
  const k = start();
  let device: Device | undefined;
  try {
    const machineId = (await machine(k.url)).id;
    const workspaceId = (await folderWorkspace(k, newDir(k.root, 'project', { 'README.md': '预览\n' }))).workspace.id;
    const port = await serve(k, workspaceId);

    const opened = await k.call('POST', `/workspaces/${workspaceId}/windows`, {
      id: crypto.randomUUID(), content: { kind: 'create', definitionId: previewDefinitionId, preview: { kind: 'web', port, browser: 'chromium' } },
    });
    expect(opened.status).toBe(200);
    const previewId = opened.body.target.instanceId as string;

    // 设备接入才开页面
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

const calledItem = (id: string, name: string, args: Json): ModelItem => ({ ...item(id, name), call: { id, name, arguments: args } });
const resultOf = (request: ModelRequest, callId: string): ToolResult => {
  const found = request.history.find((entry) => entry.type === 'tool_result' && entry.callId === callId);
  if (found?.type !== 'tool_result') throw new Error(`缺少工具结果：${callId}`);
  return found.result;
};
/** 成功的工具结果，JSON 正文解析出来。 */
const outputOf = (request: ModelRequest, callId: string): any => {
  const result = resultOf(request, callId);
  expect(result.status).toBe('success');
  return JSON.parse(result.output);
};

/*
 * 配合：代理的工具调用经操作层到预览服务，宿主开没有窗口、来源是这个代理的预览，用 Playwright 在 Chromium 里开页面、截图；
 * 截图要作为 ToolResult.images 交到模型的下一次请求里，JSON 正文不带，图片按逻辑尺寸截（尺寸等于结果里的 width、height）。
 * 点按之后宿主等画面稳定再截图，结果里的页面标题已是点过之后的。preview_list 按调用方列出、preview_close 回收实例，要跨这几处配合才对得上。
 */
test('代理用 preview_open 在工作机 Chromium 里开终端端口上的网页，截图作为工具结果的图片交给模型、JSON 里不带；preview_action 点按钮后的结果已是点过的页面；preview_list 列出它是这个代理开的、没有窗口；preview_close 后实例没了', async () => {
  const model = new ManualModel();
  const k = start(model);
  try {
    const workspaceId = (await folderWorkspace(k, newDir(k.root, 'project', { 'README.md': '预览\n' }))).workspace.id;
    const serving = serve(k, workspaceId);
    const started = await operation(k, workspaceId, 'agent.start', { operationId: 'agent' });
    const agentId = started.instanceId as string;
    expect((await k.call('POST', `/threads/${agentId}/messages`, { id: 'kickoff', text: '看看网页' })).status).toBe(200);
    const port = await serving;

    const first = await model.call(1);
    expect(first.request.allowedTools).toEqual(expect.arrayContaining(['preview_open', 'preview_action', 'preview_inspect', 'preview_list', 'preview_close']));
    await first.response.emit({ type: 'item', item: calledItem('open', 'preview_open', { kind: 'web', port, browser: 'chromium' }) });
    first.response.complete();

    const second = await model.call(2);
    const opened = outputOf(second.request, 'open');
    expect(opened).not.toHaveProperty('images');
    expect(opened).toMatchObject({ kind: 'web', port, browser: 'chromium', url: `http://localhost:${port}/`, pageTitle: '点了 0 次', settled: true });
    const openedImages = resultOf(second.request, 'open').images ?? [];
    expect(openedImages.map((image) => image.mediaType)).toEqual(['image/jpeg']);
    expect(await imageSize(openedImages[0]!.data)).toEqual({ width: opened.width, height: opened.height });
    const previewId = opened.instanceId as string;

    await second.response.emit({ type: 'item', item: calledItem('click', 'preview_action', { instanceId: previewId, action: 'left_click', coordinate: [100, 50] }) });
    second.response.complete();
    const third = await model.call(3);
    const clicked = outputOf(third.request, 'click');
    expect(clicked).not.toHaveProperty('images');
    expect(clicked).toMatchObject({ instanceId: previewId, pageTitle: '点了 1 次', settled: true });
    expect(resultOf(third.request, 'click').images?.map((image) => image.mediaType)).toEqual(['image/jpeg']);

    await third.response.emit({ type: 'item', item: calledItem('inspect', 'preview_inspect', { instanceId: previewId }) });
    await third.response.emit({ type: 'item', item: calledItem('list', 'preview_list', {}) });
    third.response.complete();
    const fourth = await model.call(4);
    expect(outputOf(fourth.request, 'inspect').text).toContain('点了 1 次');
    expect(outputOf(fourth.request, 'list')).toEqual({ previews: [{
      instanceId: previewId, title: expect.any(String), kind: 'web', port, browser: 'chromium', createdBy: agentId, window: false,
    }] });

    await fourth.response.emit({ type: 'item', item: calledItem('close', 'preview_close', { instanceId: previewId }) });
    fourth.response.complete();
    const fifth = await model.call(5);
    expect(outputOf(fifth.request, 'close')).toEqual({ ok: true });
    expect((await aggregate(k, workspaceId)).instances.map((instance) => instance.id)).not.toContain(previewId);
    const since = mark(k);
    fifth.response.complete();
    await waitIdle(k, agentId, since);
  } finally {
    await k.stop();
  }
}, 5_000);
