/** 本地会话宿主：终端与 kited 共用指令装配、目录互斥和受管进程登记。 */
import { closeSync, existsSync, fsyncSync, mkdirSync, openSync, readFileSync, realpathSync, renameSync, rmSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { randomUUID } from 'node:crypto';
import { FileJournal } from './journal.ts';
import { HarnessRunner } from './runner.ts';
import { localTools } from './local-tools.ts';
import { processGroupAlive } from './command.ts';
import { commandEnvironment, workspacePolicy, type ExecutionPolicy } from '../sandbox.ts';
import type { HarnessRequest, RequestSettings, HarnessOptions, ThreadRunner, Tool } from './types.ts';

export interface ThreadHostOptions extends Pick<HarnessOptions, 'onEvent' | 'afterTools' | 'afterTurn' | 'beforeStop' | 'startPaused'> {
  cwd: string;
  threadDir: string;
  diffDir?: string;
  env: NodeJS.ProcessEnv;
  policy?: ExecutionPolicy | (() => ExecutionPolicy);
  prepareRequest(tools: Tool[], cursor: { afterNotification: number }): HarnessRequest;
  /** 独立终端的配置来源；kited 使用实例配置，不在 metadata 重复保存。 */
  settings?: RequestSettings;
}

export interface ThreadHost {
  runner: ThreadRunner;
  /** 检查登记的进程组后解除恢复阻塞；不自动开始执行。 */
  confirmRecovery(): Promise<void>;
  close(): Promise<void>;
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

export async function openThreadHost(options: ThreadHostOptions): Promise<ThreadHost> {
  const cwd = realpathSync(options.cwd);
  mkdirSync(options.threadDir, { recursive: true, mode: 0o700 });
  const directory = realpathSync(options.threadDir);
  const lock = join(directory, 'lock');
  try { mkdirSync(lock, { mode: 0o700 }); }
  catch { throw new Error(`会话已被占用，或上次异常退出留下了锁：${lock}。确认旧进程和命令均已停止后才能删除该锁。`); }
  let journal: FileJournal | undefined;
  try {
    save(join(lock, 'owner.json'), { pid: process.pid, at: Date.now() });
    const metadataPath = join(directory, 'metadata.json');
    const previous = readThreadMetadata(directory);
    if (previous && previous.cwd !== cwd) throw new Error('不能更换已有会话的工作目录；请新建会话');
    const processFile = join(directory, 'processes.json');
    const checkProcesses = () => {
      const pids: unknown = existsSync(processFile) ? JSON.parse(readFileSync(processFile, 'utf8')) : [];
      if (!Array.isArray(pids) || !pids.every((pid) => Number.isSafeInteger(pid) && pid > 0)) throw new Error('会话进程登记损坏，不能自动恢复');
      if (pids.some((pid) => processGroupAlive(pid as number))) throw new Error('会话登记的命令进程组仍可能在运行，请先确认并停止旧执行');
    };
    checkProcesses();
    const active = new Set<number>();
    save(processFile, []);
    save(metadataPath, { cwd, ...(options.settings ? { settings: options.settings } : {}) });
    journal = new FileJournal(join(directory, 'journal.jsonl'));
    const env = commandEnvironment(options.env);
    const policy = () => typeof options.policy === 'function' ? options.policy() : options.policy ?? workspacePolicy(cwd, env);
    const tools = localTools({
      cwd, logDir: join(directory, 'commands'), diffDir: options.diffDir ?? join(directory, 'diffs'), env,
      policy: () => {
        const current = policy();
        return { ...current, denyRead: [...(current.denyRead ?? []), directory], denyWrite: [...(current.denyWrite ?? []), directory] };
      },
      onProcess(pid, running) { if (running) active.add(pid); else active.delete(pid); save(processFile, [...active]); },
    });
    const runner = new HarnessRunner({
      cwd, journal, prepareRequest: (cursor) => options.prepareRequest(tools, cursor),
      onEvent: options.onEvent,
      startPaused: options.startPaused,
      afterTools: options.afterTools, afterTurn: options.afterTurn, beforeStop: options.beforeStop,
    });
    let closing: Promise<void> | undefined;
    return {
      runner,
      async confirmRecovery() { checkProcesses(); await runner.confirmRecovery(); },
      close() {
        closing ??= (async () => {
          await runner.shutdown();
          checkProcesses();
          rmSync(lock, { recursive: true });
        })();
        return closing;
      },
    };
  } catch (error) {
    journal?.close();
    rmSync(lock, { recursive: true, force: true });
    throw error;
  }
}
