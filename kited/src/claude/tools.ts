/** Claude 的 MCP 只做传输适配，执行、授权和结果仍由 Kite 共用工具负责。 */
import { createSdkMcpServer, tool } from '@anthropic-ai/claude-agent-sdk';
import { z } from 'zod';
import { diffReferenceSchema } from '../workspace/file-diffs.ts';
import type { Json, Tool, ToolImage, ToolResult } from '../harness/types.ts';

export const CLAUDE_READ_TOOL = 'mcp__kite__read';
export const CLAUDE_PATCH_TOOL = 'mcp__kite__patch';
export const claudeToolName = (name: string): string => name.startsWith('mcp__kite__') ? name.slice('mcp__kite__'.length) : name;
/** read 只回正文；其余 Kite 工具连同状态与 diff 一起结构化返回。 */
export const structuredClaudeTool = (name: string): boolean => name.startsWith('mcp__kite__') && name !== CLAUDE_READ_TOOL;

/** 原生条目里的对象字段；不是对象时按空对象读。 */
export const object = (value: unknown): Record<string, any> => value && typeof value === 'object' ? value as Record<string, any> : {};
const imageTypes = new Set<string>(['image/png', 'image/jpeg', 'image/webp']);

/** 从原生 tool_result 还原 Kite 的执行结果；参数校验等上游错误不是结构化正文，保留原文。 */
export function claudeToolResult(block: Record<string, any>, structured: boolean): ToolResult {
  const parts = typeof block.content === 'string' ? [{ type: 'text', text: block.content }] : Array.isArray(block.content) ? block.content.map(object) : [];
  let output = parts.filter((part) => typeof part.text === 'string').map((part) => part.text as string).join('');
  const images: ToolImage[] = parts.filter((part) => part.type === 'image').map((part) => {
    const source = object(part.source);
    if (source.type !== 'base64' || !imageTypes.has(source.media_type) || typeof source.data !== 'string') throw new Error('不支持的 Claude 工具结果图片');
    return { mediaType: source.media_type, data: source.data };
  });
  let status: ToolResult['status'] = block.is_error ? 'error' : 'success';
  let diff: ToolResult['diff'];
  if (structured) {
    try {
      const result = object(JSON.parse(output));
      if (typeof result.output === 'string') {
        output = result.output;
        diff = diffReferenceSchema.safeParse(result.diff).data;
        if (['success', 'error', 'not_executed', 'unknown'].includes(result.status)) status = result.status;
      }
    } catch { /* 参数校验失败时保留上游错误文本。 */ }
  }
  return { status, output, ...(diff ? { diff } : {}), ...(images.length ? { images } : {}) };
}

/**
 * 与锁定 CLI 记录 MCP 结果的形状一致：带 structuredContent 时正文存为字符串，否则为内容块数组；
 * structuredContent 本身不发给模型。（2026-10-08 实测，见 spikes/handoff）
 */
export function claudeToolResultContent(name: string, result: ToolResult): { content: Json; is_error?: true } {
  const { images, ...rest } = result;
  const structured = structuredClaudeTool(name);
  const text = structured ? JSON.stringify(rest) : result.output;
  const content: Json = structured && !images?.length ? text : [{ type: 'text', text },
    ...(images ?? []).map((image) => ({ type: 'image', source: { type: 'base64', media_type: image.mediaType, data: image.data } }))];
  return { content, ...(result.status === 'success' ? {} : { is_error: true as const }) };
}

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
      const structured = structuredClaudeTool(`mcp__kite__${entry.name}`);
      // 上游 isError 分支只转发 content；两种分支都保留结构化执行结果。
      const { images, ...rest } = result;
      return { content: [{ type: 'text' as const, text: structured ? JSON.stringify(rest) : result.output },
        ...(images ?? []).map((image) => ({ type: 'image' as const, data: image.data, mimeType: image.mediaType }))],
        ...(structured ? { structuredContent: { ...rest } } : {}), ...(result.status === 'success' ? {} : { isError: true }) };
    }, { annotations: { readOnlyHint: entry.parallel === true, destructiveHint: entry.parallel !== true, openWorldHint: true } });
  }) });
}
