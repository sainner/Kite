/**
 * 同一线程在 Claude 与自研 harness 之间切换时的上下文翻译。
 *
 * 每个后端在线程内各有一份原生记录：harness 的 journal、Claude 的会话文件。切换时只把来源后端自上次交接以来
 * 自己产生的内容翻译后追加到目标后端的记录，标明来源位置；已有内容不改写，各自的推理与恢复字段原样留在自己的记录里。
 * 来源位置使交接可重复执行：保存失败后重试只会导入尚未导入的部分。
 *
 * 跨厂商不传推理：Claude thinking 的签名只有 Anthropic 能校验，harness 的加密 reasoning 只有 OpenAI 能解密。
 * 其余内容（输入、通知、文字、工具调用与结果、图片）按目标后端原生的形态合成，验证见 spikes/handoff。
 */
import { randomUUID } from 'node:crypto';
import { join } from 'node:path';
import { isDeepStrictEqual } from 'node:util';
import { engineAttachmentTypes } from '../claude/context-filter/hooks/register.ts';
import { acquireClaudeLock } from '../claude/host.ts';
import { readClaudeControl, saveClaudeControl, type ClaudeControl } from '../claude/control.ts';
import { CLAUDE_TOOL_SEARCH, claudeImage, claudeToolResult, claudeToolResultContent, claudeUserContent, structuredClaudeTool } from '../claude/tools.ts';
import { modelText, withSkillText } from '../harness/input.ts';
import { TOOL_SEARCH } from '../harness/tool-search.ts';
import { restoreContext } from '../harness/context/assembler.ts';
import { readJournal } from '../harness/journal.ts';
import { inputItem, outcomeFeedback, recoveryFeedback, replayUnits, skillItem } from '../harness/history.ts';
import { messageTexts } from '../harness/responses.ts';
import { appendThreadJournal } from '../harness/thread-host.ts';
import type { ContextItem, Input, Json, JsonObject, JournalRecord, ModelItem, ToolImage, ToolResult } from '../harness/types.ts';
import type { RuntimeKind, ThreadContext } from '../model.ts';
import { appendClaudeEntries, readClaudeEntries, type ClaudeEntry } from './claude-records.ts';

const object = (value: unknown): Record<string, any> => value && typeof value === 'object' ? value as Record<string, any> : {};
// 另有只写进记录、不发给模型的标记附件。
const skippedAttachments = new Set<string>([...engineAttachmentTypes, 'batching_reminder_sent', 'thinking_stripped']);
const isThinking = (block: Record<string, unknown>) => block.type === 'thinking' || block.type === 'redacted_thinking';

/**
 * 当前原生上下文里仍有效的块。CLI 2.1.280 的删除收据按 message.id 下的 thinking 序号定位（不计正文），
 * 删除目标及其后的块；目标找不到时删除此前全部 thinking。先落实收据，再换 ID，避免重组或撤销时复活旧块。
 */
function activeClaudeThinking(entries: readonly ClaudeEntry[]): Set<string> {
  const kept = new Set<string>();
  const blocks: Array<{ messageId: string; index: number; key: string }> = [];
  const counts = new Map<string, number>();
  for (const entry of entries) {
    if (entry.isSidechain) continue;
    if (entry.type === 'system' && entry.subtype === 'compact_boundary') {
      kept.clear(); blocks.length = 0; counts.clear();
    } else if (entry.type === 'assistant') {
      const message = object(entry.message);
      for (const block of Array.isArray(message.content) ? message.content.map(object) : []) {
        if (!isThinking(block)) continue;
        const index = counts.get(message.id) ?? 0;
        const key = JSON.stringify(block);
        blocks.push({ messageId: message.id, index, key });
        counts.set(message.id, index + 1);
        kept.add(key);
      }
    } else if (entry.type === 'attachment' && object(entry.attachment).type === 'thinking_stripped') {
      const attachment = object(entry.attachment), from = object(attachment.from);
      const start = attachment.scope === 'partial'
        ? blocks.findIndex((block) => block.messageId === from.messageId && block.index === from.thinkingIndex) : 0;
      for (const block of blocks.slice(Math.max(0, start))) kept.delete(block.key);
    }
  }
  return kept;
}

/** 调用方须已停止并关闭来源后端，且持有线程的控制队列。 */
export async function handOff(options: { home: string; thread: ThreadContext; to: RuntimeKind; model: string }): Promise<void> {
  const { thread, to } = options;
  const directory = join(options.home, 'sessions', thread.id);
  const { cwd } = thread.workspace;
  if (to === 'harness') { importClaude(directory, cwd, thread.nativeId); return; }
  const release = acquireClaudeLock(directory);
  try { await syncToClaude(directory, cwd, thread.nativeId, options.model); } finally { release(); }
}

/**
 * 把 Claude 自上次导入以来的内容追加进 journal，每条输入处另起一段，Claude 的消息因此也能作为压缩边界。
 * harness 宿主不能同时打开；返回追加的记录，供显示投影定位压缩范围。
 */
export function importClaude(directory: string, cwd: string, nativeId: string): JournalRecord[] {
  const records = readJournal(join(directory, 'journal.jsonl'));
  const control = readClaudeControl(directory);
  const previous = records.findLast((row) => row.type === 'context.imported');
  const groups = claudeToHarness(readClaudeEntries(cwd, nativeId), control, previous?.type === 'context.imported' ? previous.source.through : undefined);
  const instructions = control.context ?? control.initialContext;
  return groups.filter((group) => group.items.length).map((group) => appendThreadJournal(directory, { type: 'context.imported', id: randomUUID(),
    source: { runtime: 'claude', through: group.through }, items: group.items, notificationCursor: control.through,
    ...(instructions !== undefined ? { instructions } : {}) }));
}

/** 把 harness 自上次交接以来的内容交给 Claude 会话；调用方持有 Claude 会话锁，Claude 进程不在运行。 */
export async function syncToClaude(directory: string, cwd: string, nativeId: string, model: string): Promise<void> {
  const records = readJournal(join(directory, 'journal.jsonl'));
  const entries = readClaudeEntries(cwd, nativeId);
  const marker = entries.findLast((entry) => entry.kite)?.kite;
  const parent = entries.findLast((entry) => entry.uuid && !entry.isSidechain)?.uuid ?? null;
  const translated = harnessToClaude(records, marker ? Number(marker.through) : 0, { nativeId, cwd, model, parent, native: entries });
  if (!translated) return;
  await appendClaudeEntries(cwd, nativeId, translated.entries);
  const control = readClaudeControl(directory);
  control.importedInputs = [...new Set([...control.importedInputs, ...translated.inputIds])];
  control.through = Math.max(control.through, translated.notificationCursor);
  // 尚未启动过 Claude 时，系统提示会直接取当前正文，不需要另外告知更新。
  if (control.initialContext !== undefined && translated.instructions !== undefined) control.context = translated.instructions;
  saveClaudeControl(directory, control);
}

/**
 * Claude 自己产生的、位于 after 之后的条目，在每条输入处分段；through 是各段在 Claude 会话中的最后位置。
 * 宿主不对 Claude 会话回退或分叉，文件顺序即对话顺序。
 */
export function claudeToHarness(entries: ClaudeEntry[], control: ClaudeControl, after?: string): Array<{ items: ContextItem[]; through: string }> {
  const own = entries.filter((entry) => entry.uuid && !entry.isSidechain && !entry.kite);
  const start = after === undefined ? 0 : own.findIndex((entry) => entry.uuid === after) + 1;
  if (start === 0 && after !== undefined) throw new Error('Claude 会话中找不到上次交接的位置，不能续接翻译');
  const tail = own.slice(start);
  const groups: Array<{ items: ContextItem[]; through: string }> = [];
  const inputs = new Map(control.inputs.map((entry) => [entry.sdkId, entry.input]));
  // Kite 发出的输入，原生行的 uuid（回合中途是排队附件的 source_uuid）就是发送时的 sdkId；
  // 对不上的是上游自己以 user 角色送达模型的内容（中断说明等），没有包装，按 Kite 来源保留。
  const input = (sdkId: string, text: string, human: boolean): Input => inputs.get(sdkId) ?? { id: sdkId, text, source: human ? 'human' : 'kite' };
  // 点选了 skill 的输入，Claude 的原生行里正文接在输入后面；换回 harness 时照 harness 的样子另起一条跟在输入后面。
  const skills = new Map(control.inputs.flatMap((entry) => entry.skill ? [[entry.sdkId, entry.skill] as const] : []));
  const received = (sdkId: string, text: string, human: boolean, images: ToolImage[]): ContextItem[] => {
    const value = input(sdkId, text, human);
    const skill = skills.get(sdkId);
    return [inputItem(value, images), ...(skill && value.source === 'human' && value.skill ? [skillItem(value.id, value.skill, skill)] : [])];
  };
  const calls = new Map<string, string>();
  const translate = (entry: ClaudeEntry): ContextItem[] => {
    const items: ContextItem[] = [];
    const message = object(entry.message);
    // CLI 附在回合里的伴随条目（图片在 CLI 缓存里的路径、权限与用量的说明等），不是宿主发的输入，CLI 自己转交时也跳过。
    if (entry.type === 'user' && entry.turnCompanion === true) return items;
    if (entry.type === 'user') {
      const content = typeof message.content === 'string' ? [{ type: 'text', text: message.content }] : Array.isArray(message.content) ? message.content.map(object) : [];
      const texts: string[] = [];
      const images: ToolImage[] = [];
      for (const block of content) {
        if (block.type === 'tool_result') {
          const name = calls.get(block.tool_use_id);
          if (!name) throw new Error('Claude 工具结果找不到对应的调用');
          if (name === CLAUDE_TOOL_SEARCH) continue;
          items.push({ type: 'tool_result', callId: block.tool_use_id, result: claudeToolResult(block, structuredClaudeTool(name)) });
        } else if (block.type === 'text') texts.push(block.text);
        else if (block.type === 'image') images.push(claudeImage(block, '用户消息'));
        else throw new Error(`不能翻译 Claude 用户消息中的 ${String(block.type)} 内容`);
      }
      // 上游的中断说明等也以 user 角色送达模型，没有宿主输入记录的按 Kite 来源保留。
      if (texts.length) items.push(...received(entry.uuid!, texts.join(''), object(entry.origin).kind === 'human', images));
    } else if (entry.type === 'assistant') {
      // API 错误是本地记录，不进入模型请求。
      if (entry.isApiErrorMessage) return items;
      const content = Array.isArray(message.content) ? message.content.map(object) : [];
      content.forEach((block, index) => {
        const raw = JSON.parse(JSON.stringify(block)) as JsonObject;
        const id = `${entry.uuid}:${index}`;
        if (block.type === 'tool_use') {
          calls.set(block.id, block.name);
          // ToolSearch 是 Claude 自己的按需加载，自研 harness 另用 tool_search 加载；调用与结果都不带过去。
          if (block.name === CLAUDE_TOOL_SEARCH) return;
          items.push({ type: 'output', item: { id, raw, format: 'anthropic', call: { id: block.id, name: block.name, arguments: block.input as Json } } });
        } else if (['text', 'thinking', 'redacted_thinking'].includes(block.type)) items.push({ type: 'output', item: { id, raw, format: 'anthropic' } });
        else throw new Error(`不能翻译 Claude 输出中的 ${String(block.type)} 内容`);
      });
    } else if (entry.type === 'attachment') {
      const attachment = object(entry.attachment);
      if (attachment.type === 'hook_additional_context') {
        const text = (Array.isArray(attachment.content) ? attachment.content : []).filter((part: unknown) => typeof part === 'string').join('\n');
        // 只有 Kite 注册了 hooks；它们投递的都是宿主的配置与上下文通知。
        if (text) items.push({ type: 'notification', notification: { id: entry.uuid!, kind: `claude.${String(attachment.hookEvent)}`, source: 'host', authority: 'instruction' }, text });
      } else if (attachment.type === 'queued_command') {
        // 带图片的排队消息，prompt 是正文块后面跟图片块。
        const blocks = Array.isArray(attachment.prompt) ? attachment.prompt.map(object) : [{ type: 'text', text: String(attachment.prompt) }];
        const text = blocks.filter((block) => block.type === 'text').map((block) => String(block.text)).join('');
        items.push(...received(String(attachment.source_uuid ?? entry.uuid), text, object(attachment.origin).kind === 'human',
          blocks.filter((block) => block.type === 'image').map((block) => claudeImage(block, '排队消息'))));
      } else if (!skippedAttachments.has(attachment.type)) throw new Error(`不能翻译 Claude 附件 ${String(attachment.type)}`);
    } else if (entry.type === 'system') {
      if (entry.subtype === 'compact_boundary') throw new Error('不能翻译已压缩的 Claude 会话');
    } else throw new Error(`不能翻译 Claude 记录类型 ${entry.type}`);
    return items;
  };
  for (const entry of tail) {
    const items = translate(entry);
    // 以输入开头的条目另起一段；不产生内容的条目也计入当前段的位置。
    if (!groups.length || (items[0]?.type === 'input' && groups.at(-1)!.items.length)) groups.push({ items: [], through: entry.uuid! });
    const group = groups.at(-1)!;
    group.items.push(...items);
    group.through = entry.uuid!;
  }
  return groups;
}

type ClaudeTarget = { nativeId: string; cwd: string; model: string; parent: string | null;
  /** Claude 会话现有条目；重组时来自 Claude 的段按它原样拷贝。 */
  native?: ClaudeEntry[] };

/**
 * 输入在 Claude 会话里的原生条目：回合开头是 user 消息，回合中途（跟在工具结果之后）是排队的命令附件；正文按来源包装，
 * 点选的 skill 正文与 Claude 宿主一样接在后面，附件里的图片跟在正文后面（排队命令的 prompt 同样可以是内容块）。
 */
function claudeInput(input: Input, midTurn: boolean, images?: ToolImage[], skill?: string): { type: string; [key: string]: unknown } {
  const origin = input.source === 'human' ? { origin: { kind: 'human' } } : {};
  const content = claudeUserContent(withSkillText(modelText(input), skill), images);
  return midTurn
    ? { type: 'attachment', attachment: { type: 'queued_command', prompt: content, source_uuid: randomUUID(), commandMode: 'prompt',
      ...origin, humanTurn: input.source === 'human' } }
    : { type: 'user', message: { role: 'user', content }, ...origin };
}

/** 一个模型条目对应的 Claude 内容块；工具调用 ID 规范化后登记，供结果找回调用与工具名。 */
function claudeBlocks(item: ModelItem, calls: Map<string, { id: string; name: string }>): JsonObject[] {
  if (item.format === 'anthropic') {
    if (item.call) calls.set(item.call.id, { id: item.call.id, name: String(item.raw.name) });
    return [structuredClone(item.raw)];
  }
  const raw = item.raw;
  // tool_search 只在自研 harness 里有，Claude 用自己的 ToolSearch 重新加载插件工具；调用与结果都不带过去，这里只登记以便认出结果。
  if (item.call?.name === TOOL_SEARCH) { calls.set(item.call.id, { id: item.call.id, name: TOOL_SEARCH }); return []; }
  if (item.call) {
    // Anthropic 的工具调用 ID 只允许字母、数字、下划线和连字符。
    const id = item.call.id.replace(/[^a-zA-Z0-9_-]/g, '_');
    if ([...calls.entries()].some(([original, call]) => call.id === id && original !== item.call!.id)) throw new Error('工具调用 ID 规范化后重复');
    const { name } = item.call;
    calls.set(item.call.id, { id, name });
    const input = item.call.arguments;
    return [{ type: 'tool_use', id, name, input: input && typeof input === 'object' && !Array.isArray(input) ? input : { value: input } }];
  }
  if (raw.type === 'message') return messageTexts(raw).map((text) => ({ type: 'text', text }));
  if (raw.type !== 'reasoning') throw new Error(`不能翻译 harness 输出 ${String(raw.type)}`);
  return [];
}

/**
 * harness 一侧压缩或撤销过时整体重组 Claude 会话：追加一个压缩分界，再接上按 harness 当前实际上下文合成的完整历史，
 * 并把 last-prompt 指向新叶子。CLI 加载时丢弃分界之前的条目，原条目留在文件里供显示（见 readClaudeMessages）。
 * 2026-10-09 在 CLI 2.1.280 上验证，见 spikes/compaction：分界的 type、subtype 须排在行首附近，CLI 只在每行开头一段里识别；
 * 合成的助手消息须用新的 message.id，同 id 的条目会被合并，分界之前的原条目也会并进来；不更新 last-prompt 时新输入接到旧叶子上。
 * 来自 Claude 的段拷贝原生条目（换 uuid、message.id 与时间）；thinking 只保留在未改动的共同前缀中，且须仍在当前原生上下文里。
 * 删除收据先落实到块，不把引用旧 message.id 的收据复制到新链；原始条目仍留在文件里供显示。
 */
function rebaseToClaude(records: readonly JournalRecord[], options: ClaudeTarget & { importId: string; through: string; after: number }) {
  const units = replayUnits(records);
  // 移除尚未交给 Claude 的压缩/撤销，得到重组前的上下文；后面新产生的普通段仍在，才能比较完整共同前缀。
  const before = replayUnits(records.filter((row) => row.seq <= options.after
    || (row.type !== 'context.compacted' && row.type !== 'context.compaction.reverted')));
  const thinking = activeClaudeThinking(options.native ?? []);
  let unchanged = true;
  const keep = (block: Record<string, unknown>) => !isThinking(block) || (unchanged && thinking.has(JSON.stringify(block)));
  const marks = { kite: { import: options.importId, through: options.through }, kiteRebase: options.importId };
  const entries: ClaudeEntry[] = [];
  let at = Math.max(Date.now(), ...records.map((row) => row.at));
  let parent: string | null = null;
  if (options.parent) {
    parent = randomUUID();
    entries.push({ parentUuid: null, logicalParentUuid: options.parent, isSidechain: false, type: 'system', subtype: 'compact_boundary',
      content: 'Conversation compacted', isMeta: false, timestamp: new Date(++at).toISOString(), uuid: parent, level: 'info',
      compactMetadata: { trigger: 'manual', preTokens: 0 }, userType: 'external', entrypoint: 'sdk-ts', cwd: options.cwd, sessionId: options.nativeId, ...marks });
  }
  const add = (fields: { type: string; [key: string]: unknown }, parentUuid = parent): string => {
    const uuid = randomUUID();
    entries.push({ parentUuid, isSidechain: false, userType: 'external', entrypoint: 'sdk-ts', cwd: options.cwd, sessionId: options.nativeId,
      timestamp: new Date(++at).toISOString(), uuid, ...marks, ...fields });
    parent = uuid;
    return uuid;
  };
  const text = (value: string) => add({ type: 'user', message: { role: 'user', content: value } });
  const notice = (hook: 'UserPromptSubmit' | 'PostToolBatch', value: string) => add({ type: 'attachment', attachment: {
    type: 'hook_additional_context', content: [value], hookName: hook, toolUseID: `hook-${randomUUID()}`, hookEvent: hook } });
  const inputIds: string[] = [];
  const calls = new Map<string, { id: string; name: string }>();
  const owners = new Map<string, string>();
  let lastPrompt = '';
  // 上一条是工具结果：之后的输入和通知属于回合中途。
  let afterResult = false;
  // 新回合的指令性通知排在这一轮的输入之后，与原生条目顺序一致。
  let held: string[] = [];
  let assistant: { id: string; blocks: JsonObject[] } | undefined;
  const release = () => { for (const value of held) notice('UserPromptSubmit', value); held = []; };
  const close = () => {
    if (!assistant) return;
    for (const block of assistant.blocks) {
      const uuid = add({ type: 'assistant', message: { id: assistant.id, type: 'message', role: 'assistant', model: options.model,
        content: [block], stop_reason: null, stop_sequence: null, usage: { input_tokens: 0, output_tokens: 0 } } });
      if (block.type === 'tool_use') owners.set(block.id as string, uuid);
    }
    assistant = undefined;
  };
  // 各次导入在 Claude 会话中对应的原生条目：从上一次导入的位置之后，到这一次的 through 为止。
  const own = (options.native ?? []).filter((entry) => entry.uuid && !entry.isSidechain && !entry.kite);
  const position = new Map(own.map((entry, index) => [entry.uuid!, index]));
  const spans = new Map<string, ClaudeEntry[]>();
  let next = 0;
  for (const row of records) {
    if (row.type !== 'context.imported') continue;
    const end = position.get(row.source.through);
    if (end === undefined || end < next) continue;
    spans.set(row.id, own.slice(next, end + 1));
    next = end + 1;
  }
  const copy = (rows: ClaudeEntry[]) => {
    close(); release();
    const uuids = new Map<string, string>();
    const messageIds = new Map<string, string>();
    for (const row of rows) {
      if (row.type === 'attachment' && object(row.attachment).type === 'thinking_stripped') continue;
      const uuid = randomUUID();
      const message = object(row.message);
      const content = row.type === 'assistant' && Array.isArray(message.content) ? message.content.filter((block: unknown) => keep(object(block))) : undefined;
      if (content?.length === 0) continue;
      const owner = typeof row.sourceToolAssistantUUID === 'string' ? uuids.get(row.sourceToolAssistantUUID) : undefined;
      if (row.type === 'assistant' && typeof message.id === 'string' && !messageIds.has(message.id)) messageIds.set(message.id, `msg_kite_${randomUUID()}`);
      entries.push({ ...row, uuid, parentUuid: (typeof row.parentUuid === 'string' && uuids.get(row.parentUuid)) || parent,
        timestamp: new Date(++at).toISOString(), ...marks,
        ...(row.type === 'assistant' && typeof message.id === 'string' ? { message: { ...message, id: messageIds.get(message.id), ...(content ? { content } : {}) } } : {}),
        ...(owner ? { sourceToolAssistantUUID: owner } : {}) });
      uuids.set(row.uuid!, uuid);
      parent = uuid;
      if (row.type === 'user' && typeof message.content === 'string' && object(row.origin).kind === 'human') lastPrompt = message.content;
    }
    const last = object(rows.at(-1)?.message);
    afterResult = rows.at(-1)?.type === 'user' && Array.isArray(last.content) && last.content.some((block: unknown) => object(block).type === 'tool_result');
  };
  for (const [index, unit] of units.entries()) {
    unchanged &&= isDeepStrictEqual(unit, before[index]);
    for (const item of unit.items) if (item.type === 'input') inputIds.push(item.input.id);
    const span = unit.imported && spans.get(unit.imported.id);
    if (span?.length) { copy(span); continue; }
    for (const item of unit.items) switch (item.type) {
      case 'output':
        release();
        assistant ??= { id: `msg_kite_${randomUUID()}`, blocks: [] };
        assistant.blocks.push(...claudeBlocks(item.item, calls).filter(keep));
        afterResult = false;
        break;
      case 'tool_result': {
        close();
        const call = calls.get(item.callId);
        if (call?.name === TOOL_SEARCH) break;
        const owner = call && owners.get(call.id);
        if (!call || !owner) throw new Error('harness 历史中的工具结果找不到对应的调用');
        add({ type: 'user', message: { role: 'user', content: [{ tool_use_id: call.id, type: 'tool_result', ...claudeToolResultContent(call.name, item.result) }] },
          sourceToolAssistantUUID: owner }, owner);
        afterResult = true;
        break;
      }
      case 'input': {
        close();
        const { input } = item;
        add(claudeInput(input, afterResult, item.images));
        if (!afterResult) release();
        if (input.source === 'human') lastPrompt = input.text;
        break;
      }
      case 'notification':
        close();
        // 摘要和文件变化是观察材料，作为普通消息；配置类通知沿用 hook 附加内容。
        if (item.notification.authority === 'observation') { release(); text(item.text); afterResult = false; }
        else if (afterResult) notice('PostToolBatch', item.text);
        else held.push(item.text);
        break;
      case 'feedback':
        close(); release(); text(item.text); afterResult = false;
        break;
    }
  }
  close();
  release();
  entries.push({ type: 'last-prompt', lastPrompt, leafUuid: parent, sessionId: options.nativeId, kiteRebase: options.importId });
  return { entries, inputIds };
}

/**
 * harness 在 after 之后自己产生的记录，按锁定 CLI 的原生条目形态合成；导入记录本就来自 Claude，跳过。
 * 这段期间压缩或撤销过时改为整体重组。
 */
export function harnessToClaude(records: readonly JournalRecord[], after: number, options: ClaudeTarget) {
  const tail = records.filter((row) => row.seq > after && row.type !== 'context.imported');
  const reshaped = tail.some((row) => row.type === 'context.compacted' || row.type === 'context.compaction.reverted');
  if (!reshaped && !tail.some((row) => ['request.started', 'turn.feedback', 'turn.finished', 'recovery.confirmed'].includes(row.type))) return undefined;
  const through = String(records.at(-1)!.seq);
  const importId = randomUUID();
  const inputs = new Map<string, Input>();
  const images = new Map<string, ToolImage[]>();
  const skills = new Map<string, string>();
  const contexts = new Map<string, string>();
  let notificationCursor = 0;
  let instructions: string | undefined;
  for (const row of records) {
    if (row.type === 'input.received') {
      inputs.set(row.input.id, row.input);
      if (row.images) images.set(row.input.id, row.images);
      if (row.skill) skills.set(row.input.id, row.skill);
    }
    if (row.type === 'context.prepared') contexts.set(row.snapshot.id, restoreContext(row.snapshot).instructions);
    if (row.type === 'context.imported') notificationCursor = Math.max(notificationCursor, row.notificationCursor);
    if (row.type === 'request.started') {
      for (const notification of row.notifications ?? []) notificationCursor = Math.max(notificationCursor, notification.sequence ?? 0);
      instructions = contexts.get(row.contextId);
    }
  }
  if (reshaped) return { ...rebaseToClaude(records, { ...options, importId, through, after }), through, notificationCursor, instructions };
  const entries: ClaudeEntry[] = [];
  const inputIds: string[] = [];
  let parent = options.parent;
  let at = Math.max(Date.now(), ...records.map((row) => row.at));
  const add = (fields: { type: string; [key: string]: unknown }, parentUuid = parent): string => {
    const uuid = randomUUID();
    entries.push({ parentUuid, isSidechain: false, userType: 'external', entrypoint: 'sdk-ts', cwd: options.cwd, sessionId: options.nativeId,
      timestamp: new Date(++at).toISOString(), uuid, kite: { import: importId, through }, ...fields });
    parent = uuid;
    return uuid;
  };
  const text = (value: string) => add({ type: 'user', message: { role: 'user', content: value } });
  const notice = (hook: 'UserPromptSubmit' | 'PostToolBatch', value: string) => add({ type: 'attachment', attachment: {
    type: 'hook_additional_context', content: [value], hookName: hook, toolUseID: `hook-${randomUUID()}`, hookEvent: hook } });
  let request: { id: string; blocks: JsonObject[]; results: Map<string, ToolResult> } | undefined;
  let turnRequests = 0;
  const flush = () => {
    if (!request) return;
    const owners = new Map<string, string>();
    for (const block of request.blocks) {
      const uuid = add({ type: 'assistant', message: { id: `msg_kite_${request.id}`, type: 'message', role: 'assistant', model: options.model,
        content: [block], stop_reason: null, stop_sequence: null, usage: { input_tokens: 0, output_tokens: 0 } } });
      if (block.type === 'tool_use') owners.set(block.id as string, uuid);
    }
    // 与原生记录相同：每个结果挂在各自的调用下，对话从最后一个结果继续。
    for (const block of request.blocks.filter((block) => block.type === 'tool_use')) {
      const result = request.results.get(block.id as string) ?? { status: 'not_executed', output: '工具没有执行结果。' };
      add({ type: 'user', message: { role: 'user', content: [{ tool_use_id: block.id, type: 'tool_result',
        ...claudeToolResultContent(block.name as string, result) }] }, sourceToolAssistantUUID: owners.get(block.id as string) }, owners.get(block.id as string));
    }
    request = undefined;
  };
  const calls = new Map<string, { id: string; name: string }>();
  for (const row of tail) {
    switch (row.type) {
      case 'turn.started': flush(); turnRequests = 0; break;
      case 'request.started': {
        flush();
        const midTurn = turnRequests++ > 0;
        const notes = (row.notifications ?? []).map((notification) => restoreContext(notification.context).instructions);
        if (!midTurn) {
          for (const id of row.inputIds) {
            const input = inputs.get(id)!;
            inputIds.push(id);
            add(claudeInput(input, false, images.get(id), skills.get(id)));
          }
          for (const note of notes) notice('UserPromptSubmit', note);
        } else {
          for (const note of notes) notice('PostToolBatch', note);
          for (const id of row.inputIds) {
            const input = inputs.get(id)!;
            inputIds.push(id);
            add(claudeInput(input, true, images.get(id), skills.get(id)));
          }
        }
        request = { id: row.requestId, blocks: [], results: new Map() };
        break;
      }
      case 'model.item': {
        if (!request || request.id !== row.requestId) throw new Error('harness 记录的输出不属于当前请求');
        request.blocks.push(...claudeBlocks(row.item, calls));
        break;
      }
      case 'tool.finished': {
        if (!request || request.id !== row.requestId) throw new Error('harness 记录的工具结果不属于当前请求');
        request.results.set(calls.get(row.callId)?.id ?? row.callId, row.result);
        break;
      }
      case 'turn.feedback': flush(); text(row.text); break;
      case 'turn.finished': {
        flush();
        const feedback = outcomeFeedback(row.outcome);
        if (feedback) text(feedback);
        break;
      }
      case 'recovery.confirmed': flush(); text(recoveryFeedback); break;
      default: break;
    }
  }
  flush();
  return entries.length ? { entries, through, inputIds, notificationCursor, instructions } : undefined;
}
