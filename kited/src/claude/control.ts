/** 保存宿主控制状态与运行窗口；Claude 对话与恢复数据仍由 SDK 保存。 */
import { closeSync, existsSync, fsyncSync, mkdirSync, openSync, readFileSync, renameSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { randomUUID } from 'node:crypto';
import { z } from 'zod';
import { inputSchema, stopBy } from '../harness/input.ts';
import type { Outcome, Phase } from '../harness/types.ts';
import { processGroupsSchema } from '../execution/command.ts';

const input = inputSchema;
const schema = z.object({
  /** skill 是点选的 skill 收下时固定的正文（见 InputMaterial），交给 Claude 时接在输入后面。 */
  inputs: z.array(z.object({ input, skill: z.string().min(1).optional(), sdkId: z.string(), at: z.number(),
    status: z.enum(['queued', 'submitted', 'active', 'done', 'cancelled']), delivered: z.boolean(), midTurn: z.boolean().default(false) })),
  stops: z.array(z.object({ id: z.string(), request: z.string(), returned: z.array(input), completed: z.boolean().default(false), by: stopBy.optional() })),
  processes: processGroupsSchema,
  /**
   * initialContext 是系统提示；context 是最近交给模型的基础上下文去掉另由通知告知的变量后的正文（ContextAssembly.stable），比它决定要不要重发；
   * roster 是那时代理已知的工作区现况，比它决定要不要补现况变化的通知。
   */
  initialContext: z.string().optional(), context: z.string().optional(), roster: z.string().optional(), through: z.number().default(0),
  paused: z.boolean().default(false),
  /** 切换后端前由另一后端处理过的输入，重发同一 ID 不再投递。 */
  importedInputs: z.array(z.string()).default([]),
  /** CLI 上报的运行窗口，关联配置模型和对应的主循环用量，不能配给其他模型或旧请求。 */
  contextWindow: z.object({ model: z.string().min(1), tokens: z.number().int().positive(), requestId: z.string().min(1) }).optional(),
  outcome: z.discriminatedUnion('kind', [z.object({ kind: z.literal('completed') }), z.object({ kind: z.literal('interrupted') }),
    z.object({ kind: z.literal('failed'), message: z.string() })]).optional(),
  /** 回合被 kited 退出打断（关闭时停下，或打开时发现崩溃），还没接着做；下一回合开始或人停下时清除，见 openClaudeHost。 */
  exited: z.boolean().default(false),
  /** 连续被 kited 崩溃打断的次数（关闭时停下的不算）；回合正常完成、用户本人发来消息或回应、继续时清零，工具结果不清零。 */
  exits: z.number().int().nonnegative().default(0),
});
export type ClaudeControl = z.infer<typeof schema>;
export interface ClaudeState {
  inputs: ClaudeControl['inputs'];
  phase: Phase;
  busy: boolean;
  /** 正在压缩上下文；期间不启动新回合。 */
  compacting?: boolean;
  contextWindow?: ClaudeControl['contextWindow'];
  waitingForResume: boolean;
  lastOutcome?: Outcome;
}
export function readClaudeControl(directory: string): ClaudeControl {
  const path = join(directory, 'claude-control.json');
  return existsSync(path) ? schema.parse(JSON.parse(readFileSync(path, 'utf8'))) : schema.parse({ inputs: [], stops: [], processes: [] });
}
export function saveClaudeControl(directory: string, data: z.input<typeof schema>): void {
  mkdirSync(directory, { recursive: true, mode: 0o700 });
  const path = join(directory, 'claude-control.json');
  const temp = `${path}.${randomUUID()}.tmp`;
  const fd = openSync(temp, 'wx', 0o600);
  try { writeFileSync(fd, JSON.stringify(schema.parse(data))); fsyncSync(fd); } finally { closeSync(fd); }
  renameSync(temp, path);
  const folder = openSync(dirname(path), 'r');
  try { fsyncSync(folder); } finally { closeSync(folder); }
}
export const claudeState = (data: Pick<ClaudeControl, 'inputs' | 'outcome' | 'paused' | 'contextWindow'>, phase: Phase = 'idle', compacting = false): ClaudeState => ({
  // 压缩在回合之间进行，宿主内部仍是空闲；对外同 harness，压缩期间是 running。
  inputs: data.inputs, phase: compacting && phase === 'idle' ? 'running' : phase, busy: phase !== 'idle' || compacting, ...(compacting ? { compacting } : {}), lastOutcome: data.outcome,
  contextWindow: data.contextWindow,
  waitingForResume: phase === 'idle' && data.paused,
});
