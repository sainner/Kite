/** 只接收预构建单文件包；安装与读取不执行插件代码，也不运行依赖安装脚本。 */
import { createHash } from 'node:crypto';
import { existsSync, mkdirSync, readFileSync, readdirSync, renameSync, rmSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { z } from 'zod';
import { KiteError } from './errors.ts';
import { pluginDefinition, pluginDefinitions, type PluginDefinition } from './plugins.ts';

const name = z.string().regex(/^[a-z][a-z0-9._-]{0,79}$/);
export const pluginPackageSchema = z.object({
  id: name.refine((id) => !id.startsWith('kite.'), 'kite.* 只供宿主登记'),
  title: z.string().trim().min(1).max(100),
  bundle: z.string().min(1).max(4 * 1024 * 1024).refine((value) => Buffer.byteLength(value) <= 4 * 1024 * 1024, '包超过 4 MiB'),
  views: z.array(z.object({ id: name, title: z.string().trim().min(1).max(100) }).strict()).max(16).default([]),
  defaultView: name.optional(),
}).strict().refine((value) => new Set(value.views.map((view) => view.id)).size === value.views.length
  && (value.defaultView === undefined || value.views.some((view) => view.id === value.defaultView)), '默认视图或视图 ID 无效');
export type PluginPackage = z.infer<typeof pluginPackageSchema>;
export const packageRevision = (value: PluginPackage): string => createHash('sha256').update(JSON.stringify(value)).digest('hex');

export class PluginCatalog {
  private packages = new Map<string, { value: PluginPackage; definition: PluginDefinition }>();
  constructor(private directory: string) {
    if (!existsSync(directory)) return;
    for (const file of readdirSync(directory).filter((file) => file.endsWith('.json'))) {
      const value = pluginPackageSchema.parse(JSON.parse(readFileSync(join(directory, file), 'utf8')));
      if (file !== `${value.id}.json` || this.packages.has(value.id)) throw new KiteError('插件目录含重复或无效的包');
      this.packages.set(value.id, { value, definition: this.definition(value) });
    }
  }
  definitions(): PluginDefinition[] {
    return [...pluginDefinitions(), ...[...this.packages.values()].map((entry) => structuredClone(entry.definition))];
  }
  get(id: string): PluginDefinition {
    const entry = this.packages.get(id);
    return entry ? structuredClone(entry.definition) : pluginDefinition(id);
  }
  package(id: string): PluginPackage {
    const value = this.packages.get(id);
    if (!value) throw new KiteError('此定义没有 Bun 插件包', 409);
    return structuredClone(value.value);
  }
  install(raw: unknown): PluginDefinition {
    const parsed = pluginPackageSchema.safeParse(raw);
    if (!parsed.success) throw new KiteError(`插件包无效：${parsed.error.message}`);
    const value = parsed.data;
    const previous = this.packages.get(value.id);
    if (previous) {
      if (previous.definition.revision !== packageRevision(value)) throw new KiteError('定义 ID 已安装其他内容；升级请使用新的定义 ID', 409);
      return structuredClone(previous.definition);
    }
    mkdirSync(this.directory, { recursive: true, mode: 0o700 });
    const temporary = join(this.directory, `${value.id}.${crypto.randomUUID()}.tmp`);
    try {
      writeFileSync(temporary, JSON.stringify(value), { flag: 'wx', mode: 0o600 });
      renameSync(temporary, join(this.directory, `${value.id}.json`));
    } finally { rmSync(temporary, { force: true }); }
    const definition = this.definition(value);
    this.packages.set(value.id, { value, definition });
    return structuredClone(definition);
  }
  private definition(value: PluginPackage): PluginDefinition {
    return { id: value.id, title: value.title, runtime: 'bun', revision: packageRevision(value), operations: ['plugin.call'],
      views: value.views.map((view) => ({ ...view, renderer: 'web' })), defaultView: value.defaultView ?? value.views[0]?.id ?? '' };
  }
}
