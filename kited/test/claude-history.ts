import type { ThreadContext } from '../src/model.ts';
import { writeFiles } from './util.ts';

/** 原生 JSONL 固定夹具：由实际 SDK 读取、筛选父子链，不替换 SDK 或宿主。 */
export function writeClaudeHistory(thread: ThreadContext, messages: Array<{
  uuid: string; at: number; role: 'user' | 'assistant'; text: string;
  measurement?: { id: string; model: string; usage: Record<string, number> };
}>) {
  const entries = messages.map((message, index) => ({
    type: message.role, uuid: message.uuid, parentUuid: messages[index - 1]?.uuid ?? null,
    sessionId: thread.nativeId, cwd: thread.workspace.cwd, timestamp: new Date(message.at).toISOString(), isSidechain: false,
    ...(message.role === 'user' ? { origin: { kind: 'human' } } : {}),
    message: { role: message.role, content: message.role === 'user' ? message.text : [{ type: 'text', text: message.text }],
      ...message.measurement },
  }));
  writeFiles(process.env.CLAUDE_CONFIG_DIR!, {
    [`projects/${thread.workspace.cwd.replace(/[^a-zA-Z0-9]/g, '-')}/${thread.nativeId}.jsonl`]: entries.map((entry) => JSON.stringify(entry)).join('\n') + '\n',
  });
}
