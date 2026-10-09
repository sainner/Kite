/** 工作机共享的可编辑上下文：标题、压缩、签名等轻任务与各类通知，在生成时读取并固定快照。代理的提示词属于角色，见 roles.ts。 */
import { createHash } from 'node:crypto';
import { KiteError } from './errors.ts';
import { contextDefinitionSchema } from './harness/context/assembler.ts';
import { contextScenes, type ContextScene } from './harness/context/scenes.ts';
import type { ContextDefinition } from './harness/context/types.ts';
import type { Store } from './store.ts';

export interface ContextTemplate { definition: ContextDefinition; revision: string }
const editableScenes = [
  'thread.title', 'thread.compact', 'thread.configuration_changed', 'thread.context_updated',
  'thread.execution_permissions_changed', 'thread.plugin_tools_changed', 'thread.file_changes',
  'template.emblem',
] as const;

const snapshot = (definition: ContextDefinition): ContextTemplate => ({
  definition, revision: createHash('sha256').update(JSON.stringify(definition)).digest('hex'),
});

function parse(value: unknown): ContextDefinition {
  const result = contextDefinitionSchema.safeParse(value);
  if (!result.success) throw new KiteError(`上下文模板无效：${result.error.issues.map((issue) => issue.message).join('；')}`);
  if (!editableScenes.some((scene) => scene === result.data.scene)) throw new KiteError('该场景尚未开放模板编辑');
  return result.data;
}

export class ContextTemplates {
  private readonly fixedTemplates: Set<string>;
  private readonly defaults: Map<string, string>;

  constructor(private store: Store, defaults: ContextDefinition[]) {
    this.fixedTemplates = new Set(defaults.map((definition) => definition.id));
    this.defaults = new Map(defaults.map((definition) => [definition.id, snapshot(parse(definition)).revision]));
    store.transaction(() => {
      for (const definition of defaults) {
        if (!store.contextTemplate(definition.id)) store.saveContextTemplate(parse(definition));
      }
    });
  }

  list() {
    return {
      templates: this.store.contextTemplates().filter((definition) => this.available(definition)).map(snapshot),
      scenes: editableScenes.map((id) => ({ id, ...contextScenes[id] })),
    };
  }

  /** 不在模板列表里的场景（如角色提示词使用的创建会话场景）也按同一目录给出变量。 */
  sceneVariables(scene: ContextScene) { return contextScenes[scene].variables; }

  get(id: string, scene: ContextScene, revision?: string): ContextTemplate {
    const definition = this.store.contextTemplate(id);
    if (!definition || !this.available(definition)) throw new KiteError('上下文模板不存在，请刷新列表', 404);
    if (definition.scene !== scene) throw new KiteError('模板不适用于当前场景');
    const value = snapshot(definition);
    if (revision !== undefined && revision !== value.revision) throw new KiteError('模板已更新，请刷新后重新选择', 409);
    return value;
  }

  /** 用户改过的模板，资源库同步时上传本机独有的修改。 */
  edited(): ContextTemplate[] {
    return this.list().templates.filter((template) => this.defaults.get(template.definition.id) !== template.revision);
  }

  /** 账号里拉来的版本直接替换本机缓存；不是本机已知场景的跳过，返回是否有变化。 */
  cache(value: unknown): boolean {
    const definition = parse(value);
    if (!this.fixedTemplates.has(definition.id)) return false;
    const saved = this.store.contextTemplate(definition.id);
    if (saved && snapshot(saved).revision === snapshot(definition).revision) return false;
    this.store.saveContextTemplate(definition);
    return true;
  }

  /** 修改前的校验，结果先写到账号服务再存本机。 */
  validate(id: string, expectedRevision: string, value: unknown): ContextDefinition {
    const definition = parse(value);
    if (id !== definition.id) throw new KiteError('模板 ID 与请求目标不一致');
    this.get(id, definition.scene, expectedRevision);
    return definition;
  }

  update(id: string, expectedRevision: string, value: unknown): ContextTemplate {
    const definition = parse(value);
    if (id !== definition.id) throw new KiteError('模板 ID 与请求目标不一致');
    return this.store.transaction(() => {
      this.get(id, definition.scene, expectedRevision);
      this.store.saveContextTemplate(definition);
      return snapshot(definition);
    });
  }

  private available(definition: ContextDefinition): boolean {
    return this.fixedTemplates.has(definition.id);
  }
}
