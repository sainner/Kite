/** 检出登记、远程同步与现场推送；串行队列由 Kite 共享，停机等待仍由调用方负责。 */
import { existsSync } from 'node:fs';
import { KiteError } from '../errors.ts';
import type { Bus } from '../events.ts';
import type { Checkout, WorkspaceModel } from '../model.ts';
import { normalizeRemote } from '../remote-url.ts';
import type { Store } from '../store.ts';
import { commitAll, git, isAncestor, isDirty } from './git.ts';
import { mainline } from './mainline.ts';
import { cloneRemote, clonePeerProject, cloneTarget, projectOf, register, type ProjectAccess } from './projects.ts';
import { checkoutSync, currentBranch, fetchBranch, originAccess, originSpelling, originURL, pushAll, pushBranch, remoteAccess, type CheckoutSync } from './remote.ts';
import { syncPeer } from './peer-git.ts';

/** 登记本机文件夹（path），clone 远程（remote），或从别的工作机 clone 没有远程的项目（project）；后两种 path 可选。 */
export type CheckoutRequest = { path: string } | { remote: string; path?: string } | { project: string; path?: string };

export class CheckoutManagement {
  /** 正在 clone 的目标目录，clone 期间不持登记锁。 */
  private cloning = new Set<string>();

  constructor(private store: Store, private home: string, private projects: ProjectAccess, private bus: Bus,
    private serial: <T>(key: string, action: () => Promise<T>) => Promise<T>) {}

  async register(request: CheckoutRequest): Promise<WorkspaceModel> {
    // realpath 和目录重叠检查也在锁内，两个别名不能登记出重复检出。
    const registered = (model: WorkspaceModel) => {
      this.bus.emit({ type: 'checkout.changed', projectId: model.project.id, checkoutId: model.checkout.id });
      this.bus.emit({ type: 'workspace.changed', workspaceId: model.workspace.id, status: this.store.workspace(model.workspace.id)!.status });
      return model;
    };
    if (!('remote' in request) && !('project' in request)) {
      return this.serial('register', async () => registered(await register(this.store, this.home, this.projects, request.path, { cloning: this.cloning })));
    }
    // clone 可能很久，放在登记锁外；目标目录先占位，其他登记不能与它重叠。
    const source = 'remote' in request ? { remote: request.remote } : { id: request.project, name: this.projects.registry.require(request.project).name };
    const dest = await this.serial('register', async () => {
      const dest = cloneTarget(this.store, this.home, source, request.path, this.cloning);
      this.cloning.add(dest);
      return dest;
    });
    try {
      const project = 'remote' in request ? await cloneRemote(this.projects, request.remote, dest) : await clonePeerProject(this.projects, request.project, dest);
      return await this.serial('register', async () => {
        this.cloning.delete(dest);
        return registered(await register(this.store, this.home, this.projects, dest, { cloned: project, cloning: this.cloning }));
      });
    } finally { this.cloning.delete(dest); }
  }
  /**
   * 按项目登记表更新本机项目：并入了别的项目的，把本机检出改挂过去；名称或远程变了的跟上，设了远程后把各检出的 origin 改到新地址。
   * 没有远程的项目从有它检出的其他工作机拉取，本机主线落后就快进；两边都有新提交时不合并，留给用户集成。
   */
  async syncProjects(): Promise<boolean> {
    const { registry } = this.projects;
    let merged = false;
    // 没有远程的项目要访问别的工作机，放到登记锁外做，网络慢时不挡住本机登记。
    const local: Checkout[] = [];
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
          if (!latest.remote) { local.push(checkout); continue; }
          if (checkout.remote === latest.remote) continue;
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
    for (const checkout of local) await this.syncPeers(checkout);
    return merged;
  }

  /**
   * 没有远程的项目：从有它检出的其他工作机拉取，能快进就快进本机主线。连不上的跳过，下一轮再试。
   * 调用方已持有这个检出的串行锁时传 locked（例如采纳），否则在锁里做。
   */
  async syncPeers(checkout: Checkout, locked = false): Promise<void> {
    const { route, peers } = this.projects.peers(checkout.projectId);
    for (const peer of peers) {
      try {
        const sync = () => syncPeer(checkout.path, peer, checkout.projectId, route);
        const result = await (locked ? sync() : this.serial(`checkout:${checkout.id}`, sync));
        if (result === 'forwarded') this.bus.emit({ type: 'checkout.changed', projectId: checkout.projectId, checkoutId: checkout.id });
        if (result === 'diverged') console.warn(`[项目同步] ${checkout.path} 与 ${peer.id} 的主线分叉了，要在工作区里集成`);
      } catch (error) { console.warn(`[项目同步] ${(error as Error).message}`); }
    }
  }

  /**
   * 给没有远程的项目设远程：用本机检出把全部分支和标签推上去，写进登记表，再加上 origin。远程要是空的或与本机同一历史。
   * 登记表的校验放在推送之前：远程已属于别的项目时不能把这个项目的内容推过去。origin 最后加，登记失败时检出保持原样可以重试；
   * 加 origin 失败的，项目同步按登记表补上。
   */
  async setRemote(projectId: string, raw: string): Promise<ReturnType<ProjectAccess['registry']['get']>> {
    const checkout = this.store.checkouts(projectId)[0];
    if (!checkout) throw new KiteError('这台工作机上没有这个项目的检出，到有检出的工作机上设远程', 409);
    const { registry } = this.projects;
    registry.checkRemote(projectId, raw);
    return this.serial(`checkout:${checkout.id}`, async () => {
      await pushAll(checkout.path, await remoteAccess(raw, this.projects.git));
      const updated = registry.setRemote(projectId, raw);
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

  /** 现场与远程的关系，基于最近一次拉取的结果。只读，不排在集成与推送的网络操作后面。 */
  sync(id: string): Promise<CheckoutSync> { return checkoutSync(this.get(id).path); }
  /**
   * 现场的「提交并推送」，由用户触发。远程落后时把现场改动提交（message 为提交说明）后推送；
   * 远程领先而现场没有新东西时快进；两边都有新东西时不在现场合并，请用户新建工作区处理。
   */
  push(id: string, message?: string): Promise<CheckoutSync> {
    const c = this.get(id);
    return this.serial(`checkout:${c.id}`, async () => {
      const branch = await currentBranch(c.path);
      if (!branch) throw new KiteError('检出现场不在任何分支上，先切回主线分支', 409);
      const dirty = await isDirty(c.path);
      if (dirty && !message?.trim()) throw new KiteError('现场有未提交的改动，请填写提交说明', 400);
      // 没有远程的项目只提交，其他工作机同步时快进过来。
      if (!this.store.project(c.projectId)?.remote) {
        if (dirty) await commitAll(c.path, ['-m', message!.trim()]);
        return checkoutSync(c.path);
      }
      const access = await originAccess(c.path, this.projects.git);
      const upstream = await fetchBranch(c.path, branch, access);
      const head = await mainline(c);
      if (upstream && !(await isAncestor(c.path, upstream, head))) {
        if (dirty || !(await isAncestor(c.path, head, upstream))) {
          throw new KiteError('远程有新的提交，和现场的改动分叉了。请新建工作区，在工作区里集成', 409);
        }
        await git(c.path, ['merge', '-q', '--ff-only', upstream]);
        return checkoutSync(c.path);
      }
      if (dirty) await commitAll(c.path, ['-m', message!.trim()]);
      if (await pushBranch(c.path, branch, access) === 'rejected') throw new KiteError('远程刚有新的提交，请重试', 409);
      return checkoutSync(c.path);
    });
  }
  get(id: string): Checkout {
    const c = this.store.checkout(id);
    if (!c) throw new KiteError(`没有这个检出：${id}`, 404);
    return c;
  }
}
