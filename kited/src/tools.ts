/**
 * Kite 给会话的工具。SDK 加自定义工具只有进程内 MCP 服务器这一条路：工具代码就在 kited 里运行，不起进程、不走网络。
 * 启动 Claude Code 时带上 TOOLS_ENV，这类工具用裸名，模型看到的是 check 而不是 mcp__kite__check；
 * 这个变量上游没写进文档，Pigeon 从 2.1.226 用起，2.1.280 实测仍有效。再加 alwaysLoad，和内置工具一样常驻，不经 ToolSearch。
 */
import { createSdkMcpServer, type McpSdkServerConfigWithInstance } from '@anthropic-ai/claude-agent-sdk';
import { checkTool, hasCheck, type CheckResult } from './check.ts';

export const TOOLS_ENV = { CLAUDE_AGENT_SDK_MCP_NO_PREFIX: '1' };

export interface ToolContext {
  /** 主文件夹。 */
  main: string;
  worktree: string;
  /** 这个会话的检查日志放在哪，每次检查在它下面建一个目录。 */
  checkLogs: string;
  onCheck(r: CheckResult): void;
}

/** 这个会话该有的工具，一个都没有时返回 undefined。每次启动 Claude Code 进程时新建。 */
export function kiteTools(c: ToolContext): McpSdkServerConfigWithInstance | undefined {
  if (!hasCheck(c.worktree)) return undefined;
  return createSdkMcpServer({ name: 'kite', alwaysLoad: true, tools: [checkTool(c)] });
}
