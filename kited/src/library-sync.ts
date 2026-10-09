/**
 * 资源库随账号保存：角色、上下文模板、点阵签名与插件包写入时先到账号服务，成功后更新本机缓存；
 * 读取一律用缓存，后台拉取其他设备的修改，账号里还没有的本机内容顺带上传。项目约束同样按项目拉取缓存。
 * 工作机没加入账号时只用本机。
 */
import type { AccountClient, LibraryItem } from './account-client.ts';
import type { ContextTemplates } from './context-templates.ts';
import { KiteError } from './errors.ts';
import type { PluginCatalog } from './plugins/catalog.ts';
import type { ProjectToolRule, Roles } from './roles.ts';
import type { Store } from './store.ts';
import type { TemplateEmblem } from './template-emblems.ts';

/** constraints 列出约束变了的项目及变化前的规则。 */
export interface LibraryChanges { roles: boolean; templates: boolean; constraints: Array<{ projectId: string; before?: ProjectToolRule }> }

/** App 打开资源库页面时会触发拉取，短时间内的重复请求合并掉。 */
const REFRESH_INTERVAL_MS = 10_000;

export class LibrarySync {
  private pending?: Promise<void>;
  private again = false;
  private pulledAt = 0;
  private closed = false;
  /** 正在后台写出的签名；拉取不拿账号里的旧版本覆盖它们。 */
  private publishing = new Map<string, number>();

  constructor(private deps: {
    account: AccountClient; store: Store; roles: Roles; templates: ContextTemplates; catalog: PluginCatalog;
    changed: (changes: LibraryChanges) => void;
  }) {}

  get linked(): boolean { return this.deps.account.linked; }

  /** 后台拉取；进行中时合并为一次补拉。失败只记日志，继续用缓存。force 不受间隔限制。 */
  refresh(force = false): Promise<void> {
    if (!this.linked || this.closed) return Promise.resolve();
    if (this.pending) { this.again ||= force; return this.pending; }
    if (!force && Date.now() - this.pulledAt < REFRESH_INTERVAL_MS) return Promise.resolve();
    this.pending = (async () => {
      do {
        this.again = false;
        try { await this.pull(); this.pulledAt = Date.now(); }
        catch (error) { console.warn('[资源库同步]', (error as Error).message); }
      } while (this.again && !this.closed);
    })().finally(() => { this.pending = undefined; });
    return this.pending;
  }

  /** 写到账号服务；没加入账号时不做事，由调用方只存本机。版本冲突时补拉一次，让本机缓存跟上。 */
  async write(kind: LibraryItem['kind'], id: string, body: object, expectedRevision?: string | null): Promise<void> {
    if (!this.linked) return;
    try { await this.deps.account.putLibrary(kind, id, body, expectedRevision); }
    catch (error) {
      if (error instanceof KiteError && error.status === 409) void this.refresh(true);
      throw error;
    }
  }

  /** 后写为准的内容（点阵签名）在后台写出，失败等下次拉取时再上传。 */
  publish(kind: LibraryItem['kind'], id: string, body: object): void {
    const key = `${kind}:${id}`;
    this.publishing.set(key, (this.publishing.get(key) ?? 0) + 1);
    this.write(kind, id, body).catch((error: unknown) => console.warn('[资源库同步]', kind, id, (error as Error).message))
      .finally(() => {
        const left = this.publishing.get(key)! - 1;
        if (left) this.publishing.set(key, left); else this.publishing.delete(key);
      });
  }

  /** 停机时等进行中的拉取结束，之后不再访问本机数据库。 */
  async close(): Promise<void> {
    this.closed = true;
    await this.pending;
  }

  /** 本机没装的插件包从账号下载安装；内置定义和已装的直接返回。 */
  async ensurePlugin(id: string): Promise<void> {
    const { catalog, account } = this.deps;
    if (catalog.installed(id) || catalog.get(id).runtime !== 'bun') return;
    catalog.install((await account.libraryItem('plugin', id)).body);
  }

  private async pull(): Promise<void> {
    const { account, store, roles, templates, catalog } = this.deps;
    const items = await account.library();
    if (this.closed) return;
    const remote = (kind: LibraryItem['kind']) => new Map(items.filter((item) => item.kind === kind).map((item) => [item.id, item]));
    const upload = async (kind: LibraryItem['kind'], id: string, body: object, expectedRevision?: null) => {
      try { await account.putLibrary(kind, id, body, expectedRevision); }
      catch (error) { console.warn('[资源库同步] 上传失败', kind, id, (error as Error).message); }
    };
    const accepted = (kind: string, id: string, apply: () => boolean) => {
      try { return apply(); }
      catch (error) { console.warn('[资源库同步] 跳过无法用于本机的内容', kind, id, (error as Error).message); return false; }
    };
    const changes: LibraryChanges = { roles: false, templates: false, constraints: [] };

    const remoteRoles = remote('role');
    for (const item of remoteRoles.values()) changes.roles = accepted('role', item.id, () => roles.cache(item.body)) || changes.roles;
    for (const { role } of roles.list()) if (!remoteRoles.has(role.id)) await upload('role', role.id, role, null);

    const remoteTemplates = remote('template');
    for (const item of remoteTemplates.values()) changes.templates = accepted('template', item.id, () => templates.cache(item.body)) || changes.templates;
    for (const { definition } of templates.edited()) if (!remoteTemplates.has(definition.id)) await upload('template', definition.id, definition, null);

    const remoteEmblems = remote('emblem');
    for (const item of remoteEmblems.values()) {
      if (this.publishing.has(`emblem:${item.id}`) || JSON.stringify(store.templateEmblem(item.id)) === JSON.stringify(item.body)) continue;
      store.saveTemplateEmblem(item.id, item.body as unknown as TemplateEmblem);
      changes.roles = true;
    }
    for (const { id, emblem } of store.templateEmblems()) if (!remoteEmblems.has(id)) await upload('emblem', id, emblem);

    const remotePlugins = remote('plugin');
    catalog.setRemote([...remotePlugins.values()].map((item) => ({ meta: item.body, revision: item.revision })));
    for (const value of catalog.installedPackages()) if (!remotePlugins.has(value.id)) await upload('plugin', value.id, value, null);

    for (const project of store.projects()) {
      if (this.closed) return;
      let constraints;
      try { constraints = await account.constraints(project.id); }
      catch (error) { if (error instanceof KiteError && error.status === 404) continue; throw error; }
      const before = store.projectConstraints(project.id);
      if (JSON.stringify(before) === JSON.stringify(constraints)) continue;
      store.saveProjectConstraints(project.id, constraints);
      changes.constraints.push({ projectId: project.id, before: before?.tools });
    }
    this.deps.changed(changes);
  }
}
