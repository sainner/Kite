/** 上下文压缩的内容规则：范围内哪些条目原样保留、哪些并入摘要或丢弃，以及摘要的指令与包装。触发和记录由 runner 负责。 */
import { randomUUID } from 'node:crypto';
import { assembleContext } from './context/assembler.ts';
import { fileChangesContext } from './context/notifications.ts';
import type { ContextVariable } from './context/scenes.ts';
import type { ContextBinding, ContextDefinition } from './context/types.ts';
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
const stateKinds = new Set(['context.updated', 'agent.configuration.changed', 'execution.permissions.changed', 'plugin.tools.changed']);
const isState = (kind: string) => stateKinds.has(kind) || kind.startsWith('claude.');
/** 估算用量达到窗口的这个比例时自动压缩。 */
export const AUTO_COMPACT_RATIO = 0.85;
/** 自动压缩原样保留的人发消息总量。 */
const RETAINED_HUMAN_TOKENS = 20_000;
const IMAGE_TOKENS = 1_000;

/** 粗略估算：按 UTF-8 字节的三分之一计，偏向高估；图片按固定值，加密推理不计入。 */
export function roughTokens(value: string | ContextItem[]): number {
  if (typeof value === 'string') return Math.ceil(Buffer.byteLength(value) / 3);
  let tokens = 0;
  for (const item of value) {
    if (item.type === 'tool_result') {
      const { images, ...rest } = item.result;
      tokens += roughTokens(JSON.stringify(rest)) + (images?.length ?? 0) * IMAGE_TOKENS;
    } else if (item.type === 'output') {
      const { encrypted_content: _, ...raw } = item.item.raw;
      tokens += roughTokens(JSON.stringify(raw));
    } else tokens += roughTokens(JSON.stringify(item));
  }
  return tokens;
}

function truncate(text: string, tokens: number): string {
  const bytes = Buffer.from(text);
  if (bytes.length <= tokens * 3) return text;
  // 按字节截取后去掉可能被切开的末尾字符。
  return bytes.subarray(0, tokens * 3).toString('utf8').replace(/�+$/, '') + '\n……（后文已截断，要点见摘要）';
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

export function compactInstructions(definition: ContextDefinition, range: string): string {
  return assembleContext({ definition, bindings: {
    'compaction.range': { text: range }, 'compaction.summary': { text: '' },
  } satisfies Record<ContextVariable<'thread.compact'>, ContextBinding> }).instructions;
}

/**
 * 范围的替代内容，依次为：保留的人发消息、摘要、净文件变化、仍然有效的状态通知。
 * range 与 after 是范围内和范围之后实际进入请求的条目（已应用更早的压缩）。
 */
export function compactionItems(options: {
  range: ContextItem[]; after: ContextItem[]; automatic: boolean; summary: string;
  definition: ContextDefinition; files?: { changes: string; definition?: ContextDefinition };
}): ContextItem[] {
  const { range, after } = options;
  const retained: ContextItem[] = [];
  if (options.automatic) {
    let budget = RETAINED_HUMAN_TOKENS;
    for (const item of range.toReversed()) {
      if (item.type !== 'input' || item.input.source !== 'human') continue;
      const tokens = roughTokens(item.input.text);
      if (tokens > budget) {
        // 最新一条超出时截断保留；更早的消息只进摘要。
        if (!retained.length) retained.push({ type: 'input', input: { ...item.input, text: truncate(item.input.text, budget) } });
        break;
      }
      retained.unshift(item);
      budget -= tokens;
    }
  }
  const wrapped = assembleContext({ definition: options.definition, bindings: {
    'compaction.range': { text: '' }, 'compaction.summary': { text: options.summary },
  } satisfies Record<ContextVariable<'thread.compact'>, ContextBinding> }).input!;
  const items: ContextItem[] = [...retained, { type: 'notification', text: wrapped,
    notification: { id: randomUUID(), kind: 'context.summary', source: 'host.compaction', authority: 'observation' } }];
  if (options.files) items.push({ type: 'notification',
    text: assembleContext(fileChangesContext(options.files.changes, '包括 agent 自己与其他来源的改动', options.files.definition)).instructions,
    notification: { id: randomUUID(), kind: 'files.changed', source: 'host.compaction', authority: 'observation' } });
  const later = new Set(after.flatMap((item) => item.type === 'notification' ? [item.notification.kind] : []));
  const latest = new Map<string, ContextItem>();
  for (const item of range) {
    if (item.type === 'notification' && isState(item.notification.kind) && !later.has(item.notification.kind)) latest.set(item.notification.kind, item);
  }
  items.push(...range.filter((item) => [...latest.values()].includes(item)));
  return structuredClone(items);
}
