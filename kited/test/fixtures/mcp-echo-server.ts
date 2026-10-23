/**
 * 外部 MCP 服务的测试夹具：用真实的 @modelcontextprotocol/server 跑 stdio 服务，`bun run 本文件 modern|legacy`。
 * modern 用 serveStdio(工厂)，由 SDK 按开场决定协议版本（新版无状态协议，旧版客户端退回 initialize 握手）；
 * legacy 是手接的 McpServer + StdioServerTransport，只会旧版握手。两种的工具一样：
 * echo 回显文字，fail 返回 isError，grow 在连上之后再注册一个 late 工具（服务随即发 tools list_changed）。
 * 测试只 import 路径，import.meta.main 时才起服务。
 */
import { McpServer } from '@modelcontextprotocol/server';
import { serveStdio, StdioServerTransport } from '@modelcontextprotocol/server/stdio';
import { z } from 'zod';

export const mcpEchoServer = import.meta.path;

/** echo 的回复：测试按它核对工具结果里是服务返回的文字。 */
export const echoReply = (text: string) => `服务回显：${text}`;
export const failReply = '服务报告失败';

function create(): McpServer {
  const server = new McpServer({ name: 'kite-test-echo', version: '1.0.0' }, { capabilities: { tools: { listChanged: true } } });
  server.registerTool('echo', { description: '回显文字', inputSchema: z.object({ text: z.string() }) },
    async ({ text }) => ({ content: [{ type: 'text', text: echoReply(text) }] }));
  server.registerTool('fail', { description: '总是失败' },
    async () => ({ content: [{ type: 'text', text: failReply }], isError: true }));
  let grown = false;
  server.registerTool('grow', { description: '再注册一个 late 工具' }, async () => {
    if (!grown) {
      grown = true;
      server.registerTool('late', { description: '连上之后才有的工具' }, async () => ({ content: [{ type: 'text', text: '迟到的工具' }] }));
    }
    return { content: [{ type: 'text', text: '已注册 late' }] };
  });
  return server;
}

if (import.meta.main) {
  if (process.argv[2] === 'legacy') await create().connect(new StdioServerTransport());
  else serveStdio(() => create());
}
