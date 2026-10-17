/**
 * 手动合同验证：真实 kited HTTP JSON 能否由 App 的 RemoteWorkspace 解码。
 *
 * 运行：bun kited/test/manual/verify-remote-workspace-swift.ts
 *
 * 不放进 small：它需要编译 Swift；脚本自行生成临时仓库、kited home、JSON fixture 和二进制。
 */
import { mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import type { Candidate } from '../../src/account-data/directory.ts';
import type { RegisteredProject } from '../../src/account-data/registry.ts';
import { startDaemon, type Daemon } from '../../src/daemon.ts';
import type { Envelope } from '../../src/events.ts';
import type { Model } from '../../src/harness/types.ts';
import type { Machine, Project, ThreadContext, WorkspaceModel, WorkspaceWindow } from '../../src/model.ts';
import type { PluginDefinition } from '../../src/plugins/definitions.ts';
import { bunPluginSource } from '../fixtures/bun-plugin-source.ts';
import { newRepo, writeFiles } from '../util.ts';
import { command } from './command.ts';

async function call<T>(url: string, method: string, path: string, body?: unknown, machineId?: string): Promise<{ status: number; body: T; cursor: string | null }> {
  const headers: Record<string, string> = {};
  if (path !== '/machine') {
    if (!machineId) throw new Error(`请求 ${path} 缺少工作机 ID`);
    headers['X-Kite-Machine'] = machineId;
  }
  if (body !== undefined) headers['content-type'] = 'application/json';
  const response = await fetch(url + path, {
    method,
    headers,
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  return { status: response.status, body: await response.json() as T, cursor: response.headers.get('X-Kite-Cursor') };
}

type StreamEvent = { type: string; cursor: string; workspaceId?: string; threadId?: string; status?: string; state?: unknown };

/** 订阅一条 SSE（目录或线程），逐帧读出 data。 */
async function openEvents(url: string, machineId: string, query = '') {
  const controller = new AbortController();
  const response = await fetch(`${url}/events${query}`, {
    headers: { 'X-Kite-Machine': machineId }, signal: controller.signal,
  });
  if (response.status !== 200) throw new Error(`订阅 /events${query} 失败：${response.status}`);
  const reader = response.body!.pipeThrough(new TextDecoderStream()).getReader();
  const deadline = setTimeout(() => controller.abort(), 10_000);
  let buffer = '';
  return {
    async next(): Promise<StreamEvent> {
      while (true) {
        const end = buffer.indexOf('\n\n');
        if (end >= 0) {
          const frame = buffer.slice(0, end);
          buffer = buffer.slice(end + 2);
          const data = frame.split('\n').find((line) => line.startsWith('data: '));
          if (data) return JSON.parse(data.slice(6)) as StreamEvent;
          continue;
        }
        const chunk = await reader.read();
        if (chunk.done) throw new Error(`/events${query} 提前断开`);
        buffer += chunk.value;
      }
    },
    async close() { clearTimeout(deadline); controller.abort(); await reader.cancel().catch(() => {}); },
  };
}

function cursor(raw: string | null): string {
  if (!raw || !/^[0-9a-f-]{36}:\d+$/i.test(raw)) throw new Error(`无效目录游标：${raw}`);
  return raw;
}

/** 收这台 kited 的内部事件，按条件等（已收到的也算）。 */
function watch(daemon: Daemon) {
  const events: Envelope[] = [];
  const waiters: Array<{ predicate: (event: Envelope) => boolean; resolve: () => void }> = [];
  const unsubscribe = daemon.kite.bus.subscribe(undefined, (event) => {
    events.push(event);
    for (const waiter of [...waiters]) if (waiter.predicate(event)) {
      waiters.splice(waiters.indexOf(waiter), 1);
      waiter.resolve();
    }
  });
  const wait = (predicate: (event: Envelope) => boolean, what: string) => {
    if (events.some(predicate)) return Promise.resolve();
    return new Promise<void>((resolve, reject) => {
      const timer = setTimeout(() => { waiters.splice(waiters.indexOf(waiter), 1); reject(new Error(`等待超时：${what}`)); }, 10_000);
      const waiter = { predicate, resolve: () => { clearTimeout(timer); resolve(); } };
      waiters.push(waiter);
    });
  };
  return { wait, unsubscribe };
}

/** 等这台 kited 的账号级数据（本机写入或从别的工作机同步来的）满足 check。 */
function synced(daemon: Daemon, check: () => boolean, what: string): Promise<void> {
  if (check()) return Promise.resolve();
  return new Promise<void>((resolve, reject) => {
    const timer = setTimeout(() => { unsubscribe(); reject(new Error(`等待同步超时：${what}`)); }, 10_000);
    const unsubscribe = daemon.kite.accountData.subscribe(() => {
      if (!check()) return;
      clearTimeout(timer);
      unsubscribe();
      resolve();
    });
  });
}

/** 建工作区前 kited 按默认角色的模型检查厂商已登录：写一份一小时后过期的 ChatGPT 订阅登录（同 test/harness.ts 的 chatgptLogin）。 */
function chatgptLogin(home: string): void {
  const encoded = (value: unknown) => Buffer.from(JSON.stringify(value)).toString('base64url');
  const accessToken = `${encoded({ alg: 'RS256', typ: 'JWT' })}.${encoded({ exp: Math.floor(Date.now() / 1000) + 3600 })}.${encoded('仅合同')}`;
  writeFiles(home, { 'auth/chatgpt/auth.json': JSON.stringify({ auth_mode: 'chatgpt', tokens: { access_token: accessToken, account_id: 'contract-account' } }) });
}

/** 发这条首条消息的线程第一次请求就用 credentials 的请求动作要一个密钥，回合停在这次调用上等用户填写；其余线程直接完成。 */
const SECRET_PROMPT = '要一个密钥';
const SECRET_CALL = 'secret-request';
const model: Model = {
  async *stream(request) {
    const asked = request.history.some((entry) => entry.type === 'input' && entry.input.text === SECRET_PROMPT);
    const answered = request.history.some((entry) => entry.type === 'tool_result' && entry.callId === SECRET_CALL);
    if (asked && !answered) {
      yield { type: 'item', item: { id: SECRET_CALL, raw: { type: 'function_call' }, call: { id: SECRET_CALL, name: 'credentials',
        arguments: { request: { name: 'STRIPE_KEY', reason: '调支付接口', kind: 'file', value: 'sk_test_prefilled' } } } } };
    }
    yield { type: 'completed', responseId: 'fixture' };
  },
};

// 编译真实 JSON Codable 声明，不在合同里复制解码规则。
function declaration(source: string, signature: string): string {
  const start = source.indexOf(signature);
  if (start < 0 || source.indexOf(signature, start + 1) >= 0) throw new Error(`Swift 声明不唯一：${signature}`);
  const open = source.indexOf('{', start);
  let depth = 0;
  for (let index = open; index < source.length; index++) {
    if (source[index] === '{') depth++;
    if (source[index] === '}' && --depth === 0) return source.slice(start, index + 1);
  }
  throw new Error(`Swift 声明未闭合：${signature}`);
}

async function main() {
  const root = mkdtempSync(join(tmpdir(), 'swift-workspace-contract-'));
  const home = join(root, 'kite');
  // 被忽略的 .env 不进提交，添加前的检查把它列为可存成项目密钥的环境变量文件。
  const repository = newRepo(root, 'project', { 'base.txt': '原始\n', '.gitignore': '.env\n', '.env': 'PORT=3000\n' }, null);
  // 两台工作机互为组网对端：项目登记与目录摘要随账号级数据同步，第二台为没有远程的项目建工作区时从第一台的检出 clone，得到同一项目。
  const otherHome = join(root, 'other-kite');
  chatgptLogin(home);
  chatgptLogin(otherHome);
  const peers: { self: Candidate[]; other: Candidate[] } = { self: [], other: [] };
  // catalogDelayMs: 0 让检出变化立即写进目录摘要，第二台不必等 1 秒的合批才知道从哪台 clone。
  const daemon = startDaemon({ home, port: 0, lightTasks: false, catalogDelayMs: 0, model: () => model,
    directory: { candidates: () => peers.self } });
  const otherDaemon = startDaemon({ home: otherHome, port: 0, lightTasks: false, catalogDelayMs: 0, model: () => model,
    directory: { candidates: () => peers.other } });
  peers.self.push({ address: otherDaemon.url, online: true });
  peers.other.push({ address: daemon.url, online: true });
  await Promise.all([daemon.kite.directory.refresh(), otherDaemon.kite.directory.refresh()]);
  const local = watch(daemon);
  const remote = watch(otherDaemon);
  const opened = (target: ReturnType<typeof watch>, workspaceId: string) => target.wait((event) =>
    event.type === 'workspace.changed' && event.workspaceId === workspaceId && event.status === 'open', `工作区 ${workspaceId} 准备完`);
  let catalog: Awaited<ReturnType<typeof openEvents>> | undefined;
  try {
    const machine = await call<Machine>(daemon.url, 'GET', '/machine');
    if (machine.status !== 200) throw new Error(`读取工作机失败：${machine.status}`);
    const definitions = await call<PluginDefinition[]>(daemon.url, 'GET', '/plugin-definitions', undefined, machine.body.id);
    if (definitions.status !== 200) throw new Error(`读取插件定义失败：${definitions.status}`);
    const filesDefinition = definitions.body.find((definition) => definition.id === 'kite.files');
    if (!filesDefinition || filesDefinition.defaultView !== 'files'
      || filesDefinition.views.length !== 1 || filesDefinition.views[0]?.id !== 'files') {
      throw new Error(`文件插件未统一为 files 单视图：${JSON.stringify(definitions.body)}`);
    }
    const otherMachine = await call<Machine>(otherDaemon.url, 'GET', '/machine');
    if (otherMachine.status !== 200 || otherMachine.body.id === machine.body.id) throw new Error('第二个 home 未提供独立工作机身份');
    const checked = await call<unknown>(daemon.url, 'POST', '/project-registry/check', { path: repository }, machine.body.id);
    if (checked.status !== 200) throw new Error(`添加项目前的检查失败：${checked.status} ${JSON.stringify(checked.body)}`);
    const project = await call<RegisteredProject>(daemon.url, 'POST', '/project-registry', { path: repository }, machine.body.id);
    if (project.status !== 200) throw new Error(`添加项目失败：${project.status} ${JSON.stringify(project.body)}`);
    const projectId = project.body.id;
    // 第二台要同步到项目登记，并从第一台的目录摘要里看到这份检出，才知道从哪台 clone。
    await synced(otherDaemon, () => !!otherDaemon.kite.registry.get(projectId) && otherDaemon.kite.directory.entries()
      .some((entry) => entry.id === machine.body.id && entry.snapshot?.checkouts.some((checkout) => checkout.projectId === projectId)),
    '第二台工作机同步到项目登记和第一台的检出');
    // 同一项目：第二台直接为它建工作区，本机没有检出时从第一台 clone；同名的另一个普通文件夹是另一个没有远程的项目。
    const shared = await call<WorkspaceModel>(otherDaemon.url, 'POST', '/workspaces', { project: projectId }, otherMachine.body.id);
    if (shared.status !== 200) throw new Error(`第二台为同一项目建工作区失败：${shared.status} ${JSON.stringify(shared.body)}`);
    const separate = await call<RegisteredProject>(otherDaemon.url, 'POST', '/project-registry', {
      path: newRepo(join(root, 'remote-separate'), 'project', { 'base.txt': '原始\n' }, null),
    }, otherMachine.body.id);
    if (separate.status !== 200) throw new Error(`第二台添加同名项目失败：${separate.status} ${JSON.stringify(separate.body)}`);
    await opened(remote, shared.body.workspace.id);
    // 第一台的工作机目录（/machines）里要有第二台最近一次的目录摘要，且摘要里已有这个打开的工作区。
    const sharedId = shared.body.workspace.id;
    await synced(daemon, () => daemon.kite.directory.entries().some((entry) => entry.id === otherMachine.body.id
      && entry.snapshot?.workspaces.some((item) => item.id === sharedId && item.status === 'open')),
    '第一台工作机同步到第二台的目录摘要');

    const workspace = await call<WorkspaceModel>(daemon.url, 'POST', '/workspaces', {
      project: projectId, name: '主工作区', prompt: '首线程',
    }, machine.body.id);
    if (workspace.status !== 200) throw new Error(`创建工作区失败：${workspace.status} ${JSON.stringify(workspace.body)}`);
    const firstThread = workspace.body.threads[0];
    if (!firstThread) throw new Error('创建带首条消息的工作区后没有首线程');
    await local.wait((event) => event.type === 'idle' && event.threadId === firstThread.instanceId, '首线程回合结束');

    const secondThread = await call<ThreadContext>(daemon.url, 'POST', `/workspaces/${workspace.body.workspace.id}/threads`, {
      prompt: '第二线程',
    }, machine.body.id);
    if (secondThread.status !== 200) throw new Error(`创建第二线程失败：${secondThread.status}`);
    if (secondThread.body.workspace.cwd !== workspace.body.workspace.cwd) throw new Error('第二线程没有继承工作区 cwd');
    await local.wait((event) => event.type === 'idle' && event.threadId === secondThread.body.id, '第二线程回合结束');

    // 同一项目的另一个工作区：首线程停在密钥请求上，工作区聚合与线程状态都带着这个等待。
    const secretWorkspace = await call<WorkspaceModel>(daemon.url, 'POST', '/workspaces', {
      project: projectId, name: '密钥工作区', prompt: SECRET_PROMPT,
    }, machine.body.id);
    if (secretWorkspace.status !== 200) throw new Error(`创建密钥工作区失败：${secretWorkspace.status} ${JSON.stringify(secretWorkspace.body)}`);
    const secretThread = secretWorkspace.body.threads[0];
    if (!secretThread) throw new Error('密钥工作区没有首线程');
    await local.wait((event) => event.type === 'waiting' && event.threadId === secretThread.instanceId
      && event.waiting?.kind === 'secret', '首线程挂出密钥请求');
    const threadStream = await openEvents(daemon.url, machine.body.id, `?thread=${secretThread.instanceId}`);
    const history = await threadStream.next().finally(() => threadStream.close());
    if (history.type !== 'thread.history') throw new Error(`线程流未先返回历史快照：${history.type}`);

    const mainPlugin = await call<WorkspaceWindow>(daemon.url, 'POST', `/workspaces/${workspace.body.workspace.id}/windows`, {
      id: crypto.randomUUID(), content: { kind: 'create', definitionId: 'kite.files' },
    }, machine.body.id);
    if (mainPlugin.status !== 200 || mainPlugin.body.target.viewId !== 'files') {
      throw new Error(`创建插件主视图失败：${mainPlugin.status} ${JSON.stringify(mainPlugin.body)}`);
    }
    const existingPlugin = await call<WorkspaceWindow>(daemon.url, 'POST', `/workspaces/${workspace.body.workspace.id}/windows`, {
      id: crypto.randomUUID(), content: { kind: 'open', ...mainPlugin.body.target },
    }, machine.body.id);
    if (existingPlugin.status !== 200 || existingPlugin.body.id !== mainPlugin.body.id) {
      throw new Error(`重新打开插件主视图未去重：${existingPlugin.status} ${JSON.stringify(existingPlugin.body)}`);
    }
    const filesPath = `/workspaces/${workspace.body.workspace.id}/operations/`;
    const fileTarget = { instanceId: mainPlugin.body.target.instanceId };
    const directory = await call<unknown>(daemon.url, 'POST', filesPath + 'files.list', fileTarget, machine.body.id);
    const page = await call<unknown>(daemon.url, 'POST', filesPath + 'files.read', {
      ...fileTarget, path: 'base.txt',
    }, machine.body.id);
    const beforeSelection = await call<{ path: string | null; revision: string }>(daemon.url, 'POST',
      filesPath + 'files.state', fileTarget, machine.body.id);
    if (directory.status !== 200 || page.status !== 200 || beforeSelection.status !== 200) {
      throw new Error(`读取文件插件响应失败：${directory.status}/${page.status}/${beforeSelection.status}`);
    }
    const selected = await call<{ path: string | null; revision: string }>(daemon.url, 'POST',
      filesPath + 'files.select', {
        ...fileTarget, operationId: crypto.randomUUID(), expectedRevision: beforeSelection.body.revision, path: 'base.txt',
      }, machine.body.id);
    const afterSelection = await call<unknown>(daemon.url, 'POST', filesPath + 'files.state', fileTarget, machine.body.id);
    if (selected.status !== 200 || afterSelection.status !== 200) {
      throw new Error(`保存文件选择失败：${selected.status}/${afterSelection.status}`);
    }

    // 真实插件 SDK 修改业务状态，再从工作区聚合解码；资源刷新依赖这个 JSON 值而非目录游标。
    const pluginEntry = join(root, 'plugin.ts');
    symlinkSync(join(import.meta.dir, '..', '..', 'node_modules'), join(root, 'node_modules'));
    writeFileSync(pluginEntry, bunPluginSource);
    const built = await Bun.build({ entrypoints: [pluginEntry], target: 'bun', format: 'esm', minify: true });
    if (!built.success || built.outputs.length !== 1) throw new Error(`插件状态 fixture 打包失败：${built.logs.join('\n')}`);
    const installed = await call<unknown>(daemon.url, 'POST', '/plugin-definitions', {
      id: 'custom.decode-state', title: '状态解码合同', bundle: await built.outputs[0]!.text(), lifetime: 'persistent',
    }, machine.body.id);
    const pluginID = crypto.randomUUID();
    const plugin = await call<unknown>(daemon.url, 'POST', `/workspaces/${workspace.body.workspace.id}/plugin-instances`, {
      id: pluginID, definitionId: 'custom.decode-state', title: '状态解码合同',
    }, machine.body.id);
    const incremented = await call<unknown>(daemon.url, 'POST', `/instances/${pluginID}/plugin/tools/state`, {
      operationId: 'decode-state-increment', arguments: { action: 'increment' },
    }, machine.body.id);
    if ([installed.status, plugin.status, incremented.status].some((status) => status !== 200)) {
      throw new Error(`真实插件业务状态未写入合同工作区：${JSON.stringify([installed, plugin, incremented])}`);
    }

    catalog = await openEvents(daemon.url, machine.body.id);
    if ((await catalog.next()).type !== 'catalog.snapshot') throw new Error('目录流未先返回完整快照');
    const workspaces = await call<WorkspaceModel[]>(daemon.url, 'GET', '/workspaces', undefined, machine.body.id);
    if (workspaces.status !== 200) throw new Error(`读取工作区失败：${workspaces.status}`);
    const beforeCursor = cursor(workspaces.cursor);
    const fixture = join(root, 'workspaces.json');
    await Bun.write(fixture, JSON.stringify(workspaces.body));
    const definitionsFixture = join(root, 'plugin-definitions.json');
    await Bun.write(definitionsFixture, JSON.stringify(definitions.body));
    const filesFixture = join(root, 'files.json');
    await Bun.write(filesFixture, JSON.stringify({
      directory: directory.body, page: page.body, before: beforeSelection.body,
      selected: selected.body, after: afterSelection.body,
    }));
    const machineFixture = join(root, 'machine.json');
    await Bun.write(machineFixture, JSON.stringify(machine.body));
    const localProjects = await call<Project[]>(daemon.url, 'GET', '/projects', undefined, machine.body.id);
    const remoteProjects = await call<Project[]>(otherDaemon.url, 'GET', '/projects', undefined, otherMachine.body.id);
    if (localProjects.status !== 200 || remoteProjects.status !== 200) throw new Error('读取项目身份失败');
    const localProjectsFixture = join(root, 'local-projects.json');
    const remoteProjectsFixture = join(root, 'remote-projects.json');
    await Bun.write(localProjectsFixture, JSON.stringify(localProjects.body));
    await Bun.write(remoteProjectsFixture, JSON.stringify(remoteProjects.body));
    // 第二台的登记表里有同步来的共享项目和它自己添加的同名项目。
    const registry = await call<RegisteredProject[]>(otherDaemon.url, 'GET', '/project-registry', undefined, otherMachine.body.id);
    if (registry.status !== 200) throw new Error(`读取项目登记表失败：${registry.status}`);
    const registryFixture = join(root, 'project-registry.json');
    await Bun.write(registryFixture, JSON.stringify({
      check: checked.body, added: project.body, separate: separate.body, registry: registry.body,
    }));
    const machines = await call<unknown>(daemon.url, 'GET', '/machines', undefined, machine.body.id);
    if (machines.status !== 200) throw new Error(`读取工作机目录失败：${machines.status}`);
    const machinesFixture = join(root, 'machines.json');
    await Bun.write(machinesFixture, JSON.stringify({
      machines: machines.body, otherMachine: otherMachine.body.id, sharedWorkspace: sharedId, project: projectId,
    }));
    const secretFixture = join(root, 'secret-state.json');
    await Bun.write(secretFixture, JSON.stringify({ threadId: secretThread.instanceId, state: history.state }));

    const archived = await call<WorkspaceModel>(daemon.url, 'POST', `/workspaces/${workspace.body.workspace.id}/archive`, { force: true }, machine.body.id);
    if (archived.status !== 200) throw new Error(`归档两线程工作区失败：${archived.status}`);
    const changes: StreamEvent[] = [];
    while (true) {
      const event = await catalog.next();
      if (event.workspaceId !== workspace.body.workspace.id) continue;
      changes.push(event);
      if (event.type === 'workspace.changed' && event.status === 'archived') break;
    }
    const archivedThreadIds = changes.filter((event) => event.type === 'thread.changed' && event.status === 'archived')
      .map((event) => event.threadId).sort();
    if (JSON.stringify(archivedThreadIds) !== JSON.stringify([firstThread.instanceId, secondThread.body.id].sort())) {
      throw new Error(`归档通知未覆盖两个线程：${JSON.stringify(changes)}`);
    }
    await catalog.close();
    catalog = undefined;

    const archivedWorkspaces = await call<WorkspaceModel[]>(daemon.url, 'GET', '/workspaces', undefined, machine.body.id);
    if (archivedWorkspaces.status !== 200) throw new Error(`读取归档后工作区失败：${archivedWorkspaces.status}`);
    const archivedFixture = join(root, 'archived-workspaces.json');
    await Bun.write(archivedFixture, JSON.stringify(archivedWorkspaces.body));
    const otherWorkspaces = await call<WorkspaceModel[]>(otherDaemon.url, 'GET', '/workspaces', undefined, otherMachine.body.id);
    if (otherWorkspaces.status !== 200) throw new Error(`读取第二台工作机目录失败：${otherWorkspaces.status}`);
    const cursorsFixture = join(root, 'catalog-cursors.json');
    await Bun.write(cursorsFixture, JSON.stringify({
      before: beforeCursor, after: cursor(archivedWorkspaces.cursor), other: cursor(otherWorkspaces.cursor),
      archived: changes.map((event) => event.cursor),
    }));

    const compiler = await command(['xcrun', '--find', 'swiftc'], root);
    const sdk = await command(['xcrun', '--show-sdk-path'], root);
    const architecture = await command(['uname', '-m'], root);
    const decoder = join(root, 'decode-remote-workspace');
    const app = join(import.meta.dir, '..', '..', '..', 'app', 'Kite');
    const clientSource = readFileSync(join(app, 'Application', 'KitedClient.swift'), 'utf8');
    const clientTypes = join(root, 'KitedClientTypes.swift');
    writeFileSync(clientTypes, `import Foundation\n\n${[
      'extension JSON: Codable', 'nonisolated struct RemoteState', 'nonisolated struct RemoteWaiting', 'nonisolated struct ContextUsage',
    ].map((signature) => declaration(clientSource, signature)).join('\n\n')}\n`);
    // 项目登记表与工作机目录的类型和界面、本机缓存写在一起（GitAccounts.swift 引入 SwiftUI），只取这几个 Codable 声明。
    const accountSource = readFileSync(join(app, 'Application', 'GitAccounts.swift'), 'utf8');
    const catalogSource = readFileSync(join(app, 'Application', 'HostedCatalog.swift'), 'utf8');
    const accountTypes = join(root, 'AccountProjectTypes.swift');
    writeFileSync(accountTypes, `import Foundation\n\n${[
      declaration(accountSource, 'struct AccountProject: Decodable'),
      declaration(accountSource, 'struct ProjectCheck: Decodable'),
      declaration(catalogSource, 'struct ProjectAppearance: Codable'),
      declaration(catalogSource, 'struct CatalogSnapshot: Codable'),
      declaration(catalogSource, 'struct DirectoryMachine: Decodable'),
    ].join('\n\n')}\n`);
    await command([
      compiler,
      '-sdk', sdk,
      '-target', `${architecture}-apple-macosx26.0`,
      join(app, 'Conversation', 'Transcript.swift'), clientTypes, accountTypes,
      join(app, 'Conversation', 'AgentConfiguration.swift'),
      join(app, 'Plugins', 'PluginManagementModels.swift'),
      join(app, 'Application', 'RemoteWorkspace.swift'),
      join(app, 'Application', 'CatalogRefresh.swift'),
      join(import.meta.dir, 'RemoteWorkspaceDecode.swift'),
      '-o', decoder,
    ], root);
    console.log(await command([
      decoder, fixture, machineFixture, localProjectsFixture, remoteProjectsFixture,
      cursorsFixture, archivedFixture, definitionsFixture, filesFixture, registryFixture, secretFixture, machinesFixture,
    ], root));
  } finally {
    await catalog?.close();
    local.unsubscribe();
    remote.unsubscribe();
    await otherDaemon.stop();
    await daemon.stop();
    rmSync(root, { recursive: true, force: true });
  }
}

await main();
