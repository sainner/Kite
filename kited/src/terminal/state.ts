/** 终端实例的状态：进程是否在跑、怎么结束的、监听的端口。实例聚合和 terminal_read 的结果共用。 */
import { z } from 'zod';
import type { PluginInstance } from '../model.ts';

export const stateSchema = z.object({
  phase: z.enum(['running', 'exited']),
  /** 正常退出的退出码；被信号停下时为 null，signal 写信号名。 */
  exitCode: z.number().int().nullable().optional(),
  signal: z.string().optional(),
  /** 不是自己退出的原因：用户停止、工作区交接、工作机重启、启动失败。 */
  reason: z.string().optional(),
  endedAt: z.number().optional(),
  /** 运行中进程树正在监听的 TCP 端口，按端口号排；http 是能不能用 HTTP 打开。结束后没有。 */
  ports: z.array(z.object({ port: z.number().int(), http: z.boolean() }).strict()).optional(),
}).strict();
export type TerminalState = z.infer<typeof stateSchema>;
export const terminalState = (instance: Pick<PluginInstance, 'state'>): TerminalState | undefined =>
  instance.state.terminal === undefined ? undefined : stateSchema.parse(instance.state.terminal);
