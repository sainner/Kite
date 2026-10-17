/**
 * 工作区跨机流转：工作区的执行数据平时就以副本跟进到其他工作机（replica.ts），交接只剩递执行权。
 * 源机停下工作区、保存最后的快照，进入可交接状态；目标机把副本补到末尾、装到本机、跑 setup，再接过执行权：
 * 有远程的项目在远程的 lease 上比较后更新（workspace/lease.ts），没有远程的项目由目标通知源机交出（两台都要在线）。
 * 执行设备失联时，用户可以让别的工作机用手上的副本强制接管。约定见 docs/Line与工作区流转.md「工作区流转」。
 */
import { cpSync, existsSync, mkdirSync, readdirSync, renameSync, rmSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { randomUUID } from 'node:crypto';
import { KiteError } from '../errors.ts';
import { setupLogPath, worktreePath } from '../paths.ts';
import type { GitCredentials } from '../git-credential.ts';
import { holds, type AgentInstance, type Checkout, type Workspace, type WorkspaceModel, type WorkspaceStatus } from '../model.ts';
import type { Store } from '../store.ts';
import { runtimeLogin, type Environment } from '../environment.ts';
import { git, gitTry, revParse } from '../workspace/git.ts';
import { originAccess, type RemoteAccess } from '../workspace/remote.ts';
import { readLease, remoteLeases, writeLease, type Lease } from '../workspace/lease.ts';
import { addWorktree, removeWorktree, runSetup } from '../workspace/worktrees.ts';
import { forgetWorktree, snapshotRef } from '../workspace/snapshots.ts';
import { installRecords, readRecords, recordPaths } from './records.ts';
import { replicaRef, type Replicas } from './replica.ts';

export interface TransferHost {
  store: Store;
  home: string;
  git: GitCredentials;
  /** 本机手上的工作区副本。 */
  replicas: Replicas;
  /** 目录里在线的一台工作机；不在线为 undefined。 */
  online(machine: string): { id: string; address: string } | undefined;
  /** 其他工作机的目录摘要里这个工作区的记录。 */
  elsewhere(workspaceId: string): Array<{ machine: string; epoch: number; status: WorkspaceStatus }>;
  /** 调另一台工作机的接口，非 2xx 抛错。 */
  call(machine: string, method: string, path: string, body?: unknown): Promise<unknown>;
  /** 工作区控制锁：与线程控制、快照、采纳互斥。 */
  control<T>(workspaceId: string, action: () => Promise<T>): Promise<T>;
  workspace(id: string): WorkspaceModel;
  /** 线程的显示状态，只读，不启动执行。 */
  threadState(id: string): Promise<{ phase: string; busy: boolean; recovery?: unknown }>;
  stopThread(thread: AgentInstance): Promise<void>;
  /** 停下工作区的插件进程，返回放行函数。 */
  closePlugins(workspaceId: string): Promise<() => void>;
  snapshot(workspace: Workspace, label: string): Promise<void>;
  setStatus(workspaceId: string, status: WorkspaceStatus): void;
  changed(workspaceId: string): void;
  /** 工作区记录已从本机删除（还原失败清理）。 */
  removed(workspaceId: string): void;
  /** 这些线程的会话记录换了：按旧记录读出的显示历史作废。 */
  recordsReplaced(threadIds: string[]): void;
  environment(projectId: string): Promise<Environment>;
  /** 本机该项目的检出；没有时 clone 到数据目录并登记。 */
  ensureCheckout(projectId: string): Promise<Checkout>;
  /** 把项目设了路径的密钥写进工作树，在 setup 之前。 */
  writeSecrets(projectId: string, cwd: string): Promise<void>;
  /**
   * 执行权已在别的机器：冻结本地记录。handingOff 给出时只冻结仍以这一 epoch 交接中的工作区，并记下交给的那台；
   * 已撤回、或已交给别的那台时 409。状态在冻结的锁里核对，与撤回交接互斥。
   */
  freeze(workspaceId: string, handingOff?: { epoch: number; to: string }): Promise<void>;
}

/** 执行权还是本机这一代的。 */
const heldHere = (lease: Lease, w: Workspace, machine: string) => lease.machine === machine && lease.epoch === w.epoch;
/** 执行权已被别的机器接管：机器不是本机，epoch 比本地记录高。 */
const takenOver = (lease: Lease, w: Workspace, machine: string) => lease.machine !== machine && lease.epoch > w.epoch;

export class WorkspaceTransfers {
  constructor(private host: TransferHost) {}

  private get machine() { return this.host.store.machine.id; }

  /** 远程上的 lease 与它的提交；从未流转过时为 undefined。 */
  private async lease(checkout: Checkout, workspaceId: string, access: RemoteAccess): Promise<{ commit: string; lease: Lease } | undefined> {
    const commit = (await remoteLeases(checkout.path, access)).get(workspaceId);
    return commit ? { commit, lease: await readLease(checkout.path, workspaceId, commit, access) } : undefined;
  }

  /**
   * 交出工作区：所有线程空闲、没有恢复阻塞与结果未知的操作才行，不满足就拒绝。进入可交接状态后本地拒绝新的执行，
   * 停下执行进程，保存最后的快照；有远程的项目同时把 lease 置为 handing_off。中途失败停在可交接状态，可以重试或撤回。
   */
  handover(id: string): Promise<{ epoch: number }> {
    return this.host.control(id, async () => {
      const { workspace: w, checkout, project } = this.host.workspace(id);
      if (w.status !== 'open' && w.status !== 'handing_off') throw new KiteError('只有已打开的工作区可以交接', 409);
      const threads = this.host.store.threads(id).filter((t) => t.status !== 'archived');
      for (const t of threads) {
        const state = await this.host.threadState(t.id);
        if (state.busy || state.phase !== 'idle' || state.recovery) throw new KiteError('有线程正在工作或等待恢复确认，空闲后再交接', 409);
      }
      if (this.host.store.unfinishedOperations(id)) throw new KiteError('工作区有结果尚未确认的操作，先核查再交接', 409);
      const access = project.remote ? await originAccess(checkout.path, this.host.git) : undefined;
      if (access) {
        // lease 的推送同时探测平台是否接受自定义 ref：被拒时在这里明确报错，不改走别的路径。
        const current = await this.lease(checkout, id, access);
        if (current && !heldHere(current.lease, w, this.machine)) throw new KiteError('执行权已不在这台工作机', 409);
        if (current?.lease.state !== 'handing_off') {
          const written = await writeLease(checkout.path, id, { machine: this.machine, epoch: w.epoch, state: 'handing_off' }, current?.commit ?? null, access);
          if (written.status === 'conflict') throw new KiteError('执行权刚被别的工作机改动，请稍后重试', 409);
        }
      }
      this.host.setStatus(id, 'handing_off');
      for (const t of threads) await this.host.stopThread(t);
      const release = await this.host.closePlugins(id);
      try { if (existsSync(w.cwd)) await this.host.snapshot(w, '交接前保存'); }
      finally { release(); }
      return { epoch: w.epoch };
    });
  }

  /** 目标还没接管时撤回交接，工作区重新开放。已被接管时 409，并冻结本地记录。 */
  async cancel(id: string): Promise<WorkspaceModel> {
    let lost = false;
    try {
      return await this.host.control(id, async () => {
        const { workspace: w, checkout, project } = this.host.workspace(id);
        if (w.status !== 'handing_off') throw new KiteError('工作区没有在交接', 409);
        if (project.remote) {
          const access = await originAccess(checkout.path, this.host.git);
          const current = await this.lease(checkout, id, access);
          if (current && !heldHere(current.lease, w, this.machine)) {
            lost = true;
            throw new KiteError('另一台工作机已经接管了这个工作区', 409);
          }
          if (current?.lease.state === 'handing_off') {
            const written = await writeLease(checkout.path, id, { machine: this.machine, epoch: w.epoch, state: 'active' }, current.commit, access);
            if (written.status === 'conflict') { lost = true; throw new KiteError('另一台工作机正在接管这个工作区', 409); }
          }
        }
        this.host.setStatus(id, 'open');
        return this.host.workspace(id);
      });
    } finally { if (lost) await this.check(id); }
  }

  /**
   * 没有远程的项目：目标机装好工作区后通知源机交出，源机冻结本地记录并记下目标。源机已撤回交接（工作区重新开放）、epoch 对不上，
   * 或这次交接已经交给了别的工作机时 409，目标放弃这次接管：几台同时拿着副本来接，只有先到的那台成功。
   * 已经交给同一台的再收到通知照样成功，目标重试不出错。
   */
  async complete(id: string, epoch: number, machine: string): Promise<{ ok: true }> {
    const w = this.host.store.workspace(id);
    if (!w) throw new KiteError('这台工作机上没有这个工作区', 404);
    await this.host.freeze(id, { epoch, to: machine });
    return { ok: true };
  }

  /** 立即核对一个工作区的执行权；已被别的机器接管就冻结。 */
  async check(id: string): Promise<WorkspaceModel> {
    const { workspace: w, checkout, project } = this.host.workspace(id);
    if (holds(w) && await this.taken(w, checkout, project.remote)) await this.host.freeze(id);
    return this.host.workspace(id);
  }

  /**
   * 联网后核对本机持有的全部工作区，已被接管的冻结。有远程的项目看远程上的 lease：各检出的远程互不相干，一起查，一个远程卡住不耽误别的；
   * 同一检出里的逐个读，免得同一仓库里的 git 互相抢锁。没有远程的项目看其他工作机的目录摘要里是否有 epoch 更高的同一工作区。
   * 查不到时按仍持有继续，所以接管默认要求源机先进入可交接状态。
   */
  async checkAll(): Promise<void> {
    const held = this.host.store.workspaces().filter((w) => holds(w));
    await Promise.all(this.host.store.checkouts().map(async (checkout) => {
      const local = held.filter((w) => w.checkoutId === checkout.id);
      if (!local.length || !existsSync(checkout.path)) return;
      const remote = this.host.store.project(checkout.projectId)?.remote ?? null;
      if (!remote) {
        for (const w of local) if (await this.taken(w, checkout, null)) await this.host.freeze(w.id);
        return;
      }
      let leases: Map<string, string>;
      let access: RemoteAccess;
      try {
        access = await originAccess(checkout.path, this.host.git);
        leases = await remoteLeases(checkout.path, access);
      } catch { return; }
      for (const w of local) {
        const commit = leases.get(w.id);
        if (!commit) continue;
        try {
          if (takenOver(await readLease(checkout.path, w.id, commit, access), w, this.machine)) await this.host.freeze(w.id);
        } catch (error) { console.error(`[执行权] 核对工作区 ${w.id} 失败：${(error as Error).message}`); }
      }
    }));
  }

  private async taken(w: Workspace, checkout: Checkout, remote: string | null): Promise<boolean> {
    if (!remote) return this.host.elsewhere(w.id).some((entry) => entry.machine !== this.machine && holds(entry) && entry.epoch > w.epoch);
    const current = await this.lease(checkout, w.id, await originAccess(checkout.path, this.host.git));
    return !!current && takenOver(current.lease, w, this.machine);
  }

  /**
   * 在本机还原并接管流转来的工作区。from 是交出它的工作机：先把副本补到它的末尾，核对它已在可交接状态。
   * force 是用户声明源机已丢失后的强制接管：不联系源机，用本机手上的副本；源机回来后看到更高的 epoch 就冻结。
   */
  restore(projectId: string, workspaceId: string, options: { from?: string; force?: boolean } = {}): Promise<WorkspaceModel> {
    // 同一工作区的还原排队：工作树目录与会话目录按工作区和实例 ID 命名，两次还原不能交错。
    // 还原期间占住本机的副本：失败回滚后副本还在，可以再试或强制接管。
    return this.host.control(workspaceId, () => this.host.replicas.using(workspaceId, () => this.restoreHere(projectId, workspaceId, options)));
  }

  /**
   * 工作区流转回原机时，本机有同一 ID 的冻结或归档记录、它的会话文件与快照链。接管成功之前这些都不能丢：
   * 替换前先导出旧行、把会被覆盖的文件挪到备份目录、记下旧快照引用，失败时原样还原，只清掉这次新建的东西；
   * 接管成功后才删备份。数据库替换不挪到接管之后，是因为接管后再导入失败会留下「执行权已转来却没有记录」的状态。
   */
  private async restoreHere(projectId: string, workspaceId: string, options: { from?: string; force?: boolean }): Promise<WorkspaceModel> {
    const existing = this.host.store.workspace(workspaceId);
    if (existing && holds(existing)) throw new KiteError('这台工作机上已有这个工作区', 409);
    const environment = await this.host.environment(projectId);
    const checkout = await this.host.ensureCheckout(projectId);
    const remote = this.host.store.project(projectId)?.remote ?? null;
    const from = options.force ? undefined : options.from ?? this.host.replicas.store.state(workspaceId)?.holder;
    if (!options.force) {
      const holder = from && this.host.online(from);
      if (!holder) throw new KiteError('交出这个工作区的工作机不在线；确认它已丢失时可以强制接管', 409);
      await this.host.replicas.catchUp(holder, workspaceId);
    }
    const dir = this.host.replicas.store.dir(workspaceId);
    if (!this.host.replicas.store.state(workspaceId)?.complete) throw new KiteError('这台工作机上没有这个工作区的完整副本', 409);
    const { manifest, rows } = readRecords(dir);
    if (manifest.projectId !== projectId || manifest.workspaceId !== workspaceId) throw new KiteError('副本与请求的项目或工作区不符', 409);
    if (!options.force && manifest.machine !== from) throw new KiteError('副本不是来自交出它的工作机', 409);
    const handingOff = this.host.elsewhere(workspaceId).find((entry) => entry.machine === manifest.machine);
    if (!options.force && (rows.workspaces[0]?.status !== 'handing_off' || (handingOff && handingOff.epoch !== manifest.epoch))) {
      throw new KiteError('源工作机不在可交接状态，可能已撤回交接或已被接管', 409);
    }
    const access = remote ? await originAccess(checkout.path, this.host.git) : undefined;
    const current = access ? await this.lease(checkout, workspaceId, access) : undefined;
    if (access && !options.force) {
      if (!current || current.lease.state !== 'handing_off' || current.lease.machine !== manifest.machine || current.lease.epoch !== manifest.epoch) {
        throw new KiteError('源工作机不在可交接状态，可能已撤回交接或已被接管', 409);
      }
    }
    for (const runtime of new Set(manifest.threads.map((t) => t.runtime))) {
      const login = runtimeLogin(environment, runtime);
      if (login.status !== 'ready') throw new KiteError(`这台工作机不能继续这个工作区的会话：${login.message}`, 409);
    }
    const snapshots = await revParse(checkout.path, replicaRef(workspaceId, 'snapshots'));
    const epoch = Math.max(manifest.epoch, current?.lease.epoch ?? 0) + 1;
    const backup = join(this.host.home, 'transfers', randomUUID());
    const cleanup: Array<() => Promise<unknown> | unknown> = [];
    let storeTouched = false;
    try {
      const branch = await revParse(checkout.path, replicaRef(workspaceId, 'branch'));
      if (!branch) throw new KiteError('副本里没有这个工作区的分支，本机检出没取到', 409);
      const cwd = worktreePath(this.host.home, projectId, workspaceId);
      if (existsSync(cwd)) throw new KiteError('本机还留着这个工作区的旧工作树，先归档本机的旧记录', 409);
      await git(checkout.path, ['update-ref', `refs/heads/${manifest.branch}`, branch]);
      cleanup.push(() => removeWorktree(checkout.path, cwd, manifest.branch));
      await addWorktree(checkout.path, cwd, manifest.branch, null);
      // 最后一个快照的树就是交接时的工作树，含未提交的改动。
      if (snapshots) await git(cwd, ['restore', `--source=${snapshots}`, '--worktree', '--', ':/']);
      const previousSnapshots = await revParse(checkout.path, snapshotRef(workspaceId));
      if (snapshots) {
        await git(checkout.path, ['update-ref', snapshotRef(workspaceId), snapshots]);
        cleanup.push(() => previousSnapshots ? git(checkout.path, ['update-ref', snapshotRef(workspaceId), previousSnapshots])
          : gitTry(checkout.path, ['update-ref', '-d', snapshotRef(workspaceId)]));
      }
      // 快照链换成了副本里的，按路径记的快照缓存要重查。
      forgetWorktree(cwd);
      // 会被覆盖的会话文件先挪开；还原时这些路径上只可能是这次新装的或挪开的旧文件，一并删掉再把旧的挪回。
      const paths = recordPaths(manifest, this.host.home, cwd);
      const aside: Array<[string, string]> = [];
      cleanup.push(() => {
        for (const path of paths) rmSync(path, { recursive: true, force: true });
        for (const [path, saved] of aside) { mkdirSync(dirname(path), { recursive: true }); move(saved, path); }
      });
      paths.forEach((path, index) => {
        if (!existsSync(path)) return;
        mkdirSync(backup, { recursive: true });
        move(path, join(backup, String(index)));
        aside.push([path, join(backup, String(index))]);
      });
      installRecords(dir, manifest, this.host.home, cwd);
      const cursors = new Map(manifest.threads.map((t) => [t.instanceId, t.cursor]));
      const previousRows = existing && this.host.store.exportWorkspaceRows(workspaceId);
      this.host.store.transaction(() => {
        if (existing) this.host.store.deleteWorkspaceRows(workspaceId);
        this.host.store.importWorkspaceRows(rows, { checkout_id: checkout.id, cwd, status: 'preparing', epoch: manifest.epoch }, cursors);
      });
      storeTouched = true;
      // 流转回来过的工作机还留着离开前读出的历史，换成副本里的记录后要重读；还原时同样
      const threadIds = manifest.threads.map((thread) => thread.instanceId);
      this.host.recordsReplaced(threadIds);
      cleanup.push(() => this.host.store.transaction(() => {
        this.host.store.deleteWorkspaceRows(workspaceId);
        if (previousRows) this.host.store.restoreWorkspaceRows(previousRows);
      }), () => this.host.recordsReplaced(threadIds));
      this.host.changed(workspaceId);
      const model = this.host.workspace(workspaceId);
      await this.host.writeSecrets(projectId, cwd);
      const setup = await runSetup(checkout.path, cwd, setupLogPath(this.host.home, workspaceId), this.host.home);
      if (setup && setup.exit !== 0) throw new KiteError(`初始化脚本退出码 ${setup.exit}`, 409);
      await this.host.snapshot(model.workspace, options.force ? '强制接管到这台工作机' : '流转到这台工作机');
      if (access) {
        const taken = await writeLease(checkout.path, workspaceId, { machine: this.machine, epoch, state: 'active' }, current?.commit ?? null, access);
        if (taken.status === 'conflict') throw new KiteError('接管时执行权已被改动，源工作机可能撤回了交接', 409);
      } else if (!options.force) {
        const complete = () => this.host.call(manifest.machine, 'POST', `/workspaces/${workspaceId}/handover/complete`,
          { epoch: manifest.epoch, machine: this.machine });
        // 源机可能已经交给本机、只是回应没送到：再通知一次，交给本机的照样成功；已撤回或交给了别的工作机时仍然失败，放弃这次接管。
        try { await complete(); } catch { await complete(); }
      }
      cleanup.length = 0;
      rmSync(backup, { recursive: true, force: true });
      this.host.store.setWorkspaceEpoch(workspaceId, epoch);
      this.host.setStatus(workspaceId, 'open');
      return this.host.workspace(workspaceId);
    } catch (error) {
      let restored = true;
      for (const step of cleanup.reverse()) {
        try { await step(); } catch (cleanupError) { restored = false; console.error(`[流转] 清理失败：${(cleanupError as Error).message}`); }
      }
      // 还原出错时备份目录留着，旧文件还能手动找回；全部还原后才删。
      if (existsSync(backup) && !readdirSync(backup).length) rmSync(backup, { recursive: true, force: true });
      if (storeTouched) {
        if (this.host.store.workspace(workspaceId)) this.host.changed(workspaceId);
        else this.host.removed(workspaceId);
      }
      // 清理全部成功时本机回到还原前、执行权未动，结果是确定的失败；否则留给收据记成结果未知，先核查再重试。
      if (restored && !(error instanceof KiteError)) throw new KiteError(`还原失败，本机已回到还原前：${(error as Error).message}`, 409);
      throw error;
    }
  }
}

/** 挪动文件或目录；会话目录与 Claude 配置目录可能不在同一个卷，跨卷时复制后删除。 */
function move(from: string, to: string): void {
  try { renameSync(from, to); }
  catch (error) {
    if ((error as NodeJS.ErrnoException).code !== 'EXDEV') throw error;
    cpSync(from, to, { recursive: true });
    rmSync(from, { recursive: true, force: true });
  }
}
