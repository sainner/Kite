/** 短验证宿主：MCP 与持久状态桥均只绑定这一实例，不接受网页提供的身份。 */
import { Client } from '@modelcontextprotocol/client';
import { StdioClientTransport } from '@modelcontextprotocol/client/stdio';
import { z } from 'zod';
import { mkdirSync, readFileSync, existsSync, writeFileSync, renameSync } from 'node:fs';
import { join } from 'node:path';
import { pluginLaunch } from './runtime.ts';
import { replaceSchema, stateSchema } from './state.ts';
import { startDaemon } from '../../kited/src/daemon.ts';

const callSchema = z.object({ kind: z.literal('call'), name: z.string(), arguments: z.record(z.string(), z.unknown()).default({}) }).strict();
const messageSchema = z.union([callSchema, z.object({ kind: z.literal('resource') }).strict()]);

export async function startGateway(root: string) {
  const cwd = join(root, 'runtime');
  const project = join(root, 'project');
  mkdirSync(cwd, { recursive: true });
  mkdirSync(project, { recursive: true });
  writeFileSync(join(project, 'sample.txt'), '工作区授权读取成功\n');
  const daemon = startDaemon({ home: join(root, 'kite'), port: 0 });
  const model = await daemon.kite.registerCheckout(project);
  // 仅验证既有授权入口，来源与目标使用现有文件实例；自定义定义登记不在本实验实现。
  const create = () => daemon.kite.openWindow(model.workspace.id, { id: crypto.randomUUID(), content: { kind: 'create', definitionId: 'kite.files' } });
  const source = await create();
  const target = await create();
  const grants = daemon.kite.operations.grants(source.target.instanceId);
  await daemon.kite.configureOperationGrants(source.target.instanceId, grants.revision, [
    { operation: 'files.read', targets: { kind: 'instances', instanceIds: [target.target.instanceId] } },
  ]);
  const statePath = join(root, 'state.json');
  const readState = () => existsSync(statePath) ? stateSchema.parse(JSON.parse(readFileSync(statePath, 'utf8'))) : { revision: 0, tasks: [] };
  let client: Client;
  let transport: StdioClientTransport;
  let tools: Awaited<ReturnType<Client['listTools']>>['tools'];
  async function connect() {
    client = new Client({ name: 'Kite 验证宿主', version: '0.1.0' });
    client.setRequestHandler('kite/state.get', { params: z.object({}).strict(), result: stateSchema }, async () => readState());
    client.setRequestHandler('kite/state.replace', { params: replaceSchema, result: stateSchema }, async (params) => {
      const previous = readState();
      if (previous.revision !== params.expectedRevision) throw new Error('状态版本已变化');
      const next = { revision: previous.revision + 1, tasks: params.tasks };
      writeFileSync(statePath + '.tmp', JSON.stringify(next));
      renameSync(statePath + '.tmp', statePath);
      return next;
    });
    client.setRequestHandler('kite/workspace.read', { params: z.object({ path: z.string() }).strict(), result: z.object({ text: z.string() }).strict() }, async ({ path }) => {
      const result = await daemon.kite.operations.invoke({ kind: 'plugin', instanceId: source.target.instanceId }, model.workspace.id,
        'files.read', { instanceId: target.target.instanceId, path }) as { text: string };
      return { text: result.text };
    });
    transport = new StdioClientTransport({ ...pluginLaunch(join(import.meta.dir, 'dist/todo-server.js'), cwd), stderr: 'pipe', maxBufferSize: 2 * 1024 * 1024 });
    transport.stderr?.on('data', (data) => process.stderr.write(data));
    await client.connect(transport);
    tools = (await client.listTools()).tools;
  }
  await connect();
  const token = crypto.randomUUID();
  const server = Bun.serve({ hostname: '127.0.0.1', port: 0, async fetch(req) {
    const url = new URL(req.url);
    if (req.method === 'GET' && url.pathname === '/host') return new Response(Bun.file(join(import.meta.dir, 'dist/host.html')), { headers: { 'content-type': 'text/html; charset=utf-8' } });
    if (req.headers.get('authorization') !== `Bearer ${token}`) return Response.json({ error: '未授权' }, { status: 403 });
    try {
      if (req.method === 'POST' && url.pathname === '/restart') {
        await client.close();
        await connect();
        return Response.json({ ok: true });
      }
      if (req.method !== 'POST' || url.pathname !== '/bridge') return new Response('没有此入口', { status: 404 });
      const message = messageSchema.parse(await req.json());
      if (message.kind === 'resource') {
        const resource = await client.readResource({ uri: 'ui://kite-todo/view.html' });
        const content = resource.contents[0];
        if (!content || !('text' in content)) throw new Error('插件没有返回 HTML');
        return Response.json({ html: content.text });
      }
      const tool = tools.find((tool) => tool.name === message.name);
      const visibility = (tool?._meta?.ui as { visibility?: string[] } | undefined)?.visibility;
      if (!tool || (visibility && !visibility.includes('app'))) throw new Error('未授权的插件操作');
      return Response.json(await client.callTool({ name: message.name, arguments: message.arguments }));
    } catch (error) { return Response.json({ error: error instanceof Error ? error.message : String(error) }, { status: 400 }); }
  } });
  return {
    url: `http://127.0.0.1:${server.port}`, token,
    async close() { await server.stop(true); await client.close(); await daemon.stop(); },
  };
}
