/** 工作机共享的可编辑上下文；会话绑定内容，轻任务和通知在生成时读取并固定快照。 */
import { createHash } from 'node:crypto';
import { z } from 'zod';
import { KiteError } from './errors.ts';
import { contextDefinitionSchema } from './harness/context/assembler.ts';
import { contextScenes, type ContextScene } from './harness/context/scenes.ts';
import type { ContextDefinition } from './harness/context/types.ts';
import type { Store } from './store.ts';

export interface ContextTemplate { definition: ContextDefinition; revision: string }
export interface ContextTemplateSelection { id: string; revision: string }
const editableScenes = [
  'thread.create', 'thread.title', 'thread.configuration_changed', 'thread.context_updated',
  'thread.execution_permissions_changed', 'thread.plugin_tools_changed',
] as const;

export function contextTemplateSelection(value: unknown): ContextTemplateSelection | undefined {
  if (value === undefined) return undefined;
  const parsed = z.object({ id: z.string().min(1), revision: z.string().min(1) }).strict().safeParse(value);
  if (!parsed.success) throw new KiteError('模板选择须包含 id 和 revision');
  return parsed.data;
}

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

  constructor(private store: Store, defaults: ContextDefinition[]) {
    this.fixedTemplates = new Set(defaults.filter((definition) => definition.scene !== 'thread.create').map((definition) => definition.id));
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

  get(id: string, scene: ContextScene, revision?: string): ContextTemplate {
    const definition = this.store.contextTemplate(id);
    if (!definition || !this.available(definition)) throw new KiteError('上下文模板不存在，请刷新列表', 404);
    if (definition.scene !== scene) throw new KiteError('模板不适用于当前场景');
    const value = snapshot(definition);
    if (revision !== undefined && revision !== value.revision) throw new KiteError('模板已更新，请刷新后重新选择', 409);
    return value;
  }

  create(value: unknown): ContextTemplate {
    const definition = parse(value);
    if (!this.available(definition)) throw new KiteError('该场景请编辑已有模板');
    return this.store.transaction(() => {
      const saved = this.store.contextTemplate(definition.id);
      if (saved && snapshot(saved).revision !== snapshot(definition).revision) throw new KiteError('模板 ID 已存在，请另存为新模板', 409);
      if (definition.scene !== 'thread.create' && !saved) throw new KiteError('该场景请编辑已有模板');
      if (!saved) this.store.saveContextTemplate(definition);
      return snapshot(definition);
    });
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
    return definition.scene === 'thread.create' || this.fixedTemplates.has(definition.id);
  }
}
