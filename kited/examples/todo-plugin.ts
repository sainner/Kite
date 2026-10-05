/** 预构建 Bun 插件样例：持久状态交给宿主，进程重启后从同一实例继续。 */
import { McpServer } from '@modelcontextprotocol/server';
import { StdioServerTransport } from '@modelcontextprotocol/server/stdio';
import { registerAppResource, RESOURCE_MIME_TYPE } from '@modelcontextprotocol/ext-apps/server';
import { z } from 'zod';

declare const KITE_TODO_HTML: string;
const resourceUri = 'ui://kite-todo/list.html';
const _meta = { ui: { resourceUri, visibility: ['app', 'model'] } };

const server = new McpServer({ name: 'Kite 待办样例', version: '1.0.0' });
const task = z.object({ id: z.string(), title: z.string(), completed: z.boolean() });
const stateSchema = z.object({ revision: z.string(), value: z.object({ tasks: z.array(task).optional() }) });
const state = () => server.server.request({ method: 'kite/state.get', params: {} }, stateSchema);
const result = (value: z.infer<typeof stateSchema>) => ({ content: [{ type: 'text' as const, text: JSON.stringify(value.value) }], structuredContent: value });
const replace = (expectedRevision: string, tasks: z.infer<typeof task>[]) =>
  server.server.request({ method: 'kite/state.replace', params: { expectedRevision, value: { tasks } } }, stateSchema);

registerAppResource(server, '待办列表', resourceUri, { mimeType: RESOURCE_MIME_TYPE }, async () => ({
  contents: [{ uri: resourceUri, mimeType: RESOURCE_MIME_TYPE, text: KITE_TODO_HTML,
    _meta: { ui: { csp: { connectDomains: [], resourceDomains: [] } } } }],
}));

server.registerTool('todo_list', { description: '查询当前实例的待办', inputSchema: z.object({}).strict(), _meta }, async () => result(await state()));
server.registerTool('todo_add', { description: '添加待办', inputSchema: z.object({ title: z.string().trim().min(1).max(200) }).strict(), _meta }, async ({ title }) => {
  const current = await state();
  return result(await replace(current.revision, [...current.value.tasks ?? [], { id: crypto.randomUUID(), title, completed: false }]));
});
server.registerTool('todo_complete', { description: '完成一项待办', inputSchema: z.object({ id: z.string() }).strict(), _meta }, async ({ id }) => {
  const current = await state();
  const tasks = current.value.tasks ?? [];
  if (!tasks.some((task) => task.id === id)) throw new Error('没有这项待办');
  return result(await replace(current.revision, tasks.map((task) => task.id === id ? { ...task, completed: true } : task)));
});

await server.connect(new StdioServerTransport());
