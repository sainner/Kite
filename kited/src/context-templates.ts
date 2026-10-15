/** 工作机共享的可编辑上下文：事件通知、上下文压缩与辅助生成（标题、签名）的模板，在生成时读取并固定快照。代理的提示词属于角色，见 roles.ts。 */
import { createHash } from 'node:crypto';
import { z } from 'zod';
import { agentModelCatalog } from './agents/capabilities.ts';
import { agentDefinitionSchema } from './agents/definition.ts';
import { agentModels } from './agents/models.ts';
import { KiteError } from './errors.ts';
import { contextDefinitionSchema } from './harness/context/assembler.ts';
import { contextScenes, type ContextScene } from './harness/context/scenes.ts';
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
  'thread.file_changes': 'notification', 'line.monitor': 'notification', 'monitor.events': 'notification',
  'thread.compact': 'compaction',
  'thread.title': 'generation', 'template.emblem': 'generation', 'thread.voice': 'generation',
};

/**
 * 辅助生成场景可选的模型，连同编辑器里模型一节的标题与说明。一般用工作机的 ChatGPT 订阅，只能选其中的型号，内置模板默认用最轻的一档；
 * 语音识别另选识别模型（见 voice/），没有思考强度，也没有计数接口，背景文本按默认模型估。
 */
interface SceneModels {
  title: string;
  note: string;
  vendors: { id: string; title: string }[];
  models: { id: string; reasoning: string[] }[];
  counts: boolean;
  default: { model: string; reasoning: string };
}

function sceneModels(scene: ContextScene): SceneModels {
  if (scene === 'thread.voice') {
    return { title: '识别模型', note: '使用 Kite 账号凭据里的语音识别 Key。', vendors: speechVendors, models: speechModels, counts: false,
      default: defaultSpeechModel };
  }
  const catalog = agentModelCatalog();
  const models = catalog.models.filter((model) => agentModels.models.some((entry) => entry.id === model.id));
  return { title: '模型', note: '使用工作机的 ChatGPT 订阅，不调用工具。', models, counts: true,
    vendors: catalog.vendors.filter((vendor) => models.some((model) => model.vendor === vendor.id)),
    default: { model: agentModels.models.find((model) => model.tier === 'luna')!.id, reasoning: 'low' } };
}

const templateSchema = z.object({ definition: contextDefinitionSchema, model: agentDefinitionSchema.shape.model.optional() }).strict();
/** 随账号保存的模板内容：组装定义，辅助生成的另带模型与思考强度。工具属于角色，模板没有。 */
export type Template = z.infer<typeof templateSchema>;
export interface ContextTemplate extends Template { revision: string }

const snapshot = (template: Template): ContextTemplate => ({
  ...template, revision: createHash('sha256').update(JSON.stringify(template)).digest('hex'),
});

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
  /** 内置模板的默认内容，只有这些模板可编辑。本机与账号只存改过的，没改过的跟随 kited 版本的默认。 */
  private readonly defaults: Map<string, Template>;

  constructor(private store: Store, defaults: ContextDefinition[]) {
    this.defaults = new Map(defaults.map((definition) => [definition.id, parse({ definition,
      ...(editableScenes[definition.scene] === 'generation' ? { model: sceneModels(definition.scene).default } : {}) })]));
    store.transaction(() => {
      for (const template of store.contextTemplates()) if (this.isDefault(template)) store.deleteContextTemplate(template.definition.id);
    });
  }

  /** 辅助生成的场景带上可选的模型。 */
  list() {
    return {
      templates: [...this.defaults.keys()].sort().map((id) => snapshot(this.current(id)!)),
      scenes: Object.entries(editableScenes).map(([id, kind]) => {
        if (kind !== 'generation') return { id, kind, ...contextScenes[id as ContextScene] };
        const { default: _, ...models } = sceneModels(id as ContextScene);
        return { id, kind, ...contextScenes[id as ContextScene], models };
      }),
    };
  }

  /** 不在模板列表里的场景（如角色提示词使用的创建会话场景）也按同一目录给出变量。 */
  sceneVariables(scene: ContextScene) { return contextScenes[scene].variables; }

  /** 辅助生成场景的模板一定带模型。 */
  get(id: string, scene: ContextScene, revision?: string): ContextTemplate {
    const template = this.current(id);
    if (!template) throw new KiteError('上下文模板不存在，请刷新列表', 404);
    if (template.definition.scene !== scene) throw new KiteError('模板不适用于当前场景');
    const value = snapshot(template);
    if (revision !== undefined && revision !== value.revision) throw new KiteError('模板已更新，请刷新后重新选择', 409);
    return value;
  }

  /** 账号里拉来的版本直接替换本机缓存；不是本机已知场景的跳过，返回是否有变化。 */
  cache(value: unknown): boolean {
    const template = this.named(parse(value));
    const current = this.current(template.definition.id);
    if (!current || snapshot(current).revision === snapshot(template).revision) return false;
    this.save(template);
    return true;
  }

  /** 账号里已经没有的从缓存去掉，退回默认；返回是否有变化。 */
  keep(ids: ReadonlySet<string>): boolean {
    const gone = this.store.contextTemplates().filter((template) => !ids.has(template.definition.id));
    for (const template of gone) this.store.deleteContextTemplate(template.definition.id);
    return gone.length > 0;
  }

  /** 修改前的校验，结果先写到账号服务再存本机。 */
  validate(id: string, expectedRevision: string, value: unknown): Template {
    const template = this.named(parse(value));
    if (id !== template.definition.id) throw new KiteError('模板 ID 与请求目标不一致');
    this.get(id, template.definition.scene, expectedRevision);
    return template;
  }

  /** template 已经过 validate；写账号期间账号推来的同步可能已更新本机缓存，事务里再核对一次版本，已是这次的内容就不再核对。 */
  update(expectedRevision: string, template: Template): ContextTemplate {
    return this.store.transaction(() => {
      const value = snapshot(template);
      const { id, scene } = template.definition;
      if (this.get(id, scene).revision !== value.revision) {
        this.get(id, scene, expectedRevision);
        this.save(template);
      }
      return value;
    });
  }

  /** 名称固定为内置名称，用户只改内容。 */
  private named(template: Template): Template {
    const builtin = this.defaults.get(template.definition.id);
    return builtin ? { ...template, definition: { ...template.definition, title: builtin.definition.title } } : template;
  }

  private current(id: string): Template | undefined {
    return this.defaults.has(id) ? this.store.contextTemplate(id) ?? this.defaults.get(id) : undefined;
  }

  /** 改回与默认一样的不算改过，不留副本。 */
  private save(template: Template) {
    if (this.isDefault(template)) this.store.deleteContextTemplate(template.definition.id);
    else this.store.saveContextTemplate(template);
  }

  private isDefault(template: Template): boolean {
    const builtin = this.defaults.get(template.definition.id);
    return !!builtin && snapshot(builtin).revision === snapshot(template).revision;
  }
}
