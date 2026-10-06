/** Claude 的 MCP 只做传输适配，执行、授权和结果仍由 Kite 共用工具负责。 */
import { createSdkMcpServer, tool } from '@anthropic-ai/claude-agent-sdk';
import { z } from 'zod';
import type { Json, Tool, ToolResult } from '../harness/types.ts';

export const CLAUDE_READ_TOOL = 'mcp__kite__read';
export const CLAUDE_PATCH_TOOL = 'mcp__kite__patch';
export const claudeToolName = (name: string): string => name.startsWith('mcp__kite__') ? name.slice('mcp__kite__'.length) : name;

export function claudeToolServer(options: {
  tools: Tool[];
  context(callId: string): Parameters<Tool['execute']>[1];
  allowed(name: string): boolean;
  finished(callId: string, result: ToolResult): void;
}) {
  return createSdkMcpServer({ name: 'kite', alwaysLoad: true, tools: options.tools.map((entry) => {
    const schema = z.fromJSONSchema(entry.parameters);
    if (!(schema instanceof z.ZodObject)) throw new Error(`工具 ${entry.name} 的参数须为对象`);
    return tool(entry.name, entry.description, schema.shape, async (args, extra) => {
      let callId: string | undefined;
      let result: ToolResult;
      try {
        // 锁定的 Claude CLI 在 MCP 元数据里携带真实调用 ID，不接受模型自行填写身份。
        callId = (extra as { _meta?: Record<string, unknown> })._meta?.['claudecode/toolUseId'] as string | undefined;
        if (!callId || typeof callId !== 'string') throw new Error('Claude 工具调用缺少宿主身份');
        if (!options.allowed(entry.name)) throw new Error('当前实例未获准使用这个工具');
        const input = JSON.parse(JSON.stringify(args)) as Json;
        entry.validate(input);
        const context = options.context(callId);
        context.signal.throwIfAborted();
        result = await entry.execute(input, context);
      } catch (error) {
        result = { status: 'error', output: error instanceof Error ? error.message : String(error) };
      }
      if (callId) options.finished(callId, result);
      const structured = entry.name !== 'read';
      // 上游 isError 分支只转发 content；两种分支都保留结构化执行结果。
      return { content: [{ type: 'text' as const, text: structured ? JSON.stringify(result) : result.output }],
        ...(structured ? { structuredContent: { ...result } } : {}), ...(result.status === 'success' ? {} : { isError: true }) };
    }, { annotations: { readOnlyHint: entry.parallel === true, destructiveHint: entry.parallel !== true, openWorldHint: true } });
  }) });
}
