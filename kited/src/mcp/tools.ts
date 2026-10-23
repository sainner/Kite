/**
 * 外部 MCP 服务的工具交给两个后端：和插件工具一样不进声明，自研 harness 按服务名经 tool_search 加载，Claude 经 ToolSearch 搜到。
 * 包装在连上或目录变化时一次做好，每次请求只按生效的服务取；撤权在请求和调用前由运行时核验。
 */
import { createHash } from 'node:crypto';
import { ProtocolError, type CallToolResult, type Tool as McpTool } from '@modelcontextprotocol/client';
import { z } from 'zod';
import { KiteError } from '../errors.ts';
import { toolImageTypes, type JsonObject, type Tool, type ToolImage, type ToolResult } from '../harness/types.ts';
import type { PluginInstance } from '../model.ts';
import { toolVisible } from '../plugins/tools.ts';
import type { McpServers } from './servers.ts';

/** 实例打开的服务：角色给默认值，之后在实例上开关。 */
export const instanceMcp = (instance: Pick<PluginInstance, 'config'>): string[] => z.array(z.string()).catch([]).parse(instance.config.mcp ?? []);

export const MCP_TOOL_PREFIX = 'mcp__';
/** 上游惯用的 mcp__服务__工具；超过 64 个字符时截短并带摘要，免得撞名。 */
export function mcpToolName(server: string, tool: string): string {
  const name = `${MCP_TOOL_PREFIX}${server}__${tool.replace(/[^a-zA-Z0-9_-]/g, '_')}`;
  if (name.length <= 64) return name;
  return `${name.slice(0, 55)}_${createHash('sha256').update(`${server}\0${tool}`).digest('hex').slice(0, 8)}`;
}

const MAX_OUTPUT = 100_000;

function mcpToolResult(result: CallToolResult): ToolResult {
  const texts: string[] = [];
  const images: ToolImage[] = [];
  for (const block of result.content ?? []) {
    if (block.type === 'text') texts.push(block.text);
    else if (block.type === 'image' && toolImageTypes.includes(block.mimeType as ToolImage['mediaType'])) {
      images.push({ mediaType: block.mimeType as ToolImage['mediaType'], data: block.data });
    } else if (block.type === 'resource_link') texts.push(`[资源] ${block.uri}`);
    else if (block.type === 'resource') texts.push('text' in block.resource ? block.resource.text : `[二进制资源] ${block.resource.uri}`);
    else texts.push(`[${block.type === 'image' ? block.mimeType : block.type} 内容没有转交给模型]`);
  }
  if (!texts.length && result.structuredContent !== undefined) texts.push(JSON.stringify(result.structuredContent));
  let output = texts.join('\n');
  if (output.length > MAX_OUTPUT) output = `${output.slice(0, MAX_OUTPUT)}\n…（结果超过 ${MAX_OUTPUT} 字，后面截掉了）`;
  return { status: result.isError ? 'error' : 'success', output, ...(images.length ? { images } : {}) };
}

/** 一个服务的目录包成 Kite 工具：只给模型能用的（MCP Apps 只开放给界面的不给，必须走 task 的暂不支持），同名的只留第一个。 */
export function kiteTools(registry: McpServers, server: string, listed: McpTool[]): Tool[] {
  const seen = new Set<string>();
  return listed.flatMap((tool): Tool[] => {
    const name = mcpToolName(server, tool.name);
    if (seen.has(name) || !toolVisible(tool, 'model') || tool.execution?.taskSupport === 'required') return [];
    seen.add(name);
    return [{
      name, description: `（MCP 服务 ${server}）${tool.description ?? tool.title ?? tool.name}`, parameters: tool.inputSchema as JsonObject,
      deferred: { group: server },
      validate(value) { if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error('参数须为对象'); },
      async execute(value, context) {
        try {
          return mcpToolResult(await registry.call(server, tool, value as Record<string, unknown>, context.signal));
        } catch (error) {
          const message = error instanceof Error ? error.message : String(error);
          // 连不上就没发出去；服务回了 JSON-RPC 错误就是没做成；发出去以后断开、超时或停止，服务那边做没做不知道。
          if (error instanceof KiteError) return { status: 'not_executed', output: message };
          if (error instanceof ProtocolError) return { status: 'error', output: message };
          return { status: 'unknown', output: `MCP 服务 ${server} 的调用结果不明：${message}` };
        }
      },
    }];
  });
}
