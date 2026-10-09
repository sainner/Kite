/** 连续可并发调用共享执行区；排他调用是屏障，后面的调用不得越过。 */
import type { Tool, ToolCall, ToolResult } from './types.ts';

export interface BatchOptions {
  cwd: string;
  signal: AbortSignal;
  turnId?: string;
  tools: ReadonlyMap<string, Tool>;
  blocked?(name: string): string | undefined;
  started(call: ToolCall): void;
  output?(call: ToolCall, text: string, limit: number): void;
  finished(call: ToolCall, result: ToolResult): void;
  /** 存储故障或结果未知时停止当前请求与其余工具。 */
  fatal(error: unknown): void;
}

export class ToolBatch {
  private barrier: Promise<void> = Promise.resolve();
  private parallel: Promise<void>[] = [];
  private failed?: { error: unknown };
  readonly calls: ToolCall[] = [];

  constructor(private options: BatchOptions) {}

  enqueue(call: ToolCall): void {
    this.calls.push(call);
    const tool = this.options.tools.get(call.name);
    const ready = tool?.parallel ? this.barrier : Promise.all([this.barrier, ...this.parallel]);
    // 每个任务立即接住异常，流仍在读取时也不会产生 unhandled rejection。
    const task = ready.then(() => this.run(call, tool)).catch((error: unknown) => {
      this.failed ??= { error };
      this.options.fatal(error);
    });
    if (tool?.parallel) this.parallel.push(task);
    else { this.barrier = task; this.parallel = []; }
  }

  async drain(): Promise<void> {
    await Promise.all([this.barrier, ...this.parallel]);
    if (this.failed) throw this.failed.error;
  }

  private async run(call: ToolCall, tool: Tool | undefined): Promise<void> {
    const o = this.options;
    if (this.failed) return; // 存储故障后不能继续写记录或启动副作用，留给恢复处理。
    if (o.signal.aborted) {
      o.finished(call, { status: 'not_executed', output: '本次执行已停止，工具未启动。' });
      return;
    }
    try {
      if (!tool) throw new Error(`未知工具：${call.name}`);
      tool.validate(call.arguments);
    } catch (error) {
      o.finished(call, { status: 'error', output: String(error) });
      return;
    }
    const blocked = o.blocked?.(call.name);
    if (blocked !== undefined) {
      o.finished(call, { status: 'not_executed', output: blocked });
      return;
    }
    o.started(call);
    // started 的观察者也可能同步请求打断。
    if (o.signal.aborted) {
      o.finished(call, { status: 'not_executed', output: '工具启动前已收到停止请求。' });
      return;
    }
    let result: ToolResult;
    let acceptingOutput = true;
    try {
      result = await tool.execute(call.arguments, { cwd: o.cwd, signal: o.signal, callId: call.id, turnId: o.turnId,
        output: (text, limit) => { if (acceptingOutput) o.output?.(call, text, limit); } });
    } catch (error) {
      result = { status: o.signal.aborted ? 'unknown' : 'error', output: String(error) };
    }
    acceptingOutput = false;
    o.finished(call, result);
    if (result.status === 'unknown') o.fatal(new Error(`工具 ${call.id} 的执行结果未知，需要确认恢复`));
  }
}
