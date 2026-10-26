/**
 * 终端插件 kite.terminal，分三段：
 * 一、PTY 会话、设备接入的画面镜像与尺寸归属、实例随进程的回收、带命令新建（命令像粘贴那样打进 shell），
 *    以及跨两次 kited 启动的恢复；
 * 二、运行中的网页：终端从自己的进程树探测监听端口并试 HTTP，写进实例状态；本机全部终端的端口整组交给组网转发；
 *    terminal.stop 停下带后台任务的终端；
 * 三、代理的长命令转到后台终端：shell 到时限、用户插话或要求时不停进程，交给接管方接着跑。
 * shell 换成 /bin/sh（terminalShell），不起用户的登录 shell；带命令新建的两个用例另换成先输出一行、停一下再起交互 shell 的 sh 和 zsh（zsh 不读配置）。
 */
import { afterEach, expect, test } from 'bun:test';
import { closeSync, existsSync, openSync, readFileSync, writeFileSync, writeSync } from 'node:fs';
import { join } from 'node:path';
import { processGroupAlive, type BackgroundCommand } from '../../src/execution/command.ts';
import { localTools, type ShellBackground } from '../../src/execution/local-tools.ts';
import type { Input, Json, ModelItem, ModelRequest, ToolResult } from '../../src/harness/types.ts';
import type { PluginInstance, WorkspaceModel } from '../../src/model.ts';
import type { Network, NetworkStatus } from '../../src/network.ts';
import { terminalState, type TerminalState } from '../../src/terminal/state.ts';
import { terminalDefinitionId } from '../../src/terminal/terminals.ts';
import { after, folderWorkspace, machine, mark, startKited, waitIdle, type Kited } from '../harness.ts';
import { item, ManualModel, Seen } from '../harness-loop.ts';
import { ENV, newDir, until, useTemp } from '../util.ts';

const terminalShell = ['/bin/sh'];
const WAIT_MS = 2_000;

interface Control { type: string; [key: string]: any }

/** tsconfig 带了 DOM，全局 WebSocket 按浏览器的类型检查（第二参数只能是协议）；Bun 的构造另能带请求头。 */
const BunWebSocket = WebSocket as unknown as new (url: string, options: Bun.WebSocketOptions) => WebSocket;

/** 一台设备接在终端上：二进制帧按 UTF-8 拼成 output，文本帧解析后按顺序放进 controls。 */
class Device {
  readonly ws: WebSocket;
  output = '';
  readonly controls: Control[] = [];
  private readonly decoder = new TextDecoder();
  private readonly waiters = new Set<() => void>();

  constructor(url: string, machineId: string, instanceId: string, size?: { cols: number; rows: number }) {
    const query = size ? `?cols=${size.cols}&rows=${size.rows}` : '';
    this.ws = new BunWebSocket(`${url.replace(/^http/, 'ws')}/instances/${instanceId}/terminal${query}`,
      { headers: { 'X-Kite-Machine': machineId } });
    this.ws.binaryType = 'arraybuffer';
    this.ws.onmessage = (event) => {
      if (typeof event.data === 'string') this.controls.push(JSON.parse(event.data) as Control);
      else this.output += this.decoder.decode(new Uint8Array(event.data as ArrayBuffer), { stream: true });
      for (const waiter of [...this.waiters]) waiter();
    };
  }

  /** 等 find 有结果（已满足的立即返回），每收到一条消息检查一次。 */
  wait<T>(find: () => T | undefined | null | false, what: string): Promise<T> {
    const now = find();
    if (now) return Promise.resolve(now);
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.waiters.delete(check);
        reject(new Error(`等待超时：${what}；已收到输出 ${JSON.stringify(this.output)}，控制消息 ${JSON.stringify(this.controls)}`));
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

  snapshot = () => this.wait(() => this.controls.find((c) => c.type === 'snapshot'), '接入后的 snapshot');
  /** 输出位置，配合 waitOutput 只看这之后的输出。 */
  mark = () => this.output.length;
  waitOutput = (text: string, from = 0) => this.wait(() => this.output.indexOf(text, from) >= 0, `输出 ${JSON.stringify(text)}`);
  /** 等输出里出现 pattern，返回匹配。 */
  match = (pattern: RegExp) => this.wait(() => this.output.match(pattern), `输出 ${pattern}`);
  /** 等 since（controls 下标）之后的一条控制消息。 */
  waitControl = (pred: (c: Control) => boolean, what: string, since = 0) =>
    this.wait(() => this.controls.slice(since).find(pred), what);
  type(text: string) { this.ws.send(new TextEncoder().encode(text)); }
  resize(cols: number, rows: number) { this.ws.send(JSON.stringify({ type: 'resize', cols, rows })); }
  close() { this.ws.close(); }
}

async function start(root?: string, shell = terminalShell): Promise<{ k: Kited; machineId: string }> {
  const k = startKited(undefined, false, root === undefined ? { terminalShell: shell } : { root, terminalShell: shell });
  return { k, machineId: (await machine(k.url)).id };
}

async function workspaceOf(k: Kited): Promise<string> {
  const repo = newDir(k.root, 'project', { 'README.md': '终端\n' });
  return (await folderWorkspace(k, repo)).workspace.id;
}

/** 新建终端实例，带 command 时 shell 起好后把它打进去。request 是发出的请求，原样再发一次就是重试。 */
async function openTerminal(k: Kited, workspaceId: string, command?: string): Promise<{ instanceId: string; request: object }> {
  const instanceId = crypto.randomUUID();
  const request = { id: instanceId, definitionId: terminalDefinitionId, command };
  const opened = await k.call('POST', `/workspaces/${workspaceId}/instances`, request);
  expect(opened.status).toBe(200);
  expect(opened.body.id).toBe(instanceId);
  return { instanceId, request };
}

async function closeInstance(k: Kited, instanceId: string): Promise<void> {
  const closed = await k.call('DELETE', `/instances/${instanceId}`);
  expect(closed.status).toBe(200);
}

async function aggregate(k: Kited, workspaceId: string): Promise<WorkspaceModel> {
  const r = await k.call('GET', `/workspaces/${workspaceId}`);
  expect(r.status).toBe(200);
  return r.body as WorkspaceModel;
}

const instanceIn = (model: WorkspaceModel, id: string): PluginInstance | undefined => model.instances.find((i) => i.id === id);

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

const stateIn = (model: WorkspaceModel, id: string): TerminalState | undefined => {
  const instance = instanceIn(model, id);
  return instance && terminalState(instance);
};

// 运行时：Bun 1.4 的 Bun.spawn({terminal}) 给 shell 一个真 PTY（输入有回显、resize 改的尺寸 stty 看得到、退出码原样报出）；
// @xterm/headless 的 write 是异步解析的，后接入的设备拿 snapshot 时前面的输出不能还没进画面，snapshot 之后的二进制帧也不能把它再发一遍。
// 配合：两台设备的尺寸归属跟着最近输入的那台走，PTY 换成它报过的尺寸，另一台收到 size。
test('终端输入有回显并执行，后接入的设备画面里有之前的输出，PTY 尺寸跟最近输入的设备，退出码报给所有设备', async () => {
  const { k, machineId } = await start();
  const devices: Device[] = [];
  try {
    const workspaceId = await workspaceOf(k);
    const { instanceId } = await openTerminal(k, workspaceId);
    expect(stateIn(await aggregate(k, workspaceId), instanceId)).toEqual({ phase: 'running' });

    const a = new Device(k.url, machineId, instanceId, { cols: 90, rows: 30 });
    devices.push(a);
    expect(await a.snapshot()).toMatchObject({ cols: 90, rows: 30, phase: 'running' });

    // 回显的是原样的命令，执行结果是算出来的 first2，两者都要出现
    a.type('echo first$((1+1))\n');
    await a.waitOutput('echo first$((1+1))');
    await a.waitOutput('first2');

    // a 是尺寸归属者，它的 resize 直接生效
    let from = a.mark();
    a.resize(100, 40);
    a.type('stty size\n');
    await a.waitOutput('40 100', from);

    const b = new Device(k.url, machineId, instanceId, { cols: 70, rows: 20 });
    devices.push(b);
    const snapshot = await b.snapshot();
    expect(snapshot).toMatchObject({ cols: 70, rows: 20, phase: 'running' });
    expect(snapshot.data).toContain('first2');
    expect(snapshot.data).toContain('40 100');

    // a 一输入就重新成为归属者，PTY 换回 a 报过的 100x40，b 收到 size
    let since = b.controls.length;
    from = a.mark();
    a.type('stty size\n');
    await b.waitControl((c) => c.type === 'size' && c.cols === 100 && c.rows === 40, 'b 收到 a 的尺寸', since);
    await a.waitOutput('40 100', from);

    // b 一输入，PTY 换成 b 的 70x20，a 收到 size
    since = a.controls.length;
    from = a.mark();
    b.type('stty size\n');
    await a.waitControl((c) => c.type === 'size' && c.cols === 70 && c.rows === 20, 'a 收到 b 的尺寸', since);
    await a.waitOutput('20 70', from);
    await b.waitOutput('20 70');

    b.type('exit 7\n');
    for (const device of devices) {
      expect(await device.waitControl((c) => c.type === 'exit', '进程结束')).toMatchObject({ phase: 'exited', exitCode: 7 });
    }
    // snapshot 之前的输出只在 snapshot 里，二进制流不重发
    expect(b.output).not.toContain('first2');
  } finally {
    for (const device of devices) device.close();
    await k.stop();
  }
}, 5_000);

/*
 * 配合：进程退出回调与关闭实例都在工作区控制队列里改实例；用户开的终端自己退出时留着、记下退出码。
 * 真实 bug：停下就是关闭，可进程已经自己结束的终端再调 terminal.stop 原来直接返回，实例一直不回收。
 * 这里自己退出的那个用 terminal.stop 收掉（与关闭实例走同一处回收），还在跑的那个用关闭实例收掉。
 * 时序：关闭还在跑的终端是先停进程、等它退出再回收，接口返回时两件事都已做完；停进程触发的退出回调不能把已回收的实例记回去，
 * 再关闭得 404。依赖 sh：交互式 sh 开着作业控制，前台命令在自己的进程组，停终端时它也要结束（僵尸算已结束）。
 */
test('终端自己退出记为 exited 留着，再 terminal.stop 就回收；关闭还在跑的终端，返回时 shell 与前台命令都已结束、实例已回收，再关闭是 404', async () => {
  const { k, machineId } = await start();
  const devices: Device[] = [];
  // sleep 的参数带上本次的随机数，清理时按命令行找它，不按可能被复用的 pid。
  const marker = `3002.${crypto.getRandomValues(new Uint32Array(1))[0]}`;
  try {
    const workspaceId = await workspaceOf(k);
    const foreground = await openTerminal(k, workspaceId);
    const b = new Device(k.url, machineId, foreground.instanceId);
    devices.push(b);
    await b.snapshot();
    b.type('exit 5\n');
    await b.waitControl((c) => c.type === 'exit', '进程结束');
    const exited = await workspaceUntil(k, workspaceId, (model) => {
      const state = stateIn(model, foreground.instanceId);
      return state?.phase === 'exited' && state;
    }, '终端退出后记为 exited');
    expect(exited).toMatchObject({ phase: 'exited', exitCode: 5 });
    b.close();
    const stopped = await k.call('POST', `/workspaces/${workspaceId}/operations/terminal.stop`,
      { operationId: crypto.randomUUID(), instanceId: foreground.instanceId });
    expect(stopped.status).toBe(200);
    expect(stopped.body).toMatchObject({ ok: true });
    await workspaceUntil(k, workspaceId, (model) => !instanceIn(model, foreground.instanceId), '自己退出的终端在 terminal.stop 后回收');

    const busy = await openTerminal(k, workspaceId);
    const c = new Device(k.url, machineId, busy.instanceId);
    devices.push(c);
    await c.snapshot();
    c.type(`echo shell=$$; sh -c 'echo job=$$; exec sleep ${marker}'\n`);
    const ids = await c.match(/shell=(\d+)[\s\S]*job=(\d+)/);
    const pids = { shell: Number(ids[1]), job: Number(ids[2]) };
    const running = () => Object.entries(pids).flatMap(([name, pid]) => {
      const info = processInfo(pid);
      return info && !info.stat.includes('Z') ? [`${name}（${info.stat}）`] : [];
    });
    expect(running()).toHaveLength(2);

    await closeInstance(k, busy.instanceId);
    expect(running()).toEqual([]);
    expect(k.daemon.kite.store.instance(busy.instanceId)).toBeNull();
    expect((await k.call('DELETE', `/instances/${busy.instanceId}`)).status).toBe(404);
    expect(instanceIn(await aggregate(k, workspaceId), busy.instanceId)).toBeUndefined();
  } finally {
    for (const device of devices) device.close();
    Bun.spawnSync(['pkill', '-KILL', '-f', `^sleep ${marker}$`], { env: ENV() });
    await k.stop();
  }
}, 5_000);

/** 设备接入后看到的全部画面：接入时 snapshot 里的，加上之后的输出。shown 等画面里出现 text，times 数 text 出现了几次。 */
async function screenOf(device: Device) {
  const { data } = await device.snapshot();
  const screen = () => `${data as string}${device.output}`;
  return {
    screen,
    shown: (text: string) => device.wait(() => screen().includes(text), `画面里出现 ${JSON.stringify(text)}`),
    times: (text: string) => screen().split(text).length - 1,
  };
}

/*
 * 运行时：shell 在 PTY 上接管终端之前，tty 还在规范模式、开着回显，这时打进去的命令先被 tty 回显一遍，shell 读到后又显示一遍。
 * 登录 shell 起来时常先输出几行、停一下才出提示符，这里用先打一行、停 50 毫秒再 exec 交互式 sh 的启动命令模拟（停的时间短于 kited 等输出停下的那段）；
 * 实测在停的期间打进去，第二行以后的命令都显示两遍。sh 是 bash 3.2，没开括号粘贴，命令的换行换成回车逐行打进去。
 * 这些要起真 shell 才看得出：命令在画面里只出现一次、每一行都执行了、跑完 shell 还在。
 * 配合：带命令新建经请求的回执去重，同一请求重试返回原实例，不另建实例。
 */
test('带命令新建终端：等 shell 起来才把多行命令逐行打进去，每行执行一次、命令在画面里只显示一遍，跑完 shell 还在；同一请求重试返回原实例、不另建实例', async () => {
  const { k, machineId } = await start(undefined, ['/bin/sh', '-c', 'echo 正在启动; sleep 0.05; exec /bin/sh']);
  let device: Device | undefined;
  try {
    const workspaceId = await workspaceOf(k);
    const { instanceId, request } = await openTerminal(k, workspaceId, '# 先打个招呼\necho one-$((1+1))\n\necho two-$((2+3))');

    device = new Device(k.url, machineId, instanceId);
    const { shown, times } = await screenOf(device);
    await shown('two-5');

    const retried = await k.call('POST', `/workspaces/${workspaceId}/instances`, request);
    expect(retried.status).toBe(200);
    expect(retried.body).toMatchObject({ id: instanceId });
    const model = await aggregate(k, workspaceId);
    expect(model.instances.filter((i) => i.definitionId === terminalDefinitionId).map((i) => i.id)).toEqual([instanceId]);

    // 跑完 shell 还在：自己再打一行能执行；等到它的输出时，前面命令的回显早已到齐
    device.type('echo again-$((3*3))\n');
    await shown('again-9');
    expect(times('echo one-$((1+1))')).toBe(1);
    expect(times('echo two-$((2+3))')).toBe(1);
    expect(times('one-2')).toBe(1);
    expect(times('two-5')).toBe(1);
  } finally {
    device?.close();
    await k.stop();
  }
}, 5_000);

/*
 * 上游行为（zsh 5.9）：zle 开着括号粘贴（输出 \x1b[?2004h），粘贴进来的制表符、换行都原样进编辑缓冲区，回车后整段一起执行；
 * 不包括号逐字打进去时，换行逐行执行（出 for> 这类续行提示符），跟在字后面的制表符触发补全：实测补全没找到就响铃、吞掉制表符，
 * printf 的格式里少了那个制表符（行首的制表符补全时照样插进去，看不出区别，所以要放在字后面）。
 * 括号粘贴要等 zle 接管终端才打开。真实的 zsh 配置常先输出一段、再静默加载插件超过 200 毫秒，只看启动输出停下就会赶在这个空当里打进去，
 * 那时只能不包括号裸打；这里用先打一行、停 0.4 秒再 exec 交互式 zsh 的启动命令模拟，argv[0] 仍是 zsh，kited 要等到括号粘贴打开。
 * 临时验证过：同样的启动命令把 argv[0] 换成 /bin/sh（kited 只等输出停下），结果出现 for> 续行提示符、补全响铃，制表符被吞掉。
 * 交互式 zsh 默认不认 # 注释，整行当命令报 command not found: #；kited 给默认的 zsh 登录 shell 加了 -o interactivecomments，
 * 这里同样加上，-f 不读配置。这些只有起真 zsh 才知道。
 */
const zsh = '/bin/zsh';
test.skipIf(!existsSync(zsh))('zsh 先输出一段、停顿超过 200 毫秒才进入行编辑时，带命令新建等到括号粘贴打开才打进去：# 注释行不报错，制表符缩进、行内带制表符的多行循环整段执行，没有触发补全', async () => {
  const { k, machineId } = await start(undefined, [zsh, '-f', '-c', `echo loading; sleep 0.4; exec ${zsh} -f -o interactivecomments -i`]);
  let device: Device | undefined;
  try {
    const workspaceId = await workspaceOf(k);
    const command = [
      '# 只留奇数，两列之间是制表符',
      'for n in 1 2 3; do',
      '\tif [ $((n % 2)) -eq 1 ]; then',
      "\t\tprintf 'odd-%s\t%s\\n' $n $((n * 10))",
      '\tfi',
      'done',
      'echo after-$((6 * 7))',
    ].join('\n');
    const { instanceId } = await openTerminal(k, workspaceId, command);

    device = new Device(k.url, machineId, instanceId);
    const { screen, shown } = await screenOf(device);
    await shown('after-42');
    const text = screen();
    expect(text).toContain('odd-1\t10');
    expect(text).toContain('odd-3\t30');
    expect(text).not.toContain('odd-2');
    expect(text).not.toContain('\x07');
    expect(text).not.toContain('for> ');
    expect(text).not.toContain('command not found');
  } finally {
    device?.close();
    await k.stop();
  }
}, 5_000);

// 配合：跨两次 kited 启动。关闭时停掉还在跑的终端，但不把它记为结束；重启时按结束状态认出哪些是随 kited 结束的，
// 回收、删掉会话目录。关闭前已经自己退出的终端早已记为 exited，留着，接入拿到存下的画面。
test('kited 正常关闭再启动后，关闭时还在跑的终端回收、会话目录删掉；之前已自己退出的留着，接入看到最后的画面', async () => {
  const first = await start();
  let second: Awaited<ReturnType<typeof start>> | undefined;
  const devices: Device[] = [];
  try {
    const workspaceId = await workspaceOf(first.k);
    const running = await openTerminal(first.k, workspaceId);
    const a = new Device(first.k.url, first.machineId, running.instanceId);
    devices.push(a);
    await a.snapshot();
    a.type('echo before$((2+3))\n');
    await a.waitOutput('before5');
    a.close();

    const ended = await openTerminal(first.k, workspaceId);
    const c = new Device(first.k.url, first.machineId, ended.instanceId);
    devices.push(c);
    await c.snapshot();
    c.type('echo last$((3+4)); exit 6\n');
    await c.waitControl((control) => control.type === 'exit', '进程结束');
    c.close();
    await workspaceUntil(first.k, workspaceId, (model) => stateIn(model, ended.instanceId)?.phase === 'exited',
      '自己退出的终端记为 exited');

    await first.k.halt();
    const runningDir = join(first.k.home, 'sessions', running.instanceId);
    expect(existsSync(runningDir)).toBe(true);
    second = await start(first.k.root);
    const { k } = second;
    const restored = await workspaceUntil(k, workspaceId, (model) => !instanceIn(model, running.instanceId) && model,
      '关闭时还在跑的终端在重启后回收');
    expect(existsSync(runningDir)).toBe(false);

    expect(stateIn(restored, ended.instanceId)).toMatchObject({ phase: 'exited', exitCode: 6 });
    const b = new Device(k.url, second.machineId, ended.instanceId);
    devices.push(b);
    const snapshot = await b.snapshot();
    expect(snapshot).toMatchObject({ phase: 'exited', exitCode: 6 });
    expect(snapshot.data).toContain('last7');
  } finally {
    for (const device of devices) device.close();
    await second?.k.halt();
    await first.k.stop();
  }
}, 5_000);

// ---- 运行中的网页 ----
// 探测间隔缩到 50 毫秒（terminalPortScanMs）。终端里的服务用测试进程同一个 bun 跑小脚本，端口由系统分配（port: 0）后打印出来，
// 不和别的进程抢端口。

/** 不回 HTTP 的监听：有人连上就打印一行标记，回一行不是 HTTP 的字节并断开。 */
const RAW_SCRIPT = `
const listener = Bun.listen({ hostname: '127.0.0.1', port: 0, socket: {
  open(socket) { console.log('probe-raw'); socket.write('nope\\n'); socket.end(); }, data() {},
} });
console.log(\`raw-port=\${listener.port} pid=\${process.pid}\`);
`;
/** HTTP 服务：监听第一个参数给的地址，第二个参数是打印用的名字。 */
const HTTP_SCRIPT = `
const server = Bun.serve({ hostname: process.argv[2], port: 0, fetch: () => new Response('ok') });
console.log(\`http-\${process.argv[3]}=\${server.port} pid=\${process.pid}\`);
`;

/** 等这个终端的状态满足 find：先读一次，不满足就等这次读之后的 workspace.changed 再读。 */
async function stateUntil(k: Kited, workspaceId: string, instanceId: string,
  find: (state: TerminalState | undefined) => boolean, what: string): Promise<TerminalState | undefined> {
  let last: TerminalState | undefined;
  while (true) {
    const since = mark(k);
    last = stateIn(await aggregate(k, workspaceId), instanceId);
    if (find(last)) return last;
    const isAfter = after(k, since);
    await k.waitEvent((e) => e.type === 'workspace.changed' && e.workspaceId === workspaceId && isAfter(e), WAIT_MS)
      .catch(() => { throw new Error(`等待超时：${what}；最后的状态 ${JSON.stringify(last)}`); });
  }
}

/** 只记转发的组网：每次 forward 收到的端口集合按顺序记下；kited 别处还会读组网状态，给一个没启用的。 */
class Forwards {
  readonly values: number[][] = [];
  private readonly waiters = new Set<() => void>();
  readonly network = {
    status: (): NetworkStatus => ({ enabled: false, state: 'Stopped' }),
    forward: (ports: number[]) => {
      this.values.push([...ports].sort((a, b) => a - b));
      for (const waiter of [...this.waiters]) waiter();
    },
  } as unknown as Network;

  /** 下标，配合 exactly 只看这之后的转发。 */
  mark = () => this.values.length;

  /** 等 from 之后的某次转发正好是这组端口（与顺序无关）。 */
  exactly(ports: number[], from: number): Promise<void> {
    const want = [...ports].sort((a, b) => a - b).join();
    const hit = () => this.values.slice(from).some((got) => got.join() === want);
    if (hit()) return Promise.resolve();
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.waiters.delete(check);
        reject(new Error(`等待超时：转发 [${want}]；第 ${from} 次起收到 ${JSON.stringify(this.values.slice(from))}`));
      }, WAIT_MS);
      const check = () => {
        if (!hit()) return;
        clearTimeout(timer);
        this.waiters.delete(check);
        resolve();
      };
      this.waiters.add(check);
    });
  }
}

/*
 * 运行时与系统工具：端口来自 macOS 的 `ps -Ao pid=,ppid=`（进程树）和 `lsof -nP -iTCP -sTCP:LISTEN -Fpn`（监听）的真实输出；
 * 交互式 sh 的后台任务开了作业控制，不在 shell 的进程组里，要按父子关系找；`sh -c '…; :'` 不 exec，bun 是终端 shell 的孙进程。
 * lsof 把 IPv6 的监听写成 `[::1]:端口`，只监听 ::1 的服务连 127.0.0.1 不通，要再试 ::1 才认得出 HTTP。
 * 测试进程自己（kited 的接口端口）在监听，但不在任何终端的进程树里，不算也不转发。
 * 配合：两个终端各自的扫描、实例状态与本机整组转发几处共用端口集合；一个终端结束只去掉它自己的端口。
 */
test('终端从进程树找出监听端口并认出 HTTP，本机端口整组转发；terminal.stop 返回时终端已结束、记为在界面上停止，端口从状态和转发里去掉', async () => {
  const k = startKited(undefined, false, { terminalShell, terminalPortScanMs: 50 });
  const devices: Device[] = [];
  const pids: number[] = [];
  try {
    // 换上只记转发的组网，换上时就按当前集合转发一次。
    const forwards = new Forwards();
    k.daemon.kite.listening({ url: k.url, network: forwards.network });
    expect(forwards.values).toEqual([[]]);
    const ownPort = Number(new URL(k.url).port);
    const machineId = (await machine(k.url)).id;
    const workspaceId = (await folderWorkspace(k, newDir(k.root, 'project', { 'README.md': '网页\n' }))).workspace.id;
    const raw = join(k.root, 'raw.js');
    const http = join(k.root, 'http.js');
    writeFileSync(raw, RAW_SCRIPT);
    writeFileSync(http, HTTP_SCRIPT);
    const bun = process.execPath;

    const open = async () => {
      const instanceId = crypto.randomUUID();
      const opened = await k.call('POST', `/workspaces/${workspaceId}/instances`, { id: instanceId, definitionId: terminalDefinitionId });
      expect(opened.status).toBe(200);
      const device = new Device(k.url, machineId, instanceId);
      devices.push(device);
      await device.snapshot();
      return { instanceId, device };
    };
    const stop = async (instanceId: string) => {
      const stopped = await k.call('POST', `/workspaces/${workspaceId}/operations/terminal.stop`, { operationId: crypto.randomUUID(), instanceId });
      expect(stopped.status).toBe(200);
    };

    const first = await open();
    const second = await open();
    // 第二个终端：只监听 ::1 的 HTTP 服务，是 shell 的子进程。
    second.device.type(`'${bun}' '${http}' ::1 v6 &\n`);
    // 第一个终端：先起不回 HTTP 的监听（孙进程），等 kited 连过它一次，再起 127.0.0.1 上的 HTTP 服务；
    // 这样认出 HTTP 服务时，不回 HTTP 的那个早已试过，它的 http 为 false 不是因为还没试。
    first.device.type(`sh -c '"$0" "$1"; :' '${bun}' '${raw}' &\n`);
    const rawMatch = await first.device.match(/raw-port=(\d+) pid=(\d+)/);
    const rawPort = Number(rawMatch[1]);
    pids.push(Number(rawMatch[2]));
    await first.device.match(/probe-raw/);
    first.device.type(`'${bun}' '${http}' 127.0.0.1 v4 &\n`);
    const v4Match = await first.device.match(/http-v4=(\d+) pid=(\d+)/);
    const v4Port = Number(v4Match[1]);
    pids.push(Number(v4Match[2]));
    const v6Match = await second.device.match(/http-v6=(\d+) pid=(\d+)/);
    const v6Port = Number(v6Match[1]);
    pids.push(Number(v6Match[2]));

    const firstPorts = [{ port: rawPort, http: false }, { port: v4Port, http: true }].sort((a, b) => a.port - b.port);
    const portsAre = (want: TerminalState['ports']) => (state: TerminalState | undefined) =>
      JSON.stringify(state?.ports) === JSON.stringify(want);
    await stateUntil(k, workspaceId, first.instanceId, portsAre(firstPorts), '第一个终端的两个端口，HTTP 服务认出为 http');
    await stateUntil(k, workspaceId, second.instanceId, portsAre([{ port: v6Port, http: true }]), '第二个终端只监听 ::1 的 HTTP 服务');
    await forwards.exactly([rawPort, v4Port, v6Port], 0);
    expect(forwards.values.some((ports) => ports.includes(ownPort))).toBe(false);

    // 一个终端停下只去掉它自己的端口，另一个的照常转发
    // 运行时与配合：停止给进程组发 SIGHUP，交互式 sh 收到就退出；操作要等进程退出才返回。
    let since = forwards.mark();
    await stop(second.instanceId);
    await forwards.exactly([rawPort, v4Port], since);
    expect(stateIn(await aggregate(k, workspaceId), first.instanceId)?.ports).toEqual(firstPorts);

    since = forwards.mark();
    await stop(first.instanceId);
    await forwards.exactly([], since);
  } finally {
    for (const device of devices) device.close();
    // 测试中途失败时终端可能没停，后台任务留着，按 pid 清掉。
    for (const pid of pids) { try { process.kill(pid, 'SIGKILL'); } catch { /* 已经停了 */ } }
    await k.stop();
  }
}, 5_000);

/** ps 读进程的进程组和状态；进程不在了返回 undefined。 */
function processInfo(pid: number): { pgid: number; stat: string } | undefined {
  const r = Bun.spawnSync(['ps', '-o', 'pgid=,stat=', '-p', String(pid)], { env: ENV(), stdout: 'pipe', stderr: 'pipe' });
  const [pgid, stat] = r.stdout.toString().trim().split(/\s+/);
  return pgid && stat ? { pgid: Number(pgid), stat } : undefined;
}

/*
 * 真实 bug：交互式 shell 开着作业控制，每个后台作业各在自己的进程组；停止终端原来只对 shell 自己的进程组发信号，
 * shell 退出、状态记为 exited，忽略 SIGHUP 的后台作业却还活着。
 * 依赖的运行时行为：sh 在 PTY 上交互运行时开作业控制，& 起的作业在独立的进程组（下面先核对这一点，不成立时这个测试测不出 bug）；
 * nohup 让 sleep 忽略 SIGHUP，shell 收到 SIGHUP 时转发给作业也带不走它。被杀的作业在父进程收走前是僵尸（ps 状态含 Z），算已结束。
 */
test('停止终端时，shell 用作业控制放进别的进程组、忽略 SIGHUP 的后台作业也一起结束', async () => {
  const k = startKited(undefined, false, { terminalShell });
  // sleep 的参数带上本次的随机数，清理时按命令行找它，不按可能被复用的 pid。
  const marker = `3001.${crypto.getRandomValues(new Uint32Array(1))[0]}`;
  let device: Device | undefined;
  try {
    const machineId = (await machine(k.url)).id;
    const workspaceId = await workspaceOf(k);
    const { instanceId } = await openTerminal(k, workspaceId);
    device = new Device(k.url, machineId, instanceId);
    await device.snapshot();
    device.type(`nohup sleep ${marker} >/dev/null 2>&1 & echo shell=$$ job=$!\n`);
    const ids = await device.match(/shell=(\d+) job=(\d+)/);
    const shell = Number(ids[1]);
    const job = Number(ids[2]);
    const jobBefore = processInfo(job);
    expect(jobBefore?.stat).not.toContain('Z');
    expect(jobBefore?.pgid).not.toBe(processInfo(shell)?.pgid);

    const stopped = await k.call('POST', `/workspaces/${workspaceId}/operations/terminal.stop`, { operationId: crypto.randomUUID(), instanceId });
    expect(stopped.status).toBe(200);
    const left = processInfo(job);
    expect(left && !left.stat.includes('Z') ? `仍在运行，状态 ${left.stat}` : '已结束').toBe('已结束');
  } finally {
    device?.close();
    Bun.spawnSync(['pkill', '-KILL', '-f', `^sleep ${marker}$`], { env: ENV() });
    await k.stop();
  }
}, 5_000);

// ---- 代理的长命令转到后台终端 ----
// 前两个测试直接调 localTools，接管方是测试里的替身；最后一个在本进程起 kited，接管方是终端服务，模型换成 ManualModel。
// 命令何时结束由测试控制：单元测试用 fifo（测试先以读写方式打开，sh 打开读端不会卡住，写一行它才读到）；
// kited 里的命令跑在 git 工作区里，不往那里放 fifo，改成等文件出现。

const temp = useTemp();
type Tools = ReturnType<typeof localTools>;

/** 接管方替身：记下每条转到后台的命令，heard 是转后台之前的输出加上之后陆续收到的；fire 模拟用户发来一条消息。 */
function backgroundHost() {
  const listeners = new Set<() => void>();
  const adopted: Array<{ command: BackgroundCommand; heard: Seen<string> }> = [];
  const host: ShellBackground = {
    interjected(listener) {
      listeners.add(listener);
      return () => { listeners.delete(listener); };
    },
    adopt(command) {
      const heard = new Seen<string>();
      let text = command.output;
      heard.add(text);
      command.listen((chunk) => { text += chunk; heard.add(text); });
      adopted.push({ command, heard });
      return `接管说明 ${adopted.length}`;
    },
  };
  return { host, listeners, adopted, fire: () => { for (const listener of [...listeners]) listener(); } };
}

function shellTool(tools: Tools) {
  const tool = tools.find((candidate) => candidate.name === 'shell');
  if (!tool) throw new Error('缺少 shell 工具');
  return tool;
}

/** 建 fifo 并以读写方式打开：sh 打开读端时立刻有写端，不卡在 open 上；写进去的行留在管道里等它读。 */
function fifo(root: string, name: string): { fd: number; release(line: string): void } {
  const path = join(root, name);
  expect(Bun.spawnSync(['mkfifo', path], { env: ENV() }).exitCode).toBe(0);
  const fd = openSync(path, 'r+');
  return { fd, release: (line) => { writeSync(fd, `${line}\n`); } };
}

/** 失败时别把进程留下：还在跑的转后台命令停掉并等它结束。 */
async function cleanup(adopted: ReturnType<typeof backgroundHost>['adopted'], fds: number[]) {
  for (const { command } of adopted) {
    if (processGroupAlive(command.pid)) command.stop('测试结束');
  }
  await Promise.all(adopted.map(({ command }) => command.done.catch(() => undefined)));
  for (const fd of fds) closeSync(fd);
}

/*
 * 几个部分的配合：runCommand 里进程结束与超时竞速，超时一方赢了不停进程，把它从这次调用上摘下交给接管方；
 * 打断信号要随之解绑，进程登记交出去，进程真正退出后才收尾日志并给出 done。
 * 依赖 sh：read 卡在 fifo 上，测试写一行才往下走并以 exit 4 退出。
 */
test('shell 到 timeout_ms 还没结束时转到后台：工具立刻成功返回并交出进程登记，之后打断这次调用不停进程，后续输出写进日志并交给接管方，done 给出退出码', async () => {
  const root = temp('shell-timeout-');
  const go = fifo(root, 'go');
  const { host, adopted } = backgroundHost();
  const processes: Array<[number, boolean]> = [];
  const tools = localTools({
    cwd: root, logDir: join(root, 'logs'), env: ENV(), background: host,
    onProcess(pid, active) { processes.push([pid, active]); },
  });
  const controller = new AbortController();
  try {
    const args: Json = { description: '等发布', command: 'read x < go; printf \'after-%s\\n\' "$x"; exit 4', timeout_ms: 50 };
    const tool = shellTool(tools);
    tool.validate(args);
    const result = await tool.execute(args, { cwd: root, signal: controller.signal, callId: 'call-1', turnId: 'turn-1' });
    expect(result.status).toBe('success');
    expect(result.output).toMatch(/^命令在 \S+ (毫)?秒内没有结束，已转到后台接着运行。/);
    expect(result.output).toContain('接管说明 1');
    expect(adopted).toHaveLength(1);
    const { command, heard } = adopted[0]!;
    expect(processGroupAlive(command.pid)).toBe(true);
    expect(processes).toEqual([[command.pid, true], [command.pid, false]]);

    controller.abort();
    go.release('go');
    expect(await command.done).toEqual({ code: 4 });
    await heard.wait((text) => text.includes('after-go'));
    expect(readFileSync(command.log, 'utf8')).toContain('after-go');
    expect(processGroupAlive(command.pid)).toBe(false);
  } finally {
    controller.abort();
    await cleanup(adopted, [go.fd]);
  }
}, 1_000);

/*
 * 几个部分的配合：插话订阅只在这次命令运行期间有效，触发时与进程结束竞速；background: true 不等就交出去。
 * 依赖 sh：后台的 sleep 与 sh 同在一个进程组（非交互 sh 不开作业控制），stop 停整个组时它也要停下。
 */
test('background: true 一开始就转后台，stop 停下整个进程组；运行中用户发来消息时转后台，转之前的输出交给接管方，交出后不再订阅插话', async () => {
  const root = temp('shell-interject-');
  const go = fifo(root, 'go');
  const { host, listeners, adopted, fire } = backgroundHost();
  const tools = localTools({ cwd: root, logDir: join(root, 'logs'), env: ENV(), background: host });
  const tool = shellTool(tools);
  const run = (args: Json, output?: (text: string) => void): Promise<ToolResult> => {
    tool.validate(args);
    return tool.execute(args, { cwd: root, signal: new AbortController().signal, ...(output ? { output } : {}) });
  };
  try {
    const server = await run({ description: '起服务', command: 'sleep 30 & echo ready; wait', background: true });
    expect(server.status).toBe('success');
    expect(server.output).toStartWith('命令已在后台运行。');
    expect(server.output).toContain('接管说明 1');
    const serving = adopted[0]!;
    await serving.heard.wait((text) => text.includes('ready'));
    serving.command.stop('测试停下');
    expect(await serving.command.done).toMatchObject({ stopped: '测试停下' });
    expect(processGroupAlive(serving.command.pid)).toBe(false);

    const early = new Seen<string>();
    let seen = '';
    const waiting = run({ description: '等构建', command: "printf 'early\\n'; read x < go; printf 'late\\n'" },
      (text) => { seen += text; early.add(seen); });
    await early.wait((text) => text.includes('early'));
    fire();
    const interjected = await waiting;
    expect(interjected.status).toBe('success');
    expect(interjected.output).toStartWith('用户发来了新消息，命令转到后台接着运行，没有停下。');
    expect(interjected.output).toContain('接管说明 2');
    const building = adopted[1]!;
    expect(building.command.output).toContain('early');
    // 交出去的命令不再订阅插话：还在后台跑时再来一条消息，不会再转一次。
    expect(listeners.size).toBe(0);
    fire();
    expect(adopted).toHaveLength(2);
    go.release('go');
    expect(await building.command.done).toEqual({ code: 0 });
    await building.heard.wait((text) => text.includes('late'));
  } finally {
    await cleanup(adopted, [go.fd]);
  }
}, 1_000);

let kited: Kited | undefined;
afterEach(async () => { await kited?.stop(); kited = undefined; });

const calledItem = (id: string, name: string, args: Json): ModelItem => ({ ...item(id, name), call: { id, name, arguments: args } });
const resultOf = (request: ModelRequest, callId: string): ToolResult => {
  const found = request.history.find((entry) => entry.type === 'tool_result' && entry.callId === callId);
  if (found?.type !== 'tool_result') throw new Error(`缺少工具结果：${callId}`);
  return found.result;
};
const inputsOf = (request: ModelRequest): Input[] => request.history.flatMap((entry) => entry.type === 'input' ? [entry.input] : []);

/*
 * 几个部分的配合：用户消息经宿主触发插话，shell 转后台交给终端服务；终端服务在工作区控制队列里建没有窗口的实例，
 * origin 是这个代理，代理凭默认授权读得到它；命令退出后在控制队列里记结束、给代理投 Kite 来源的输入并唤醒空闲的代理，
 * 随后回收实例。命令还在跑时线程宿主不再登记它的进程，代理照常空闲，但不能改执行授权。
 */
test('代理的 shell 运行中用户发来消息：命令转到没有窗口、origin 是这个代理的终端，消息随工具结果送到模型，terminal_read 读得到输出，运行中改执行授权被拒；命令结束后代理被含退出码和输出末尾的 Kite 输入唤醒，终端回收', async () => {
  const model = new ManualModel();
  const k = startKited(() => model);
  kited = k;
  const registered = await folderWorkspace(k, newDir(k.root, 'project', { 'a.txt': 'a\n' }));
  const workspaceId = registered.workspace.id;
  const cwd = registered.workspace.cwd;
  const started = await k.call('POST', `/workspaces/${workspaceId}/operations/agent.start`, { operationId: 'agent' });
  expect(started.status).toBe(200);
  const agentId = started.body.instanceId as string;
  expect((await k.call('POST', `/threads/${agentId}/messages`, { id: 'kickoff', text: '跑一下构建' })).status).toBe(200);

  const first = await model.call(1);
  expect(first.request.allowedTools).toEqual(expect.arrayContaining(['shell', 'terminal_read', 'terminal_stop']));
  const command = "printf '开始\\n'; : > started; while [ ! -e go ]; do sleep 0.02; done; printf '结束了\\n'; exit 3";
  await first.response.emit({ type: 'item', item: calledItem('build', 'shell', { description: '等构建', command }) });
  first.response.complete();
  await until(() => existsSync(join(cwd, 'started')), '命令开始运行', 900);
  expect((await k.call('POST', `/threads/${agentId}/messages`, { id: 'aside', text: '顺便看看日志' })).status).toBe(200);

  const second = await model.call(2);
  const moved = resultOf(second.request, 'build');
  expect(moved.status).toBe('success');
  expect(moved.output).toStartWith('用户发来了新消息，命令转到后台接着运行，没有停下。');
  expect(inputsOf(second.request).map((input) => input.text)).toContain('顺便看看日志');
  const terminal = k.daemon.kite.store.instances(workspaceId)
    .find((instance) => instance.definitionId === terminalDefinitionId);
  if (!terminal) throw new Error('工作区里没有接管命令的终端');
  expect(moved.output).toContain(`后台终端的实例 ID 是 ${terminal.id}`);
  expect(terminal.origin).toMatchObject({ instanceId: agentId });
  expect(terminal.config.terminal).toEqual({ command, log: expect.any(String) });
  expect(terminalState(terminal)).toMatchObject({ phase: 'running' });
  const aggregate = (await k.call('GET', `/workspaces/${workspaceId}`)).body as WorkspaceModel;
  expect(aggregate.instances.map((instance) => instance.id)).toContain(terminal.id);

  // 输出经 kited 读管道再写日志，等日志里有了再读，免得和写入赛跑。
  const log = (terminal.config.terminal as { log: string }).log;
  await until(() => existsSync(log) && readFileSync(log, 'utf8').includes('开始'), '日志里有转后台之前的输出', 900);
  await second.response.emit({ type: 'item', item: calledItem('peek', 'terminal_read', { instanceId: terminal.id }) });
  second.response.complete();
  const third = await model.call(3);
  const peek = resultOf(third.request, 'peek');
  expect(peek.status).toBe('success');
  const read = JSON.parse(peek.output) as { phase: string; text: string };
  expect(read.phase).toBe('running');
  expect(read.text).toContain('开始');
  let since = mark(k);
  third.response.complete();
  await waitIdle(k, agentId, since);

  // 代理空闲而命令还在跑：线程宿主的进程登记里已没有它；改执行授权被拒。
  expect(JSON.parse(readFileSync(join(k.home, 'sessions', agentId, 'processes.json'), 'utf8'))).toEqual([]);
  const grants = await k.call('GET', `/instances/${agentId}/execution-grants`);
  expect(grants.status).toBe(200);
  const rejected = await k.call('PUT', `/instances/${agentId}/execution-grants`, {
    expectedRevision: grants.body.revision, grants: { workspace: 'read', add: { read: [], write: [], network: [], unsandboxed: [] }, remove: { read: [], write: [], network: [], unsandboxed: [] } },
  });
  expect(rejected.status).toBe(409);
  expect(JSON.stringify(rejected.body)).toContain('这个代理转到后台的命令还在运行，请先停下再修改执行授权');

  since = mark(k);
  writeFileSync(join(cwd, 'go'), '');
  const woke = await model.call(4);
  const notice = inputsOf(woke.request).at(-1)!;
  expect(notice.source).toBe('kite');
  expect(notice.text).toContain('结束了');
  await until(() => !k.daemon.kite.store.instance(terminal.id), '没有窗口的终端在命令结束后回收', 900);
  woke.response.complete();
  await waitIdle(k, agentId, since);
}, 1_000);
