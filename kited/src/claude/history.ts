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
  const resumed = unrebase(entries);
  const originals = new Map(entries.filter((entry) => entry.uuid).map((entry) => [entry.uuid!, entry]));
  return (await getSessionMessages(nativeId, { dir: cwd, sessionStore, includeSystemMessages: true })).flatMap((message) => {
    const original = originals.get(message.uuid);
    const at = Date.parse(original?.timestamp ?? '');
    // 无时间的内部记录不冒充近期对话；宿主收到的用户输入另有可靠的接收时间。
    const shown = { ...message, at: Number.isFinite(at) ? at : 0, ...(original?.origin ? { origin: original.origin } : {}),
      // 跨后端导入的条目，显示时由来源后端的记录提供。
      ...(original?.kite ? { kite: original.kite as { import: string; through: string } } : {}) };
    // 接回处补上重组带来的导入标记，后续 Claude 段仍排在对应的 harness 内容之后。
    const rebase = resumed.get(message.uuid);
    return rebase?.kite ? [{ ...shown, uuid: rebase.boundary, kite: rebase.kite }, shown] : [shown];
  });
}

/**
 * Kite 整体重组会话（见 handoff 的 rebaseToClaude）写入的条目只服务模型上下文：显示时去掉，之后的新条目接回重组前的叶子，
 * 显示仍按原来的对话顺序。返回接回的条目及其所跟随的重组。
 */
function unrebase(entries: SessionStoreEntry[]): Map<string, { boundary: string; kite?: { import: string; through: string } }> {
  const rebases = new Map<string, { boundary: string; logical: string | null; kite?: { import: string; through: string } }>();
  const owner = new Map<string, string>();
  for (const entry of entries) {
    if (typeof entry.kiteRebase !== 'string') continue;
    if (entry.uuid) owner.set(entry.uuid, entry.kiteRebase);
    if (entry.type === 'system' && entry.subtype === 'compact_boundary' && entry.uuid) rebases.set(entry.kiteRebase, {
      boundary: entry.uuid, logical: typeof entry.logicalParentUuid === 'string' ? entry.logicalParentUuid : null,
      ...(entry.kite ? { kite: entry.kite as { import: string; through: string } } : {}) });
  }
  // 重组前的叶子本身也可能来自更早的重组。
  const leaf = (uuid: string | null): string | null => {
    const seen = new Set<string>();
    while (uuid && owner.has(uuid) && !seen.has(uuid)) { seen.add(uuid); uuid = rebases.get(owner.get(uuid)!)?.logical ?? null; }
    return uuid;
  };
  const resumed = new Map<string, { boundary: string; kite?: { import: string; through: string } }>();
  let kept = 0;
  for (const entry of entries) {
    if (typeof entry.kiteRebase === 'string') continue;
    const parent = typeof entry.parentUuid === 'string' ? entry.parentUuid : undefined;
    const rebase = parent && owner.has(parent) ? rebases.get(owner.get(parent)!) : undefined;
    if (rebase && entry.uuid) {
      resumed.set(entry.uuid, rebase);
      entries[kept++] = { ...entry, parentUuid: leaf(parent!) };
    } else entries[kept++] = entry;
  }
  entries.length = kept;
  return resumed;
}
