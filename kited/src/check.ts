/**
 * check 工具：跑工作树里的 .kite/check（契约见 kite-onboard skill）。
 * 在哪跑照预览目标的规则（docs/实例操作.md「目标」）：检查命令在工作树里，代理改得了，与这台工作机检出主线上的一致才直接在沙箱外跑，
 * 不一致时先经审批，没获准就在沙箱里跑；工作区只读时总在沙箱里跑。沙箱里用的是代理的执行授权、网络审批，进程登记两处都一样。
 * 怎么跑由这里定，项目的检查命令只管查什么、怎么报：
 * - KITE_BASE：取工作区分支和主线的分叉点，工作区里已经提交的改动也算进受影响的范围；
 * - KITE_LOG_DIR：每次检查一个日志目录，放在 Kite 数据目录里按工作区分开，代理之后能读；
 * - 排队：一台机器上一次只跑一个检查。
 */
import { existsSync, mkdirSync, readdirSync, readFileSync, rmSync } from 'node:fs';
import { randomUUID } from 'node:crypto';
import { join } from 'node:path';
import { gitTry, revParse } from './workspace/git.ts';
import { mainlineFile } from './workspace/mainline.ts';
import { runCommand, type CommandOptions } from './execution/command.ts';
import type { ExecutionPolicy } from './execution/sandbox.ts';
import type { ToolResult } from './harness/types.ts';

const CHECK_TIMEOUT_MS = 10 * 60_000;
/** 每个工作区留最近这么多次检查的日志，代理要看的通常是刚没通过的那次。 */
const KEEP_RUNS = 10;

const SCRIPT = '.kite/check';

export const hasCheck = (worktree: string): boolean => existsSync(join(worktree, SCRIPT));

/** 一个工作区的检查日志都在这里，代理只读。 */
export const checkLogs = (home: string, workspaceId: string): string => join(home, 'checks', workspaceId);

/** 工作区分支和主线（检出是裸仓库，HEAD 就是主线）的分叉点。 */
async function forkPoint(main: string, worktree: string): Promise<string | null> {
  const tip = await revParse(main, 'HEAD');
  if (!tip) return null;
  const r = await gitTry(worktree, ['merge-base', 'HEAD', tip]);
  return r.code === 0 ? r.stdout.trim() : null;
}

/*
 * 排队：检查按耗时预算判定，两个同时跑会互相拖慢、误报超时（实测两次全量同时跑都超了），所以一台机器上一次只跑一个。
 * 预算把一次全量限在十几秒，排在后面最多等这么久，不会像 Pigeon 那样被几分钟的检查堵住。
 * 一台机器只有一个 kited，进程内排队就够了；agent 绕开工具在 shell 里跑的不排队。
 */
let queue: Promise<void> = Promise.resolve();

/** 排到了返回放行函数；排队时 signal 触发返回 null，排在后面的照常往前走。 */
async function takeTurn(signal: AbortSignal): Promise<(() => void) | null> {
  let release!: () => void;
  const done = new Promise<void>((r) => (release = r));
  const ahead = queue;
  queue = ahead.then(() => done);
  let onAbort = () => {};
  const aborted = new Promise<null>((r) => { onAbort = () => r(null); });
  if (signal.aborted) onAbort();
  signal.addEventListener('abort', onAbort, { once: true });
  const turn = await Promise.race([ahead.then(() => release), aborted]);
  signal.removeEventListener('abort', onAbort);
  if (!turn) release();
  return turn;
}

/** 新开这次检查的日志目录，旧的只留最近几次。目录名按时间排序；排着队，删的不会是正在跑的那次。 */
function newRun(logs: string): string {
  mkdirSync(logs, { recursive: true });
  const runs = readdirSync(logs).sort();
  for (const old of runs.slice(0, Math.max(0, runs.length - KEEP_RUNS + 1))) rmSync(join(logs, old), { recursive: true, force: true });
  const dir = join(logs, `${new Date().toISOString().replace(/[:.]/g, '-')}-${randomUUID().slice(0, 4)}`);
  mkdirSync(dir);
  return dir;
}

/** 宿主给 check 工具的：检出、日志目录，以及判断能不能出沙箱要用的。 */
export interface CheckHost {
  /** 检出（主线所在的仓库）。 */
  main: string;
  /** 这个工作区的检查日志目录，见 checkLogs。 */
  logs: string;
  /** 不给时总在沙箱里跑（独立终端）。 */
  outside?: {
    /** 工作区此刻按执行授权是否只读。 */
    readOnly(): boolean;
    /** 与主线不一致的检查命令出沙箱前问：按审批模式放行、拒绝或问人，记住过的内容直接放行。 */
    approve(script: string, reason: string, signal: AbortSignal): Promise<boolean>;
  };
}

export interface CheckOptions extends CheckHost {
  timeoutMs?: number;
  /** 和 shell 一样的执行设置；cwd 是工作树。不转后台、不带密钥。 */
  command: Pick<CommandOptions, 'cwd' | 'env' | 'outputLimit' | 'onOutput' | 'onProcess' | 'askNetwork'> & { policy: ExecutionPolicy };
}

const readScript = (worktree: string): string | null => { try { return readFileSync(join(worktree, SCRIPT), 'utf8'); } catch { return null; } };

/** 这份检查命令在不在沙箱外跑；在沙箱里跑时 note 说明为什么。 */
async function placement(o: CheckOptions, script: string, signal: AbortSignal): Promise<{ unsandboxed: boolean; note?: string }> {
  if (!o.outside) return { unsandboxed: false };
  if (o.outside.readOnly()) return { unsandboxed: false, note: '工作区只读，检查在沙箱里跑。' };
  const main = await mainlineFile({ path: o.main }, SCRIPT);
  if (main === script) return { unsandboxed: true };
  const approved = await o.outside.approve(script, main === null ? '主线上还没有检查命令，批准后在沙箱外运行' : '检查命令与主线上的不一致，批准后在沙箱外运行', signal);
  return approved ? { unsandboxed: true } : { unsandboxed: false, note: '没有获准在沙箱外运行，检查在沙箱里跑；沙箱里做不到的事（如监听本机端口）会失败。' };
}

/** 命令的输出和 .kite/check 自己的日志都写进这次检查的目录；在沙箱里跑时检查命令只多得到这个目录的写权限。 */
export async function runCheck(all: boolean, signal: AbortSignal, o: CheckOptions): Promise<ToolResult> {
  const { command } = o;
  const script = readScript(command.cwd);
  if (script === null) return { status: 'error', output: `工作树里没有 ${SCRIPT}。` };
  // 审批可能要等人，放在排队之前，免得占着队列。
  const where = await placement(o, script, signal);
  if (signal.aborted) return { status: 'not_executed', output: '检查还没开始就被停下，没有运行。' };
  const queued = performance.now();
  const release = await takeTurn(signal);
  if (!release) return { status: 'not_executed', output: '检查还在排队时被停下，没有运行。' };
  try {
    // 核对之后、排到之前，同一工作区别的代理可能改了它；出沙箱的只跑核对过的那份。
    if (where.unsandboxed && readScript(command.cwd) !== script) return { status: 'error', output: `${SCRIPT} 在核对之后又被改了，检查没有运行。` };
    const waited = Math.round((performance.now() - queued) / 1000);
    // 排到了才算：排队时主线可能又往前走了
    const base = await forkPoint(o.main, command.cwd);
    const logDir = newRun(o.logs);
    const result = await runCommand(`exec ./${SCRIPT}${all ? ' --all' : ''}`, o.timeoutMs ?? CHECK_TIMEOUT_MS, signal, {
      ...command, logDir, env: { ...command.env, KITE_LOG_DIR: logDir, ...(base ? { KITE_BASE: base } : {}) },
      ...(where.unsandboxed ? { unsandboxed: true } : { policy: { ...command.policy, write: [...command.policy.write, logDir] } }),
    });
    const notes = [where.note, waited >= 1 ? `排队等了 ${waited} 秒，这台工作机上别的检查在跑。` : undefined].filter(Boolean);
    return notes.length ? { ...result, output: `${result.output}\n${notes.map((note) => `（${note}）`).join('\n')}` } : result;
  } finally {
    release();
  }
}
