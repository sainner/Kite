# 会话记录普查

根目录：`~/.claude/projects`，36723 行记录，86.26 MB，解析失败 0 行。

## 主会话首条记录的 Claude Code 版本

2.1.222×1，2.1.226×2，2.1.229×2，2.1.246×22，2.1.258×53，2.1.266×1，2.1.280×7

## 记录种类

「范围」：main 是主会话，subagent 是 subagents/ 下的子 agent 记录，legacy-agent 是项目目录下的老格式子 agent 记录。块（block）的字节只算块本身。

| 范围 | 种类 | 条数 | 文件数 | MB | 版本范围 | 常见字段 |
|---|---|---|---|---|---|---|
| legacy-agent | assistant [isSidechain] | 102 | 3 | 0.24 | 2.1.280–2.1.280 | parentUuid, isSidechain, agentId, message, apiBlockIndex, requestId, attributionAgent, type, uuid, timestamp, advisorModel, effort, perTurnEffort, userType |
| legacy-agent | assistant.block:text | 7 | 3 | 0.01 | 2.1.280–2.1.280 | type, text |
| legacy-agent | assistant.block:thinking | 37 | 3 | 0.05 | 2.1.280–2.1.280 | type, thinking, signature |
| legacy-agent | assistant.block:tool_use | 58 | 3 | 0.03 | 2.1.280–2.1.280 | type, id, name, input, caller |
| legacy-agent | attachment:agent_listing_delta | 3 | 3 | 0.02 | 2.1.280–2.1.280 | type, addedTypes, addedLines, removedTypes, isInitial, showConcurrencyNote |
| legacy-agent | attachment:auto_mode | 3 | 3 | 0.00 | 2.1.280–2.1.280 | type, autoModeConsentFlow, bashFirst, bashFirstSteer, steerOnly, bypass |
| legacy-agent | attachment:date | 3 | 3 | 0.00 | 2.1.280–2.1.280 | type, date |
| legacy-agent | attachment:deferred_tools_delta | 6 | 3 | 0.03 | 2.1.280–2.1.280 | type, addedNames, addedLines, removedNames, wireHiddenNames, readdedNames, pendingMcpServers(3), needsAuthMcpServers(3), failedMcpServers(3) |
| legacy-agent | attachment:environment | 3 | 3 | 0.00 | 2.1.280–2.1.280 | type, snapshot |
| legacy-agent | attachment:instructions | 3 | 3 | 0.00 | 2.1.280–2.1.280 | type, files |
| legacy-agent | attachment:model | 3 | 3 | 0.00 | 2.1.280–2.1.280 | type, identity, text |
| legacy-agent | attachment:prompt_snapshot | 6 | 3 | 0.29 | 2.1.280–2.1.280 | type, systemPrompt, tools(3), cliPrefix(3) |
| legacy-agent | attachment:queued_command | 1 | 1 | 0.00 | 2.1.280–2.1.280 | type, prompt, source_uuid, commandMode, timestamp |
| legacy-agent | attachment:remote_session_change | 3 | 3 | 0.00 | 2.1.280–2.1.280 | type, url, commit, pr, sendUserFileHint, managedCommit, managedPr |
| legacy-agent | attachment:session_context | 3 | 3 | 0.01 | 2.1.280–2.1.280 | type, context |
| legacy-agent | attachment:skill_listing | 3 | 3 | 0.10 | 2.1.280–2.1.280 | type, content, skillCount, isInitial, names |
| legacy-agent | attachment:total_tokens_reminder | 57 | 3 | 0.03 | 2.1.280–2.1.280 | type, text |
| legacy-agent | user [isSidechain] | 61 | 3 | 0.24 | 2.1.280–2.1.280 | parentUuid, isSidechain, promptId, agentId, type, message, uuid, timestamp, userType, entrypoint, cwd, sessionId, version, gitBranch |
| legacy-agent | user.block:tool_result | 58 | 3 | 0.21 | 2.1.280–2.1.280 | tool_use_id, type, content, is_error |
| legacy-agent | user.content:string | 3 | 3 | 0.00 | 2.1.280–2.1.280 |  |
| legacy-agent | user.toolUseResult | 1 | 1 | 0.00 | 2.1.280–2.1.280 |  |
| main | agent-name | 149 | 7 | 0.01 | – | type, agentName, sessionId |
| main | ai-title | 25 | 3 | 0.00 | – | type, aiTitle, sessionId |
| main | assistant | 11373 | 86 | 33.77 | 2.1.222–2.1.280 | parentUuid, isSidechain, message, type, uuid, timestamp, userType, entrypoint, cwd, sessionId, version, gitBranch, requestId(11354), effort(11354) |
| main | assistant [isApiErrorMessage] | 5 | 3 | 0.01 | 2.1.246–2.1.258 | parentUuid, isSidechain, type, uuid, timestamp, message, requestId, quotaLimits, error, isApiErrorMessage, apiErrorStatus, userType, entrypoint, cwd |
| main | assistant.block:text | 1907 | 86 | 0.86 | 2.1.222–2.1.280 | type, text |
| main | assistant.block:thinking | 3969 | 83 | 14.26 | 2.1.222–2.1.280 | type, thinking, signature |
| main | assistant.block:tool_use | 5502 | 82 | 3.81 | 2.1.222–2.1.280 | type, id, name, input, caller |
| main | atis-latch | 1688 | 83 | 0.14 | – | type, atis, sessionId |
| main | attachment:agent_listing_delta | 88 | 88 | 0.42 | 2.1.222–2.1.280 | type, addedTypes, addedLines, removedTypes, isInitial, showConcurrencyNote |
| main | attachment:auto_mode | 73 | 73 | 0.04 | 2.1.222–2.1.280 | type, autoModeConsentFlow, bashFirst, steerOnly, bypass(72), bashFirstSteer(7) |
| main | attachment:batching_reminder_sent | 157 | 7 | 0.09 | 2.1.258–2.1.280 | type, text, model, clearAt(31) |
| main | attachment:command_permissions | 15 | 14 | 0.01 | 2.1.246–2.1.280 | type, allowedTools |
| main | attachment:date | 45 | 44 | 0.02 | 2.1.258–2.1.280 | type, date, changed(1) |
| main | attachment:deferred_tools_delta | 104 | 88 | 0.36 | 2.1.222–2.1.280 | type, addedNames, addedLines, removedNames, readdedNames, pendingMcpServers, needsAuthMcpServers, wireHiddenNames(75), failedMcpServers(75) |
| main | attachment:deferred_tools_record | 3 | 3 | 0.01 | 2.1.280–2.1.280 | type, entries |
| main | attachment:edited_text_file | 47 | 12 | 0.27 | 2.1.246–2.1.280 | type, filename, snippet |
| main | attachment:environment | 70 | 44 | 0.06 | 2.1.258–2.1.280 | type, snapshot, changes(26) |
| main | attachment:file | 4 | 4 | 0.14 | 2.1.280–2.1.280 | type, filename, content, displayPath |
| main | attachment:hook_additional_context | 87 | 14 | 0.07 | 2.1.246–2.1.258 | type, content, hookName, toolUseID, hookEvent |
| main | attachment:instructions | 11 | 7 | 0.04 | 2.1.280–2.1.280 | type, files, changed(4), reason(4) |
| main | attachment:mcp_instructions_delta | 1 | 1 | 0.00 | 2.1.222–2.1.222 | type, addedNames, addedBlocks, removedNames |
| main | attachment:model | 48 | 44 | 0.03 | 2.1.258–2.1.280 | type, identity, text |
| main | attachment:prompt_snapshot | 16 | 8 | 1.15 | 2.1.266–2.1.280 | type, systemPrompt, tools(8), cliPrefix(8) |
| main | attachment:queued_command | 126 | 29 | 0.37 | 2.1.222–2.1.280 | type, prompt, commandMode, timestamp, source_uuid(19), origin(4), humanTurn(3) |
| main | attachment:remote_session_change | 9 | 8 | 0.01 | 2.1.266–2.1.280 | type, url, commit, pr, sendUserFileHint, managedCommit(7), managedPr(7) |
| main | attachment:sandbox_instructions | 3 | 3 | 0.01 | 2.1.258–2.1.258 | type, content |
| main | attachment:session_context | 44 | 44 | 0.04 | 2.1.258–2.1.280 | type, context |
| main | attachment:silent_turn_reminder | 22 | 9 | 0.01 | 2.1.258–2.1.280 | type, text |
| main | attachment:skill_listing | 88 | 88 | 0.50 | 2.1.222–2.1.280 | type, content, skillCount, isInitial, names |
| main | attachment:task_reminder | 10 | 3 | 0.00 | 2.1.222–2.1.229 | type, content, itemCount |
| main | attachment:thinking_drop | 3 | 3 | 0.00 | 2.1.280–2.1.280 | type, requestId, model, querySource, thinkingBlocksSent, thinkingTurnsSent, newlyDropped, blockHashes, firstReportForThreadInProcess, clientChange |
| main | attachment:total_tokens_reminder | 5049 | 84 | 2.33 | 2.1.229–2.1.280 | type, text |
| main | bridge-session | 41 | 1 | 0.01 | – | type, sessionId, bridgeSessionId, lastSequenceNum, ownerAccountUuid, ownerOrganizationUuid |
| main | cost-state | 4 | 4 | 0.00 | – | type, sessionId, totalCostUSD, totalAPIDuration, totalAPIDurationWithoutRetries, totalToolDuration, totalLinesAdded, totalLinesRemoved, totalDuration, startTime, modelUsage, hasUnknownModelCost |
| main | custom-title | 1699 | 85 | 0.18 | – | type, customTitle, sessionId |
| main | file-history-delta | 17 | 6 | 0.01 | – | type, messageId, snapshotMessageId, trackingPath, backup, timestamp |
| main | file-history-snapshot | 154 | 8 | 0.14 | – | type, messageId, snapshot, isSnapshotUpdate |
| main | last-prompt | 1828 | 88 | 0.49 | – | type, lastPrompt, leafUuid, sessionId |
| main | mode | 785 | 44 | 0.06 | – | type, mode, sessionId |
| main | queue-operation | 952 | 88 | 0.97 | – | type, operation, timestamp, sessionId, content(528), reason(127) |
| main | system:stop_hook_summary | 161 | 20 | 0.09 | 2.1.229–2.1.280 | parentUuid, isSidechain, type, subtype, hookCount, hookInfos, hookErrors, hookAdditionalContext, preventedContinuation, stopReason, hasOutput, level, timestamp, uuid |
| main | user | 5878 | 88 | 28.41 | 2.1.222–2.1.280 | parentUuid, isSidechain, promptId, type, message, uuid, timestamp, userType, entrypoint, cwd, sessionId, version, gitBranch, toolUseResult(5501) |
| main | user [interruptedByShutdown] | 1 | 1 | 0.00 | 2.1.226–2.1.226 | parentUuid, isSidechain, promptId, type, message, uuid, timestamp, interruptedByShutdown, userType, entrypoint, cwd, sessionId, version, gitBranch |
| main | user [isMeta,turnCompanion] | 15 | 14 | 0.32 | 2.1.246–2.1.280 | parentUuid, isSidechain, promptId, type, message, isMeta, turnCompanion, uuid, timestamp, sourceToolUseID, userType, entrypoint, cwd, sessionId |
| main | user [isMeta] | 22 | 13 | 0.01 | 2.1.226–2.1.280 | parentUuid, isSidechain, promptId, type, message, isMeta, uuid, timestamp, userType, entrypoint, cwd, sessionId, version, gitBranch |
| main | user [queueSkipAttachments] | 31 | 15 | 0.15 | 2.1.258–2.1.280 | parentUuid, isSidechain, promptId, type, message, uuid, timestamp, permissionMode, origin, promptSource, queueSkipAttachments, userType, entrypoint, cwd |
| main | user.block:image | 3 | 2 | 0.14 | 2.1.258–2.1.258 | type, source |
| main | user.block:text | 388 | 84 | 2.99 | 2.1.226–2.1.280 | type, text |
| main | user.block:tool_result | 5501 | 82 | 10.39 | 2.1.222–2.1.280 | tool_use_id, type, content, is_error(4664) |
| main | user.content:string | 326 | 55 | 0.25 | 2.1.222–2.1.280 |  |
| main | user.toolUseResult | 5501 | 82 | 12.11 | 2.1.222–2.1.280 |  |
| subagent | assistant [isApiErrorMessage,isSidechain] | 1 | 1 | 0.00 | 2.1.258–2.1.258 | parentUuid, isSidechain, agentId, type, uuid, timestamp, message, requestId, quotaLimits, error, isApiErrorMessage, apiErrorStatus, userType, entrypoint |
| subagent | assistant [isSidechain] | 3229 | 49 | 7.09 | 2.1.226–2.1.280 | parentUuid, isSidechain, agentId, message, requestId, attributionAgent, type, uuid, timestamp, userType, entrypoint, cwd, sessionId, version |
| subagent | assistant.block:text | 260 | 49 | 0.36 | 2.1.226–2.1.280 | type, text |
| subagent | assistant.block:thinking | 929 | 49 | 2.23 | 2.1.226–2.1.280 | type, thinking, signature |
| subagent | assistant.block:tool_use | 2041 | 49 | 0.92 | 2.1.226–2.1.280 | type, id, name, input, caller |
| subagent | attachment:agent_listing_delta | 2 | 2 | 0.02 | 2.1.280–2.1.280 | type, addedTypes, addedLines, removedTypes, isInitial, showConcurrencyNote |
| subagent | attachment:auto_mode | 2 | 2 | 0.00 | 2.1.280–2.1.280 | type, autoModeConsentFlow, bashFirst, bashFirstSteer, steerOnly, bypass |
| subagent | attachment:batching_reminder_sent | 16 | 2 | 0.01 | 2.1.280–2.1.280 | type, text, model, clearAt |
| subagent | attachment:date | 12 | 12 | 0.01 | 2.1.258–2.1.280 | type, date |
| subagent | attachment:deferred_tools_delta | 50 | 48 | 0.18 | 2.1.226–2.1.280 | type, addedNames, addedLines, removedNames, readdedNames, wireHiddenNames(38), pendingMcpServers(2), needsAuthMcpServers(2), failedMcpServers(2) |
| subagent | attachment:deferred_tools_record | 2 | 2 | 0.00 | 2.1.280–2.1.280 | type, entries |
| subagent | attachment:environment | 3 | 3 | 0.00 | 2.1.280–2.1.280 | type, snapshot |
| subagent | attachment:instructions | 3 | 3 | 0.02 | 2.1.280–2.1.280 | type, files |
| subagent | attachment:model | 3 | 3 | 0.00 | 2.1.280–2.1.280 | type, identity, text |
| subagent | attachment:prompt_snapshot | 6 | 3 | 0.30 | 2.1.280–2.1.280 | type, systemPrompt, tools(3), cliPrefix(3) |
| subagent | attachment:remote_session_change | 3 | 3 | 0.00 | 2.1.280–2.1.280 | type, url, commit, pr, sendUserFileHint, managedCommit, managedPr |
| subagent | attachment:session_context | 12 | 12 | 0.01 | 2.1.258–2.1.280 | type, context |
| subagent | attachment:skill_listing | 48 | 48 | 0.22 | 2.1.226–2.1.280 | type, content, skillCount, isInitial, names |
| subagent | attachment:total_tokens_reminder | 24 | 3 | 0.01 | 2.1.280–2.1.280 | type, text |
| subagent | user [isMeta,isSidechain,turnCompanion] | 5 | 5 | 0.02 | 2.1.258–2.1.258 | parentUuid, isSidechain, promptId, agentId, type, message, isMeta, turnCompanion, uuid, timestamp, sourceToolUseID, userType, entrypoint, cwd |
| subagent | user [isMeta,isSidechain] | 1 | 1 | 0.00 | 2.1.258–2.1.258 | parentUuid, isSidechain, promptId, agentId, type, message, isMeta, uuid, timestamp, origin, userType, entrypoint, cwd, sessionId |
| subagent | user [isSidechain] | 2090 | 49 | 6.61 | 2.1.226–2.1.280 | parentUuid, isSidechain, promptId, agentId, type, message, uuid, timestamp, userType, entrypoint, cwd, sessionId, version, gitBranch |
| subagent | user.block:text | 5 | 5 | 0.02 | 2.1.258–2.1.258 | type, text |
| subagent | user.block:tool_result | 2041 | 49 | 5.39 | 2.1.226–2.1.280 | tool_use_id, type, content, is_error(1750) |
| subagent | user.content:string | 50 | 49 | 0.06 | 2.1.226–2.1.280 |  |
| subagent | user.toolUseResult | 59 | 27 | 0.05 | 2.1.246–2.1.280 |  |

## 树结构

504 个文件；无父节点的记录 140 条，0 个文件有多个根；分叉点（一个父节点有多个子节点）462 个，分布在 66 个文件；带 logicalParentUuid 的记录 0 条。

一条 API 回复（按 message.id）拆成多条 assistant 记录：14710 条 assistant 记录对应 6516 个 message.id，单个 message.id 最多 23 条。

分叉点的子节点种类组合（前 12）：

| 次数 | 子节点 |
|---|---|
| 373 | assistant(tool_use) ＋ user(tool_result) |
| 86 | attachment:hook_additional_context ＋ user(tool_result) |
| 2 | assistant(thinking) ＋ user(文本) |
| 1 | user(文本) ＋ user(文本) |

## 小枚举字段的取值

- queue-operation.operation+reason："enqueue"×479，"dequeue"×345，"remove absorbed_mid_turn"×127，"remove"×1
- user.userType："external"×8104
- user.entrypoint："sdk-ts"×7075，"claude-desktop"×1029
- instructions.reason：null×13，"session_start"×4
- environment.changes 的键："0"×26

## prompt_snapshot 附件出现的位置

| 会话 | 范围 | 版本 | 位置 | 之前的 environment 附件 | 系统提示 | 工具 |
|---|---|---|---|---|---|---|
| cc4d7e90 | main | 2.1.280 | 第 53/969 行 | 之前 environment 附件 1 个 | systemPrompt 12 段 | tools 无 |
| cc4d7e90 | main | 2.1.280 | 第 59/969 行 | 之前 environment 附件 1 个 | systemPrompt 12 段 | tools 20 个 |
| 8f0e7f62 | main | 2.1.280 | 第 22/654 行 | 之前 environment 附件 1 个 | systemPrompt 12 段 | tools 无 |
| 8f0e7f62 | main | 2.1.280 | 第 28/654 行 | 之前 environment 附件 1 个 | systemPrompt 12 段 | tools 20 个 |
| aa7bc77d | main | 2.1.280 | 第 27/1041 行 | 之前 environment 附件 1 个 | systemPrompt 16 段 | tools 无 |
| aa7bc77d | main | 2.1.280 | 第 32/1041 行 | 之前 environment 附件 1 个 | systemPrompt 16 段 | tools 21 个 |
| agent-ad | subagent | 2.1.280 | 第 8/58 行 | 之前 environment 附件 1 个 | systemPrompt 4 段 | tools 无 |
| agent-ad | subagent | 2.1.280 | 第 17/58 行 | 之前 environment 附件 1 个 | systemPrompt 4 段 | tools 4 个 |
| 36085a23 | main | 2.1.280 | 第 21/248 行 | 之前 environment 附件 1 个 | systemPrompt 16 段 | tools 无 |
| 36085a23 | main | 2.1.280 | 第 26/248 行 | 之前 environment 附件 1 个 | systemPrompt 16 段 | tools 21 个 |
| 5965ce20 | main | 2.1.280 | 第 21/253 行 | 之前 environment 附件 1 个 | systemPrompt 16 段 | tools 无 |
| 5965ce20 | main | 2.1.280 | 第 26/253 行 | 之前 environment 附件 1 个 | systemPrompt 16 段 | tools 21 个 |
| 03af8109 | main | 2.1.280 | 第 18/68 行 | 之前 environment 附件 1 个 | systemPrompt 16 段 | tools 无 |
| 03af8109 | main | 2.1.280 | 第 28/68 行 | 之前 environment 附件 1 个 | systemPrompt 16 段 | tools 21 个 |
| agent-ab | subagent | 2.1.280 | 第 10/143 行 | 之前 environment 附件 1 个 | systemPrompt 4 段 | tools 无 |
| agent-ab | subagent | 2.1.280 | 第 14/143 行 | 之前 environment 附件 1 个 | systemPrompt 4 段 | tools 14 个 |
| agent-af | subagent | 2.1.280 | 第 10/315 行 | 之前 environment 附件 1 个 | systemPrompt 4 段 | tools 无 |
| agent-af | subagent | 2.1.280 | 第 14/315 行 | 之前 environment 附件 1 个 | systemPrompt 4 段 | tools 14 个 |
| b25682c5 | main | 2.1.266 | 第 16/714 行 | 之前 environment 附件 1 个 | systemPrompt 12 段 | tools 无 |
| b25682c5 | main | 2.1.266 | 第 21/714 行 | 之前 environment 附件 1 个 | systemPrompt 12 段 | tools 19 个 |
| agent-ad | legacy-agent | 2.1.280 | 第 10/61 行 | 之前 environment 附件 1 个 | systemPrompt 4 段 | tools 无 |
| agent-ad | legacy-agent | 2.1.280 | 第 14/61 行 | 之前 environment 附件 1 个 | systemPrompt 4 段 | tools 13 个 |
| agent-ad | legacy-agent | 2.1.280 | 第 10/86 行 | 之前 environment 附件 1 个 | systemPrompt 4 段 | tools 无 |
| agent-ad | legacy-agent | 2.1.280 | 第 13/86 行 | 之前 environment 附件 1 个 | systemPrompt 4 段 | tools 13 个 |
| 71bcb31d | main | 2.1.280 | 第 19/146 行 | 之前 environment 附件 1 个 | systemPrompt 12 段 | tools 无 |
| 71bcb31d | main | 2.1.280 | 第 25/146 行 | 之前 environment 附件 1 个 | systemPrompt 12 段 | tools 20 个 |
| agent-af | legacy-agent | 2.1.280 | 第 10/113 行 | 之前 environment 附件 1 个 | systemPrompt 4 段 | tools 无 |
| agent-af | legacy-agent | 2.1.280 | 第 13/113 行 | 之前 environment 附件 1 个 | systemPrompt 4 段 | tools 13 个 |

## instructions 附件出现的位置

| 会话 | 范围 | 版本 | 位置 | 之前的 environment 附件 | 文件类型 | 原因 |
|---|---|---|---|---|---|---|
| cc4d7e90 | main | 2.1.280 | 第 49/969 行 | 之前 environment 附件 1 个 | AutoMem |   |
| cc4d7e90 | main | 2.1.280 | 第 441/969 行 | 之前 environment 附件 3 个 | AutoMem | session_start changed=true |
| 8f0e7f62 | main | 2.1.280 | 第 18/654 行 | 之前 environment 附件 1 个 | AutoMem |   |
| aa7bc77d | main | 2.1.280 | 第 23/1041 行 | 之前 environment 附件 1 个 | User+User |   |
| aa7bc77d | main | 2.1.280 | 第 56/1041 行 | 之前 environment 附件 2 个 | AutoMem | session_start changed=true |
| agent-ad | subagent | 2.1.280 | 第 4/58 行 | 之前 environment 附件 1 个 | User+User+AutoMem |   |
| 36085a23 | main | 2.1.280 | 第 17/248 行 | 之前 environment 附件 1 个 | User+User |   |
| 36085a23 | main | 2.1.280 | 第 57/248 行 | 之前 environment 附件 2 个 | AutoMem | session_start changed=true |
| 5965ce20 | main | 2.1.280 | 第 17/253 行 | 之前 environment 附件 1 个 | User+User |   |
| 5965ce20 | main | 2.1.280 | 第 57/253 行 | 之前 environment 附件 2 个 | AutoMem | session_start changed=true |
| 03af8109 | main | 2.1.280 | 第 14/68 行 | 之前 environment 附件 1 个 | User+User |   |
| agent-ab | subagent | 2.1.280 | 第 6/143 行 | 之前 environment 附件 1 个 | User+User+AutoMem |   |
| agent-af | subagent | 2.1.280 | 第 6/315 行 | 之前 environment 附件 1 个 | User+User+AutoMem |   |
| agent-ad | legacy-agent | 2.1.280 | 第 6/61 行 | 之前 environment 附件 1 个 | AutoMem |   |
| agent-ad | legacy-agent | 2.1.280 | 第 6/86 行 | 之前 environment 附件 1 个 | AutoMem |   |
| 71bcb31d | main | 2.1.280 | 第 15/146 行 | 之前 environment 附件 1 个 | AutoMem |   |
| agent-af | legacy-agent | 2.1.280 | 第 6/113 行 | 之前 environment 附件 1 个 | AutoMem |   |

## 旁路文件

| 种类 | 个数 | MB | 字段 |
|---|---|---|---|
| tool-results/*（外置的大工具输出） | 64 | 13.47 |  |
| subagents/*.json（子 agent 元数据） | 49 | 0.01 | agentType, description, toolUseId, spawnDepth, requestShape(3), requestNonInteractive(3) |
| <会话>/*.json | 3 | 0.00 | customTitle |

## 附：合成样本普查

用 `spikes/sdk/synth.ts` 在 Claude Code 2.1.280 上制造的压缩、分叉、后台任务、打断四个会话，根目录是临时的 `claude-config/projects`。

### 记录种类

「范围」：main 是主会话，subagent 是 subagents/ 下的子 agent 记录，legacy-agent 是项目目录下的老格式子 agent 记录。块（block）的字节只算块本身。

| 范围 | 种类 | 条数 | 文件数 | MB | 版本范围 | 常见字段 |
|---|---|---|---|---|---|---|
| main | assistant | 15 | 5 | 0.02 | 2.1.280–2.1.280 | parentUuid, isSidechain, message, apiBlockIndex, type, uuid, timestamp, effort, perTurnEffort, userType, entrypoint, cwd, sessionId, version |
| main | assistant.block:text | 13 | 5 | 0.00 | 2.1.280–2.1.280 | type, text |
| main | assistant.block:tool_use | 2 | 2 | 0.00 | 2.1.280–2.1.280 | type, id, name, input |
| main | atis-latch | 12 | 5 | 0.00 | – | type, atis, sessionId |
| main | attachment:agent_listing_delta | 6 | 5 | 0.02 | 2.1.280–2.1.280 | type, addedTypes, addedLines, removedTypes, isInitial, showConcurrencyNote |
| main | attachment:date | 6 | 5 | 0.00 | 2.1.280–2.1.280 | type, date |
| main | attachment:environment | 6 | 5 | 0.01 | 2.1.280–2.1.280 | type, snapshot |
| main | attachment:model | 6 | 5 | 0.01 | 2.1.280–2.1.280 | type, identity, text |
| main | attachment:prompt_snapshot | 12 | 5 | 0.44 | 2.1.280–2.1.280 | type, systemPrompt, tools(6), cliPrefix(6) |
| main | attachment:remote_session_change | 6 | 5 | 0.01 | 2.1.280–2.1.280 | type, url, commit, pr, sendUserFileHint, managedCommit, managedPr |
| main | attachment:session_context | 6 | 5 | 0.00 | 2.1.280–2.1.280 | type, context |
| main | attachment:skill_listing | 5 | 5 | 0.06 | 2.1.280–2.1.280 | type, content, skillCount, isInitial, names |
| main | attachment:total_tokens_reminder | 14 | 5 | 0.01 | 2.1.280–2.1.280 | type, text |
| main | cost-state | 5 | 5 | 0.00 | – | type, sessionId, totalCostUSD, totalAPIDuration, totalAPIDurationWithoutRetries, totalToolDuration, totalLinesAdded, totalLinesRemoved, totalDuration, startTime, modelUsage, hasUnknownModelCost |
| main | last-prompt | 10 | 5 | 0.00 | – | type, lastPrompt, leafUuid, sessionId |
| main | mode | 2 | 1 | 0.00 | – | type, mode, sessionId |
| main | queue-operation | 26 | 5 | 0.00 | – | type, operation, timestamp, sessionId, content(13) |
| main | system:compact_boundary | 1 | 1 | 0.00 | 2.1.280–2.1.280 | parentUuid, logicalParentUuid, isSidechain, type, subtype, content, isMeta, timestamp, uuid, level, compactMetadata, userType, entrypoint, cwd |
| main | user | 18 | 5 | 0.01 | 2.1.280–2.1.280 | parentUuid, isSidechain, promptId, type, message, uuid, timestamp, userType, entrypoint, cwd, sessionId, version, gitBranch, permissionMode(13) |
| main | user [isCompactSummary,isVisibleInTranscriptOnly] | 1 | 1 | 0.00 | 2.1.280–2.1.280 | parentUuid, isSidechain, promptId, type, message, isVisibleInTranscriptOnly, isCompactSummary, uuid, timestamp, userType, entrypoint, cwd, sessionId, version |
| main | user [isMeta] | 1 | 1 | 0.00 | 2.1.280–2.1.280 | parentUuid, isSidechain, promptId, type, message, isMeta, uuid, timestamp, userType, entrypoint, cwd, sessionId, version, gitBranch |
| main | user [queueSkipAttachments] | 1 | 1 | 0.00 | 2.1.280–2.1.280 | parentUuid, isSidechain, promptId, type, message, uuid, timestamp, permissionMode, origin, promptSource, turnOrigin, queueSkipAttachments, userType, entrypoint |
| main | user.block:text | 1 | 1 | 0.00 | 2.1.280–2.1.280 | type, text |
| main | user.block:tool_result | 2 | 2 | 0.00 | 2.1.280–2.1.280 | type, content, is_error, tool_use_id |
| main | user.content:string | 18 | 5 | 0.00 | 2.1.280–2.1.280 |  |
| main | user.toolUseResult | 2 | 2 | 0.00 | 2.1.280–2.1.280 |  |

### 树结构

5 个文件；无父节点的记录 6 条，1 个文件有多个根；分叉点（一个父节点有多个子节点）0 个，分布在 0 个文件；带 logicalParentUuid 的记录 1 条。

一条 API 回复（按 message.id）拆成多条 assistant 记录：15 条 assistant 记录对应 15 个 message.id，单个 message.id 最多 1 条。

分叉点的子节点种类组合（前 12）：

| 次数 | 子节点 |
|---|---|

### 小枚举字段的取值

- queue-operation.operation+reason："enqueue"×13，"dequeue"×13
- user.userType："external"×21
- user.entrypoint："sdk-ts"×21

### prompt_snapshot 附件出现的位置

| 会话 | 范围 | 版本 | 位置 | 之前的 environment 附件 | 系统提示 | 工具 |
|---|---|---|---|---|---|---|
| 28670fe2 | main | 2.1.280 | 第 13/29 行 | 之前 environment 附件 1 个 | systemPrompt 1 段 | tools 无 |
| 28670fe2 | main | 2.1.280 | 第 15/29 行 | 之前 environment 附件 1 个 | systemPrompt 1 段 | tools 20 个 |
| 1671028c | main | 2.1.280 | 第 13/26 行 | 之前 environment 附件 1 个 | systemPrompt 1 段 | tools 无 |
| 1671028c | main | 2.1.280 | 第 16/26 行 | 之前 environment 附件 1 个 | systemPrompt 1 段 | tools 20 个 |
| a3665c8c | main | 2.1.280 | 第 14/26 行 | 之前 environment 附件 1 个 | systemPrompt 1 段 | tools 无 |
| a3665c8c | main | 2.1.280 | 第 16/26 行 | 之前 environment 附件 1 个 | systemPrompt 1 段 | tools 20 个 |
| 1b15e7ce | main | 2.1.280 | 第 13/26 行 | 之前 environment 附件 1 个 | systemPrompt 1 段 | tools 无 |
| 1b15e7ce | main | 2.1.280 | 第 16/26 行 | 之前 environment 附件 1 个 | systemPrompt 1 段 | tools 20 个 |
| cb3df55b | main | 2.1.280 | 第 13/52 行 | 之前 environment 附件 1 个 | systemPrompt 1 段 | tools 无 |
| cb3df55b | main | 2.1.280 | 第 15/52 行 | 之前 environment 附件 1 个 | systemPrompt 1 段 | tools 20 个 |
| cb3df55b | main | 2.1.280 | 第 47/52 行 | 之前 environment 附件 2 个 | systemPrompt 1 段 | tools 无 |
| cb3df55b | main | 2.1.280 | 第 49/52 行 | 之前 environment 附件 2 个 | systemPrompt 1 段 | tools 20 个 |

### instructions 附件出现的位置

| 会话 | 范围 | 版本 | 位置 | 之前的 environment 附件 | 文件类型 | 原因 |
|---|---|---|---|---|---|---|

### 旁路文件

| 种类 | 个数 | MB | 字段 |
|---|---|---|---|
