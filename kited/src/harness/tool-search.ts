/**
 * 插件与外部 MCP 服务的工具按需加载，规则见 docs/Bun插件.md「按需加载」：声明里固定一个由客户端执行的 tool_search，这些工具不进声明；
 * 模型按分组（插件实例 ID 或 MCP 服务名）搜索时，结果带上这一组已授权工具的定义，适配器把它作为 tool_search_output 追加进历史。
 * 两家 Responses 接口的实测见 spikes/tool-search/README.md。
 */
import { z } from 'zod';
import type { ContextItem, Tool, ToolDefinition } from './types.ts';

export const TOOL_SEARCH = 'tool_search';

const input = z.object({ groups: z.array(z.string().min(1)).min(1).max(20) }).strict();

/** 加载结果的说明；Claude 的 ToolSearch 结果显示时也用它，两个后端写法一致。 */
export const loadedText = (names: string[]) => `已加载 ${names.length} 个工具：${names.join('、')}`;

/** 每次请求按当前授权新建，tools 是此刻获准、按需加载的工具；说明与参数固定，和首次请求登记的声明一致。 */
export function searchTool(tools: Tool[]): Tool {
  return {
    name: TOOL_SEARCH,
    description: '加载按需加载的工具：groups 填插件实例 ID 或 MCP 服务名。加载后这些工具直接按名字调用，不用再加载。',
    parameters: z.toJSONSchema(input) as Tool['parameters'],
    validate(value) { input.parse(value); },
    async execute(value) {
      const ids = [...new Set(input.parse(value).groups)];
      const found = tools.filter((tool) => ids.includes(tool.deferred!.group)).map(({ name, description, parameters }) => ({ name, description, parameters }));
      const missing = ids.filter((id) => !tools.some((tool) => tool.deferred!.group === id));
      const note = missing.length ? `；没有 ${missing.join('、')} 这一组已授权的工具` : '';
      if (!found.length) return { status: 'error', output: `没有加载到工具${note}`, tools: [] };
      return { status: 'success', output: `${loadedText(found.map((tool) => tool.name))}${note}`, tools: found };
    },
  };
}

/** 当前上下文里经 tool_search 加载过的定义，同名取最近一次；被压缩掉的那段里加载的不算。 */
export function loadedDefinitions(history: readonly ContextItem[]): Map<string, ToolDefinition> {
  const loaded = new Map<string, ToolDefinition>();
  for (const item of history) {
    if (item.type === 'tool_result') for (const tool of item.result.tools ?? []) loaded.set(tool.name, tool);
  }
  return loaded;
}

export const sameDefinition = (a: ToolDefinition, b: ToolDefinition) =>
  a.description === b.description && JSON.stringify(a.parameters) === JSON.stringify(b.parameters);
