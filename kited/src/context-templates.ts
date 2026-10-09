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
  /** 内置模板的默认内容，只有这些模板可编辑。本机与账号只存改过的，没改过的跟随 kited 版本的默认。 */
  private readonly defaults: Map<string, ContextDefinition>;

  constructor(private store: Store, defaults: ContextDefinition[]) {
    this.defaults = new Map(defaults.map((definition) => [definition.id, parse(definition)]));
    store.transaction(() => {
      for (const definition of store.contextTemplates()) if (this.isDefault(definition)) store.deleteContextTemplate(definition.id);
    });
  }

  list() {
    return {
      templates: [...this.defaults.keys()].sort().map((id) => snapshot(this.current(id)!)),
      scenes: editableScenes.map((id) => ({ id, ...contextScenes[id] })),
    };
  }

  /** 不在模板列表里的场景（如角色提示词使用的创建会话场景）也按同一目录给出变量。 */
  sceneVariables(scene: ContextScene) { return contextScenes[scene].variables; }

  get(id: string, scene: ContextScene, revision?: string): ContextTemplate {
    const definition = this.current(id);
    if (!definition) throw new KiteError('上下文模板不存在，请刷新列表', 404);
    if (definition.scene !== scene) throw new KiteError('模板不适用于当前场景');
    const value = snapshot(definition);
    if (revision !== undefined && revision !== value.revision) throw new KiteError('模板已更新，请刷新后重新选择', 409);
    return value;
  }

  /** 账号里拉来的版本直接替换本机缓存；不是本机已知场景的跳过，返回是否有变化。 */
  cache(value: unknown): boolean {
    const definition = parse(value);
    const current = this.current(definition.id);
    if (!current || snapshot(current).revision === snapshot(definition).revision) return false;
    this.save(definition);
    return true;
  }

  /** 账号里已经没有的从缓存去掉，退回默认；返回是否有变化。 */
  keep(ids: ReadonlySet<string>): boolean {
    const gone = this.store.contextTemplates().filter((definition) => !ids.has(definition.id));
    for (const definition of gone) this.store.deleteContextTemplate(definition.id);
    return gone.length > 0;
  }

  /** 修改前的校验，结果先写到账号服务再存本机。 */
  validate(id: string, expectedRevision: string, value: unknown): ContextDefinition {
    const definition = parse(value);
    if (id !== definition.id) throw new KiteError('模板 ID 与请求目标不一致');
    this.get(id, definition.scene, expectedRevision);
    return definition;
  }

  /** definition 已经过 validate；写账号期间账号推来的同步可能已更新本机缓存，事务里再核对一次版本，已是这次的内容就不再核对。 */
  update(expectedRevision: string, definition: ContextDefinition): ContextTemplate {
    return this.store.transaction(() => {
      const value = snapshot(definition);
      if (this.get(definition.id, definition.scene).revision !== value.revision) {
        this.get(definition.id, definition.scene, expectedRevision);
        this.save(definition);
      }
      return value;
    });
  }

  private current(id: string): ContextDefinition | undefined {
    return this.defaults.has(id) ? this.store.contextTemplate(id) ?? this.defaults.get(id) : undefined;
  }

  /** 改回与默认一样的不算改过，不留副本。 */
  private save(definition: ContextDefinition) {
    if (this.isDefault(definition)) this.store.deleteContextTemplate(definition.id);
    else this.store.saveContextTemplate(definition);
  }

  private isDefault(definition: ContextDefinition): boolean {
    const builtin = this.defaults.get(definition.id);
    return !!builtin && snapshot(builtin).revision === snapshot(definition).revision;
  }
}
