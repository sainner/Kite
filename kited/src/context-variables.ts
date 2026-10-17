/** 代理线程的公共变量：所在工作机、项目、工作区与代理实例的状态，见 harness/context/scenes.ts 的分层。 */
import { mkdirSync, existsSync, readFileSync, realpathSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { instanceAgent, type AgentDefinition } from './agents/definition.ts';
import { permittedTools } from './agents/tool-policy.ts';
import { KiteError } from './errors.ts';
import { effectiveExecution, instanceExecutionChanges, type ProjectExecution } from './execution/grants.ts';
import {
  contentHash, directoryVariables, documentFiles, documentLimit, documentPaths, documentVariables, today, type DocumentFile, type DocumentVariable,
} from './harness/context/project.ts';
import { contextLayers, isPublicVariable, type ContextLayer, type LayerVariable, type PublicVariable } from './harness/context/scenes.ts';
import type { ContextBinding, ContextValues } from './harness/context/types.ts';
import type { Machine, Project, ThreadContext, Workspace } from './model.ts';
import { operationGrantsSchema } from './operations/contract.ts';
import { pluginToolBindings, pluginToolGranted, pluginToolSource } from './plugins/tools.ts';
import type { ProjectToolRule } from './roles.ts';
import type { Store } from './store.ts';

/** 代理配置里的工具经项目约束实时过滤后的有效集。 */
export const effectiveTools = (agent: AgentDefinition, project: ProjectToolRule | undefined) => permittedTools(agent.tools, project ? [project] : []);

/** 环境层：所有场景都取得到。 */
export function environmentVariables(machine: Machine) {
  return { 'environment.date': today, 'machine.name': () => ({ text: machine.name }) } satisfies Record<LayerVariable<'environment'>, () => ContextBinding>;
}

const text = (value: () => string) => (): ContextBinding => ({ text: value() });

/** 环境层加项目层：项目规则与记忆索引从 cwd 往上找，按检出取时 cwd 是项目文件夹。 */
function projectVariables(machine: Machine, project: Project, cwd: string) {
  const directory = directoryVariables(cwd);
  return {
    ...environmentVariables(machine),
    'project.name': text(() => project.name),
    'project.remote': text(() => project.remote ?? '没有远程'),
    'project.rules': directory['project.rules'],
    'project.memory': directory['project.memory'],
  } satisfies Record<LayerVariable<'environment' | 'project'>, () => ContextBinding>;
}

/** 环境、项目与工作区三层，项目规则与记忆索引从工作目录往上找。 */
export function workspaceVariables(model: { machine: Machine; project: Project; workspace: Workspace }) {
  const directory = directoryVariables(model.workspace.cwd);
  return {
    ...projectVariables(model.machine, model.project, model.workspace.cwd),
    'environment.cwd': directory['environment.cwd'],
    'workspace.branch': directory['workspace.branch'],
    'workspace.name': text(() => model.workspace.name),
  } satisfies Record<LayerVariable<'environment' | 'project' | 'workspace'>, () => ContextBinding>;
}

/**
 * thread 是取值时的状态：生成通知时传入变化之后的配置，变量取新值。每个值在模板引用时才取。
 * constraint 是项目的工具约束，允许的工具按它过滤，与配置通知一致。
 */
export function threadVariables(thread: ThreadContext, constraint: ProjectToolRule | undefined, execution?: ProjectExecution): ContextValues {
  const agent = () => instanceAgent(thread);
  return {
    ...workspaceVariables(thread),
    'agent.title': text(() => thread.title),
    // 角色的名称随提示词拷进实例，之后修改角色不影响。
    'agent.role': text(() => agent().context.title),
    'agent.model': text(() => agent().model.model),
    'agent.reasoning': text(() => agent().model.reasoning),
    'agent.tools': text(() => effectiveTools(agent(), constraint).join('、') || '无'),
    'agent.max_requests_per_turn': text(() => String(agent().maxRequestsPerTurn)),
    'execution.grants': text(() => JSON.stringify(effectiveExecution(instanceExecutionChanges(thread), execution).grants)),
    'plugin.tools': text(() => {
      const grants = operationGrantsSchema.parse(thread.config.grants ?? []);
      return JSON.stringify(pluginToolBindings(thread).filter((binding) => pluginToolGranted(binding, grants)).map(pluginToolSource));
    }),
  } satisfies Record<PublicVariable, () => ContextBinding>;
}

/** 按线程当前保存的状态取值。 */
export function storedThreadVariables(store: Store, id: string): ContextValues {
  const thread = store.threadContext(id);
  if (!thread) throw new Error(`没有这个线程：${id}`);
  const constraints = store.workspaceConstraints(thread.workspaceId);
  return threadVariables(thread, constraints?.tools, constraints?.execution);
}

/**
 * 编辑器里看一个公共变量现在的值，按变量所在的层选取值的对象：环境层按工作机，项目层与工作区层按工作区，代理层按代理实例；
 * 范围大的也能取范围小的层。来自文件的另带从工作区根目录逐级找到的各份文件，供直接编辑；
 * 一份都没有时 create 是在最里面那一级新建的位置。场景材料只在生成时才有，不能这样取。
 */
export type VariableScope = { kind: 'machine' } | { kind: 'workspace' | 'instance'; id: string };

export interface VariablePreview { name: string; text: string; files?: DocumentFile[]; create?: string }

const layerOf = (name: PublicVariable) =>
  (Object.keys(contextLayers) as ContextLayer[]).find((layer) => contextLayers[layer].variables.some((variable) => variable.name === name))!;

/** 范围能取到的层、各变量的取值，以及来自文件的变量往上找的起点。 */
function scopeValues(store: Store, scope: VariableScope): { layers: ContextLayer[]; values: ContextValues; cwd?: string } {
  switch (scope.kind) {
    case 'machine':
      return { layers: ['environment'], values: environmentVariables(store.machine) };
    case 'workspace': {
      const model = store.workspaceModel(scope.id);
      if (!model) throw new KiteError(`没有这个工作区：${scope.id}`, 404);
      return { layers: ['environment', 'project', 'workspace'], cwd: model.workspace.cwd, values: workspaceVariables(model) };
    }
    case 'instance': {
      const thread = store.threadContext(scope.id);
      if (!thread) throw new KiteError(`没有这个线程：${scope.id}`, 404);
      const constraints = store.workspaceConstraints(thread.workspaceId);
      return { layers: ['environment', 'project', 'workspace', 'agent'], cwd: thread.workspace.cwd,
        values: threadVariables(thread, constraints?.tools, constraints?.execution) };
    }
  }
}

export function previewVariable(store: Store, scope: VariableScope, name: string): VariablePreview {
  if (!isPublicVariable(name)) throw new KiteError(`${name} 不是公共变量，场景材料只在生成时才有`, 404);
  const { layers, values, cwd } = scopeValues(store, scope);
  const layer = layerOf(name);
  if (!layers.includes(layer)) throw new KiteError(`${name} 在${contextLayers[layer].title}层，这里取不到`);
  try {
    const text = values[name]!().text;
    if (!Object.hasOwn(documentVariables, name) || cwd === undefined) return { name, text };
    const root = realpathSync(cwd);
    const file = documentVariables[name as DocumentVariable];
    const files = documentFiles(root, file);
    return { name, text, files, ...(files.length === 0 ? { create: join(root, file) } : {}) };
  } catch (error) {
    throw new KiteError(`取值失败：${error instanceof Error ? error.message : String(error)}`, 409);
  }
}

/**
 * 从编辑器写回来自文件的变量（项目规则、记忆索引）：写进工作区的工作树，只能写这个变量从工作区根目录逐级查找的位置；
 * expectedSha256 是读到时的摘要，新建时为 null，文件在别处改过就拒绝。这个工作区里的代理下一次请求组装时生效。
 */
export function writeVariableFile(store: Store, workspaceId: string, name: string,
  input: { path: string; content: string; expectedSha256: string | null }): VariablePreview {
  if (!Object.hasOwn(documentVariables, name)) throw new KiteError(`${name} 不来自文件，不能这样修改`);
  const workspace = store.workspace(workspaceId);
  if (!workspace) throw new KiteError(`没有这个工作区：${workspaceId}`, 404);
  if (!documentPaths(realpathSync(workspace.cwd), documentVariables[name as DocumentVariable]).includes(input.path)) {
    throw new KiteError('只能写这个变量逐级查找的文件');
  }
  if (input.content.length > documentLimit) throw new KiteError(`文件不能超过 ${documentLimit} 字`);
  const current = existsSync(input.path) ? contentHash(readFileSync(input.path, 'utf8')) : null;
  if (current !== input.expectedSha256) throw new KiteError('文件已在别处修改，请重新读取', 409);
  mkdirSync(dirname(input.path), { recursive: true });
  writeFileSync(input.path, input.content);
  return previewVariable(store, { kind: 'workspace', id: workspaceId }, name);
}
