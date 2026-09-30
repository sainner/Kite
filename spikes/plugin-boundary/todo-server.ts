import { McpServer } from '@modelcontextprotocol/server';
import { StdioServerTransport } from '@modelcontextprotocol/server/stdio';
import { registerAppResource, registerAppTool, RESOURCE_MIME_TYPE } from '@modelcontextprotocol/ext-apps/server';
import { z } from 'zod';
import { stateSchema } from './state.ts';
import html from './dist/view.html' with { type: 'text' };

const server = new McpServer({ name: 'Kite 待办验证', version: '0.1.0' });
const resourceUri = 'ui://kite-todo/view.html';
const state = () => server.server.request({ method: 'kite/state.get', params: {} }, stateSchema);
const result = (value: z.infer<typeof stateSchema>) => ({ content: [{ type: 'text' as const, text: JSON.stringify(value) }], structuredContent: value });

registerAppTool(server, 'todo_list', {
  description: '查询待办', inputSchema: z.object({}).strict(),
  _meta: { ui: { resourceUri, visibility: ['app', 'model'] } },
}, async () => result(await state()));

registerAppTool(server, 'todo_add', {
  description: '添加待办', inputSchema: z.object({ title: z.string().trim().min(1).max(200) }).strict(),
  _meta: { ui: { resourceUri, visibility: ['app', 'model'] } },
}, async ({ title }) => {
  const current = await state();
  return result(await server.server.request({ method: 'kite/state.replace', params: {
    expectedRevision: current.revision, tasks: [...current.tasks, { id: crypto.randomUUID(), title, done: false }],
  } }, stateSchema));
});

registerAppTool(server, 'todo_complete', {
  description: '完成待办', inputSchema: z.object({ id: z.string() }).strict(),
  _meta: { ui: { resourceUri, visibility: ['app', 'model'] } },
}, async ({ id }) => {
  const current = await state();
  return result(await server.server.request({ method: 'kite/state.replace', params: {
    expectedRevision: current.revision, tasks: current.tasks.map((task) => task.id === id ? { ...task, done: true } : task),
  } }, stateSchema));
});

registerAppTool(server, 'todo_read_workspace', {
  description: '经授权读取工作区样本', inputSchema: z.object({ path: z.string() }).strict(),
  _meta: { ui: { resourceUri, visibility: ['app'] } },
}, async (args) => {
  const value = await server.server.request({ method: 'kite/workspace.read', params: args }, z.object({ text: z.string() }).strict());
  return { content: [{ type: 'text' as const, text: value.text }] };
});

registerAppResource(server, '待办视图', resourceUri, { mimeType: RESOURCE_MIME_TYPE }, async () => ({
  contents: [{ uri: resourceUri, mimeType: RESOURCE_MIME_TYPE, text: html, _meta: { ui: { csp: { connectDomains: [], resourceDomains: [] } } } }],
}));

await server.connect(new StdioServerTransport());

