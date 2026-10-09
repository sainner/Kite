/** Claude 原生消息、输入身份与分块序号的显示转换；记录与增量由公共投影保存。 */
import type { ClaudeState } from '../claude/control.ts';
import { claudeToolName, claudeToolResult, object, structuredClaudeTool } from '../claude/tools.ts';
import { claudeInputTokens } from '../claude/usage.ts';
import type { DisplayBlock, DisplayDelta, DisplayRecord, DisplayState, PendingInput } from './protocol.ts';

interface ClaudeProjectionTarget {
  records: ReadonlyMap<string, DisplayRecord>;
  streamIds: Map<string, string>;
  replaying(): boolean;
  stopping(): boolean;
  put(record: DisplayRecord): void;
  delta(delta: DisplayDelta): void;
  endDrafts(): void;
  context(value: DisplayState['context']): void;
}

const textParts = (value: unknown, separator = ''): string => Array.isArray(value)
  ? value.map((part) => object(part).text).filter((text) => typeof text === 'string').join(separator) : '';

export class ClaudeProjection {
  private structuredCalls = new Set<string>();
  private inputs = new Map<string, ClaudeState['inputs'][number]>();
  private messageId = '';
  private index = 0;
  private offsets = new Map<string, number>();
  private rows = new Map<string, number>();
  private usage: Record<string, number> = {};

  constructor(private target: ClaudeProjectionTarget) {}

  get hasInputs(): boolean { return this.inputs.size > 0; }
  get hasUnconfirmedInput(): boolean { return [...this.inputs.values()].some((entry) => entry.status === 'unconfirmed'); }

  syncInputs(state: ClaudeState, pending: Map<string, PendingInput>): void {
    for (const entry of state.inputs) {
      this.inputs.set(entry.sdkId, entry);
      if (['queued', 'submitted', 'unconfirmed'].includes(entry.status) || (entry.status === 'active' && !entry.delivered)) pending.set(entry.input.id, { ...entry.input, midTurn: entry.midTurn });
      if (!this.target.replaying() && entry.delivered && !this.target.records.has(`input:${entry.input.id}`)) {
        this.target.put({ id: `input:${entry.input.id}`, at: entry.at, block: entry.input.source === 'human'
          ? { type: 'human', id: entry.input.id, text: entry.input.text, midTurn: entry.midTurn } : { type: 'kite', text: entry.input.text } });
      }
    }
  }

  restoreInputs(): void {
    // 宿主已确认收下、但 CLI 尚未来得及写入原生历史的输入仍然可见，不自动重放。
    for (const entry of this.inputs.values()) {
      if (!entry.delivered || entry.status === 'cancelled' || this.target.records.has(`input:${entry.input.id}`)) continue;
      this.target.put({ id: `input:${entry.input.id}`, at: entry.at, block: entry.input.source === 'human'
        ? { type: 'human', id: entry.input.id, text: entry.input.text, midTurn: entry.midTurn } : { type: 'kite', text: entry.input.text } });
    }
  }

  /** SDK 的增量、完整块和历史统一使用消息 ID + 块序号，工具始终以 call ID 对齐。 */
  message(value: unknown, at: number): void {
    const row = object(value);
    if (row.type === 'stream_event') {
      const event = object(row.event);
      if (event.type === 'message_start') {
        this.messageId = object(event.message).id; this.index = 0; this.usage = object(object(event.message).usage);
      }
      if (!this.messageId) return;
      const id = `claude:${this.messageId}:${event.index}`;
      if (event.type === 'content_block_start') {
        this.index = event.index;
        const block = object(event.content_block);
        const key = block.type === 'tool_use' ? `call:${block.id}` : id;
        this.target.streamIds.set(id, key);
        if (block.type === 'tool_use') this.target.put({ id: key, at, generation: 'streaming', block: {
          type: 'tool_use', id: block.id, name: claudeToolName(block.name), input: null, arguments: '', stage: 'generating', batch: this.messageId } });
        else if (block.type === 'text' || block.type === 'thinking') this.target.put({ id: key, at, generation: 'streaming',
          block: { type: block.type, text: block.text ?? block.thinking ?? '' } });
      } else if (event.type === 'content_block_delta') {
        const delta = object(event.delta);
        const key = this.target.streamIds.get(id);
        if (key && this.target.records.get(key)?.generation === 'streaming') {
          if (delta.type === 'input_json_delta') this.target.delta({ id: key, field: 'arguments', text: delta.partial_json });
          else if (delta.type === 'text_delta' || delta.type === 'thinking_delta') this.target.delta({ id: key, field: 'text', text: delta.text ?? delta.thinking });
        }
      } else if (event.type === 'message_delta') {
        const usage = this.usage = { ...this.usage, ...object(event.usage) };
        this.updateContext(this.messageId, usage, at);
      }
      return;
    }
    if (typeof row.uuid !== 'string') return;
    const message = object(row.message);
    if (row.type === 'assistant' && message.usage) this.updateContext(message.id ?? row.uuid, object(message.usage), at);
    const parent = typeof row.parent_tool_use_id === 'string' ? row.parent_tool_use_id : undefined;
    const content = typeof message.content === 'string' ? [{ type: 'text', text: message.content }] : message.content;
    const offset = this.rows.get(row.uuid) ?? (message.id === this.messageId ? this.index : this.offsets.get(message.id) ?? 0);
    this.rows.set(row.uuid, offset);
    if (message.id) this.offsets.set(message.id, offset + (Array.isArray(content) ? content.length : 0));
    const put = (id: string, block: DisplayBlock, generation: DisplayRecord['generation'] = 'complete') =>
      this.target.put({ id, at: this.target.replaying() && at > 0 ? at : this.target.records.get(id)?.at ?? at, ...(parent ? { parent } : {}), generation, block });
    if (Array.isArray(content)) content.forEach((part, index) => {
      const block = object(part);
      const id = `claude:${message.id ?? row.uuid}:${offset + index}`;
      if (block.type === 'text' && typeof block.text === 'string') {
        if (row.type === 'user') {
          const entry = this.inputs.get(row.uuid);
          if (entry?.status === 'cancelled') return;
          const inputId = entry?.input.id ?? row.uuid;
          const text = entry?.input.text ?? block.text;
          // user 是传输角色，原生中断及 hook 反馈也使用它；只有明确的人类来源才显示成人发消息。
          const human = entry ? entry.input.source === 'human' : object(row.origin).kind === 'human';
          put(`input:${inputId}`, human ? { type: 'human', id: inputId, text, midTurn: entry?.midTurn ?? false } : { type: 'kite', text });
        } else put(id, { type: 'text', text: block.text });
      } else if (block.type === 'thinking' && typeof block.thinking === 'string') put(id, { type: 'thinking', text: block.thinking });
      else if (block.type === 'tool_use') {
        const name = claudeToolName(block.name);
        if (structuredClaudeTool(block.name)) this.structuredCalls.add(block.id);
        const previous = this.target.records.get(`call:${block.id}`)?.block;
        put(`call:${block.id}`, { ...(previous?.type === 'tool_use' ? previous : {}), type: 'tool_use', id: block.id,
          name, input: block.input, arguments: JSON.stringify(block.input), batch: message.id,
          stage: previous?.type === 'tool_use' && ['running', 'finished'].includes(previous.stage ?? '') ? previous.stage : 'queued' });
      } else if (block.type === 'tool_result') {
        let result: ReturnType<typeof claudeToolResult>;
        try { result = claudeToolResult(block, this.structuredCalls.has(block.tool_use_id)); }
        catch { result = { status: block.is_error ? 'error' : 'success', output: typeof block.content === 'string' ? block.content : textParts(block.content) }; }
        const { output, diff, status } = result;
        const call = this.target.records.get(`call:${block.tool_use_id}`);
        if (call?.block.type === 'tool_use') this.target.put({ ...call, block: { ...call.block, stage: 'finished' } });
        put(`result:${block.tool_use_id}`, { type: 'tool_result', call: block.tool_use_id, output, ...(diff ? { diff } : {}), status });
      }
    });
    if (row.type === 'system' && row.subtype === 'compact_boundary') put(`${row.uuid}:0`, { type: 'compacted', text: '' });
    if (row.type === 'result') {
      this.target.endDrafts();
      if (this.target.stopping() && ['aborted_tools', 'aborted_streaming'].includes(row.terminal_reason)) put(`${row.uuid}:0`, { type: 'interrupted' });
      else if (row.is_error) put(`${row.uuid}:0`, { type: 'error', text: Array.isArray(row.errors) ? row.errors.join('\n') : '模型执行失败' });
    }
  }

  private updateContext(requestId: string, usage: Record<string, any>, at: number): void {
    const inputTokens = claudeInputTokens(usage);
    this.target.context(inputTokens === undefined ? undefined : { requestId, inputTokens, measuredAt: at });
  }
}
