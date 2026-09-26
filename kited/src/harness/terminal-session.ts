/** 独立终端宿主：指令装配、会话目录互斥和受管进程登记，不经过旧 Claude Runner。 */
import { closeSync, existsSync, fsyncSync, mkdirSync, openSync, readFileSync, realpathSync, renameSync, rmSync, writeFileSync } from 'node:fs';
import { dirname, join, parse } from 'node:path';
import { randomUUID } from 'node:crypto';
import { FileJournal } from './journal.ts';
import { HarnessSession } from './session.ts';
import { localTools } from './local-tools.ts';
import { processGroupAlive } from './command.ts';
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

function instructions(cwd: string): string {
  const folders: string[] = [];
  let folder = cwd;
  while (true) {
    folders.unshift(folder);
    if (existsSync(join(folder, '.git')) || folder === parse(folder).root) break;
    folder = dirname(folder);
  }
  const documents: string[] = [];
  for (const directory of folders) {
    for (const name of ['AGENTS.md', '.kite/memory/MEMORY.md']) {
      const path = join(directory, name);
      if (existsSync(path)) {
        const content = readFileSync(path, 'utf8');
        if (content.length > 100_000) throw new Error(`项目指令文件过大：${path}`);
        documents.push(`文件 ${path}：\n${content}`);
      }
    }
  }
  return [
    '你是 Kite 的本地编程助手。使用简体中文交流，按用户要求完成工作并验证结果。',
    `当前工作目录：${cwd}。日期：${new Date().toISOString().slice(0, 10)}。`,
    '使用 read 读取真实文件，用 patch 创建、修改和删除文件；不要编造执行结果。搜索用 shell 中的 rg。',
    '建议编辑前先读文件；未读或文件变化仅提示，不是编辑门槛。patch 提示存在其他变化时，依赖周边内容的后续修改应先重读。',
    '进入子目录前读取适用的 AGENTS.md。项目记忆只使用 .kite/memory，不新建另一份。',
    'shell 命令直接在当前目录执行，不要启动后台任务或脱离进程组的守护进程。',
    '修改文件后做与任务相关的检查。不要擅自提交、推送或部署。',
    '当前提供文件和 shell 工具，没有子 agent 或 MCP 工具；项目要求这些能力时如实说明限制，不声称已经调用。',
    ...documents,
  ].join('\n\n');
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
    const prompt = instructions(cwd);
    journal = new FileJournal(join(directory, 'journal.jsonl'));
    const runner = new HarnessSession({
      cwd, instructions: prompt, journal, model: options.model,
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
