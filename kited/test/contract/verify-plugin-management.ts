/**
 * 手动合同：真实 MCP 目标、共享模型清单和后端配置 JSON 经 Swift 编辑、编码 PUT，并验证旧版本冲突。
 * 运行：kited/node_modules/.bin/bun kited/test/contract/verify-plugin-management.ts；不使用真实模型。
 */
import { randomUUID } from 'node:crypto';
import { mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, symlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { isDeepStrictEqual } from 'node:util';
import modelCatalog from '../../../shared/agent-models.json';
import type { AgentDefinition } from '../../src/agent-definition.ts';
import { defaultAgentModel } from '../../src/agent-models.ts';
import { startDaemon } from '../../src/daemon.ts';
import type { ExecutionGrants } from '../../src/execution-grants.ts';
import type { Model } from '../../src/harness/types.ts';
import type { OperationGrant } from '../../src/operation-contract.ts';
import { bunPluginSource } from '../fixtures/bun-plugin-source.ts';
import { newRepo } from '../util.ts';
import { command } from './command.ts';

interface InstanceGrants { revision: string; grants: OperationGrant[] }
interface GrantUpdate { expectedRevision: string; grants: OperationGrant[] }
interface InstanceExecutionGrants { revision: string; grants: ExecutionGrants }
interface AgentConfigurationSnapshot { revision: string; instance: { config: { agent: AgentDefinition } } }
interface AgentConfigurationUpdate { expectedRevision: string; agent: AgentDefinition }

// 沿用远程工作区合同：编译真实 JSON Codable 声明，不复制编码实现。
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

const root = mkdtempSync(join(tmpdir(), 'plugin-management-contract-'));
let modelCalls = 0;
const model: Model = { async *stream() { modelCalls++; yield { type: 'completed', responseId: 'fixture' }; } };
const daemon = startDaemon({ home: join(root, 'kite'), port: 0, lightTasks: false, model: () => model });
let machineID = '';

async function request<T>(method: string, path: string, body?: unknown, expectedStatus = 200): Promise<T> {
  const headers: Record<string, string> = {};
  if (path !== '/machine') headers['X-Kite-Machine'] = machineID;
  if (body !== undefined) headers['content-type'] = 'application/json';
  const response = await fetch(daemon.url + path, {
    method, headers, body: body === undefined ? undefined : JSON.stringify(body),
  });
  const value = await response.json();
  if (response.status !== expectedStatus) {
    throw new Error(`${method} ${path}：期望 ${expectedStatus}，实际 ${response.status} ${JSON.stringify(value)}`);
  }
  return value as T;
}

try {
  machineID = (await request<{ id: string }>('GET', '/machine')).id;
  const repository = newRepo(root, 'project', { 'note.txt': '授权合同\n' });
  const checkout = await request<{ workspace: { id: string } }>('POST', '/checkouts', { path: repository });
  const workspaceID = checkout.workspace.id;
  const openBuiltin = async (definitionId: string) => {
    const window = await request<{ target: { instanceId: string } }>('POST', `/workspaces/${workspaceID}/windows`, {
      id: randomUUID(), content: { kind: 'create', definitionId },
    });
    return window.target.instanceId;
  };
  const callerID = await openBuiltin('kite.agent.coding');
  await request('GET', `/threads/${callerID}/state`);
  if (modelCalls !== 0) throw new Error('读取空闲线程状态启动了模型');
  const filesID = await openBuiltin('kite.files');
  const entry = join(root, 'plugin.ts');
  symlinkSync(join(import.meta.dir, '..', '..', 'node_modules'), join(root, 'node_modules'));
  writeFileSync(entry, bunPluginSource);
  const built = await Bun.build({ entrypoints: [entry], target: 'bun', format: 'esm', minify: true });
  if (!built.success || built.outputs.length !== 1) throw new Error(`MCP fixture 打包失败：${built.logs.join('\n')}`);
  await request('POST', '/plugin-definitions', {
    id: 'custom.management-contract', title: '授权合同', bundle: await built.outputs[0]!.text(), lifetime: 'persistent',
  });
  const targetID = randomUUID();
  const otherTargetID = randomUUID();
  for (const id of [targetID, otherTargetID]) {
    await request('POST', `/workspaces/${workspaceID}/plugin-instances`, {
      id, definitionId: 'custom.management-contract', title: '真实 MCP 目标',
    });
    await request('GET', `/instances/${id}/plugin/tools`);
  }
  const path = `/instances/${callerID}/operation-grants`;
  const initial = await request<InstanceGrants>('GET', path);
  const snapshot = await request<InstanceGrants>('PUT', path, {
    expectedRevision: initial.revision,
    grants: [
      ...initial.grants,
      { operation: 'files.read', targets: { kind: 'instances', instanceIds: [filesID] } },
      { operation: 'plugin.call', instanceId: targetID, tools: ['state'] },
      { operation: 'plugin.call', instanceId: otherTargetID, tools: ['state'] },
    ] satisfies OperationGrant[],
  });

  const compiler = await command(['xcrun', '--find', 'swiftc'], root);
  const sdk = await command(['xcrun', '--show-sdk-path'], root);
  const architecture = await command(['uname', '-m'], root);
  const executable = join(root, 'PluginManagement');
  const app = join(import.meta.dir, '..', '..', '..', 'app', 'Kite');
  const jsonCodable = join(root, 'JSONCodable.swift');
  writeFileSync(jsonCodable, `import Foundation\n\n${
    declaration(readFileSync(join(app, 'KitedClient.swift'), 'utf8'), 'extension JSON: Codable')
  }\n`);
  await command([compiler, '-sdk', sdk, '-target', `${architecture}-apple-macosx26.0`,
    join(app, 'Transcript.swift'), jsonCodable, join(app, 'AgentConfiguration.swift'),
    join(app, 'PluginManagementModels.swift'),
    join(import.meta.dir, 'PluginManagement.swift'), '-o', executable], root);

  const edit = async (action: 'add' | 'remove', value: InstanceGrants) => {
    const input = join(root, `${action}-snapshot.json`);
    const output = join(root, `${action}-put.json`);
    await Bun.write(input, JSON.stringify(value));
    console.log(await command([executable, action, input, targetID, output], root));
    return await Bun.file(output).json() as GrantUpdate;
  };
  const add = await edit('add', snapshot);
  const added = await request<InstanceGrants>('PUT', path, add);
  if (!isDeepStrictEqual(added.grants, add.grants)) throw new Error('Swift PUT 未完整保存草稿授权');
  const remove = await edit('remove', await request<InstanceGrants>('GET', path));
  const removed = await request<InstanceGrants>('PUT', path, remove);
  if (!isDeepStrictEqual(removed.grants, remove.grants)) throw new Error('撤权 PUT 未完整保存 Swift 草稿');
  await request('PUT', path, add, 409);
  const afterConflict = await request<InstanceGrants>('GET', path);
  if (!isDeepStrictEqual(afterConflict, removed)) throw new Error('旧 revision 冲突静默覆盖了当前授权');
  console.log('Swift 授权与真实后端往返保留 agent/files/其它插件授权，撤去最后工具并拒绝旧 revision');

  const executionPath = `/instances/${callerID}/execution-grants`;
  const executionSnapshot = await request<InstanceExecutionGrants>('GET', executionPath);
  const executionInput = join(root, 'execution-snapshot.json');
  const executionFixture = join(root, 'execution-fixture.json');
  const executionOutput = join(root, 'execution-stale-put.json');
  const readPath = join(root, '额外只读目录');
  const writePath = join(root, '额外可写目录');
  mkdirSync(readPath);
  mkdirSync(writePath);
  const canonicalReadPath = realpathSync(readPath);
  const canonicalWritePath = realpathSync(writePath);
  await Bun.write(executionInput, JSON.stringify(executionSnapshot));
  await Bun.write(executionFixture, JSON.stringify({
    url: daemon.url, machineID, instanceID: callerID, readPath: canonicalReadPath, writePath: canonicalWritePath,
  }));
  console.log(await command([executable, 'execution', executionInput, executionFixture, executionOutput], root));
  const executionSaved = await request<InstanceExecutionGrants>('GET', executionPath);
  if (!isDeepStrictEqual(executionSaved.grants, {
    workspace: 'read', read: [canonicalReadPath], write: [canonicalWritePath], network: ['new.example.net'],
  })) throw new Error('Swift 执行授权往返改变了已保存的目录或网络许可');
  if (!isDeepStrictEqual(await request<InstanceGrants>('GET', path), removed)) {
    throw new Error('编辑执行授权连带改写了操作授权');
  }
  await request('GET', `/threads/${callerID}/state`);
  if (modelCalls !== 0) throw new Error('授权编辑或读取状态启动了模型');
  console.log('执行授权与操作授权分别保存，线程状态读取保持只读');

  const agentPath = `/instances/${callerID}/agent-config`;
  const agentSnapshot = await request<AgentConfigurationSnapshot>('GET', agentPath);
  const agentInput = join(root, 'agent-snapshot.json');
  const agentOutput = join(root, 'agent-model-put.json');
  const defaultModel = modelCatalog.models.find(({ tier }) => tier === modelCatalog.defaultTier);
  const selectedModel = modelCatalog.models.find(({ tier }) => tier === 'astra');
  if (!defaultModel || !selectedModel) throw new Error('共享模型清单缺少默认模型或 astra 模型');
  if (agentSnapshot.instance.config.agent.model.model !== defaultModel.id || defaultAgentModel !== defaultModel.id) {
    throw new Error('真实后端初始配置、kited 默认模型与共享 JSON 不一致');
  }
  const nextModel = selectedModel.id;
  await Bun.write(agentInput, JSON.stringify(agentSnapshot));
  console.log(await command([executable, 'model', agentInput,
    join(import.meta.dir, '..', '..', '..', 'shared', 'agent-models.json'), agentOutput], root));
  const agentUpdate = await Bun.file(agentOutput).json() as AgentConfigurationUpdate;
  const expectedAgent = structuredClone(agentSnapshot.instance.config.agent);
  expectedAgent.model.model = nextModel;
  if (agentUpdate.expectedRevision !== agentSnapshot.revision || !isDeepStrictEqual(agentUpdate.agent, expectedAgent)) {
    throw new Error('Swift 模型切换丢失上下文、工具、reasoning、预算或原始 revision');
  }
  const agentSaved = await request<AgentConfigurationSnapshot>('PUT', agentPath, agentUpdate);
  if (!isDeepStrictEqual(agentSaved.instance.config.agent, expectedAgent) || agentSaved.revision === agentSnapshot.revision) {
    throw new Error('真实 PUT 未完整保存 Swift 模型配置或推进 revision');
  }
  await request('PUT', agentPath, { ...agentUpdate, agent: agentSnapshot.instance.config.agent }, 409);
  if (!isDeepStrictEqual(await request<AgentConfigurationSnapshot>('GET', agentPath), agentSaved)) {
    throw new Error('旧 revision 覆盖了已保存模型配置');
  }
  if (modelCalls !== 0) throw new Error('模型选择或配置读取启动了模型');
  console.log('Swift 与 Bun 共享默认模型，真实模型切换保留完整配置，旧 revision 拒绝且不唤醒模型');
} finally {
  await daemon.stop();
  rmSync(root, { recursive: true, force: true });
}
