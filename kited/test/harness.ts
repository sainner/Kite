/**
 * 在本进程里起一个 kited（startDaemon），KITE_HOME 是临时目录；Claude Code 指向 setup.ts 起的假端点。
 * 账号级数据（项目登记、凭据、资源库）在工作机之间同步：几台 kited 要互相看到时用 connect 让它们互为组网对端，
 * 要等的数据用 synced 等。没有远程的项目以各工作机的检出互为远程，别的工作机按目录摘要找到有检出的那台，见 registerBeforeStart。
 * 需要有远程的项目时用 fake-git.ts 的 Git 平台替身。
 * 另有 spawnKited：按路径起 kited 子进程，供进程被杀和启动时环境隔离的测试使用。
 */
import { rmSync } from 'node:fs';
import { join } from 'node:path';
import { startDaemon, type Daemon } from '../src/daemon.ts';
import type { Envelope } from '../src/events.ts';
import type { AgentDefinition } from '../src/agents/definition.ts';
import type { Model } from '../src/harness/types.ts';
import type { Candidate } from '../src/account-data/directory.ts';
import type { Machine, Thread, ThreadContext, WorkspaceModel } from '../src/model.ts';
import type { Role } from '../src/roles.ts';
import type { RuntimeOptions } from '../src/runtime.ts';
import type { Snapshot } from '../src/workspace/snapshots.ts';
import { api } from './setup.ts';
import { makeTemp, writeFiles } from './util.ts';

export { api };

export interface Kited {
  /** 这个 kited 的临时根目录：KITE_HOME 在 root/kite，项目文件夹建在 root 下。 */
  root: string;
  home: string;
  url: string;
  daemon: Daemon;
  /** 组网里的对端（RuntimeOptions.directory 的 candidates），由 connect 填写。 */
  candidates: Candidate[];
  /** 收到的内部事件，按发生顺序。 */
  events: Envelope[];
  call(method: string, path: string, body?: unknown): Promise<{ status: number; body: any }>;
  /** 等满足条件的事件（已收到的也算）。 */
  waitEvent(pred: (e: Envelope) => boolean, timeoutMs?: number): Promise<Envelope>;
  /** 停掉 kited 但留着临时目录，之后用 startKited 的 root 选项在同一数据目录上重启；停过的再 stop 只删目录。 */
  halt(): Promise<void>;
  /** 放行假端点上挂着的请求，停掉 kited，删掉临时目录。 */
  stop(): Promise<void>;
}

/** 读 /machine 里这台工作机的持久身份，与工作区聚合里的 machine 同形；/machine 另带的 version 不在其中。 */
export async function machine(url: string): Promise<Machine> {
  const response = await fetch(url + '/machine');
  if (response.status !== 200) throw new Error(`读取工作机失败：${response.status}`);
  const { id, name, createdAt } = await response.json() as Machine;
  return { id, name, createdAt };
}

export async function call(
  url: string, method: string, path: string, body?: unknown, machineId?: string | Promise<string>,
): Promise<{ status: number; body: any }> {
  const headers: Record<string, string> = {};
  if (path !== '/machine') headers['X-Kite-Machine'] = machineId === undefined ? (await machine(url)).id : await machineId;
  if (body !== undefined) headers['content-type'] = 'application/json';
  const r = await fetch(url + path, {
    method,
    headers,
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  return { status: r.status, body: await r.json() };
}

export interface KitedOptions extends Pick<RuntimeOptions, 'peers' | 'monitorWakeDelayMs' | 'catalogDelayMs' | 'terminalShell' | 'terminalPortScanMs' | 'install'> {
  /** 用已有的临时根目录（数据目录沿用 root/kite），停止时同样删掉；见 registerBeforeStart。 */
  root?: string;
}

/**
 * peers.directory 替换 Line 看到的工作机目录：同一进程里的几台 kited 直接按各自的监听地址互相访问（Line 的跨机调用），不经 kite-net。
 * 组网对端一律换成 candidates（起初为空，见 connect），发现与同步也直接访问对方的监听地址。
 * monitorWakeDelayMs 缩短 monitor 从事件到唤醒的合批等待，观察唤醒的测试不必真等默认的 1 秒；
 * catalogDelayMs 缩短本机检出与工作区变化写进目录摘要的合批等待，别的工作机要看到这些变化的测试不必等 1 秒。
 * terminalShell 换掉终端插件起的 shell，测试用 /bin/sh，不起用户的登录 shell（慢，还带个人配置）。
 * terminalPortScanMs 缩短终端探测监听端口的间隔，看端口变化的测试不必等默认的 2 秒。
 * install 让它当安装版：安装目录与运行目录由测试建好；通常连换版的钩子（apply）也换掉，不起安装进程，见 test/small/updates.test.ts。
 */
export function startKited(
  model?: (thread: ThreadContext) => Model, lightTasks: RuntimeOptions['lightTasks'] = false,
  { root = makeTemp('kited-'), ...options }: KitedOptions = {},
): Kited {
  const home = join(root, 'kite');
  const candidates: Candidate[] = [];
  const daemon = startDaemon({ home, port: 0, model, lightTasks, directory: { candidates: () => candidates }, ...options });
  let machineId: Promise<string> | undefined;
  const events: Envelope[] = [];
  const waiters: Array<{ pred: (e: Envelope) => boolean; resolve: (e: Envelope) => void }> = [];
  const unsubscribe = daemon.kite.bus.subscribe(undefined, (e) => {
    events.push(e);
    for (const w of [...waiters]) if (w.pred(e)) { waiters.splice(waiters.indexOf(w), 1); w.resolve(e); }
  });
  let halted: Promise<void> | undefined;
  const halt = () => halted ??= (async () => {
    api.releaseAll();
    unsubscribe();
    await daemon.stop();
  })();
  return {
    root, home, daemon, candidates, events,
    url: daemon.url,
    call: (method, path, body) => call(daemon.url, method, path, body, machineId ??= machine(daemon.url).then((value) => value.id)),
    waitEvent(pred, timeoutMs = 3_000) {
      const hit = events.find(pred);
      if (hit) return Promise.resolve(hit);
      return new Promise((resolve, reject) => {
        const w = { pred, resolve: (e: Envelope) => { clearTimeout(t); resolve(e); } };
        const t = setTimeout(() => { waiters.splice(waiters.indexOf(w), 1); reject(new Error('等待事件超时')); }, timeoutMs);
        waiters.push(w);
      });
    },
    halt,
    async stop() {
      try { await halt(); }
      finally { rmSync(root, { recursive: true, force: true }); }
    },
  };
}

/**
 * 在 root（之后交给 startKited 的 root 选项）的数据目录上先登记这些本机文件夹，再停掉，返回各自的根工作区聚合。
 * 工作机的目录摘要（有哪些检出）启动时写一次，之后检出的变化要合并 1 秒才写；别的工作机按这份摘要找有检出的工作机
 * （没有远程的项目从那里 clone 和拉取），先登记再起，测试就不用等这 1 秒。起来以后还要改检出或工作区的，改用 catalogDelayMs: 0。
 */
export async function registerBeforeStart(root: string, paths: string[]): Promise<WorkspaceModel[]> {
  const daemon = startDaemon({ home: join(root, 'kite'), port: 0, lightTasks: false });
  try {
    const models: WorkspaceModel[] = [];
    for (const path of paths) {
      const r = await call(daemon.url, 'POST', '/checkouts', { path });
      if (r.status !== 200) throw new Error(`登记 ${path} 失败：${r.status} ${JSON.stringify(r.body)}`);
      models.push(r.body as WorkspaceModel);
    }
    return models;
  } finally { await daemon.stop(); }
}

/**
 * 让几台 kited 互为组网对端：各自的对端换成其余几台的监听地址，立刻重读一遍（不等 20 秒一次的定时），
 * 读到 /machine 后各自开始从对方拉账号级数据。
 */
export async function connect(...ks: Kited[]): Promise<void> {
  for (const k of ks) k.candidates.splice(0, Infinity, ...ks.filter((other) => other !== k).map((other) => ({ address: other.url, online: true })));
  await Promise.all(ks.map((k) => k.daemon.kite.directory.refresh()));
}

/** 等 k 的账号级数据满足 check（已满足的立即返回）：本机写入或从别的工作机同步来的每次变化后检查一次。 */
export function synced<T>(k: Kited, check: () => T | undefined | null | false, what: string, timeoutMs = 3_000): Promise<T> {
  const now = check();
  if (now) return Promise.resolve(now);
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => { unsubscribe(); reject(new Error(`等待同步超时：${what}`)); }, timeoutMs);
    // check 在 kited 的变化通知里调用，抛错也不能打断通知，转成这里的失败。
    const unsubscribe = k.daemon.kite.accountData.subscribe(() => {
      let value: T | undefined | null | false;
      try { value = check(); } catch (error) {
        clearTimeout(timer);
        unsubscribe();
        reject(error as Error);
        return;
      }
      if (!value) return;
      clearTimeout(timer);
      unsubscribe();
      resolve(value);
    });
  });
}

/** 在 k 的数据目录（home）写一份未过期的 ChatGPT 订阅登录：access_token 是一小时后过期的 JWT。环境检查、还原与换机按它判断自研后端的厂商已登录。 */
export function chatgptLogin(home: string): void {
  const encoded = (value: unknown) => Buffer.from(JSON.stringify(value)).toString('base64url');
  const accessToken = `${encoded({ alg: 'RS256', typ: 'JWT' })}.${encoded({ exp: Math.floor(Date.now() / 1000) + 3600 })}.${encoded('仅测试')}`;
  writeFiles(home, { 'auth/chatgpt/auth.json': JSON.stringify({ auth_mode: 'chatgpt', tokens: { access_token: accessToken, account_id: 'test-account' } }) });
}

// ---- 接口的常用组合 ----

export async function registerCheckout(k: Kited, path: string): Promise<WorkspaceModel> {
  const r = await k.call('POST', '/checkouts', { path });
  if (r.status !== 200) throw new Error(`登记 ${path} 失败：${r.status} ${JSON.stringify(r.body)}`);
  return r.body as WorkspaceModel;
}

/** 原内置 Claude 定义的默认模型；后端由模型推出，传这个模型就得到 Claude 线程。 */
export const claudeModel: AgentDefinition['model'] = { model: 'sonnet', reasoning: 'medium' };

type Request = (method: string, path: string, body?: unknown) => Promise<{ status: number; body: any }>;

/** 默认模型为 Claude 的测试角色，其余照抄内置的工作角色；同样内容重复保存是幂等的。返回选择角色用的 {id, revision}。 */
export async function claudeRole(request: Request): Promise<{ id: string; revision: string }> {
  const catalog = await request('GET', '/roles');
  if (catalog.status !== 200) throw new Error(`取角色失败：${catalog.status} ${JSON.stringify(catalog.body)}`);
  const work = (catalog.body.roles as Array<{ role: Role }>).find((entry) => entry.role.id === 'kite.work');
  if (!work) throw new Error('缺少内置的工作角色');
  const saved = await request('POST', '/roles', { role: { ...work.role, id: 'test.claude', title: 'Claude', model: claudeModel } });
  if (saved.status !== 200) throw new Error(`存 Claude 角色失败：${saved.status} ${JSON.stringify(saved.body)}`);
  return { id: saved.body.role.id, revision: saved.body.revision };
}

/**
 * 打开一个新代理窗口，返回实例 ID。窗口请求只带插件定义，新代理按默认角色建在自研后端；
 * 给出 model 时随即改配置换模型，后端随模型换（传 claudeModel 得到空的 Claude 线程）。
 */
export async function openAgent(request: Request, workspaceId: string, model?: AgentDefinition['model']): Promise<string> {
  const opened = await request('POST', `/workspaces/${workspaceId}/windows`, {
    id: crypto.randomUUID(), content: { kind: 'create', definitionId: 'kite.agent' },
  });
  if (opened.status !== 200) throw new Error(`开代理窗口失败：${opened.status} ${JSON.stringify(opened.body)}`);
  const id = opened.body.target.instanceId as string;
  if (model) {
    const config = await request('GET', `/instances/${id}/agent-config`);
    const changed = await request('PUT', `/instances/${id}/agent-config`, {
      expectedRevision: config.body.revision, agent: { ...config.body.instance.config.agent, model },
    });
    if (changed.status !== 200) throw new Error(`换模型失败：${changed.status} ${JSON.stringify(changed.body)}`);
  }
  return id;
}

/** 新建工作区及首线程；返回线程控制和运行时所需的完整上下文。建工作区只能选角色，Claude 首线程用 claudeRole。 */
export async function createWorkspace(
  k: Kited, checkout: string, prompt: string, runtime: Thread['runtime'] = 'claude',
): Promise<ThreadContext> {
  const role = runtime === 'claude' ? await claudeRole(k.call) : undefined;
  const r = await k.call('POST', '/workspaces', { checkout, prompt, ...(role ? { role } : {}) });
  if (r.status !== 200) throw new Error(`建工作区失败：${r.status} ${JSON.stringify(r.body)}`);
  const thread = (r.body as WorkspaceModel).threads[0];
  if (!thread) throw new Error('建工作区后没有首线程');
  const view = await k.call('GET', `/threads/${thread.instanceId}`);
  if (view.status !== 200) throw new Error(`取线程 ${thread.instanceId} 失败：${view.status} ${JSON.stringify(view.body)}`);
  return view.body as ThreadContext;
}

export async function sendThreadMessage(k: Kited, id: string, text: string): Promise<void> {
  const r = await k.call('POST', `/threads/${id}/messages`, { text });
  if (r.status !== 200) throw new Error(`发消息失败：${r.status} ${JSON.stringify(r.body)}`);
}

export async function listSnapshots(k: Kited, workspaceId: string): Promise<Snapshot[]> {
  const r = await k.call('GET', `/workspaces/${workspaceId}/snapshots`);
  if (r.status !== 200) throw new Error(`取快照失败：${r.status} ${JSON.stringify(r.body)}`);
  return r.body;
}

/** 事件下标，配合 after 判断事件是否发生在某个动作之后。 */
export const mark = (k: Kited) => k.events.length;
export const after = (k: Kited, since: number) => (e: Envelope) => k.events.indexOf(e) >= since;

/** 等 since 之后这个会话的 runner 变为 state。 */
export function waitRunner(k: Kited, id: string, state: string, since = 0, timeoutMs?: number) {
  const isAfter = after(k, since);
  return k.waitEvent((e) => e.type === 'runner' && e.threadId === id && e.state === state && isAfter(e), timeoutMs);
}

/** 等 since 之后这个会话的回合结束。Claude 进程随实例常驻，回合结束时进程不关闭，要等 idle 事件而不是 runner 关闭。 */
export function waitIdle(k: Kited, id: string, since = 0, timeoutMs?: number) {
  const isAfter = after(k, since);
  return k.waitEvent((e) => e.type === 'idle' && e.threadId === id && isAfter(e), timeoutMs);
}

// ---- kited 子进程 ----

export interface KitedProcess {
  url: string;
  pid: number;
  kill(signal: NodeJS.Signals): Promise<void>;
}

/** 按路径起 kited 子进程（bun src/main.ts），等它在标准输出报出地址。 */
export async function spawnKited(home: string): Promise<KitedProcess> {
  const main = join(import.meta.dir, '..', 'src', 'main.ts');
  const proc = Bun.spawn([process.execPath, main], {
    env: { ...(process.env as Record<string, string>), KITE_HOME: home, KITE_PORT: '0' },
    stdout: 'pipe',
    stderr: 'inherit',
  });
  const reader = proc.stdout.getReader();
  try {
    const decoder = new TextDecoder();
    let out = '';
    while (!out.includes('\n')) {
      const { value, done } = await reader.read();
      if (done) throw new Error(`kited 没有启动：${out}`);
      out += decoder.decode(value, { stream: true });
    }
    const m = /http:\/\/127\.0\.0\.1:\d+/.exec(out.split('\n')[0]!);
    if (!m) throw new Error(`kited 第一行输出里没有地址：${out}`);
    // 之后的输出照样读走，免得管道写满卡住 kited；停进程时等待读完。
    const reading = (async () => {
      try { while (!(await reader.read()).done); }
      finally { reader.releaseLock(); }
    })();
    return {
      url: m[0],
      pid: proc.pid,
      async kill(signal) {
        if (proc.exitCode === null) proc.kill(signal);
        await Promise.all([proc.exited, reading]);
      },
    };
  } catch (error) {
    if (proc.exitCode === null) proc.kill('SIGKILL');
    await proc.exited;
    await reader.cancel();
    reader.releaseLock();
    throw error;
  }
}
