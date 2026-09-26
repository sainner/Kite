/**
 * kited 的核心：把登记项目、会话工作树、执行后端、快照、采纳串成一条流程。
 *
 * 并发：同一会话的快照串行（私有索引只有一份）；同一项目里碰主文件夹的操作（建会话时保存主文件夹、采纳）
 * 串行，这就是「本机按项目加一把锁」。
 */
import { randomUUID } from 'node:crypto';
import { existsSync } from 'node:fs';
import { join } from 'node:path';
import { getSessionMessages } from '@anthropic-ai/claude-agent-sdk';
import { KiteError } from './errors.ts';
import { type AdoptResult, Bus } from './events.ts';
import { hasUnmerged, mainline, mergeBack } from './mainline.ts';
import { register } from './projects.ts';
import { openRuntime, type Runtime, type RuntimeOptions } from './runtime.ts';
import { capture, findSnapshot, list, restore, type Snapshot } from './snapshots.ts';
import type { Project, Session, Store } from './store.ts';
import { addWorktree, removeWorktree, runSetup } from './worktrees.ts';
import { readJournal } from './harness/journal.ts';
import { TranscriptFeed, TranscriptProjection, type History } from './transcript.ts';

export interface SessionView extends Session {
  runner: Runtime['state'];
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
  readonly events = new TranscriptFeed();
  private transcripts = new Map<string, TranscriptProjection>();
  private loadingTranscripts = new Map<string, Promise<TranscriptProjection>>();
  private runners = new Map<string, Runtime>();
  private queues = new Map<string, Promise<unknown>>();
  private preparations = new Map<string, AbortController>();
  private stopping = false;
  private turnLabels = new Map<string, string>();
  /** 交给 agent 解决合并冲突、等它这一轮结束后重试采纳的会话。 */
  private adoptAfterTurn = new Set<string>();

  constructor(readonly store: Store, readonly home: string, readonly bus: Bus, private options: RuntimeOptions = {}) {
    // 上次 kited 退出时还在准备的会话，准备过程已经中断
    for (const s of store.sessions()) if (s.status === 'preparing') this.setStatus(s, 'prepare_failed');
    bus.subscribe(undefined, (event) => {
      const transcript = this.transcripts.get(event.session);
      if (transcript) transcript.accept(event);
      else if (event.type !== 'sdk' && event.type !== 'harness' && event.type !== 'runner') this.events.emit(event.session, event);
    });
  }

  /** 只读投影。缓存先于 runtime 建立，原生记录落盘后的事件同步更新同一份历史。 */
  async history(id: string): Promise<History> { return (await this.transcript(this.mustSession(id))).snapshot(); }

  historyNow(id: string): History {
    const transcript = this.transcripts.get(id);
    if (!transcript) throw new KiteError('请先加载会话历史', 409);
    return transcript.snapshot();
  }

  private transcript(s: Session): Promise<TranscriptProjection> {
    const cached = this.transcripts.get(s.id);
    if (cached) return Promise.resolve(cached);
    const loading = this.loadingTranscripts.get(s.id);
    if (loading) return loading;
    const promise = (async () => {
      const projection = new TranscriptProjection(s, this.events);
      if (s.runtime === 'harness') {
        for (const row of readJournal(join(this.home, 'sessions', s.id, 'journal.jsonl'))) projection.journal(row);
      } else {
        for (const row of await getSessionMessages(s.nativeId, { dir: s.worktree, includeSystemMessages: true })) projection.claude(row, s.createdAt);
      }
      projection.finishReplay();
      this.transcripts.set(s.id, projection);
      return projection;
    })().finally(() => this.loadingTranscripts.delete(s.id));
    this.loadingTranscripts.set(s.id, promise);
    return promise;
  }

  // ── 项目 ──

  projects(): Project[] { return this.store.projects(); }

  registerProject(path: string): Promise<Project> {
    this.assertRunning();
    return this.serial(`register:${path}`, () => register(this.store, this.home, path));
  }

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

  private assertRunning(): void {
    if (this.stopping) throw new KiteError('kited 正在关闭', 503);
  }

  /** 控制操作按会话串行，避免打开两份 journal，或在采纳、归档时又开始执行。 */
  private control<T>(id: string, fn: () => Promise<T>): Promise<T> {
    this.assertRunning();
    return this.serial(`session:${id}`, async () => { this.assertRunning(); return fn(); });
  }

  private setStatus(s: Session, status: Session['status']): void {
    this.store.setStatus(s.id, status);
    s.status = status;
    this.bus.emit(s.id, { type: 'status', status });
  }

  /** 新会话：从主线建工作树、初始化，然后把第一条消息交给 agent。立即返回，准备过程看事件。 */
  async createSession(projectId: string, prompt: string, runtime: Session['runtime'] = 'harness'): Promise<SessionView> {
    this.assertRunning();
    if (runtime !== 'harness' && runtime !== 'claude') throw new KiteError('runtime 必须是 harness 或 claude');
    const project = this.project(projectId);
    if (!prompt.trim()) throw new KiteError('第一条消息不能为空');
    const id = newSessionId();
    const base = await this.serial(`project:${project.id}`, () => mainline(project));
    this.assertRunning();
    const s: Session = {
      id, projectId: project.id, title: titleOf(prompt),
      worktree: join(this.home, 'worktrees', project.id, id), branch: `kite/${id}`, base,
      runtime, nativeId: randomUUID(), status: 'preparing', createdAt: Date.now(),
    };
    this.store.addSession(s);
    const controller = new AbortController();
    this.preparations.set(id, controller);
    void this.serial(`session:${id}`, () => this.prepare(s, project, prompt, controller.signal))
      .finally(() => this.preparations.delete(id));
    return this.view(s);
  }

  private setupLog(id: string) { return join(this.home, 'sessions', id, 'setup.log'); }

  private async prepare(s: Session, project: Project, prompt: string, signal: AbortSignal): Promise<void> {
    try {
      await addWorktree(project.path, s.worktree, s.branch, s.base);
      signal.throwIfAborted();
      const setup = await runSetup(project.path, s.worktree, this.setupLog(s.id), signal);
      this.bus.emit(s.id, { type: 'setup', exit: setup?.exit ?? null, log: setup?.tail ?? '' });
      if (setup && setup.exit !== 0) return this.setStatus(s, 'prepare_failed');
      // 起点快照：回退到「agent 动手之前」要有落点
      await this.snapshot(s, [], '会话开始');
      signal.throwIfAborted();
      const runner = await this.runner(s);
      signal.throwIfAborted();
      this.setStatus(s, 'open');
      await runner.send({ id: randomUUID(), text: prompt, source: 'human' });
    } catch (e) {
      this.bus.emit(s.id, { type: 'error', message: (e as Error).message });
      this.setStatus(s, 'prepare_failed');
    }
  }

  private async runner(s: Session): Promise<Runtime> {
    let r = this.runners.get(s.id);
    if (r) return r;
    await this.transcript(s);
    r = await openRuntime(s, this.home, this.project(s.projectId).path, {
      emit: (event) => this.bus.emit(s.id, event),
      label: (text) => this.turnLabels.set(s.id, firstLine(text)),
      snapshot: (ids) => this.snapshot(s, ids),
      idle: (completed) => {
        this.bus.emit(s.id, { type: 'idle' });
        if (completed && !this.stopping && this.adoptAfterTurn.delete(s.id)) {
          this.adopt(s.id).catch((e) => this.bus.emit(s.id, { type: 'error', message: `自动采纳失败：${(e as Error).message}` }));
        }
      },
    }, this.options);
    this.runners.set(s.id, r);
    return r;
  }

  /** 管理操作重新打开可用的 harness 以核查锁和恢复状态；不为此启动 Claude 进程。 */
  private async runnerForManagement(s: Session): Promise<Runtime | undefined> {
    return this.runners.get(s.id) ?? (s.runtime === 'harness' && s.status === 'open' ? this.runner(s) : undefined);
  }

  send(id: string, text: string, inputId: string = randomUUID()): Promise<{ id: string }> {
    if (!text.trim()) throw new KiteError('消息不能为空');
    if (!inputId) throw new KiteError('消息 id 不能为空');
    return this.control(id, async () => {
      const r = await this.runner(this.mustOpen(id));
      await r.send({ id: inputId, text, source: 'human' });
      return { id: inputId };
    });
  }

  cancel(id: string, inputId: string): Promise<void> {
    return this.control(id, async () => {
      const r = await this.runner(this.mustOpen(id));
      if (!r.cancel) throw new KiteError('这个后端不支持撤回排队消息', 409);
      await r.cancel(inputId);
    });
  }

  async interrupt(id: string): Promise<void> {
    this.preparations.get(id)?.abort();
    await this.control(id, async () => {
      this.mustSession(id);
      await this.runners.get(id)?.interrupt();
    });
  }

  resume(id: string): Promise<void> {
    return this.control(id, async () => {
      const r = await this.runner(this.mustOpen(id));
      if (!r.resume) throw new KiteError('这个后端通过发消息继续会话', 409);
      await r.resume();
    });
  }

  recover(id: string): Promise<void> {
    return this.control(id, async () => {
      const r = await this.runner(this.mustOpen(id));
      if (!r.recover) throw new KiteError('这个后端不支持恢复确认', 409);
      await r.recover();
    });
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
        this.emitSnapshot(s, await capture(s.worktree, s.id, label, toolUseIds), label);
      } catch (e) {
        this.bus.emit(s.id, { type: 'error', message: `快照失败：${(e as Error).message}` });
        // 新循环在持久化边界失败时暂停；旧 Runner 维持原有行为。
        if (s.runtime === 'harness') throw e;
      }
    });
  }

  snapshots(id: string): Promise<Snapshot[]> {
    const s = this.mustSession(id);
    return list(this.project(s.projectId).path, s.id);
  }

  /** 把会话的工作树恢复到某一枚快照。agent 正在工作时不行。 */
  async restore(id: string, commit: string): Promise<void> {
    return this.control(id, async () => {
      const s = this.mustOpen(id);
      const r = await this.runnerForManagement(s);
      if (r?.busy) throw new KiteError('agent 正在工作或等待恢复确认，先打断或等这一轮结束', 409);
      const target = await findSnapshot(s.worktree, s.id, commit);
      if (!target) throw new KiteError(`这个会话没有快照 ${commit}`, 404);
      await this.serial(`snap:${s.id}`, async () => {
        const { current, label } = await restore(s.worktree, s.id, target);
        this.emitSnapshot(s, current, label);
      });
    });
  }

  private emitSnapshot(s: Session, r: { commit: string; created: boolean; changedFiles: number }, label: string): void {
    if (r.created) this.bus.emit(s.id, { type: 'snapshot', commit: r.commit, label, changedFiles: r.changedFiles });
  }

  // ── 采纳 ──

  /**
   * 把会话的改动合回主线。先在会话工作树里提交全部改动，再把主线合进会话分支：冲突留在会话工作树里交给 agent，
   * 主文件夹永远不会处于冲突状态。最后主文件夹快进到会话分支。采纳之后会话照常可用，可以继续改、再采纳。
   */
  async adopt(id: string): Promise<AdoptResult> {
    return this.control(id, async () => {
      const s = this.mustOpen(id);
      const runner = await this.runnerForManagement(s);
      if (runner?.busy) throw new KiteError('agent 正在工作或等待恢复确认，等这一轮结束再采纳', 409);
      const p = this.project(s.projectId);
      const result = await this.serial(`project:${p.id}`, async (): Promise<AdoptResult> => {
        const r = await mergeBack(p, s.worktree, s.title);
        if (r.status === 'merged') return { status: 'adopted', commit: r.commit };
        // 刚合出来的冲突交给 agent；上次留下的已经交过了，等它解决
        if (r.fresh) {
          this.adoptAfterTurn.add(s.id);
          await (await this.runner(s)).send({ id: randomUUID(), text: conflictPrompt(s.branch, r.files), source: 'kite' });
        }
        return { status: 'conflict', files: r.files };
      });
      this.bus.emit(s.id, { type: 'adopt', result });
      return result;
    });
  }

  // ── 归档 ──

  /** 关掉进程、删工作树和会话分支，快照引用保留。有没采纳的改动时要 force。 */
  async archive(id: string, force = false): Promise<void> {
    this.preparations.get(id)?.abort();
    return this.control(id, async () => {
      const s = this.mustSession(id);
      if (s.status === 'archived') return;
      const p = this.project(s.projectId);
      // 重新打开 harness 会核查残锁和受管进程；没确认停止前不能删除工作树。
      const r = await this.runnerForManagement(s);
      this.adoptAfterTurn.delete(id);
      if (r) {
        // harness 的 shutdown 先禁止推进，再打断，避免收尾时启动排队输入。
        await r.shutdown();
        this.runners.delete(id);
      }
      if (!force && (await hasUnmerged(p.path, s.worktree))) throw new KiteError('会话有没合回主线的改动；确定丢弃就加 force', 409);
      if (existsSync(s.worktree)) await this.serial(`snap:${s.id}`, () => capture(s.worktree, s.id, '归档前保存'));
      await removeWorktree(p.path, s.worktree, s.branch);
      this.turnLabels.delete(id);
      this.queues.delete(`snap:${id}`);
      this.setStatus(s, 'archived');
    });
  }

  async shutdown(): Promise<void> {
    this.stopping = true;
    for (const controller of this.preparations.values()) controller.abort();
    await Promise.allSettled([...this.queues.values()]);
    await Promise.all([...this.runners.values()].map((r) => r.shutdown()));
  }
}
