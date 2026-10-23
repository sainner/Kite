/** Claude 的 MCP 只做传输适配，执行、授权和结果仍由 Kite 共用工具负责。 */
import { createSdkMcpServer, tool } from '@anthropic-ai/claude-agent-sdk';
import { z } from 'zod';
import { diffReferenceSchema } from '../workspace/file-diffs.ts';
import { loadedText } from '../harness/tool-search.ts';
import { skillMarkSchema } from '../harness/request-config.ts';
import type { Json, Tool, ToolImage, ToolResult } from '../harness/types.ts';

/** Claude Code 内置的按需加载工具，结果是加载到的工具引用。 */
export const CLAUDE_TOOL_SEARCH = 'ToolSearch';
/** 开放的 Claude Code 内置工具；其余都是 Kite 工具，用裸名。 */
export const CLAUDE_BUILTIN_TOOLS = [CLAUDE_TOOL_SEARCH];
/** read 只回正文；其余 Kite 工具连同状态与 diff 一起结构化返回。 */
export const structuredClaudeTool = (name: string): boolean => name !== 'read' && !CLAUDE_BUILTIN_TOOLS.includes(name);

/** 原生条目里的对象字段；不是对象时按空对象读。 */
export const object = (value: unknown): Record<string, any> => value && typeof value === 'object' ? value as Record<string, any> : {};
const imageTypes = new Set<string>(['image/png', 'image/jpeg', 'image/webp']);

const imageBlock = (image: ToolImage) => ({ type: 'image' as const, source: { type: 'base64' as const, media_type: image.mediaType, data: image.data } });

/** 输入交给 Claude 的内容：只有正文时是字符串，带附件里的图片时是正文块后面跟图片块。 */
export function claudeUserContent(text: string, images?: ToolImage[]) {
  return images?.length ? [{ type: 'text' as const, text }, ...images.map(imageBlock)] : text;
}

/** 原生用户内容里的图片块还原成 Kite 的图片；只认 Kite 发出去的那几种。 */
export function claudeImage(block: Record<string, any>, what: string): ToolImage {
  const source = object(block.source);
  if (source.type !== 'base64' || !imageTypes.has(source.media_type) || typeof source.data !== 'string') throw new Error(`不支持的 Claude ${what}图片`);
  return { mediaType: source.media_type, data: source.data };
}

/** 从原生 tool_result 还原 Kite 的执行结果；参数校验等上游错误不是结构化正文，保留原文。 */
export function claudeToolResult(block: Record<string, any>, structured: boolean): ToolResult {
  const parts = typeof block.content === 'string' ? [{ type: 'text', text: block.content }] : Array.isArray(block.content) ? block.content.map(object) : [];
  let output = parts.filter((part) => typeof part.text === 'string').map((part) => part.text as string).join('');
  // ToolSearch 的结果只有工具引用，没有正文。
  const loaded = parts.filter((part) => part.type === 'tool_reference' && typeof part.tool_name === 'string').map((part) => part.tool_name as string);
  if (loaded.length) output = loadedText(loaded);
  const images = parts.filter((part) => part.type === 'image').map((part) => claudeImage(part, '工具结果'));
  let status: ToolResult['status'] = block.is_error ? 'error' : 'success';
  let diff: ToolResult['diff'];
  let skill: ToolResult['skill'];
  if (structured) {
    try {
      const result = object(JSON.parse(output));
      if (typeof result.output === 'string') {
        output = result.output;
        diff = diffReferenceSchema.safeParse(result.diff).data;
        skill = skillMarkSchema.safeParse(result.skill).data;
        if (['success', 'error', 'not_executed', 'unknown'].includes(result.status)) status = result.status;
      }
    } catch { /* 参数校验失败时保留上游错误文本。 */ }
  }
  return { status, output, ...(diff ? { diff } : {}), ...(skill ? { skill } : {}), ...(images.length ? { images } : {}) };
}

/**
 * 与锁定 CLI 记录 MCP 结果的形状一致：带 structuredContent 时正文存为字符串，否则为内容块数组；
 * structuredContent 本身不发给模型。（2026-10-08 实测，见 spikes/handoff）
 */
export function claudeToolResultContent(name: string, result: ToolResult): { content: Json; is_error?: true } {
  const { images, ...rest } = result;
  const structured = structuredClaudeTool(name);
  const text = structured ? JSON.stringify(rest) : result.output;
  const content: Json = structured && !images?.length ? text : [{ type: 'text', text }, ...(images ?? []).map(imageBlock)];
  return { content, ...(result.status === 'success' ? {} : { is_error: true as const }) };
}

export function claudeToolServer(options: {
  tools: Tool[];
  context(callId: string): Parameters<Tool['execute']>[1];
  allowed(name: string): boolean;
  finished(callId: string, result: ToolResult): void;
}) {
  // 提问与审批等用户回应不设时限；上游对单次调用有硬时限，这里取它允许的最大值（约 24.8 天）。
  // 服务整体设常驻会盖过单个工具，所以逐个设：按需加载的以外都常驻。
  return { ...createSdkMcpServer({ name: 'kite', tools: options.tools.map((entry) => {
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
      const structured = structuredClaudeTool(entry.name);
      // 上游 isError 分支只转发 content；两种分支都保留结构化执行结果。
      const { images, ...rest } = result;
      return { content: [{ type: 'text' as const, text: structured ? JSON.stringify(rest) : result.output },
        ...(images ?? []).map((image) => ({ type: 'image' as const, data: image.data, mimeType: image.mediaType }))],
        ...(structured ? { structuredContent: { ...rest } } : {}), ...(result.status === 'success' ? {} : { isError: true }) };
    }, { annotations: { readOnlyHint: entry.parallel === true, destructiveHint: entry.parallel !== true, openWorldHint: true },
      alwaysLoad: !entry.deferred });
  }) }), timeout: 2_147_483_647 };
}
