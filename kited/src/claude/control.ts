/** 保存宿主控制状态与运行窗口；Claude 对话与恢复数据仍由 SDK 保存。 */
import { closeSync, existsSync, fsyncSync, mkdirSync, openSync, readFileSync, renameSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { randomUUID } from 'node:crypto';
import { z } from 'zod';
import type { Input, Outcome, Phase, Recovery } from '../harness/types.ts';

const input = z.object({ id: z.string().min(1), text: z.string(), source: z.enum(['human', 'kite']) });
const schema = z.object({
  inputs: z.array(z.object({ input, sdkId: z.string(), at: z.number(), status: z.enum(['queued', 'submitted', 'unconfirmed', 'active', 'done', 'cancelled']), delivered: z.boolean(), midTurn: z.boolean().default(false) })),
  stops: z.array(z.object({ id: z.string(), request: z.string(), returned: z.array(input), completed: z.boolean().default(false) })),
  processes: z.array(z.number().int().positive()),
  initialContext: z.string().optional(), context: z.string().optional(), through: z.number().default(0),
  paused: z.boolean().default(false),
  /** 切换后端前由另一后端处理过的输入，重发同一 ID 不再投递。 */
  importedInputs: z.array(z.string()).default([]),
  /** CLI 上报的运行窗口，关联配置模型和对应的主循环用量，不能配给其他模型或旧请求。 */
  contextWindow: z.object({ model: z.string().min(1), tokens: z.number().int().positive(), requestId: z.string().min(1) }).optional(),
  outcome: z.discriminatedUnion('kind', [z.object({ kind: z.literal('completed') }), z.object({ kind: z.literal('interrupted') }),
    z.object({ kind: z.literal('failed'), message: z.string() })]).optional(),
  recovery: z.object({ message: z.string() }).optional(),
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
  recovery?: Recovery;
}
export function readClaudeControl(directory: string): ClaudeControl {
  const path = join(directory, 'claude-control.json');
  const data = existsSync(path) ? schema.parse(JSON.parse(readFileSync(path, 'utf8'))) : schema.parse({ inputs: [], stops: [], processes: [] });
  if (data.inputs.some((entry) => entry.status === 'active' || entry.status === 'submitted')) data.recovery ??= { message: '上次 Claude 执行未收尾，请确认旧进程已停止后恢复；不会重放工具。' };
  if (data.stops.some((entry) => !entry.completed)) data.recovery ??= { message: '上次停止尚未确认完成，请核查旧执行后恢复，再重试原停止请求。' };
  if (data.inputs.some((entry) => entry.status === 'queued')) data.paused = true;
  return data;
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
export const claudeState = (data: Pick<ClaudeControl, 'inputs' | 'outcome' | 'recovery' | 'paused' | 'contextWindow'>, phase: Phase = 'idle', compacting = false): ClaudeState => ({
  inputs: data.inputs, phase, busy: phase !== 'idle' || compacting, ...(compacting ? { compacting } : {}), lastOutcome: data.outcome, recovery: data.recovery,
  contextWindow: data.contextWindow,
  waitingForResume: !!data.recovery || (phase === 'idle' && data.paused),
});
export const sameInput = (a: Input, b: Input) => a.id === b.id && a.text === b.text && a.source === b.source;
