/**
 * kited 的核心：把登记项目、会话工作树、Claude Code 进程、快照、采纳串成一条流程。
 *
 * 并发：同一会话的快照串行（私有索引只有一份）；同一项目里碰主文件夹的操作（建会话时保存主文件夹、采纳）
 * 串行，这就是「本机按项目加一把锁」。
 */
import { randomUUID } from 'node:crypto';
import { existsSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { KiteError } from './errors.ts';
import { type AdoptResult, Bus } from './events.ts';
import { hasUnmerged, mainline, mergeBack } from './mainline.ts';
import { register } from './projects.ts';
import { Runner } from './runner.ts';
import { capture, list, restore, type Snapshot } from './snapshots.ts';
import type { Project, Session, Store } from './store.ts';
import { kiteTools } from './tools.ts';
import { addWorktree, removeWorktree, runSetup } from './worktrees.ts';

export interface SessionView extends Session {
  runner: Runner['state'];
  busy: boolean;
}

const newSessionId = () => randomUUID().replace(/-/g, '').slice(0, 10);

/** 消息的第一行，作快照标签。 */
const firstLine = (text: string) => text.trim().split('\n')[0]!.trim() || '（空消息）';

const titleOf = (prompt: string) => firstLine(prompt).slice(0, 80);

function conflictPrompt(branch: string, files: string[]): string {
  return [
    `Kite 正在把这个会话的改动合回主线。主线在你工作期间有了新提交，把它合进 ${branch} 时这些文件冲突了：`,
    ...files.map((f) => `- ${f}`),
    '',
    '请解决冲突，保留双方的意图，然后 git add 并 git commit 完成这次合并。完成后 Kite 会自动继续合回主线。',
  ].join('\n');
}

export class Kite {
  private runners = new Map<string, Runner>();
  private queues = new Map<string, Promise<unknown>>();
  private turnLabels = new Map<string, string>();
  /** 交给 agent 解决合并冲突、等它这一轮结束后重试采纳的会话。 */
  private adoptAfterTurn = new Set<string>();

  constructor(readonly store: Store, readonly home: string, readonly bus: Bus) {
    // 上次 kited 退出时还在准备的会话，准备过程已经中断
    for (const s of store.sessions()) if (s.status === 'preparing') this.setStatus(s, 'prepare_failed');
  }

  // ── 项目 ──

  projects(): Project[] { return this.store.projects(); }

  registerProject(path: string): Promise<Project> { return register(this.store, this.home, path); }

  private project(id: string): Project {
    const p = this.store.project(id);
    if (!p) throw new KiteError(`没有这个项目：${id}`, 404);
    return p;
  }

  // ── 会话 ──

  sessions(projectId?: string): SessionView[] { return this.store.sessions(projectId).map((s) => this.view(s)); }

  session(id: string): SessionView { return this.view(this.mustSession(id)); }

  private mustSession(id: string): Session {
    const s = this.store.session(id);
    if (!s) throw new KiteError(`没有这个会话：${id}`, 404);
    return s;
  }

  private view(s: Session): SessionView {
    const r = this.runners.get(s.id);
    return { ...s, runner: r?.state ?? 'closed', busy: r?.busy ?? false };
  }

  private mustOpen(id: string): Session {
    const s = this.mustSession(id);
    if (s.status !== 'open') throw new KiteError(`会话状态是 ${s.status}，不能这样操作`, 409);
    return s;
  }

  private setStatus(s: Session, status: Session['status']): void {
    this.store.setStatus(s.id, status);
    s.status = status;
    this.bus.emit(s.id, { type: 'status', status });
  }

  /** 新会话：从主线建工作树、初始化，然后把第一条消息交给 agent。立即返回，准备过程看事件。 */
  async createSession(projectId: string, prompt: string): Promise<SessionView> {
    const project = this.project(projectId);
    if (!prompt.trim()) throw new KiteError('第一条消息不能为空');
    const id = newSessionId();
    const base = await this.serial(`project:${project.id}`, () => mainline(project));
    const s: Session = {
      id, projectId: project.id, title: titleOf(prompt),
      worktree: join(this.home, 'worktrees', project.id, id), branch: `kite/${id}`, base,
      runtime: 'claude', nativeId: randomUUID(), status: 'preparing', createdAt: Date.now(),
    };
    this.store.addSession(s);
    void this.prepare(s, project, prompt);
    return this.view(s);
  }

  private setupLog(id: string) { return join(this.home, 'sessions', id, 'setup.log'); }

  private async prepare(s: Session, project: Project, prompt: string): Promise<void> {
    try {
      await addWorktree(project.path, s.worktree, s.branch, s.base);
      const exit = await runSetup(project.path, s.worktree, this.setupLog(s.id));
      const log = exit === null ? '' : readFileSync(this.setupLog(s.id), 'utf8').slice(-4000);
      this.bus.emit(s.id, { type: 'setup', exit, log });
      if (exit !== null && exit !== 0) return this.setStatus(s, 'prepare_failed');
      // 起点快照：回退到「agent 动手之前」要有落点
      await this.snapshot(s, [], '会话开始');
      this.setStatus(s, 'open');
      this.runner(s).send({ text: prompt, human: true });
    } catch (e) {
      this.bus.emit(s.id, { type: 'error', message: (e as Error).message });
      this.setStatus(s, 'prepare_failed');
    }
  }

  private runner(s: Session): Runner {
    let r = this.runners.get(s.id);
    if (r) return r;
    const tools = () => kiteTools({
      main: this.project(s.projectId).path, worktree: s.worktree,
      onCheck: (result) => this.bus.emit(s.id, { type: 'check', result }),
    });
    r = new Runner({ cwd: s.worktree, nativeId: s.nativeId, title: s.title, tools }, {
      message: (message) => this.bus.emit(s.id, { type: 'sdk', message }),
      turnStart: (prompt, source) => this.turnLabels.set(s.id, source === 'system' ? '后台任务完成' : firstLine(prompt)),
      toolBatch: (input) => this.snapshot(s, input.tool_calls.map((c) => c.tool_use_id)),
      // 回合末再打一枚，收进后台任务在工具之外写的文件；树没变不产生提交
      turnEnd: () => this.snapshot(s, []),
      idle: () => {
        this.bus.emit(s.id, { type: 'idle' });
        if (this.adoptAfterTurn.delete(s.id)) {
          this.adopt(s.id).catch((e) => this.bus.emit(s.id, { type: 'error', message: `自动采纳失败：${(e as Error).message}` }));
        }
      },
      state: (state, error) => this.bus.emit(s.id, { type: 'runner', state, ...(error ? { error } : {}) }),
    });
    this.runners.set(s.id, r);
    return r;
  }

  send(id: string, text: string): void {
    const s = this.mustOpen(id);
    if (!text.trim()) throw new KiteError('消息不能为空');
    this.runner(s).send({ text, human: true });
  }

  async interrupt(id: string): Promise<void> {
    this.mustSession(id);
    await this.runners.get(id)?.interrupt();
  }

  // ── 快照 ──

  /** 同一个 key 的任务依次执行。 */
  private serial<T>(key: string, fn: () => Promise<T>): Promise<T> {
    const next = (this.queues.get(key) ?? Promise.resolve()).then(fn, fn);
    this.queues.set(key, next.catch(() => {}));
    return next;
  }

  private snapshot(s: Session, toolUseIds: string[], fixedLabel?: string): Promise<void> {
    return this.serial(`snap:${s.id}`, async () => {
      const label = fixedLabel ?? this.turnLabels.get(s.id) ?? s.title;
      try {
        const r = await capture(s.worktree, s.id, label, toolUseIds);
        if (r.created) this.bus.emit(s.id, { type: 'snapshot', commit: r.commit, label, changedFiles: r.changedFiles });
      } catch (e) {
        // 快照失败不能卡住 agent
        this.bus.emit(s.id, { type: 'error', message: `快照失败：${(e as Error).message}` });
      }
    });
  }

  snapshots(id: string): Promise<Snapshot[]> {
    const s = this.mustSession(id);
    return list(this.project(s.projectId).path, s.id);
  }

  /** 把会话的工作树恢复到某一枚快照。agent 正在工作时不行。 */
  async restore(id: string, commit: string): Promise<void> {
    const s = this.mustOpen(id);
    if (this.runners.get(id)?.busy) throw new KiteError('agent 正在工作，先打断或等这一轮结束', 409);
    const snaps = await this.snapshots(id);
    const target = snaps.find((x) => x.commit.startsWith(commit));
    if (!commit || !target) throw new KiteError(`这个会话没有快照 ${commit}`, 404);
    await this.serial(`snap:${s.id}`, async () => {
      const { current, label } = await restore(s.worktree, s.id, target.commit);
      if (current.created) this.bus.emit(s.id, { type: 'snapshot', commit: current.commit, label, changedFiles: current.changedFiles });
    });
  }

  // ── 采纳 ──

  /**
   * 把会话的改动合回主线。先在会话工作树里提交全部改动，再把主线合进会话分支：冲突留在会话工作树里交给 agent，
   * 主文件夹永远不会处于冲突状态。最后主文件夹快进到会话分支。采纳之后会话照常可用，可以继续改、再采纳。
   */
  async adopt(id: string): Promise<AdoptResult> {
    const s = this.mustOpen(id);
    if (this.runners.get(id)?.busy) throw new KiteError('agent 正在工作，等这一轮结束再采纳', 409);
    const p = this.project(s.projectId);
    const result = await this.serial(`project:${p.id}`, async (): Promise<AdoptResult> => {
      const r = await mergeBack(p, s.worktree, s.title);
      if (r.status === 'merged') return { status: 'adopted', commit: r.commit };
      // 刚合出来的冲突交给 agent；上次留下的已经交过了，等它解决
      if (r.fresh) {
        this.adoptAfterTurn.add(s.id);
        this.runner(s).send({ text: conflictPrompt(s.branch, r.files), human: false });
      }
      return { status: 'conflict', files: r.files };
    });
    this.bus.emit(s.id, { type: 'adopt', result });
    return result;
  }

  // ── 归档 ──

  /** 关掉进程、删工作树和会话分支，快照引用保留。有没采纳的改动时要 force。 */
  async archive(id: string, force = false): Promise<void> {
    const s = this.mustSession(id);
    if (s.status === 'archived') return;
    const p = this.project(s.projectId);
    if (!force && (await hasUnmerged(p.path, s.worktree))) throw new KiteError('会话有没合回主线的改动；确定丢弃就加 force', 409);
    const r = this.runners.get(id);
    if (r) {
      if (r.busy) await r.interrupt().catch(() => {});
      await r.shutdown();
      this.runners.delete(id);
    }
    if (existsSync(s.worktree)) await this.serial(`snap:${s.id}`, () => capture(s.worktree, s.id, '归档前保存'));
    await removeWorktree(p.path, s.worktree, s.branch);
    this.turnLabels.delete(id);
    this.adoptAfterTurn.delete(id);
    this.queues.delete(`snap:${id}`);
    this.setStatus(s, 'archived');
  }

  async shutdown(): Promise<void> {
    await Promise.all([...this.runners.values()].map((r) => r.shutdown()));
  }
}
