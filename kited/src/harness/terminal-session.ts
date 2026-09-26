/** 独立终端宿主：指令装配、会话目录互斥和受管进程登记，不经过旧 Claude Runner。 */
import { closeSync, existsSync, fsyncSync, mkdirSync, openSync, readFileSync, realpathSync, renameSync, rmSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { randomUUID } from 'node:crypto';
import { FileJournal } from './journal.ts';
import { HarnessSession } from './session.ts';
import { localTools } from './local-tools.ts';
import { processGroupAlive } from './command.ts';
import { projectContext } from './context/project.ts';
import type { ContextDefinition } from './context/types.ts';
import type { JsonObject, Model, SessionEvent, SessionRunner, Tool } from './types.ts';

export interface TerminalSessionOptions {
  cwd: string;
  sessionDir: string;
  model: Model;
  tools?: Tool[];
  env: NodeJS.ProcessEnv;
  onEvent?(event: SessionEvent): void;
  maxRequestsPerTurn?: number;
  /** 命令行记录实际选用的模型参数；不放认证信息。 */
  modelConfig?: JsonObject;
  /** 宿主可替换定义；动态定义在下一次请求边界生效。 */
  contextDefinition?: ContextDefinition | (() => ContextDefinition);
}

export interface TerminalSession {
  runner: SessionRunner;
  close(): Promise<void>;
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

export async function openTerminalSession(options: TerminalSessionOptions): Promise<TerminalSession> {
  const cwd = realpathSync(options.cwd);
  mkdirSync(options.sessionDir, { recursive: true, mode: 0o700 });
  const directory = realpathSync(options.sessionDir);
  const lock = join(directory, 'lock');
  try { mkdirSync(lock, { mode: 0o700 }); }
  catch { throw new Error(`会话已被占用，或上次异常退出留下了锁：${lock}。确认旧进程和命令均已停止后才能删除该锁。`); }
  let journal: FileJournal | undefined;
  try {
    save(join(lock, 'owner.json'), { pid: process.pid, at: Date.now() });
    const metadataPath = join(directory, 'metadata.json');
    const previous = existsSync(metadataPath) ? JSON.parse(readFileSync(metadataPath, 'utf8')) as { cwd?: unknown; modelConfig?: unknown } : undefined;
    if (previous && previous.cwd !== cwd) throw new Error('不能更换已有会话的工作目录；请新建会话');
    const processFile = join(directory, 'processes.json');
    const pids: unknown = existsSync(processFile) ? JSON.parse(readFileSync(processFile, 'utf8')) : [];
    if (!Array.isArray(pids) || !pids.every((pid) => Number.isSafeInteger(pid) && pid > 0)) throw new Error('会话进程登记损坏，不能自动恢复');
    if (pids.some((pid) => processGroupAlive(pid as number))) throw new Error('会话登记的命令进程组仍可能在运行，请先确认并停止旧执行');
    const active = new Set<number>();
    save(processFile, []);
    save(metadataPath, { version: 1, cwd, modelConfig: options.modelConfig ?? previous?.modelConfig ?? {} });
    journal = new FileJournal(join(directory, 'journal.jsonl'));
    const runner = new HarnessSession({
      cwd, journal, model: options.model,
      instructions: () => projectContext(cwd, typeof options.contextDefinition === 'function' ? options.contextDefinition() : options.contextDefinition),
      tools: options.tools ?? localTools({
        cwd, logDir: join(directory, 'commands'), env: options.env,
        onProcess(pid, running) { if (running) active.add(pid); else active.delete(pid); save(processFile, [...active]); },
      }),
      onEvent: options.onEvent, maxRequestsPerTurn: options.maxRequestsPerTurn,
    });
    let closing: Promise<void> | undefined;
    return {
      runner,
      close() {
        closing ??= (async () => {
          await runner.shutdown();
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
