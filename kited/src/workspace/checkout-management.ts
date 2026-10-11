/** 检出登记、远程同步与现场推送；串行队列由 Kite 共享，停机等待仍由调用方负责。 */
import { existsSync } from 'node:fs';
import type { AccountClient } from '../account-client.ts';
import { KiteError } from '../errors.ts';
import type { Bus } from '../events.ts';
import type { Checkout, WorkspaceModel } from '../model.ts';
import { normalizeRemote } from '../remote-url.ts';
import type { Store } from '../store.ts';
import { commitAll, git, isAncestor, isDirty } from './git.ts';
import { mainline } from './mainline.ts';
import { cloneRemote, cloneTarget, register } from './projects.ts';
import { checkoutSync, currentBranch, fetchBranch, originAccess, originURL, pushBranch, type CheckoutSync } from './remote.ts';

export class CheckoutManagement {
  /** 正在 clone 的目标目录，clone 期间不持登记锁。 */
  private cloning = new Set<string>();

  constructor(private store: Store, private home: string, private account: AccountClient, private bus: Bus,
    private serial: <T>(key: string, action: () => Promise<T>) => Promise<T>) {}

  /** 登记本机文件夹（path）或 clone 远程（remote，path 可选）。 */
  async register(request: { path: string; remote?: undefined } | { remote: string; path?: string }): Promise<WorkspaceModel> {
    // realpath 和目录重叠检查也在锁内，两个别名不能登记出重复检出。
    const registered = (model: WorkspaceModel) => {
      this.bus.emit({ type: 'checkout.changed', projectId: model.project.id, checkoutId: model.checkout.id });
      this.bus.emit({ type: 'workspace.changed', workspaceId: model.workspace.id, status: this.store.workspace(model.workspace.id)!.status });
      return model;
    };
    if (request.remote === undefined) {
      return this.serial('register', async () => registered(await register(this.store, this.home, this.account, request.path, { cloning: this.cloning })));
    }
    // clone 可能很久，放在登记锁外；目标目录先占位，其他登记不能与它重叠。
    const { remote, path } = request;
    const dest = await this.serial('register', async () => {
      const dest = cloneTarget(this.store, this.home, remote, path, this.cloning);
      this.cloning.add(dest);
      return dest;
    });
    try {
      const project = await cloneRemote(this.account, remote, dest);
      return await this.serial('register', async () => {
        this.cloning.delete(dest);
        return registered(await register(this.store, this.home, this.account, dest, { cloned: project, cloning: this.cloning }));
      });
    } finally { this.cloning.delete(dest); }
  }
  /**
   * 按账号的项目登记表更新本机项目。远程迁移后把各检出的 origin 改到新地址，
   * 目录上报随 checkout.changed 带上新远程，账号服务据此删除托管仓库。
   */
  async syncProjects(): Promise<void> {
    // 登记表在锁外取，账号服务不通时不挡住本机登记。
    const projects = await this.account.projects();
    await this.serial('register', async () => {
      const registered = new Map(projects.map((p) => [p.id, p]));
      for (const project of this.store.projects()) {
        const latest = registered.get(project.id);
        if (!latest) continue;
        if (latest.remote !== project.remote || latest.name !== project.name) {
          this.store.saveProject({ ...project, name: latest.name, remote: latest.remote });
        }
        for (const checkout of this.store.checkouts(project.id)) {
          if (checkout.remote === latest.remote || !existsSync(checkout.path)) continue;
          try {
            const origin = await originURL(checkout.path);
            if (!origin || normalizeRemote(origin) !== latest.remote) await git(checkout.path, ['remote', 'set-url', 'origin', latest.url]);
          } catch (error) {
            console.error(`[项目同步] 更新 ${checkout.path} 的 origin 失败：${(error as Error).message}`);
            continue;
          }
          this.store.setCheckoutRemote(checkout.id, latest.remote);
          this.bus.emit({ type: 'checkout.changed', projectId: project.id, checkoutId: checkout.id });
        }
      }
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
      const access = await originAccess(c.path, this.account);
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
