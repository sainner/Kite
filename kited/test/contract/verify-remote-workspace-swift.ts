/**
 * 手动合同验证：真实 kited HTTP JSON 能否由 App 的 RemoteWorkspace 解码。
 *
 * 运行：bun kited/test/contract/verify-remote-workspace-swift.ts
 *
 * 不放进 small：它需要编译 Swift；脚本自行生成临时仓库、kited home、JSON fixture 和二进制。
 */
import { mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { startDaemon } from '../../src/daemon.ts';
import type { Envelope } from '../../src/events.ts';
import type { Model } from '../../src/harness/types.ts';
import type { Machine, Project, ThreadContext, WorkspaceModel, WorkspaceWindow } from '../../src/model.ts';
import type { PluginDefinition } from '../../src/plugins.ts';
import { bunPluginSource } from '../fixtures/bun-plugin-source.ts';
import { newRepo } from '../util.ts';
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

type CatalogEvent = { type: string; cursor: string; workspaceId?: string; threadId?: string; status?: string };

async function openCatalog(url: string, machineId: string) {
  const controller = new AbortController();
  const response = await fetch(`${url}/events`, {
    headers: { 'X-Kite-Machine': machineId }, signal: controller.signal,
  });
  if (response.status !== 200) throw new Error(`订阅目录失败：${response.status}`);
  const reader = response.body!.pipeThrough(new TextDecoderStream()).getReader();
  const deadline = setTimeout(() => controller.abort(), 10_000);
  let buffer = '';
  return {
    async next(): Promise<CatalogEvent> {
      while (true) {
        const end = buffer.indexOf('\n\n');
        if (end >= 0) {
          const frame = buffer.slice(0, end);
          buffer = buffer.slice(end + 2);
          const data = frame.split('\n').find((line) => line.startsWith('data: '));
          if (data) return JSON.parse(data.slice(6)) as CatalogEvent;
          continue;
        }
        const chunk = await reader.read();
        if (chunk.done) throw new Error('目录 SSE 提前断开');
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

const completeModel: Model = { async *stream() { yield { type: 'completed', responseId: 'fixture' }; } };

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
  const repository = newRepo(root, 'project', { 'base.txt': '原始\n' });
  const daemon = startDaemon({ home, port: 0, lightTasks: false, model: () => completeModel });
  const otherDaemon = startDaemon({ home: join(root, 'other-kite'), port: 0, lightTasks: false, model: () => completeModel });
  const events: Envelope[] = [];
  const waiters: Array<{ predicate: (event: Envelope) => boolean; resolve: () => void }> = [];
  const unsubscribe = daemon.kite.bus.subscribe(undefined, (event) => {
    events.push(event);
    for (const waiter of [...waiters]) if (waiter.predicate(event)) {
      waiters.splice(waiters.indexOf(waiter), 1);
      waiter.resolve();
    }
  });
  const waitEvent = (predicate: (event: Envelope) => boolean) => {
    if (events.some(predicate)) return Promise.resolve();
    return new Promise<void>((resolve) => waiters.push({ predicate, resolve }));
  };
  let catalog: Awaited<ReturnType<typeof openCatalog>> | undefined;
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
    const project = await call<WorkspaceModel>(daemon.url, 'POST', '/checkouts', { path: repository }, machine.body.id);
    if (project.status !== 200) throw new Error(`登记项目失败：${project.status}`);
    const sharedParent = join(root, 'remote-shared');
    const separateParent = join(root, 'remote-separate');
    mkdirSync(sharedParent);
    mkdirSync(separateParent);
    const shared = await call<WorkspaceModel>(otherDaemon.url, 'POST', '/checkouts', {
      path: newRepo(sharedParent, 'project', { 'base.txt': '原始\n' }), project: project.body.project,
    }, otherMachine.body.id);
    const separate = await call<WorkspaceModel>(otherDaemon.url, 'POST', '/checkouts', {
      path: newRepo(separateParent, 'project', { 'base.txt': '原始\n' }),
    }, otherMachine.body.id);
    if (shared.status !== 200 || separate.status !== 200) throw new Error('第二台工作机登记项目失败');
    const workspace = await call<WorkspaceModel>(daemon.url, 'POST', '/workspaces', {
      checkout: project.body.checkout.id, prompt: '首线程', runtime: 'harness',
    }, machine.body.id);
    if (workspace.status !== 200) throw new Error(`创建工作区失败：${workspace.status}`);
    const firstThread = workspace.body.threads[0];
    if (!firstThread) throw new Error('创建带首条消息的工作区后没有首线程');
    await waitEvent((event) => event.type === 'idle' && event.threadId === firstThread.instanceId);

    const secondThread = await call<ThreadContext>(daemon.url, 'POST', `/workspaces/${workspace.body.workspace.id}/threads`, {
      prompt: '第二线程', runtime: 'harness',
    }, machine.body.id);
    if (secondThread.status !== 200) throw new Error(`创建第二线程失败：${secondThread.status}`);
    if (secondThread.body.workspace.cwd !== workspace.body.workspace.cwd) throw new Error('第二线程没有继承工作区 cwd');
    await waitEvent((event) => event.type === 'idle' && event.threadId === secondThread.body.id);

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
      throw new Error('真实插件业务状态未写入合同工作区');
    }

    catalog = await openCatalog(daemon.url, machine.body.id);
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
    const otherMachineFixture = join(root, 'other-machine.json');
    await Bun.write(otherMachineFixture, JSON.stringify(otherMachine.body));
    const localProjects = await call<Project[]>(daemon.url, 'GET', '/projects', undefined, machine.body.id);
    const remoteProjects = await call<Project[]>(otherDaemon.url, 'GET', '/projects', undefined, otherMachine.body.id);
    if (localProjects.status !== 200 || remoteProjects.status !== 200) throw new Error('读取项目身份失败');
    const localProjectsFixture = join(root, 'local-projects.json');
    const remoteProjectsFixture = join(root, 'remote-projects.json');
    await Bun.write(localProjectsFixture, JSON.stringify(localProjects.body));
    await Bun.write(remoteProjectsFixture, JSON.stringify(remoteProjects.body));

    const archived = await call<WorkspaceModel>(daemon.url, 'POST', `/workspaces/${workspace.body.workspace.id}/archive`, { force: true }, machine.body.id);
    if (archived.status !== 200) throw new Error(`归档两线程工作区失败：${archived.status}`);
    const changes: CatalogEvent[] = [];
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
    const jsonCodable = join(root, 'JSONCodable.swift');
    writeFileSync(jsonCodable, `import Foundation\n\n${
      declaration(readFileSync(join(app, 'KitedClient.swift'), 'utf8'), 'extension JSON: Codable')
    }\n`);
    await command([
      compiler,
      '-sdk', sdk,
      '-target', `${architecture}-apple-macosx26.0`,
      join(app, 'Transcript.swift'), jsonCodable,
      join(app, 'AgentConfiguration.swift'),
      join(app, 'PluginManagementModels.swift'),
      join(import.meta.dir, '..', '..', '..', 'app', 'Kite', 'RemoteWorkspace.swift'),
      join(import.meta.dir, '..', '..', '..', 'app', 'Kite', 'MachineConnections.swift'),
      join(import.meta.dir, '..', '..', '..', 'app', 'Kite', 'CatalogRefresh.swift'),
      join(import.meta.dir, 'RemoteWorkspaceDecode.swift'),
      '-o', decoder,
    ], root);
    console.log(await command([
      decoder, fixture, machineFixture, otherMachineFixture, localProjectsFixture, remoteProjectsFixture,
      daemon.url, otherDaemon.url, cursorsFixture, archivedFixture, definitionsFixture, filesFixture,
    ], root));
  } finally {
    await catalog?.close();
    unsubscribe();
    await otherDaemon.stop();
    await daemon.stop();
    rmSync(root, { recursive: true, force: true });
  }
}

await main();
