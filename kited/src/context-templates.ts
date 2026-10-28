/** 工作机共享的可编辑上下文：事件通知、上下文压缩与辅助生成（标题、工作区名称、签名）的模板，在生成时读取并固定快照。代理的提示词属于角色，见 roles.ts。 */
import { z } from 'zod';
import { revisionOf } from './account-data/store.ts';
import { agentModelCatalog } from './agents/capabilities.ts';
import { agentDefinitionSchema } from './agents/definition.ts';
import { agentModels, modelVendors } from './agents/models.ts';
import { KiteError } from './errors.ts';
import { contextDefinitionSchema } from './harness/context/assembler.ts';
import { contextScenes, sceneVariables, type ContextScene } from './harness/context/scenes.ts';
import type { ContextDefinition } from './harness/context/types.ts';
import type { Store } from './store.ts';
import { defaultSpeechModel, speechModels, speechVendors } from './voice/models.ts';

/**
 * 可编辑的场景及在资源库代理上下文里的分类，按进入代理上下文的方式分：事件通知（notification）是插进会话的正文；
 * 上下文压缩（compaction）由代理自己写摘要，替换一段历史；辅助生成（generation）由辅助模型另外生成，结果不进入代理上下文。
 */
const editableScenes: Partial<Record<ContextScene, 'notification' | 'compaction' | 'generation'>> = {
  'thread.configuration_changed': 'notification', 'thread.context_updated': 'notification',
  'thread.execution_permissions_changed': 'notification', 'thread.plugin_tools_changed': 'notification',
  'thread.file_changes': 'notification', 'line.monitor': 'notification', 'monitor.events': 'notification', 'terminal.exit': 'notification',
  'thread.instances_changed': 'notification', 'agent.report': 'notification', 'agent.workspace': 'notification',
  'thread.compact': 'compaction',
  'thread.title': 'generation', 'workspace.naming': 'generation', 'template.emblem': 'generation', 'thread.voice': 'generation',
  'thread.voice_tidy': 'generation', 'workspace.pull_request': 'generation', 'workspace.commit': 'generation',
};

/**
 * 辅助生成场景可选的模型，连同模板窗口里用什么凭据调用的说明。可选自研 harness 运行的型号：ChatGPT 用工作机的订阅，DeepSeek 用账号凭据里的 Key；
 * 内置模板默认用 ChatGPT 最轻的一档，语音整理默认用 DeepSeek（2026-10-29 用户定，对比见 docs/research/2026-10-29-语音润色.md）。
 * 语音识别另选识别模型（见 voice/），没有思考强度，也没有计数接口，背景文本按默认模型估。
 */
interface SceneModels {
  note: string;
  vendors: { id: string; title: string }[];
  models: { id: string; reasoning: string[] }[];
  counts: boolean;
  default: { model: string; reasoning: string };
}

function sceneModels(scene: ContextScene): SceneModels {
  if (scene === 'thread.voice') {
    return { note: '使用 Kite 账号凭据里的语音识别 Key。', vendors: speechVendors, models: speechModels, counts: false,
      default: defaultSpeechModel };
  }
  const catalog = agentModelCatalog();
  const harness = new Set<string>(modelVendors.filter((vendor) => vendor.runtime === 'harness').map((vendor) => vendor.id));
  const models = catalog.models.filter((model) => harness.has(model.vendor));
  const lightest = scene === 'thread.voice_tidy' ? agentModels.deepseek.find((model) => model.tier === 'flash')!
    : agentModels.models.find((model) => model.tier === 'luna')!;
  return { note: 'ChatGPT 型号用工作机的订阅，DeepSeek 用 Kite 账号凭据里的 API Key；不调用工具。', models, counts: true,
    vendors: catalog.vendors.filter((vendor) => models.some((model) => model.vendor === vendor.id)),
    default: { model: lightest.id, reasoning: 'low' } };
}

const templateSchema = z.object({ definition: contextDefinitionSchema, model: agentDefinitionSchema.shape.model.optional() }).strict();
/** 随账号保存的模板内容：组装定义，辅助生成的另带模型与思考强度。工具属于角色，模板没有。 */
export type Template = z.infer<typeof templateSchema>;
export interface ContextTemplate extends Template { revision: string }

const snapshot = (template: Template): ContextTemplate => ({ ...template, revision: revisionOf(template) });

function parse(value: unknown): Template {
  const result = templateSchema.safeParse(value);
  if (!result.success) throw new KiteError(`上下文模板无效：${result.error.issues.map((issue) => issue.message).join('；')}`);
  const { definition, model } = result.data;
  const kind = editableScenes[definition.scene];
  if (!kind) throw new KiteError('该场景尚未开放模板编辑');
  if (kind !== 'generation') {
    if (model) throw new KiteError('只有辅助生成的模板可以设置模型');
  } else {
    if (!model) throw new KiteError('辅助生成的模板须设置模型');
    const entry = sceneModels(definition.scene).models.find((candidate) => candidate.id === model.model);
    if (!entry) throw new KiteError('只能使用这个模板可选的模型');
    if (entry.reasoning.length ? !entry.reasoning.includes(model.reasoning) : model.reasoning !== 'default') throw new KiteError('思考强度无效');
  }
  return result.data;
}

export class ContextTemplates {
  /**
   * 内置模板的默认内容，只有这些模板可编辑。账号只存改过的，没改过的跟随 kited 版本的默认；
   * 本机缓存是账号的镜像，账号里有的才存，写账号时据此给出期望的版本。
   */
  private readonly defaults: Map<string, Template>;

  constructor(private store: Store, defaults: ContextDefinition[]) {
    this.defaults = new Map(defaults.map((definition) => [definition.id, parse({ definition,
      ...(editableScenes[definition.scene] === 'generation' ? { model: sceneModels(definition.scene).default } : {}) })]));
  }

  /** 辅助生成的场景带上可选的模型。 */
  list() {
    return {
      templates: [...this.defaults.keys()].sort().map((id) => this.entry(this.current(id)!)),
      scenes: Object.entries(editableScenes).map(([id, kind]) => {
        const scene = { id, kind, title: contextScenes[id as ContextScene].title, variables: sceneVariables(id as ContextScene) };
        if (kind !== 'generation') return scene;
        const { default: _, ...models } = sceneModels(id as ContextScene);
        return { ...scene, models };
      }),
    };
  }

  /** 不在模板列表里的场景（如角色提示词使用的创建会话场景）也按同一目录给出变量。 */
  sceneVariables(scene: ContextScene) { return sceneVariables(scene); }

  /** 辅助生成场景的模板一定带模型。 */
  get(id: string, scene: ContextScene, revision?: string): ContextTemplate {
    const template = this.current(id);
    if (!template) throw new KiteError('上下文模板不存在，请刷新列表', 404);
    if (template.definition.scene !== scene) throw new KiteError('模板不适用于当前场景');
    const value = snapshot(template);
    if (revision !== undefined && revision !== value.revision) throw new KiteError('模板已更新，请刷新后重新选择', 409);
    return value;
  }

  /** 账号里拉来的版本直接替换本机缓存，等于默认的也照存；不是本机已知场景的跳过。返回看到的内容是否有变化。 */
  cache(value: unknown): boolean {
    const template = this.named(parse(value));
    const { id } = template.definition;
    const before = this.current(id);
    if (!before) return false;
    const stored = this.store.contextTemplate(id);
    if (stored && snapshot(stored).revision === snapshot(template).revision) return false;
    this.store.saveContextTemplate(template);
    return snapshot(before).revision !== snapshot(template).revision;
  }

  /** 账号里这一项的版本：本机缓存是账号的镜像，没有缓存副本的在账号里也没有，是 null。 */
  accountRevision(id: string): string | null {
    const stored = this.store.contextTemplate(id);
    return stored ? snapshot(stored).revision : null;
  }

  /** 账号里已经没有的从缓存去掉，退回默认；返回是否有变化。 */
  keep(ids: ReadonlySet<string>): boolean {
    const gone = this.store.contextTemplates().filter((template) => !ids.has(template.definition.id));
    for (const template of gone) this.store.deleteContextTemplate(template.definition.id);
    return gone.length > 0;
  }

  /** 修改前的校验，结果先写进账号级数据再存本机。 */
  validate(id: string, expectedRevision: string, value: unknown): Template {
    const template = this.named(parse(value));
    if (id !== template.definition.id) throw new KiteError('模板 ID 与请求目标不一致');
    this.get(id, template.definition.scene, expectedRevision);
    return template;
  }

  /**
   * template 已经过 validate，账号里已写入或删掉；写账号期间账号推来的同步可能已更新本机缓存，事务里再核对一次版本，
   * 已是这次的内容就不再核对。本机缓存随账号：等于默认的已从账号删掉，本机也不留。
   */
  update(expectedRevision: string, template: Template): ContextTemplate & { defaultRevision: string } {
    return this.store.transaction(() => {
      const value = this.entry(template);
      const { id, scene } = template.definition;
      if (this.get(id, scene).revision !== value.revision) this.get(id, scene, expectedRevision);
      if (this.isDefault(template)) this.store.deleteContextTemplate(id);
      else this.store.saveContextTemplate(template);
      return value;
    });
  }

  /** 内置模板的默认内容，恢复默认时按它保存。 */
  builtin(id: string): Template {
    const template = this.defaults.get(id);
    if (!template) throw new KiteError('上下文模板不存在，请刷新列表', 404);
    return template;
  }

  /** 和默认内容一样的不算改过，账号里不留副本。 */
  isDefault(template: Template): boolean {
    const builtin = this.defaults.get(template.definition.id);
    return !!builtin && snapshot(builtin).revision === snapshot(template).revision;
  }

  /** 名称固定为内置名称，用户只改内容。 */
  private named(template: Template): Template {
    const builtin = this.defaults.get(template.definition.id);
    return builtin ? { ...template, definition: { ...template.definition, title: builtin.definition.title } } : template;
  }

  private current(id: string): Template | undefined {
    return this.defaults.has(id) ? this.store.contextTemplate(id) ?? this.defaults.get(id) : undefined;
  }

  /** 列表与保存结果带上默认内容的版本，与 revision 不同就是改过，可以恢复默认。 */
  private entry(template: Template): ContextTemplate & { defaultRevision: string } {
    return { ...snapshot(template), defaultRevision: snapshot(this.defaults.get(template.definition.id)!).revision };
  }
}
