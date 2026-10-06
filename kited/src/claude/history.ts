/** 仍由 SDK 选择原生会话分支，只补上其显示接口未暴露的时间和来源。 */
import { getSessionInfo, getSessionMessages, importSessionToStore, type SessionStoreEntry } from '@anthropic-ai/claude-agent-sdk';

export async function readClaudeMessages(nativeId: string, cwd: string) {
  if (!await getSessionInfo(nativeId, { dir: cwd })) return [];
  const entries: SessionStoreEntry[] = [];
  const sessionStore = {
    async append(_key: unknown, batch: SessionStoreEntry[]) { entries.push(...batch); },
    async load() { return entries; },
  };
  await importSessionToStore(nativeId, sessionStore, { dir: cwd, includeSubagents: false });
  const originals = new Map(entries.filter((entry) => entry.uuid).map((entry) => [entry.uuid!, entry]));
  return (await getSessionMessages(nativeId, { dir: cwd, sessionStore, includeSystemMessages: true })).map((message) => {
    const original = originals.get(message.uuid);
    const at = Date.parse(original?.timestamp ?? '');
    // 无时间的内部记录不冒充近期对话；宿主收到的用户输入另有可靠的接收时间。
    return { ...message, at: Number.isFinite(at) ? at : 0, ...(original?.origin ? { origin: original.origin } : {}) };
  });
}
