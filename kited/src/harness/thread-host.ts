/** 本地会话宿主：终端与 kited 共用指令装配、目录互斥和受管进程登记。 */
import { closeSync, existsSync, fsyncSync, mkdirSync, openSync, readFileSync, realpathSync, renameSync, rmSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { randomUUID } from 'node:crypto';
import { FileJournal } from './journal.ts';
import { HarnessRunner } from './runner.ts';
import { localTools, type ShellBackground, type ShellOutside } from '../execution/local-tools.ts';
import type { SecretProvider } from '../secrets.ts';
import type { CheckHost } from '../check.ts';
import { processAlive, processGroupsSchema, stopProcessGroups, type NetworkAsk } from '../execution/command.ts';
import { commandEnvironment, workspacePolicy, type ExecutionPolicy } from '../execution/sandbox.ts';
import { SkillCatalog } from './context/project.ts';
import { systemSkillSources } from './context/skills.ts';
import type { HarnessRequest, JournalEvent, JournalRecord, RequestSettings, HarnessOptions, ThreadRunner, Tool } from './types.ts';

export interface ThreadHostOptions extends Pick<HarnessOptions, 'onEvent' | 'afterTools' | 'afterTurn' | 'beforeStop' | 'compactionFiles'> {
  cwd: string;
  threadDir: string;
  diffDir?: string;
  env: NodeJS.ProcessEnv;
  secrets?: SecretProvider;
  policy?: ExecutionPolicy | (() => ExecutionPolicy);
  /** 命令连接授权之外的主机时交给谁决定，见 CommandOptions.askNetwork。 */
  askNetwork?: NetworkAsk;
  /** 长命令转到后台终端，见 ShellBackground；独立终端没有。 */
  background?: ShellBackground;
  /** 沙箱外运行的判断与申请，见 ShellOutside；独立终端没有，命令总在沙箱里。 */
  outside?: ShellOutside;
  /** 工具用的 skill 清单，每次请求前刷新后再调 prepareRequest；不给时只有系统层与项目层。 */
  skills?: SkillCatalog;
  /** check 工具要的检出、日志目录与出沙箱的判断，见 CheckHost；独立终端没有。 */
  check?: CheckHost;
  prepareRequest(tools: Tool[], cursor: { afterNotification: number }): HarnessRequest;
  /** 独立终端的配置来源；kited 使用实例配置，不在 metadata 重复保存。 */
  settings?: RequestSettings;
}

export interface ThreadHost {
  runner: ThreadRunner;
  /** 见 ThreadRunner.continueInterrupted；打开时有命令进程没能停下的，一并写进继续说明。 */
  continueInterrupted(note?: string): Promise<void>;
  close(): Promise<void>;
}

/**
 * 会话目录里的标记：回合在跑，或被 kited 退出打断后还没续跑时留着，由宿主照记录推导（harness 见 HarnessRunner.running）。
 * kited 启动时据此打开这些会话，打开时由宿主按记录决定是否接着做；两个后端共用。
 */
export const RUNNING_MARKER = 'running';
export function markRunning(directory: string, running: boolean): void {
  const path = join(directory, RUNNING_MARKER);
  if (running) writeFileSync(path, '');
  else rmSync(path, { force: true });
}

interface ThreadMetadata {
  cwd: string;
  settings?: RequestSettings;
}

/** 入口只决定配置覆盖顺序，会话文件的位置和格式由宿主管理。 */
export function readThreadMetadata(directory: string): ThreadMetadata | undefined {
  const path = join(directory, 'metadata.json');
  return existsSync(path) ? JSON.parse(readFileSync(path, 'utf8')) as ThreadMetadata : undefined;
}

function save(path: string, data: unknown): void {
  const temp = `${path}.${randomUUID()}.tmp`;
  const fd = openSync(temp, 'wx', 0o600);
  try { writeFileSync(fd, JSON.stringify(data, null, 2) + '\n'); fsyncSync(fd); }
  finally { closeSync(fd); }
  try { renameSync(temp, path); }
  finally { rmSync(temp, { force: true }); }
  const directory = openSync(dirname(path), 'r');
  try { fsyncSync(directory); } finally { closeSync(directory); }
}

/** 宿主未打开时追加记录（跨后端导入）；沿用宿主的锁，不能与运行中的宿主并发写。 */
export function appendThreadJournal(threadDir: string, event: JournalEvent): JournalRecord {
  const release = lockThread(threadDir);
  try {
    const journal = new FileJournal(join(threadDir, 'journal.jsonl'));
    try { return journal.append(event); } finally { journal.close(); }
  } finally { release(); }
}

/** 宿主未打开时在 journal 上做一段工作（Claude 线程的压缩）；期间持有宿主的锁。 */
export async function withThreadJournal<T>(threadDir: string, work: (journal: FileJournal) => Promise<T>): Promise<T> {
  const release = lockThread(threadDir);
  try {
    const journal = new FileJournal(join(threadDir, 'journal.jsonl'));
    try { return await work(journal); } finally { journal.close(); }
  } finally { release(); }
}

/** 占住锁目录（会话目录下），返回释放函数；占着它的进程已经不在了（上次异常退出留下的锁）就收回。两个后端共用。 */
export function lockDirectory(lock: string, busy: (pid: number) => Error): () => void {
  mkdirSync(dirname(lock), { recursive: true, mode: 0o700 });
  try { mkdirSync(lock, { mode: 0o700 }); }
  catch {
    let pid = 0;
    try { pid = Number(readFileSync(join(lock, 'owner'), 'utf8')); } catch { /* 建锁与写 owner 之间退出，视为无主的旧锁。 */ }
    if (Number.isSafeInteger(pid) && pid > 0 && processAlive(pid)) throw busy(pid);
    rmSync(lock, { recursive: true, force: true });
    mkdirSync(lock, { mode: 0o700 });
  }
  try { writeFileSync(join(lock, 'owner'), String(process.pid)); }
  catch (error) { rmSync(lock, { recursive: true, force: true }); throw error; }
  return () => rmSync(lock, { recursive: true, force: true });
}

const lockThread = (directory: string) => lockDirectory(join(directory, 'lock'), (pid) => new Error(`会话已被进程 ${pid} 占用：${directory}`));

export async function openThreadHost(options: ThreadHostOptions): Promise<ThreadHost> {
  const cwd = realpathSync(options.cwd);
  mkdirSync(options.threadDir, { recursive: true, mode: 0o700 });
  const directory = realpathSync(options.threadDir);
  const release = lockThread(directory);
  let journal: FileJournal | undefined;
  try {
    const metadataPath = join(directory, 'metadata.json');
    const previous = readThreadMetadata(directory);
    if (previous && previous.cwd !== cwd) throw new Error('不能更换已有会话的工作目录；请新建会话');
    const processFile = join(directory, 'processes.json');
    const registered = processGroupsSchema.safeParse(existsSync(processFile) ? JSON.parse(readFileSync(processFile, 'utf8')) : []);
    if (!registered.success) throw new Error('会话进程登记损坏');
    // 停不掉的留在登记里，下次打开或关闭时再停。
    const active = new Map((await stopProcessGroups(registered.data)).map((group) => [group.pid, group]));
    save(processFile, [...active.values()]);
    save(metadataPath, { cwd, ...(options.settings ? { settings: options.settings } : {}) });
    journal = new FileJournal(join(directory, 'journal.jsonl'));
    const env = commandEnvironment(options.env);
    const policy = () => typeof options.policy === 'function' ? options.policy() : options.policy ?? workspacePolicy(cwd, env);
    const skills = options.skills ?? new SkillCatalog(cwd, systemSkillSources);
    const tools = localTools({
      cwd, secrets: options.secrets, logDir: join(directory, 'commands'), diffDir: options.diffDir ?? join(directory, 'diffs'), env, skills,
      ...(options.askNetwork ? { askNetwork: options.askNetwork } : {}),
      ...(options.background ? { background: options.background } : {}),
      ...(options.outside ? { outside: options.outside } : {}),
      ...(options.check ? { check: options.check } : {}),
      policy: () => {
        const current = policy();
        return { ...current, denyRead: [...(current.denyRead ?? []), directory], denyWrite: [...(current.denyWrite ?? []), directory] };
      },
      onProcess(pid, running, started) { if (running) active.set(pid, { pid, started }); else active.delete(pid); save(processFile, [...active.values()]); },
    });
    const leftovers = active.size ? '有命令的进程没能停下，可能还在运行' : undefined;
    // 运行标记只照 runner.running 放下、收起，每条记录之后对一次；构造时补记的恢复记录等构造完一起对（那时 marked 还没有值）。
    let marked: boolean | undefined;
    const mark = (running: boolean) => {
      if (running === marked) return;
      marked = running;
      markRunning(directory, running);
    };
    const runner: HarnessRunner = new HarnessRunner({
      cwd, journal, prepareRequest: (cursor) => { skills.refresh(); return options.prepareRequest(tools, cursor); },
      onEvent(event) {
        if (event.type === 'record' && marked !== undefined) mark(runner.running);
        options.onEvent?.(event);
      },
      afterTools: options.afterTools, afterTurn: options.afterTurn, beforeStop: options.beforeStop,
      compactionFiles: options.compactionFiles,
    });
    mark(runner.running);
    let closing: Promise<void> | undefined;
    return {
      runner,
      continueInterrupted: (note) => runner.continueInterrupted([note, leftovers].filter(Boolean).join('；') || undefined),
      close() {
        closing ??= (async () => {
          try {
            await runner.shutdown();
            if (active.size) save(processFile, await stopProcessGroups([...active.values()]));
          } finally { release(); }
        })();
        return closing;
      },
    };
  } catch (error) {
    journal?.close();
    release();
    throw error;
  }
}
