/**
 * 插件工具按需加载，规则见 docs/Bun插件.md「按需加载」：声明里固定一个由客户端执行的 tool_search，插件工具不进声明；
 * 模型按实例搜索时，结果带上这个实例已授权工具的定义，适配器把它作为 tool_search_output 追加进历史。
 * 两家 Responses 接口的实测见 spikes/tool-search/README.md。
 */
import { z } from 'zod';
import type { ContextItem, Tool, ToolDefinition } from './types.ts';

export const TOOL_SEARCH = 'tool_search';

const input = z.object({ instances: z.array(z.string().min(1)).min(1).max(20) }).strict();

/** 可以加载的插件工具：所属实例与交给模型的定义。 */
export interface SearchableTool { instanceId: string; definition: ToolDefinition }

/** 加载结果的说明；Claude 的 ToolSearch 结果显示时也用它，两个后端写法一致。 */
export const loadedText = (names: string[]) => `已加载 ${names.length} 个工具：${names.join('、')}`;

/** 每次请求按当前授权新建；说明与参数固定，和首次请求登记的声明一致。 */
export function searchTool(searchable: SearchableTool[]): Tool {
  return {
    name: TOOL_SEARCH,
    description: '加载插件实例的工具。基础上下文里「插件工具」列出了可以加载的实例与工具名；按实例 ID 加载后，这些工具之后直接按名字调用，不用再加载。',
    parameters: z.toJSONSchema(input) as Tool['parameters'],
    validate(value) { input.parse(value); },
    async execute(value) {
      const ids = [...new Set(input.parse(value).instances)];
      const tools = searchable.filter((tool) => ids.includes(tool.instanceId)).map((tool) => tool.definition);
      const missing = ids.filter((id) => !searchable.some((tool) => tool.instanceId === id));
      const note = missing.length ? `；${missing.join('、')} 不是已授权的插件实例` : '';
      if (!tools.length) return { status: 'error', output: `没有加载到工具${note}`, tools: [] };
      return { status: 'success', output: `${loadedText(tools.map((tool) => tool.name))}${note}`, tools };
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
