/**
 * 工作区跨机流转：源机进入可交接状态并推送材料，目标机还原、跑 setup、校验后以 lease 的比较后更新接管。
 * 流程与材料的约定见 docs/Line与工作区流转.md「工作区流转」；执行权的读写见 workspace/lease.ts。
 */
import { cpSync, existsSync, mkdirSync, readdirSync, renameSync, rmSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { randomUUID } from 'node:crypto';
import { KiteError } from '../errors.ts';
import { setupLogPath, worktreePath } from '../paths.ts';
import type { AccountClient } from '../account-client.ts';
import type { AgentInstance, Checkout, Project, Workspace, WorkspaceModel, WorkspaceStatus } from '../model.ts';
import type { Store } from '../store.ts';
import type { Environment } from '../environment.ts';
import { KITE_IDENTITY, git, gitTry, isAncestor, isDirty, revParse } from '../workspace/git.ts';
import { currentBranch, fetchBranch, originAccess, type RemoteAccess } from '../workspace/remote.ts';
import { readLease, remoteLeases, writeLease, type Lease } from '../workspace/lease.ts';
import { addWorktree, removeWorktree, runSetup } from '../workspace/worktrees.ts';
import { forgetWorktree, snapshotRef } from '../workspace/snapshots.ts';
import { commitDirectory, deleteMaterials, emptyDirectory, extractCommit, fetchMaterials, pushMaterials, type Materials } from './materials.ts';
import { installRecords, readRecords, recordPaths, writeRecords } from './records.ts';
import { repositoryVisibility } from './visibility.ts';

export interface TransferHost {
  store: Store;
  home: string;
  account: AccountClient;
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
  /** 工作区记录已从本机删除（还原失败清理，或根工作区被流转来的替换）。 */
  removed(workspaceId: string): void;
  /** 这些线程的会话记录换了：按旧记录读出的显示历史作废。 */
  recordsReplaced(threadIds: string[]): void;
  environment(projectId: string): Promise<Environment>;
  /** 本机该项目的检出；没有时 clone 到默认位置并登记。 */
  ensureCheckout(projectId: string): Promise<Checkout>;
  /** 核对执行权后发现已被接管时冻结。 */
  freeze(workspaceId: string): Promise<void>;
  /** 交接检查现场之前的准备：Line 的根工作区先由宿主提交并推送现场。 */
  beforeHandover(workspaceId: string): Promise<void>;
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

  /** 公开仓库默认不推材料；看不出是否公开时问用户一次。确认后记在项目上。 */
  private async assertMaterialsAllowed(project: Project, allow: boolean): Promise<void> {
    if (allow) { this.host.store.allowTransfer(project.id); return; }
    if (this.host.store.transferAllowed(project.id)) return;
    if (this.host.account.linked && (await this.host.account.projects()).find((p) => p.id === project.id)?.hosted) return;
    const visibility = await repositoryVisibility(project.remote, this.host.account);
    if (visibility === 'private') return;
    throw new KiteError(visibility === 'public'
      ? '这是公开仓库，流转材料含会话记录，推上去所有人都能看到；确认要推就在交接请求里加 allowMaterials: true'
      : '看不出这个远程是否公开，流转材料含会话记录；确认可以推到这个远程就在交接请求里加 allowMaterials: true', 409);
  }

  /**
   * 交出工作区：所有线程空闲、没有恢复阻塞与结果未知的操作才行，不满足就拒绝。lease 置为 handing_off 后本地拒绝新的执行，
   * 停下执行进程，保存最后的快照，导出记录并把材料推到项目远程。中途失败停在 handing_off，可以重试或撤回。
   * 根工作区的现场须已提交并推送，目标检出快进到同一提交。
   */
  handover(id: string, options: { allowMaterials?: boolean } = {}): Promise<{ epoch: number }> {
    return this.host.control(id, async () => {
      const { workspace: w, checkout, project } = this.host.workspace(id);
      if (w.status !== 'open' && w.status !== 'handing_off') throw new KiteError('只有已打开的工作区可以交接', 409);
      // 归档的线程不再执行，只核对、停下未归档的；它们的会话文件照样进材料，否则目标机上归档线程的历史是空的。
      const threads = this.host.store.threads(id);
      const live = threads.filter((t) => t.status !== 'archived');
      for (const t of live) {
        const state = await this.host.threadState(t.id);
        if (state.busy || state.phase !== 'idle' || state.recovery) throw new KiteError('有线程正在工作或等待恢复确认，空闲后再交接', 409);
      }
      if (this.host.store.unfinishedOperations(id)) throw new KiteError('工作区有结果尚未确认的操作，先核查再交接', 409);
      await this.assertMaterialsAllowed(project, options.allowMaterials === true);
      await this.host.beforeHandover(id);
      const access = await originAccess(checkout.path, this.host.account);
      let head: string | null = null;
      if (w.kind === 'root') {
        if (await isDirty(checkout.path)) throw new KiteError('根工作区现场有未提交的改动，先提交并推送再交接', 409);
        const branch = await currentBranch(checkout.path);
        if (!branch) throw new KiteError('检出现场不在任何分支上，先切回主线分支', 409);
        head = await git(checkout.path, ['rev-parse', 'HEAD']);
        const upstream = await fetchBranch(checkout.path, branch, access);
        if (!upstream || !(await isAncestor(checkout.path, head, upstream))) throw new KiteError('根工作区现场还没推送到远程，先推送再交接', 409);
      }
      // lease 的推送同时探测平台是否接受自定义 ref：被拒时在这里明确报错，不改走别的路径。
      const current = await this.lease(checkout, id, access);
      if (current && !heldHere(current.lease, w, this.machine)) throw new KiteError('执行权已不在这台工作机', 409);
      if (current?.lease.state !== 'handing_off') {
        const written = await writeLease(checkout.path, id, { machine: this.machine, epoch: w.epoch, state: 'handing_off' }, current?.commit ?? null, access);
        if (written.status === 'conflict') throw new KiteError('执行权刚被别的工作机改动，请稍后重试', 409);
      }
      this.host.setStatus(id, 'handing_off');
      for (const t of live) await this.host.stopThread(t);
      const release = await this.host.closePlugins(id);
      const dir = emptyDirectory();
      try {
        if (existsSync(w.cwd)) await this.host.snapshot(w, '交接前保存');
        const materials: Materials = {};
        materials.snapshots = await revParse(checkout.path, snapshotRef(id)) ?? undefined;
        if (w.kind === 'worktree') {
          materials.branch = await git(checkout.path, ['rev-parse', `refs/heads/${w.branch}`]);
          head = materials.branch;
          if (materials.snapshots) {
            materials.worktree = await git(checkout.path, ['commit-tree', `${materials.snapshots}^{tree}`, '-p', materials.branch,
              '-m', `Kite：工作区 ${id} 交接时未提交的改动`], { env: KITE_IDENTITY });
          }
        }
        writeRecords(dir, { home: this.host.home, machine: this.machine, projectId: project.id, workspace: w, head, threads,
          rows: this.host.store.exportWorkspaceRows(id) });
        materials.records = await commitDirectory(checkout.path, dir, `Kite：工作区 ${id} 的流转记录`);
        await pushMaterials(checkout.path, access, id, materials);
      } finally {
        rmSync(dir, { recursive: true, force: true });
        release();
      }
      return { epoch: w.epoch };
    });
  }

  /** 目标还没接管时撤回交接：lease 改回 active，删掉材料，工作区重新开放。已被接管时 409，并冻结本地记录。 */
  async cancel(id: string): Promise<WorkspaceModel> {
    let lost = false;
    try {
      return await this.host.control(id, async () => {
        const { workspace: w, checkout } = this.host.workspace(id);
        if (w.status !== 'handing_off') throw new KiteError('工作区没有在交接', 409);
        const access = await originAccess(checkout.path, this.host.account);
        const current = await this.lease(checkout, id, access);
        if (current && !heldHere(current.lease, w, this.machine)) {
          lost = true;
          throw new KiteError('另一台工作机已经接管了这个工作区', 409);
        }
        if (current?.lease.state === 'handing_off') {
          const written = await writeLease(checkout.path, id, { machine: this.machine, epoch: w.epoch, state: 'active' }, current.commit, access);
          if (written.status === 'conflict') { lost = true; throw new KiteError('另一台工作机正在接管这个工作区', 409); }
        }
        try { await deleteMaterials(checkout.path, access, id); }
        catch (error) { console.error(`[流转] 撤回后删除材料失败：${(error as Error).message}`); }
        this.host.setStatus(id, 'open');
        return this.host.workspace(id);
      });
    } finally { if (lost) await this.check(id); }
  }

  /** 立即核对一个工作区的执行权；已被别的机器接管就冻结。 */
  async check(id: string): Promise<WorkspaceModel> {
    const { workspace: w, checkout } = this.host.workspace(id);
    if (w.status !== 'transferred' && w.status !== 'archived') {
      const current = await this.lease(checkout, id, await originAccess(checkout.path, this.host.account));
      if (current && takenOver(current.lease, w, this.machine)) await this.host.freeze(id);
    }
    return this.host.workspace(id);
  }

  /**
   * 联网后核对本机持有的全部工作区，已被接管的冻结。各检出的远程互不相干，一起查，一个远程卡住不耽误别的；
   * 同一检出里的逐个读，免得同一仓库里的 git 互相抢锁。从未流转过的没有 lease；查不到远程时按仍持有继续，
   * 所以接管默认要求源机先进入可交接状态。
   */
  async checkAll(): Promise<void> {
    const held = this.host.store.workspaces().filter((w) => w.status !== 'transferred' && w.status !== 'archived');
    await Promise.all(this.host.store.checkouts().map(async (checkout) => {
      const local = held.filter((w) => w.checkoutId === checkout.id);
      if (!local.length || !existsSync(checkout.path)) return;
      let leases: Map<string, string>;
      let access: RemoteAccess;
      try {
        access = await originAccess(checkout.path, this.host.account);
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

  /**
   * 在本机还原并接管流转来的工作区：确认或建立检出，取回材料，核对 lease 仍是源机的 handing_off 与预期 epoch，
   * 建工作树并还原未提交改动，导入记录、改写会话目录，跑 setup，保存初始快照，最后比较后更新 lease 接管。
   * 接管之前任何一步失败都清掉本地半成品，lease 不变，源机可以撤回交接继续工作。
   */
  restore(projectId: string, workspaceId: string): Promise<WorkspaceModel> {
    // 同一工作区的还原排队：工作树目录与会话目录按工作区和实例 ID 命名，两次还原不能交错。
    return this.host.control(workspaceId, () => this.restoreHere(projectId, workspaceId));
  }

  /**
   * 工作区流转回原机时，本机有同一 ID 的冻结或归档记录、它的会话文件与快照链。接管成功之前这些都不能丢：
   * 替换前先导出旧行、把会被覆盖的文件挪到备份目录、记下旧快照引用，失败时原样还原，只清掉这次新建的东西；
   * 接管成功后才删备份。数据库替换不挪到接管之后，是因为接管后再导入失败会留下「执行权已转来却没有记录」的状态。
   */
  private async restoreHere(projectId: string, workspaceId: string): Promise<WorkspaceModel> {
    const existing = this.host.store.workspace(workspaceId);
    if (existing && existing.status !== 'transferred' && existing.status !== 'archived') throw new KiteError('这台工作机上已有这个工作区', 409);
    const environment = await this.host.environment(projectId);
    const checkout = await this.host.ensureCheckout(projectId);
    const access = await originAccess(checkout.path, this.host.account);
    const materials = await fetchMaterials(checkout.path, access, workspaceId);
    const dir = await extractCommit(checkout.path, materials.records!);
    const backup = join(this.host.home, 'transfers', randomUUID());
    const cleanup: Array<() => Promise<unknown> | unknown> = [];
    let replacedRoot: Workspace | undefined;
    let storeTouched = false;
    try {
      const { manifest, rows } = readRecords(dir);
      if (manifest.projectId !== projectId || manifest.workspaceId !== workspaceId) throw new KiteError('流转材料与请求的项目或工作区不符', 409);
      const current = await this.lease(checkout, workspaceId, access);
      if (!current || current.lease.state !== 'handing_off' || current.lease.machine !== manifest.machine || current.lease.epoch !== manifest.epoch) {
        throw new KiteError('源工作机不在可交接状态，可能已撤回交接或已被接管', 409);
      }
      for (const runtime of new Set(manifest.threads.map((t) => t.runtime))) {
        const login = environment.logins[runtime === 'claude' ? 'claude' : 'chatgpt'];
        if (login.status !== 'ready') throw new KiteError(`这台工作机不能继续这个工作区的会话：${login.message}`, 409);
      }
      let cwd: string;
      if (manifest.kind === 'worktree') {
        cwd = worktreePath(this.host.home, projectId, workspaceId);
        if (existsSync(cwd)) throw new KiteError('本机还留着这个工作区的旧工作树，先归档本机的旧记录', 409);
        await git(checkout.path, ['update-ref', `refs/heads/${manifest.branch}`, materials.branch!]);
        cleanup.push(() => removeWorktree(checkout.path, cwd, manifest.branch!));
        await addWorktree(checkout.path, cwd, manifest.branch!, null);
        if (materials.worktree) await git(cwd, ['restore', `--source=${materials.worktree}`, '--worktree', '--', ':/']);
      } else {
        cwd = checkout.path;
        const root = this.host.store.rootWorkspaceModel(checkout.id);
        if (root && root.instances.length) throw new KiteError('目标检出的根工作区已有实例，不能承接流转来的根工作区', 409);
        if (await isDirty(cwd)) throw new KiteError('目标检出的现场有未提交的改动', 409);
        const branch = await currentBranch(cwd);
        if (!branch) throw new KiteError('目标检出不在任何分支上', 409);
        await fetchBranch(cwd, branch, access);
        if (!(await isAncestor(cwd, 'HEAD', manifest.head!))) throw new KiteError('目标检出与源工作机的现场分叉了，不能快进', 409);
        await git(cwd, ['merge', '-q', '--ff-only', manifest.head!]);
        replacedRoot = root?.workspace;
      }
      const previousSnapshots = await revParse(checkout.path, snapshotRef(workspaceId));
      if (materials.snapshots) {
        await git(checkout.path, ['update-ref', snapshotRef(workspaceId), materials.snapshots]);
        cleanup.push(() => previousSnapshots ? git(checkout.path, ['update-ref', snapshotRef(workspaceId), previousSnapshots])
          : gitTry(checkout.path, ['update-ref', '-d', snapshotRef(workspaceId)]));
      }
      // 快照链换成了材料里的，根工作区的目录没变，按路径记的快照缓存要重查。
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
      const rootRows = replacedRoot && this.host.store.exportWorkspaceRows(replacedRoot.id);
      this.host.store.transaction(() => {
        if (existing) this.host.store.deleteWorkspaceRows(workspaceId);
        if (replacedRoot) this.host.store.deleteWorkspaceRows(replacedRoot.id);
        this.host.store.importWorkspaceRows(rows, { checkout_id: checkout.id, cwd, status: 'preparing', epoch: manifest.epoch }, cursors);
      });
      storeTouched = true;
      // 流转回来过的工作机还留着离开前读出的历史，换成材料里的记录后要重读；还原时同样
      const threadIds = manifest.threads.map((thread) => thread.instanceId);
      this.host.recordsReplaced(threadIds);
      cleanup.push(() => this.host.store.transaction(() => {
        this.host.store.deleteWorkspaceRows(workspaceId);
        if (previousRows) this.host.store.restoreWorkspaceRows(previousRows);
        if (rootRows) this.host.store.restoreWorkspaceRows(rootRows);
      }), () => this.host.recordsReplaced(threadIds));
      this.host.changed(workspaceId);
      const model = this.host.workspace(workspaceId);
      if (manifest.kind === 'worktree') {
        const setup = await runSetup(checkout.path, cwd, setupLogPath(this.host.home, workspaceId), this.host.home);
        if (setup && setup.exit !== 0) throw new KiteError(`初始化脚本退出码 ${setup.exit}`, 409);
      }
      await this.host.snapshot(model.workspace, '流转到这台工作机');
      const taken = await writeLease(checkout.path, workspaceId, { machine: this.machine, epoch: manifest.epoch + 1, state: 'active' }, current.commit, access);
      if (taken.status === 'conflict') throw new KiteError('接管时执行权已被改动，源工作机可能撤回了交接', 409);
      cleanup.length = 0;
      rmSync(backup, { recursive: true, force: true });
      this.host.store.setWorkspaceEpoch(workspaceId, manifest.epoch + 1);
      this.host.setStatus(workspaceId, 'open');
      if (replacedRoot) this.host.removed(replacedRoot.id);
      try { await deleteMaterials(checkout.path, access, workspaceId); }
      catch (error) { console.error(`[流转] 接管后删除材料失败：${(error as Error).message}`); }
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
        if (replacedRoot) this.host.changed(replacedRoot.id);
      }
      // 清理全部成功时本机回到还原前、lease 未动，结果是确定的失败；否则留给收据记成结果未知，先核查再重试。
      if (restored && !(error instanceof KiteError)) throw new KiteError(`还原失败，本机已回到还原前：${(error as Error).message}`, 409);
      throw error;
    } finally { rmSync(dir, { recursive: true, force: true }); }
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
