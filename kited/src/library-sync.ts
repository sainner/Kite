/**
 * 资源库（角色、上下文模板、点阵签名、插件包、skill）与项目约束是账号级数据（account-data/），写入先进账号级数据，再更新本机缓存；
 * 读取一律用缓存。账号级数据有变化（本机写入或从其他工作机同步来）就把缓存对一遍：角色与模板以账号级数据为准，
 * 那里没有的从缓存去掉，内置的退回默认；skill 的缓存就是数据目录里的文件夹；本机有、那里没有的点阵签名与插件包补写进去。
 */
import type { ContextTemplates } from './context-templates.ts';
import type { PluginCatalog } from './plugins/catalog.ts';
import type { ProjectToolRule, Roles } from './roles.ts';
import type { Skills } from './skills.ts';
import type { Store } from './store.ts';
import type { TemplateEmblem } from './template-emblems.ts';
import type { AccountData, EntryKind } from './account-data/store.ts';
import type { ProjectRegistry } from './account-data/registry.ts';
import type { ProjectExecution } from './execution/grants.ts';

export type LibraryKind = Extract<EntryKind, 'role' | 'template' | 'emblem' | 'plugin' | 'skill'>;
const synced = new Set<EntryKind>(['role', 'template', 'emblem', 'plugin', 'skill', 'constraints']);

/** constraints 列出约束变了的项目及变化前的规则。 */
export interface LibraryChanges { roles: boolean; templates: boolean; skills: boolean; constraints: Array<{ projectId: string; before?: { tools?: ProjectToolRule; execution?: ProjectExecution } }> }

export class LibrarySync {
  private scheduled = false;
  private unsubscribe?: () => void;

  constructor(private deps: {
    data: AccountData; registry: ProjectRegistry; store: Store; roles: Roles; templates: ContextTemplates; catalog: PluginCatalog; skills: Skills;
    changed: (changes: LibraryChanges) => void;
  }) {}

  /** 开始跟随账号级数据，先对一遍。 */
  start(): void {
    this.unsubscribe ??= this.deps.data.subscribe((changed) => { if (changed.some((entry) => synced.has(entry.kind))) this.soon(); });
    this.refresh();
  }

  close(): void { this.unsubscribe?.(); }

  write(kind: LibraryKind, id: string, body: object, expectedRevision?: string | null): void {
    this.deps.data.put(kind, id, body as Record<string, unknown>, expectedRevision);
  }

  /** 删掉后各工作机对缓存时发现没有了，内置的退回默认。 */
  remove(kind: LibraryKind, id: string, expectedRevision: string | null): void {
    this.deps.data.remove(kind, id, expectedRevision);
  }

  /**
   * 保存内置或自建的一项：改回与默认一样的内置内容就删掉，不留一份等于默认的副本，
   * 否则 kited 升级换了默认后它会被当成改过的内容；其余写入。
   */
  save(kind: LibraryKind, id: string, body: object, expectedRevision: string | null, isDefault: boolean): void {
    if (isDefault) this.remove(kind, id, expectedRevision);
    else this.write(kind, id, body, expectedRevision);
  }

  /** 本机没装的插件包从账号级数据取出安装；内置定义和已装的直接返回。 */
  ensurePlugin(id: string): void {
    const { catalog, data } = this.deps;
    if (catalog.installed(id) || catalog.get(id).runtime !== 'bun') return;
    const item = data.get('plugin', id);
    if (item) catalog.install(item.body);
  }

  /** 把缓存对一遍；同一轮里的多次变化合并成一次。 */
  private soon(): void {
    if (this.scheduled) return;
    this.scheduled = true;
    queueMicrotask(() => { this.scheduled = false; this.refresh(); });
  }

  refresh(): void {
    const { data, registry, store, roles, templates, catalog, skills } = this.deps;
    const items = (kind: LibraryKind, omit?: string[]) => new Map(data.list(kind, omit).map((item) => [item.id, item]));
    const accepted = (kind: string, id: string, apply: () => boolean) => {
      try { return apply(); }
      catch (error) { console.warn('[资源库同步] 跳过无法用于本机的内容', kind, id, (error as Error).message); return false; }
    };
    const changes: LibraryChanges = { roles: false, templates: false, skills: false, constraints: [] };

    const accountRoles = items('role');
    for (const item of accountRoles.values()) changes.roles = accepted('role', item.id, () => roles.cache(item.body)) || changes.roles;
    changes.roles = roles.keep(new Set(accountRoles.keys())) || changes.roles;

    const accountTemplates = items('template');
    for (const item of accountTemplates.values()) changes.templates = accepted('template', item.id, () => templates.cache(item.body)) || changes.templates;
    changes.templates = templates.keep(new Set(accountTemplates.keys())) || changes.templates;

    const accountSkills = items('skill', ['files']);
    for (const item of accountSkills.values()) changes.skills = accepted('skill', item.id, () => skills.cache(item.id, item.revision)) || changes.skills;
    changes.skills = skills.keep(new Set(accountSkills.keys())) || changes.skills;

    const accountEmblems = items('emblem');
    for (const item of accountEmblems.values()) {
      if (JSON.stringify(store.templateEmblem(item.id)) === JSON.stringify(item.body)) continue;
      store.saveTemplateEmblem(item.id, item.body as unknown as TemplateEmblem);
      changes.roles = true;
    }
    for (const { id, emblem } of store.templateEmblems()) if (!accountEmblems.has(id)) this.write('emblem', id, emblem);

    const accountPlugins = items('plugin', ['bundle']);
    catalog.setRemote([...accountPlugins.values()].map((item) => ({ meta: item.body, revision: item.revision })));
    for (const id of catalog.installedIds()) if (!accountPlugins.has(id)) this.write('plugin', id, catalog.package(id), null);

    for (const project of store.projects()) {
      let value;
      try { value = registry.constraints(project.id); } catch { continue; /* 登记表里还没有的项目没有约束。 */ }
      const before = store.projectConstraints(project.id);
      if (JSON.stringify(before) === JSON.stringify(value)) continue;
      store.saveProjectConstraints(project.id, value);
      changes.constraints.push({ projectId: project.id, ...(before ? { before } : {}) });
    }
    this.deps.changed(changes);
  }
}
