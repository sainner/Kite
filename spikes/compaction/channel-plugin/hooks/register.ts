/**
 * 实验用 mod：把宿主的内部工具设为延迟加载，移出模型的工具列表（工具搜索已关闭，模型找不到它）；
 * 每个回合结束时调用它一次，再把收到的结果原样回传，宿主据此确认往返。进出 hook 都记到日志文件里。
 */
export function register(on: any): void {
  const lines: string[] = [];
  // hooks worker 不能直接写文件；经 $.fs.write 写到工作目录里。
  const log = async ($: any, text: string) => {
    lines.push(text);
    try { await $.fs.write(process.env.KITE_SPIKE_LOG!, lines.join('\n')); } catch (error) { lines.push(`写日志失败：${error}`); }
  };
  if (process.env.KITE_SPIKE_DEFER === '1') on('tool.describe', { tool: 'mcp__kite-internal__plan' }, async ($: any, e: any, next: any) => ({ ...(await next(e)), isDeferred: true }));
  on('turn.complete', async ($: any, e: any, next: any) => {
    await log($, '进入 turn.complete');
    const result = await next(e);
    try {
      const reply = await $.mcp.call('kite-internal', 'plan', { probe: 'mod' });
      await $.mcp.call('kite-internal', 'plan', { echo: JSON.stringify(reply) });
      await log($, `调用完成：${JSON.stringify(reply)}`);
    } catch (error) {
      await log($, `调用失败：${error instanceof Error ? error.message : String(error)}`);
    }
    return result;
  });
}
