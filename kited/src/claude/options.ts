/** 会话与能力查询共用同一份精简 Claude 配置。 */
import type { Options } from '@anthropic-ai/claude-agent-sdk';
import { join } from 'node:path';

export function claudeOptions(cwd: string): Options {
  return {
    cwd,
    env: { ...process.env,
      // 不让宿主进程携带的插件、IDE 或自动恢复开关绕过本会话的配置。
      CLAUDE_CODE_PLUGIN_DIRS: undefined,
      CLAUDE_CODE_PLUGIN_SEED_DIR: undefined,
      FORCE_AUTOUPDATE_PLUGINS: '0',
      CLAUDE_CODE_AUTO_CONNECT_IDE: 'false',
      CLAUDE_CODE_RESUME_INTERRUPTED_TURN: '0',
      CLAUDE_AGENT_SDK_DISABLE_BUILTIN_AGENTS: '1',
      // CLI 2.1.280 的附件总开关，也覆盖工具调用之间的提醒。
      // verbatimPrompts 只覆盖回合开头；日期、环境等另由提示过滤插件处理。
      CLAUDE_CODE_DISABLE_ATTACHMENTS: '1',
      // 2.1.280 的官方 mods 早期入口；升级时须重新抓取真实 CLI 请求核对。
      CLAUDE_CODE_ENABLE_FUNCTION_HOOKS: '1',
      CLAUDE_CODE_TOTAL_TOKENS_REMINDER: 'off',
      CLAUDE_CODE_ENABLE_TOKEN_USAGE_ATTACHMENT: '0',
      CLAUDE_CODE_DISABLE_AUTO_MEMORY: '1',
      CLAUDE_CODE_DISABLE_BACKGROUND_TASKS: '1',
      CLAUDE_CODE_DISABLE_CRON: '1',
      CLAUDE_CODE_DISABLE_FILE_CHECKPOINTING: '1',
      CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC: '1',
      CLAUDE_CODE_ENABLE_TELEMETRY: '0',
      CLAUDE_CODE_DISABLE_FEEDBACK_SURVEY: '1',
      CLAUDE_CODE_ENABLE_FEEDBACK_SURVEY_FOR_OTEL: '0',
      // 也关闭 SDK 首条消息的自动命名请求；会话标题统一由 Kite 生成。
      CLAUDE_CODE_DISABLE_TERMINAL_TITLE: '1',
      CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION: 'false',
      ENABLE_TOOL_SEARCH: 'false',
      DISABLE_COMPACT: '1',
    },
    // 内置工具与 skills 保持关闭；MCP 只接受宿主显式注入的能力。
    tools: [],
    includePartialMessages: true,
    skills: [],
    strictMcpConfig: true,
    plugins: [{ type: 'local', path: join(import.meta.dir, 'context-filter'), skipMcpDiscovery: true }],
    pluginDelivery: 'initialize',
    // 恢复时也重建提示，避免沿用旧会话保存的 claude_code 预设。
    systemPrompt: { type: 'custom', snapshot: false,
      prompt: '你是 Kite 中的助手。根据用户请求工作，只使用宿主提供的工具。工具不可用时说明限制，不虚构执行结果。' },
    verbatimPrompts: true,
    extraArgs: { 'disable-slash-commands': null, 'no-chrome': null, 'replay-user-messages': null },
    settingSources: [],
    promptSuggestions: false,
    agentProgressSummaries: false,
    enableFileCheckpointing: false,
    settings: {
      // 配置来源为空，只显式载入 Kite 的插件和下面的 SDK 回调；disableAllHooks 会连过滤插件一起关闭。
      disableBundledSkills: true,
      // 2.1.280 的内置插件名；启用 mods 会默认带入 plugin-authoring。
      enabledPlugins: {
        'agents-md@builtin': false,
        'plugin-authoring@builtin': false,
        'telemetry@builtin': false,
      },
      autoMemoryEnabled: false,
      autoDreamEnabled: false,
      autoCompactEnabled: false,
      precomputeCompactionEnabled: false,
      includeGitInstructions: false,
      attribution: { commit: '', pr: '' },
      disableWorkflows: true,
      workflowKeywordTriggerEnabled: false,
      // 工作区、会话和通知统一由 Kite 管理。
      disableRemoteControl: true,
      remoteControlAtStartup: false,
      autoUploadSessions: false,
      crossSessionInbound: 'refuse',
      channelsEnabled: false,
      inputNeededNotifEnabled: false,
      agentPushNotifEnabled: false,
      autoContinueAtUsageLimit: false,
      // 会话由 Kite 管，不用 Claude Code 自己的后台会话（claude agents、--bg）
      disableAgentView: true,
      // 从 claude.ai 同步来的 skill、插件和连接器（Gmail、日历等）。经 settings 传入只对这个会话生效，不动本机的文件
      syncClaudeAiSkills: false,
      syncClaudeAiPlugins: false,
      disableClaudeAiConnectors: true,
    },
    permissionMode: 'bypassPermissions',
    allowDangerouslySkipPermissions: true,
  };
}
