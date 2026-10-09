/**
 * 在本进程里起一个 kited（startDaemon），KITE_HOME 是临时目录；Claude Code 指向 setup.ts 起的假端点。
 * 每个 kited 默认接上自己的账号服务替身（fake-account.ts），登记项目要用；模拟同一账号的多台工作机时传入共享的替身。
 * 另有 spawnKited：按路径起 kited 子进程，供进程被杀和启动时环境隔离的测试使用。
 */
import { rmSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { startDaemon, type Daemon } from '../src/daemon.ts';
import type { Envelope } from '../src/events.ts';
import type { AgentDefinition } from '../src/agents/definition.ts';
import type { Model } from '../src/harness/types.ts';
import type { Machine, Thread, ThreadContext, WorkspaceModel } from '../src/model.ts';
import type { Role } from '../src/roles.ts';
import type { RuntimeOptions } from '../src/runtime.ts';
import { type FakeAccount, linkAccount, startFakeAccount } from './fake-account.ts';
import { api } from './setup.ts';
import { makeTemp } from './util.ts';

export { api };

export interface Kited {
  /** 这个 kited 的临时根目录：KITE_HOME 在 root/kite，项目文件夹建在 root 下。 */
  root: string;
  home: string;
  url: string;
  daemon: Daemon;
  /** 这个 kited 加入的账号服务替身。 */
  account: FakeAccount;
  /** 收到的内部事件，按发生顺序。 */
  events: Envelope[];
  call(method: string, path: string, body?: unknown): Promise<{ status: number; body: any }>;
  /** 等满足条件的事件（已收到的也算）。 */
  waitEvent(pred: (e: Envelope) => boolean, timeoutMs?: number): Promise<Envelope>;
  /** 放行假端点上挂着的请求，停掉 kited 和它自己起的账号替身（传入的共享替身由调用方停），删掉临时目录。 */
  stop(): Promise<void>;
}

export async function machine(url: string): Promise<Machine> {
  const response = await fetch(url + '/machine');
  if (response.status !== 200) throw new Error(`读取工作机失败：${response.status}`);
  return await response.json() as Machine;
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

export function startKited(
  model?: (thread: ThreadContext) => Model, lightTasks: RuntimeOptions['lightTasks'] = false, shared?: FakeAccount,
): Kited {
  const root = makeTemp('kited-');
  const home = join(root, 'kite');
  const account = shared ?? startFakeAccount(join(root, 'account'));
  linkAccount(home, account);
  const daemon = startDaemon({ home, port: 0, model, lightTasks });
  let machineId: Promise<string> | undefined;
  const events: Envelope[] = [];
  const waiters: Array<{ pred: (e: Envelope) => boolean; resolve: (e: Envelope) => void }> = [];
  const unsubscribe = daemon.kite.bus.subscribe(undefined, (e) => {
    events.push(e);
    for (const w of [...waiters]) if (w.pred(e)) { waiters.splice(waiters.indexOf(w), 1); w.resolve(e); }
  });
  return {
    root, home, daemon, account, events,
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
    async stop() {
      api.releaseAll();
      unsubscribe();
      try { await daemon.stop(); }
      finally {
        if (!shared) account.stop();
        rmSync(root, { recursive: true, force: true });
      }
    },
  };
}

/** 自己在 home 上 startDaemon 的测试用：新起一个账号替身（数据放在 home 旁边）并让 home 加入它。替身由调用方停。 */
export function linkNewAccount(home: string): FakeAccount {
  const account = startFakeAccount(join(dirname(home), `account-${crypto.randomUUID()}`));
  linkAccount(home, account);
  return account;
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

export async function listSnapshots(k: Kited, workspaceId: string): Promise<Array<{ commit: string; at: number; label: string; toolUseIds: string[] }>> {
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

/** 按路径起 kited 子进程（bun src/main.ts），等它在标准输出报出地址。传入 account 时先让它加入这个账号替身。 */
export async function spawnKited(home: string, account?: FakeAccount): Promise<KitedProcess> {
  if (account) linkAccount(home, account);
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
