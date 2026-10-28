/** 上下文压缩的内容规则：范围内哪些条目原样保留、哪些并入摘要或丢弃，以及摘要的指令与包装。触发和记录由 runner 负责。 */
import { randomUUID } from 'node:crypto';
import { assembleContext, bindContext, sceneValues } from './context/assembler.ts';
import { fileChangesContext } from './context/notifications.ts';
import type { ContextDefinition, ContextValues } from './context/types.ts';
import type { ContextItem, ModelItem } from './types.ts';

export const compactTemplate: ContextDefinition = {
  version: 2, id: 'kite.compact', title: '压缩上下文', scene: 'thread.compact',
  blocks: [{ type: 'paragraph', id: 'instructions', title: '摘要指令', parts: [
    { type: 'text', text: '上下文即将压缩：' },
    { type: 'variable', name: 'compaction.range' },
    { type: 'text', text: '的对话会被一份摘要替换，范围之外的内容保持原样。请写这份摘要，供你之后代替原文继续工作。\n\n'
      + '写清：用户提出的目标、要求与约束（关键限制尽量保留原话）；已经做出的决定及理由；已完成的工作和关键结论；'
      + '尚未完成的事项与下一步；遇到的错误、已排除的做法和仍需核实的结果。文件改动清单由宿主另行提供，不必逐个列出文件。\n\n'
      + '不要调用工具，不要继续执行任务，只输出摘要正文。' },
  ] }],
  input: [{ type: 'paragraph', id: 'summary', title: '摘要包装', parts: [
    { type: 'text', text: '以下是先前一段对话的摘要，它替代了那段对话的原文：\n\n' },
    { type: 'variable', name: 'compaction.summary' },
  ] }],
};

/** 描述当前状态的通知：范围之后有同类就丢弃，否则保留最新一条。从 Claude 导入的宿主通知按 hook 事件归类。 */
const stateKinds = new Set(['context.updated', 'agent.configuration.changed', 'execution.permissions.changed', 'plugin.tools.changed', 'instances.changed']);
const isState = (kind: string) => stateKinds.has(kind) || kind.startsWith('claude.');
/** 估算用量达到窗口的这个比例时自动压缩。 */
export const AUTO_COMPACT_RATIO = 0.85;
/**
 * Claude 线程的空闲压缩：主循环上一次请求开始后一直空闲到这时，实测输入不少于门槛就在后台压缩。Claude 订阅的提示缓存保留
 * 1 小时，赶在过期前做，摘要请求还能读缓存；过了最晚时刻（如机器睡眠错过了）缓存多半已过期，不压。时机同 Claude Code
 * 的预先压缩（2026-10-28 按本机记录实测在空闲约 55 分钟时）。
 */
export const IDLE_COMPACT_AFTER_MS = 55 * 60_000;
export const IDLE_COMPACT_LATEST_MS = 58 * 60_000;
export const IDLE_COMPACT_TOKENS = 200_000;
/** 自动压缩原样保留的人发消息总量。 */
const RETAINED_HUMAN_TOKENS = 20_000;
const IMAGE_TOKENS = 1_000;
/** 压缩后重附已加载的 skill 正文：每个最多这么多 token，合计不超过总额；与 Claude Code 的做法一致。 */
const SKILL_REATTACH_TOKENS = 5_000;
const SKILL_REATTACH_TOTAL = 25_000;
/** 一段 skill 正文作为通知交给模型时的种类：/名字 点选跟在输入后面的，与压缩后重附的；都带 skill 标记。 */
export const SKILL_LOADED = 'skill.loaded';
/** 重附的正文前面那条说明。 */
const SKILLS_REATTACHED = 'skills.reattached';

/** 粗略估算：按 UTF-8 字节的三分之一计，偏向高估；图片按固定值，加密推理不计入。 */
export function roughTokens(value: string | ContextItem[]): number {
  if (typeof value === 'string') return Math.ceil(Buffer.byteLength(value) / 3);
  let tokens = 0;
  for (const item of value) {
    if (item.type === 'tool_result') {
      const { images, ...rest } = item.result;
      tokens += roughTokens(JSON.stringify(rest)) + (images?.length ?? 0) * IMAGE_TOKENS;
    } else if (item.type === 'input') {
      tokens += roughTokens(JSON.stringify(item.input)) + (item.images?.length ?? 0) * IMAGE_TOKENS;
    } else if (item.type === 'output') {
      const { encrypted_content: _, ...raw } = item.item.raw;
      tokens += roughTokens(JSON.stringify(raw));
    } else tokens += roughTokens(JSON.stringify(item));
  }
  return tokens;
}

function truncate(text: string, tokens: number, note = '\n……（后文已截断，要点见摘要）'): string {
  const bytes = Buffer.from(text);
  if (bytes.length <= tokens * 3) return text;
  // 按字节截取后去掉可能被切开的末尾字符。
  return bytes.subarray(0, tokens * 3).toString('utf8').replace(/�+$/, '') + note;
}

/**
 * 范围里交给过模型的 skill 正文，同名取最近一次，按最近的在前。只看 skill 标记（SkillMark）：带标记的成功工具结果（skill 工具加载的）
 * 与带标记的通知（/名字 点选跟在输入后面的、上一次压缩重附的），正文就是那一条的文字。
 */
function loadedSkills(range: ContextItem[]): Array<{ name: string; text: string }> {
  const latest = new Map<string, string>();
  const touch = (name: string, text: string) => { latest.delete(name); latest.set(name, text); };
  for (const item of range) {
    if (item.type === 'tool_result' && item.result.skill && item.result.status === 'success') touch(item.result.skill.name, item.result.output);
    else if (item.type === 'notification' && item.skill) touch(item.skill.name, item.text);
  }
  return [...latest].reverse().map(([name, text]) => ({ name, text }));
}

/**
 * 重附的通知：一条说明，接着每个 skill 一条带标记的正文，嵌套压缩时照样认得出。最近加载的优先占预算，每个截到单个上限，
 * 总额用完就不再附；正文按原来加载的先后排，嵌套压缩再认时先后不变。没有加载过时为空。
 */
function skillsReattachment(range: ContextItem[]): ContextItem[] {
  const notification = (kind: string) => ({ id: randomUUID(), kind, source: 'host.compaction', authority: 'observation' as const });
  const bodies: ContextItem[] = [];
  let budget = SKILL_REATTACH_TOTAL;
  for (const skill of loadedSkills(range)) {
    const allowance = Math.min(SKILL_REATTACH_TOKENS, budget);
    if (allowance <= 0) break;
    const text = truncate(skill.text, allowance, '\n……（正文过长，后面截掉了；要看全文再用 skill 工具加载）');
    bodies.unshift({ type: 'notification', notification: notification(SKILL_LOADED), text, skill: { name: skill.name } });
    budget -= roughTokens(text);
  }
  return bodies.length ? [{ type: 'notification', notification: notification(SKILLS_REATTACHED),
    text: '以下 skill 在被压缩的那段对话里加载过，正文重附在后面。这些是你之前已经读过的材料，不要因为再看到就重新执行一遍，手头的任务按摘要接着做。' }, ...bodies] : [];
}

/** 摘要请求只取消息正文；适配器格式以订阅 Responses 为准。 */
export function summaryText(items: ModelItem[]): string {
  let text = '';
  for (const item of items) {
    if (item.call) throw new Error('压缩摘要请求返回了工具调用');
    const raw = item.raw;
    if (raw.type !== 'message' || !Array.isArray(raw.content)) continue;
    if (raw.status === 'incomplete') throw new Error('压缩摘要生成未完成');
    for (const part of raw.content) {
      if (!part || typeof part !== 'object' || Array.isArray(part)) continue;
      if (part.type === 'refusal') throw new Error('模型拒绝生成压缩摘要');
      if (part.type === 'output_text' && typeof part.text === 'string') text += part.text;
    }
  }
  if (!text.trim()) throw new Error('压缩摘要为空');
  return text.trim();
}

/** values 是宿主给的公共变量，独立宿主没有时模板只能引用压缩自己的变量。 */
export function compactInstructions(definition: ContextDefinition, range: string, values: ContextValues = {}): string {
  return assembleContext(bindContext(definition, { ...values, ...sceneValues<'thread.compact'>({ 'compaction.range': range, 'compaction.summary': '' }) })).instructions;
}

/**
 * 范围的替代内容，依次为：保留的人发消息、摘要、净文件变化、已加载 skill 的正文、仍然有效的状态通知。
 * range 与 after 是范围内和范围之后实际进入请求的条目（已应用更早的压缩）。
 */
export function compactionItems(options: {
  range: ContextItem[]; after: ContextItem[]; automatic: boolean; summary: string;
  definition: ContextDefinition; files?: { changes: string; definition?: ContextDefinition }; values?: ContextValues;
}): ContextItem[] {
  const { range, after } = options;
  const retained: ContextItem[] = [];
  if (options.automatic) {
    let budget = RETAINED_HUMAN_TOKENS;
    for (const item of range.toReversed()) {
      // 代理来信对子代理来说就是任务本身，和人发的消息一样保留原文。
      if (item.type !== 'input' || item.input.source === 'kite') continue;
      const tokens = roughTokens(item.input.text) + (item.images?.length ?? 0) * IMAGE_TOKENS;
      if (tokens > budget) {
        // 最新一条超出时截断保留；更早的消息只进摘要。
        if (!retained.length) retained.push({ ...item, input: { ...item.input, text: truncate(item.input.text, budget) } });
        break;
      }
      retained.unshift(item);
      budget -= tokens;
    }
  }
  const values = options.values ?? {};
  const wrapped = assembleContext(bindContext(options.definition,
    { ...values, ...sceneValues<'thread.compact'>({ 'compaction.range': '', 'compaction.summary': options.summary }) })).input!;
  const items: ContextItem[] = [...retained, { type: 'notification', text: wrapped,
    notification: { id: randomUUID(), kind: 'context.summary', source: 'host.compaction', authority: 'observation' } }];
  if (options.files) items.push({ type: 'notification',
    text: assembleContext(fileChangesContext(options.files.changes, '包括 agent 自己与其他来源的改动', values, options.files.definition)).instructions,
    notification: { id: randomUUID(), kind: 'files.changed', source: 'host.compaction', authority: 'observation' } });
  items.push(...skillsReattachment(range));
  const later = new Set(after.flatMap((item) => item.type === 'notification' ? [item.notification.kind] : []));
  const latest = new Map<string, ContextItem>();
  for (const item of range) {
    if (item.type === 'notification' && isState(item.notification.kind) && !later.has(item.notification.kind)) latest.set(item.notification.kind, item);
  }
  items.push(...range.filter((item) => [...latest.values()].includes(item)));
  return structuredClone(items);
}
