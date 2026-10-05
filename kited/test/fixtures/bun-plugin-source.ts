/** 由 Bun.build 预打包后通过 HTTP 安装；运行时不需要读取测试仓库。 */
export const bunPluginSource = String.raw`
import { McpServer } from '@modelcontextprotocol/server';
import { StdioServerTransport } from '@modelcontextprotocol/server/stdio';
import { z } from 'zod';
import { readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { createConnection } from 'node:net';

const server = new McpServer({ name: 'kite-test-plugin', version: '1.0.0' }, { capabilities: { tools: {} } });
const stateSchema = z.object({ revision: z.string(), value: z.record(z.string(), z.unknown()) });
const operationSchema = z.object({ value: z.unknown() });
const stateGet = () => server.server.request({ method: 'kite/state.get', params: {} }, stateSchema);
const stateReplace = (expectedRevision, value) => server.server.request({
  method: 'kite/state.replace', params: { expectedRevision, value },
}, stateSchema);
const result = (value) => ({ content: [{ type: 'text', text: JSON.stringify(value) }], structuredContent: value });

// 这些资源经过真实 SDK 的 resources/read 传输，用于核对 HTTP 视图契约。
for (const name of ['state', 'unlisted', 'non-html', 'missing', 'multiple', 'wrong-uri', 'network', 'permissions', 'oversized']) {
  const resourceUri = 'ui://test/' + name + '.html';
  server.registerResource(name, resourceUri, { mimeType: 'text/html;profile=mcp-app' }, async () => {
    if (name === 'missing') return { contents: [] };
    const before = await stateGet();
    const content = {
      uri: name === 'wrong-uri' ? 'ui://test/another.html' : resourceUri,
      mimeType: name === 'non-html' ? 'text/plain' : 'text/html;profile=mcp-app',
      text: name === 'oversized' ? '界'.repeat(700_000) : '<main>计数：' + Number(before.value.count ?? 0) + '</main>',
    };
    if (name === 'network') content._meta = { ui: { csp: { connectDomains: ['https://example.com'] } } };
    if (name === 'permissions') content._meta = { ui: { permissions: { camera: {} } } };
    return { contents: name === 'multiple' ? [content, content] : [content] };
  });
}

server.registerTool('state', { inputSchema: z.object({
  action: z.enum(['read', 'increment', 'stale']), expectedRevision: z.string().optional(),
}) }, async ({ action, expectedRevision }) => {
  const before = await stateGet();
  if (action === 'read') return result({ revision: before.revision, value: before.value, pid: process.pid });
  if (action === 'stale') {
    try {
      await stateReplace(expectedRevision, { count: 999 });
      return result({ staleRejected: false });
    } catch {
      return result({ staleRejected: true });
    }
  }
  const after = await stateReplace(before.revision, {
    ...before.value, count: Number(before.value.count ?? 0) + 1,
  });
  return result({ revision: after.revision, value: after.value, pid: process.pid });
});

server.registerTool('app-only', {
  inputSchema: z.object({ value: z.string() }),
  _meta: { ui: { visibility: ['app'] } },
}, async ({ value }) => result({ value }));

server.registerTool('read-file', { inputSchema: z.object({
  targetId: z.string(), path: z.string(), forge: z.boolean().optional(),
}) }, async ({ targetId, path, forge }) => {
  const params = { name: 'files.read', arguments: { instanceId: targetId, path } };
  if (forge) {
    params.caller = { kind: 'system' };
    params.workspaceId = 'forged-workspace';
  }
  try {
    const response = await server.server.request({ method: 'kite/operation', params }, operationSchema);
    return result({ allowed: true, value: response.value });
  } catch (error) {
    return result({ allowed: false, error: String(error) });
  }
});

const canRead = (path) => { try { readFileSync(path); return true; } catch { return false; } };
function canConnect(port) {
  return new Promise((resolve) => {
    const socket = createConnection({ host: '127.0.0.1', port });
    socket.once('connect', () => { socket.destroy(); resolve('connected'); });
    socket.once('error', (error) => resolve(error.code ?? 'error'));
    socket.setTimeout(100, () => { socket.destroy(); resolve('timeout'); });
  });
}
server.registerTool('probe', { inputSchema: z.object({
  workspaceFile: z.string(), externalFile: z.string(), hostFile: z.string(), port: z.number(),
}) }, async ({ workspaceFile, externalFile, hostFile, port }) => {
  const temporary = join(process.env.TMPDIR, 'plugin-probe-' + process.pid);
  let tempWrite = false;
  try { writeFileSync(temporary, 'writable'); tempWrite = true; } catch {}
  const child = Bun.spawnSync([process.execPath, '-e',
    'const f=require("node:fs");try{f.readFileSync(process.argv[1]);console.log("read")}catch{console.log("denied")}',
    externalFile], { cwd: process.cwd(), env: process.env, stdout: 'pipe', stderr: 'pipe' });
  return result({ pid: process.pid, tmpdir: process.env.TMPDIR,
    workspaceRead: canRead(workspaceFile), externalRead: canRead(externalFile),
    hostRead: canRead(hostFile), hostSecret: process.env.KITE_TEST_HOST_SECRET ?? null,
    tempWrite, childExit: child.exitCode, childRead: child.stdout.toString().trim(),
    tcp: await canConnect(port),
  });
});

server.registerTool('block', { inputSchema: z.object({ marker: z.string() }) }, async ({ marker }) => {
  const child = Bun.spawn([process.execPath, '-e', 'setInterval(() => {}, 1000)'], {
    env: process.env, stdout: 'ignore', stderr: 'ignore',
  });
  writeFileSync(marker, JSON.stringify({ parent: process.pid, child: child.pid }));
  return new Promise(() => {});
});

await server.connect(new StdioServerTransport());
`;
