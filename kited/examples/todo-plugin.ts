/** 预构建 Bun 插件样例：持久状态交给宿主，进程重启后从同一实例继续。 */
import { McpServer } from '@modelcontextprotocol/server';
import { StdioServerTransport } from '@modelcontextprotocol/server/stdio';
import { z } from 'zod';

const server = new McpServer({ name: 'Kite 待办样例', version: '1.0.0' });
const task = z.object({ id: z.string(), title: z.string(), completed: z.boolean() });
const stateSchema = z.object({ revision: z.string(), value: z.object({ tasks: z.array(task).optional() }) });
const state = () => server.server.request({ method: 'kite/state.get', params: {} }, stateSchema);
const result = (value: z.infer<typeof stateSchema>) => ({ content: [{ type: 'text' as const, text: JSON.stringify(value.value) }], structuredContent: value });
const replace = (expectedRevision: string, tasks: z.infer<typeof task>[]) =>
  server.server.request({ method: 'kite/state.replace', params: { expectedRevision, value: { tasks } } }, stateSchema);

server.registerTool('todo_list', { description: '查询当前实例的待办', inputSchema: z.object({}).strict() }, async () => result(await state()));
server.registerTool('todo_add', { description: '添加待办', inputSchema: z.object({ title: z.string().trim().min(1).max(200) }).strict() }, async ({ title }) => {
  const current = await state();
  return result(await replace(current.revision, [...current.value.tasks ?? [], { id: crypto.randomUUID(), title, completed: false }]));
});
server.registerTool('todo_complete', { description: '完成一项待办', inputSchema: z.object({ id: z.string() }).strict() }, async ({ id }) => {
  const current = await state();
  const tasks = current.value.tasks ?? [];
  if (!tasks.some((task) => task.id === id)) throw new Error('没有这项待办');
  return result(await replace(current.revision, tasks.map((task) => task.id === id ? { ...task, completed: true } : task)));
});

await server.connect(new StdioServerTransport());
