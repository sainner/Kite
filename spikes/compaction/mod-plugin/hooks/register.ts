/**
 * 实验用 mod：接管 session.compact。第一轮与第三轮的消息带着引擎的 handle 原样交回，第二轮换成 $.model.fork 写的摘要；
 * 触发方式、消息条数、handle 数等诊断写进摘要消息，从假端点收到的请求里读出来。
 */
export function register(on: any): void {
  // KITE_SPIKE_DEFER=1：把 read 设为延迟加载，检查它是否从模型的工具列表里消失（工具搜索已关闭）。
  if (process.env.KITE_SPIKE_DEFER === '1') on('tool.describe', async ($: any, e: any, next: any) =>
    e.tool === 'mcp__kite__read' ? { ...(await next(e)), isDeferred: true } : next(e));
  on('session.compact', async ($: any, e: any, next: any) => {
    const messages = e.messages as any[];
    const second = messages.findIndex((message) => message.role === 'user' && message.text.includes('第二个问题'));
    const third = messages.findIndex((message) => message.role === 'user' && message.text.includes('请读文件'));
    let percent: unknown;
    try { percent = (await $.session.usage()).context?.percent; } catch (error) { percent = `usage 失败：${error}`; }
    let fork: any;
    // 触发方式与条数写进分叉的提示，hook 的结果被引擎丢弃时也能从请求里读到。
    try { fork = await $.model.fork({ prompt: `请把「第二个问题」那一轮写成摘要，只输出摘要正文。（trigger=${e.trigger} messages=${messages.length} range=${second}..${third}）` }); }
    catch (error) { fork = { isAnswered: false, reason: `抛错：${error}` }; }
    // 经引擎已连接的 MCP 服务调用工具，验证 mod 与宿主之间的通道。
    let channel: string;
    try { channel = JSON.stringify((await $.mcp.call('kite', 'read', { path: 'a.txt' })).content); }
    catch (error) { channel = `失败：${error instanceof Error ? error.message : String(error)}`; }
    const diagnosis = `channel=${channel} trigger=${e.trigger} messages=${messages.length} handles=${messages.filter((message) => message.handle).length}`
      + ` range=${second}..${third} percent=${percent} fork=${fork.isAnswered ? 'ok' : fork.reason}`;
    if (second < 0 || third < 0) return next({ ...e, instructions: `【诊断】${diagnosis}` });
    const summary = `以下是先前一段对话的摘要：${fork.isAnswered ? fork.text : '（分叉失败）'}【诊断】${diagnosis}`;
    const built = { role: 'user', text: summary, toolUses: [] };
    // KITE_SPIKE_SHAPE=suffix：只保留第三轮（摘要接最近消息）；默认保留首尾两轮、中间换成摘要。
    if (process.env.KITE_SPIKE_SHAPE === 'suffix') return { messages: [built, ...messages.slice(third)] };
    return { messages: [...messages.slice(0, second), built, ...messages.slice(third)] };
  });
}
