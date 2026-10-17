/** 添加项目、检出的建立与远程同步；串行队列由 Kite 共享，停机等待仍由调用方负责。 */
import { existsSync, realpathSync, rmSync } from 'node:fs';
import { randomUUID } from 'node:crypto';
import { KiteError } from '../errors.ts';
import type { Bus } from '../events.ts';
import type { Checkout } from '../model.ts';
import { checkoutPath, within } from '../paths.ts';
import { normalizeRemote } from '../remote-url.ts';
import type { Store } from '../store.ts';
import type { GitCredentials } from '../git-credential.ts';
import type { Peer } from '../peer-fetch.ts';
import { gitHubRepo, type GitHubBinding } from '../account-data/github.ts';
import type { Integration, IntegrationChoice, ProjectRegistry, RegisteredProject } from '../account-data/registry.ts';
import { git } from './git.ts';
import { checkEnvFiles } from '../secrets.ts';
import { fetchMainline, mainRefs } from './mainline.ts';
import { clonePeers, createRepository, findEnvFiles, folderName, importFolder, inspectFolder, projectOf, readEnvFile, type Folder } from './projects.ts';
import { clone, originAccess, originSpelling, originURL, pushAll, remoteAccess, remoteHead, type RemoteAccess } from './remote.ts';
import { syncPeer, type PeerRoute } from './peer-git.ts';

/** 添加项目的来源：远程地址，或这台工作机上的文件夹。 */
export type ProjectSource = { remote: string } | { path: string };
/** 要存成项目密钥的环境变量文件：path 是在工作区里的路径；不带 value 时从所选文件夹里读。 */
export type EnvFile = { path: string; value?: string };

export interface ProjectCheck extends IntegrationChoice {
  /** 归一化的远程地址；没有远程的文件夹为 null。 */
  remote: string | null;
  /** 文件夹里被忽略的环境变量文件，远程为空。 */
  envFiles: string[];
  /** 同一远程已登记的项目。 */
  existing?: RegisteredProject;
}

/** 添加项目与访问远程要用的：项目登记表、Git 凭据、GitHub，没有远程的项目可以从哪几台工作机拉取，以及环境变量文件存成密钥。 */
export interface ProjectAccess {
  registry: ProjectRegistry;
  git: GitCredentials;
  github: GitHubBinding;
  peers(projectId: string): { route: PeerRoute; peers: Peer[] };
  /** 把环境变量文件存成设了路径的项目密钥：项目里已有设在这个路径的就换内容，没有就新建。 */
  saveEnvFiles(projectId: string, files: Array<{ path: string; value: string }>): Promise<void>;
  /** 添加中途失败：从登记表删掉这个项目，连同已经存下的项目密钥。 */
  discard(projectId: string): void;
}

export class CheckoutManagement {
  constructor(private store: Store, private home: string, private projects: ProjectAccess, private bus: Bus,
    private serial: <T>(key: string, action: () => Promise<T>) => Promise<T>) {}

  /** 远程的集成方式默认值：GitHub 按协作者与保护规则选，其他平台直接合入。head 是远程的默认分支。 */
  private async integrationFor(remote: string, head: string | null): Promise<IntegrationChoice> {
    const repo = gitHubRepo(remote);
    if (repo) return this.projects.github.integration(repo.owner, repo.repo, head);
    return { integration: 'merge', integrationReason: '自动开 PR 只支持 GitHub，其他平台默认直接合入' };
  }

  /** 选的文件夹：不能是 Kite 的数据目录、在它里面或包着它，否则 Kite 自己的凭据和会话记录会被导入。 */
  private async folder(path: string) {
    const folder = await inspectFolder(path);
    const home = existsSync(this.home) ? realpathSync(this.home) : this.home;
    if (within(folder.path, home) || within(home, folder.path)) throw new KiteError('不能添加 Kite 的数据目录，或包含它的文件夹');
    return folder;
  }

  /** 来源的远程：文件夹看它的 origin。raw 是原来的写法，remote 是归一化的地址，没有远程时都为 null。 */
  private async source(source: ProjectSource): Promise<{ folder: Folder | undefined; raw: string | null; remote: string | null }> {
    const folder = 'path' in source ? await this.folder(source.path) : undefined;
    const raw = folder ? folder.origin : (source as { remote: string }).remote;
    const remote = raw ? normalizeRemote(raw) : null;
    if (raw && !remote) throw new KiteError(folder ? `无法识别 origin 的地址：${raw}，请使用 GitHub、GitLab 等平台的仓库地址` : '远程地址格式无法识别');
    return { folder, raw, remote };
  }

  /** 添加项目前的检查，不写任何东西：确认远程能访问并给出集成方式的默认值，文件夹另列出被忽略的环境变量文件。 */
  async check(source: ProjectSource): Promise<ProjectCheck> {
    const { folder, raw, remote } = await this.source(source);
    // 本机扫文件夹与访问远程互不依赖，一起做。
    const [envFiles, head] = await Promise.all([folder ? findEnvFiles(folder) : [], raw ? remoteHead(raw, this.projects.git) : null]);
    if (!raw || !remote) return { remote: null, integration: 'merge', envFiles };
    const existing = this.projects.registry.byRemote(remote);
    return { remote, ...(await this.integrationFor(remote, head)), envFiles, ...(existing ? { existing } : {}) };
  }

  /**
   * 添加项目：远程与有 origin 的文件夹先确认能访问，再写进登记表，不 clone；没有远程的文件夹在这台工作机上导入成检出，原文件夹不动。
   * 环境变量文件存成设了路径的项目密钥。全部成功才登记；同一远程已登记时返回原项目，不改它的设置，环境变量文件存进它的项目密钥。
   */
  async add(source: ProjectSource, options: { integration?: Integration; envFiles?: EnvFile[] } = {}): Promise<RegisteredProject> {
    const { folder, raw, remote } = await this.source(source);
    const files = (options.envFiles ?? []).map(({ path, value }) => {
      if (value !== undefined) return { path, value };
      if (!folder) throw new KiteError('添加远程项目时环境变量文件要带内容');
      return { path, value: readEnvFile(folder, path) };
    });
    checkEnvFiles(files);
    if (raw && remote) return this.addRemote(raw, remote, options.integration, files);
    if (options.integration === 'pullRequest') throw new KiteError('没有远程的项目只能直接合入');
    return this.addLocal(folderName(folder!), (dest) => importFolder(folder!, dest), files);
  }

  /** 在这台工作机上新建一个没有远程的项目，检出里只有写着 files 的初始版本（启用 Line 时用）。 */
  create(name: string, files: Record<string, string>): Promise<RegisteredProject> {
    return this.addLocal(name, (dest) => createRepository(dest, files), []);
  }

  /** 没有远程的项目：build 在数据目录里建好检出，再登记项目、存环境变量文件、记下本机检出；中途失败什么都不留。 */
  private async addLocal(name: string, build: (dest: string) => Promise<void>, files: Array<{ path: string; value: string }>): Promise<RegisteredProject> {
    const id = randomUUID();
    const dest = checkoutPath(this.home, id);
    await build(dest);
    let registered: RegisteredProject | undefined;
    try {
      registered = this.projects.registry.createLocal(name, id);
      await this.projects.saveEnvFiles(id, files);
      await this.serial('register', async () => this.addCheckout(registered!, dest));
      return registered;
    } catch (error) {
      if (registered) this.projects.discard(id);
      rmSync(dest, { recursive: true, force: true });
      throw error;
    }
  }

  private async addRemote(raw: string, remote: string, integration: Integration | undefined, files: Array<{ path: string; value: string }>): Promise<RegisteredProject> {
    const known = this.projects.registry.byRemote(remote);
    if (known) {
      await this.projects.saveEnvFiles(known.id, files);
      return known;
    }
    const head = await remoteHead(raw, this.projects.git);
    const choice = integration ? { integration } : await this.integrationFor(remote, head);
    // 上面等网络期间可能已有别的请求登记了同一远程：登记前再查一次（与登记之间没有 await），那样就不是这次新建的，失败时不能删。
    const existing = this.projects.registry.byRemote(remote);
    const registered = existing ?? this.projects.registry.register(raw, choice);
    try { await this.projects.saveEnvFiles(registered.id, files); }
    catch (error) { if (!existing) this.projects.discard(registered.id); throw error; }
    return registered;
  }

  /** 记下本机在 path 的检出与项目；首次取得项目的约束，已有项目的缓存由资源库同步持续更新。调用方持有登记锁。 */
  private addCheckout(project: RegisteredProject, path: string): Checkout {
    const checkout: Checkout = { id: randomUUID(), projectId: project.id, machineId: this.store.machine.id, path, remote: project.remote, createdAt: Date.now() };
    const constraints = this.store.projectConstraints(project.id) ?? this.projects.registry.constraints(project.id);
    this.store.transaction(() => {
      this.store.addCheckout(projectOf(project), checkout);
      this.store.saveProjectConstraints(project.id, constraints);
    });
    this.bus.emit({ type: 'checkout.changed', projectId: project.id, checkoutId: checkout.id });
    return checkout;
  }

  /** 本机该项目的检出；没有时 clone 到数据目录：有远程的从远程，没有远程的从在线、有它检出的工作机。cloned 表示这次刚 clone，主线已是最新。 */
  async ensure(projectId: string): Promise<{ checkout: Checkout; cloned: boolean }> {
    const existing = this.store.checkouts(projectId)[0];
    if (existing) return { checkout: existing, cloned: false };
    return this.serial(`clone:${projectId}`, async () => {
      const again = this.store.checkouts(projectId)[0];
      if (again) return { checkout: again, cloned: false };
      const project = this.projects.registry.require(projectId);
      const dest = checkoutPath(this.home, projectId);
      // 数据目录里的检出只由 Kite 写；没有登记的是上次没 clone 完的。
      rmSync(dest, { recursive: true, force: true });
      if (project.url) await clone(project.url, dest, this.projects.git);
      else {
        const { route, peers } = this.projects.peers(projectId);
        await clonePeers(peers, route, projectId, dest);
      }
      return this.serial('register', async () => ({ checkout: this.addCheckout(this.projects.registry.get(projectId) ?? project, dest), cloned: true }));
    });
  }

  /**
   * 按项目登记表更新本机项目：并入了别的项目的，把本机检出改挂过去；名称或远程变了的跟上，设了远程后把各检出的 origin 改到新地址。
   * 给了 refreshed 时再拉取各检出的主线（见 refresh），每个检出拉完就把主线引用交给它，不等别的检出。返回有没有项目并入别的项目。
   */
  async syncProjects(refreshed?: (checkout: Checkout, mains: string[]) => Promise<void>): Promise<boolean> {
    const { registry } = this.projects;
    let merged = false;
    // 拉取要访问网络，放到登记锁外做，网络慢时不挡住本机登记。
    const checkouts: Checkout[] = [];
    await this.serial('register', async () => {
      for (let project of this.store.projects()) {
        const id = registry.canonical(project.id);
        const latest = id && registry.get(id);
        if (!latest) continue;
        if (latest.id !== project.id) {
          this.store.mergeProject(project.id, projectOf(latest));
          merged = true;
          for (const checkout of this.store.checkouts(latest.id)) this.bus.emit({ type: 'checkout.changed', projectId: latest.id, checkoutId: checkout.id });
          project = this.store.project(latest.id)!;
        }
        if (latest.remote !== project.remote || latest.name !== project.name) {
          this.store.saveProject({ ...project, name: latest.name, remote: latest.remote });
        }
        for (const checkout of this.store.checkouts(project.id)) {
          if (!existsSync(checkout.path)) continue;
          checkouts.push(checkout);
          if (!latest.remote || checkout.remote === latest.remote) continue;
          try {
            const origin = await originURL(checkout.path);
            if (!origin) await git(checkout.path, ['remote', 'add', 'origin', latest.url!]);
            else if (normalizeRemote(origin) !== latest.remote) await git(checkout.path, ['remote', 'set-url', 'origin', latest.url!]);
          } catch (error) {
            console.error(`[项目同步] 更新 ${checkout.path} 的 origin 失败：${(error as Error).message}`);
            continue;
          }
          this.store.setCheckoutRemote(checkout.id, latest.remote);
          this.bus.emit({ type: 'checkout.changed', projectId: project.id, checkoutId: checkout.id });
        }
      }
    });
    if (refreshed) await Promise.all(checkouts.map(async (checkout) => {
      try {
        const { mains, offline } = await this.serial(`checkout:${checkout.id}`, () => this.refresh(checkout));
        if (offline) console.warn(`[项目同步] ${offline}`);
        await refreshed(checkout, mains);
      } catch (error) { console.warn(`[项目同步] ${checkout.path}：${(error as Error).message}`); }
    }));
    return merged;
  }

  /**
   * 拉取最新的主线，调用方持有检出的串行锁：有远程的从远程拉，本机主线落后就快进；没有远程的从有它检出的其他工作机拉，同样只做快进，
   * 两边都有新提交时留给用户集成。拉不到时照用本机主线。返回主线的引用（见 mainRefs），拉取成功时另带访问方式，失败时带原因。
   */
  async refresh(checkout: Checkout): Promise<{ mains: string[]; access?: RemoteAccess; offline?: string }> {
    if (!this.store.project(checkout.projectId)?.remote) {
      await this.syncPeers(checkout);
      return { mains: await mainRefs(checkout) };
    }
    try {
      const access = await originAccess(checkout.path, this.projects.git);
      return { mains: await fetchMainline(checkout, access), access };
    } catch (error) { return { mains: await mainRefs(checkout).catch(() => []), offline: (error as Error).message }; }
  }

  /** 没有远程的项目：从有它检出的其他工作机拉取，能快进就快进本机主线，调用方持有检出的串行锁。连不上的跳过，下一轮再试。 */
  private async syncPeers(checkout: Checkout): Promise<void> {
    const { route, peers } = this.projects.peers(checkout.projectId);
    for (const peer of peers) {
      try {
        const result = await syncPeer(checkout.path, peer, checkout.projectId, route);
        if (result === 'forwarded') this.bus.emit({ type: 'checkout.changed', projectId: checkout.projectId, checkoutId: checkout.id });
        if (result === 'diverged') console.warn(`[项目同步] ${checkout.path} 与 ${peer.id} 的主线分叉了，要在工作区里集成`);
      } catch (error) { console.warn(`[项目同步] ${(error as Error).message}`); }
    }
  }

  /**
   * 给没有远程的项目设远程：用本机检出把全部分支和标签推上去，写进登记表（集成方式按仓库情况重选），再加上 origin。
   * 远程要是空的或与本机同一历史。登记表的校验放在推送之前：远程已属于别的项目时不能把这个项目的内容推过去。
   * origin 最后加，登记失败时检出保持原样可以重试；加 origin 失败的，项目同步按登记表补上。
   */
  async setRemote(projectId: string, raw: string): Promise<RegisteredProject> {
    const checkout = this.store.checkouts(projectId)[0];
    if (!checkout) throw new KiteError('这台工作机上没有这个项目的检出，到有检出的工作机上设远程', 409);
    const { registry } = this.projects;
    const remote = registry.checkRemote(projectId, raw);
    return this.serial(`checkout:${checkout.id}`, async () => {
      await pushAll(checkout.path, await remoteAccess(raw, this.projects.git));
      const choice = await this.integrationFor(remote, await remoteHead(raw, this.projects.git).catch(() => null));
      const updated = registry.setRemote(projectId, raw, choice);
      if (await originURL(checkout.path)) await git(checkout.path, ['remote', 'set-url', 'origin', originSpelling(raw)]);
      else await git(checkout.path, ['remote', 'add', 'origin', originSpelling(raw)]);
      await this.serial('register', async () => {
        this.store.saveProject(projectOf(updated));
        this.store.setCheckoutRemote(checkout.id, updated.remote);
      });
      this.bus.emit({ type: 'checkout.changed', projectId, checkoutId: checkout.id });
      return updated;
    });
  }
}
