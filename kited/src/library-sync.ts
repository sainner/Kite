/**
 * 资源库随账号保存：角色、上下文模板、点阵签名与插件包写入时先到账号服务，成功后更新本机缓存；读取一律用缓存。
 * 加入账号后与账号服务保持一条事件流：连上时先全量同步一遍，之后账号里有变化（含其他设备的修改与项目约束）就再同步；
 * 断线后退避重连，重连时同样先同步。角色与模板的缓存以账号为准，账号里没有的从缓存去掉，内置的退回默认。
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

/** 账号服务每 25 秒发一次心跳，事件流超过这么久没有任何数据就当作断了。 */
const SILENCE_MS = 60_000;
const RETRY_MIN_MS = 1_000;
const RETRY_MAX_MS = 60_000;

export class LibrarySync {
  private pending?: Promise<void>;
  private again = false;
  private closed = false;
  /** 停机时中止进行中的账号请求与事件流，不等网络超时。 */
  private abort = new AbortController();
  /** 当前的事件流；换凭据时中止它，用新凭据立即重连。 */
  private stream?: AbortController;
  private reconnecting = false;
  private listening?: Promise<void>;
  /** 结束重连前的等待。 */
  private wake?: () => void;
  /** 正在后台写出的签名；拉取不拿账号里的旧版本覆盖它们。 */
  private publishing = new Map<string, number>();

  constructor(private deps: {
    account: AccountClient; store: Store; roles: Roles; templates: ContextTemplates; catalog: PluginCatalog;
    changed: (changes: LibraryChanges) => void;
  }) {}

  get linked(): boolean { return this.deps.account.linked; }

  /** 启动或加入账号、换了凭据时调用：断开旧的事件流，用当前凭据重新连接。没加入账号时不做事。 */
  connect(): void {
    if (this.closed) return;
    this.reconnecting = true;
    this.stream?.abort();
    this.wake?.();
    this.listening ??= this.listen().finally(() => { this.listening = undefined; });
  }

  /** 全量同步一遍；进行中时合并为一次补拉。失败只记日志，继续用缓存。 */
  refresh(): Promise<void> {
    if (!this.linked || this.closed) return Promise.resolve();
    if (this.pending) { this.again = true; return this.pending; }
    this.pending = (async () => {
      do {
        this.again = false;
        try { await this.pull(); }
        catch (error) { if (!this.closed) console.warn('[资源库同步]', (error as Error).message); }
      } while (this.again && !this.closed);
    })().finally(() => { this.pending = undefined; });
    return this.pending;
  }

  /** 写到账号服务；没加入账号时不做事，由调用方只存本机。版本冲突时补拉一次，让本机缓存跟上。 */
  async write(kind: LibraryItem['kind'], id: string, body: object, expectedRevision?: string | null): Promise<void> {
    if (!this.linked) return;
    try { await this.deps.account.putLibrary(kind, id, body, expectedRevision); }
    catch (error) {
      if (error instanceof KiteError && error.status === 409) void this.refresh();
      throw error;
    }
  }

  /** 后写为准的内容（点阵签名）在后台写出，失败等下次同步时再上传。 */
  publish(kind: LibraryItem['kind'], id: string, body: object): void {
    const key = `${kind}:${id}`;
    this.publishing.set(key, (this.publishing.get(key) ?? 0) + 1);
    this.write(kind, id, body).catch((error: unknown) => console.warn('[资源库同步]', kind, id, (error as Error).message))
      .finally(() => {
        const left = this.publishing.get(key)! - 1;
        if (left) this.publishing.set(key, left); else this.publishing.delete(key);
      });
  }

  /** 停机时中止事件流并等进行中的同步结束，之后不再访问本机数据库。 */
  async close(): Promise<void> {
    this.closed = true;
    this.abort.abort();
    this.wake?.();
    await Promise.all([this.pending, this.listening]);
  }

  /** 本机没装的插件包从账号下载安装；内置定义和已装的直接返回。 */
  async ensurePlugin(id: string): Promise<void> {
    const { catalog, account } = this.deps;
    if (catalog.installed(id) || catalog.get(id).runtime !== 'bun') return;
    catalog.install((await account.libraryItem('plugin', id)).body);
  }

  private async listen(): Promise<void> {
    let delay = RETRY_MIN_MS;
    while (!this.closed && this.linked) {
      const stream = this.stream = new AbortController();
      this.reconnecting = false;
      try {
        const body = await this.deps.account.libraryEvents(AbortSignal.any([stream.signal, this.abort.signal]));
        delay = RETRY_MIN_MS;
        await this.read(body, stream);
      } catch (error) {
        // 断线期间按退避重试，只在每轮断线的第一次记日志。
        if (!this.closed && !this.reconnecting && delay === RETRY_MIN_MS) console.warn('[资源库同步]', (error as Error).message);
      }
      if (this.closed || this.reconnecting) continue;
      await new Promise<void>((resolve) => {
        const timer = setTimeout(() => this.wake?.(), delay);
        this.wake = () => { clearTimeout(timer); this.wake = undefined; resolve(); };
      });
      delay = Math.min(delay * 2, RETRY_MAX_MS);
    }
  }

  /** 每条事件都触发一次全量同步，连上时服务先发的那条就是重连后的同步。 */
  private async read(body: ReadableStream<Uint8Array>, stream: AbortController): Promise<void> {
    const decoder = new TextDecoder();
    let buffer = '';
    let silence = setTimeout(() => stream.abort(), SILENCE_MS);
    try {
      for await (const chunk of body) {
        clearTimeout(silence);
        silence = setTimeout(() => stream.abort(), SILENCE_MS);
        const events = (buffer + decoder.decode(chunk, { stream: true })).split('\n\n');
        buffer = events.pop()!;
        if (events.some((event) => event.split('\n').some((line) => line.startsWith('data:')))) void this.refresh();
      }
    } finally {
      clearTimeout(silence);
    }
  }

  private async pull(): Promise<void> {
    const { account, store, roles, templates, catalog } = this.deps;
    const { signal } = this.abort;
    // 约束按项目取，与资源库列表一起并发请求；账号里还没登记的项目（404）没有约束。
    const [items, constraints] = await Promise.all([account.library(signal), Promise.all(store.projects().map((project) =>
      account.constraints(project.id, signal).then((value) => ({ projectId: project.id, value }), (error: unknown) => {
        if (error instanceof KiteError && error.status === 404) return undefined;
        throw error;
      })))]);
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
    changes.roles = roles.keep(new Set(remoteRoles.keys())) || changes.roles;

    const remoteTemplates = remote('template');
    for (const item of remoteTemplates.values()) changes.templates = accepted('template', item.id, () => templates.cache(item.body)) || changes.templates;
    changes.templates = templates.keep(new Set(remoteTemplates.keys())) || changes.templates;

    const remoteEmblems = remote('emblem');
    for (const item of remoteEmblems.values()) {
      if (this.publishing.has(`emblem:${item.id}`) || JSON.stringify(store.templateEmblem(item.id)) === JSON.stringify(item.body)) continue;
      store.saveTemplateEmblem(item.id, item.body as unknown as TemplateEmblem);
      changes.roles = true;
    }

    const remotePlugins = remote('plugin');
    catalog.setRemote([...remotePlugins.values()].map((item) => ({ meta: item.body, revision: item.revision })));
    // 本机有、账号里没有的签名与插件包一起补传
    await Promise.all([
      ...store.templateEmblems().filter(({ id }) => !remoteEmblems.has(id)).map(({ id, emblem }) => upload('emblem', id, emblem)),
      ...catalog.installedIds().filter((id) => !remotePlugins.has(id)).map((id) => upload('plugin', id, catalog.package(id), null)),
    ]);
    if (this.closed) return;

    for (const { projectId, value } of constraints.filter((entry) => entry !== undefined)) {
      const before = store.projectConstraints(projectId);
      if (JSON.stringify(before) === JSON.stringify(value)) continue;
      store.saveProjectConstraints(projectId, value);
      changes.constraints.push({ projectId, before: before?.tools });
    }
    this.deps.changed(changes);
  }
}
