/** 单写者 JSONL。同步落盘让输入交接与副作用放行处于同一个短同步段。 */
import { closeSync, existsSync, fsyncSync, ftruncateSync, mkdirSync, openSync, readFileSync, writeSync } from 'node:fs';
import { dirname } from 'node:path';
import { randomUUID } from 'node:crypto';
import { z } from 'zod';
import { contextSnapshotSchema } from './context/assembler.ts';
import type { Journal, JournalEvent, JournalRecord } from './types.ts';

const id = z.string().min(1);
const raw = z.record(z.string(), z.json());
const input = z.object({ id, text: z.string(), source: z.enum(['human', 'kite']) });
const call = z.object({ id, name: id, arguments: z.json() });
const item = z.object({ id, raw, call: call.optional() });
const result = z.object({ status: z.enum(['success', 'error', 'not_executed', 'unknown']), output: z.string() });
const outcome = z.discriminatedUnion('kind', [
  z.object({ kind: z.literal('completed') }), z.object({ kind: z.literal('interrupted') }),
  z.object({ kind: z.literal('failed'), message: z.string() }),
  z.object({ kind: z.literal('needs_recovery'), message: z.string() }),
]);
const request = { turnId: id, requestId: id };
const event = z.discriminatedUnion('type', [
  z.object({ type: z.literal('input.received'), input }),
  z.object({ type: z.literal('input.cancelled'), inputId: id }),
  z.object({ type: z.literal('turn.started'), turnId: id }),
  z.object({ type: z.literal('context.prepared'), snapshot: contextSnapshotSchema }),
  z.object({ type: z.literal('request.started'), ...request, inputIds: z.array(id), contextId: id.optional() }),
  z.object({ type: z.literal('model.item'), ...request, item }),
  z.object({ type: z.literal('request.completed'), ...request, responseId: id, needsFollowUp: z.boolean(), usage: raw.optional() }),
  z.object({ type: z.literal('request.failed'), ...request, message: z.string() }),
  z.object({ type: z.literal('tool.started'), ...request, callId: id }),
  z.object({ type: z.literal('tool.finished'), ...request, callId: id, result }),
  z.object({ type: z.literal('turn.feedback'), turnId: id, text: z.string() }),
  z.object({ type: z.literal('turn.finished'), turnId: id, outcome }),
  z.object({ type: z.literal('recovery.confirmed') }),
]);
const record = z.intersection(
  z.object({ version: z.literal(1), seq: z.number().int().positive(), at: z.number().int().nonnegative() }), event,
);

function writeAll(fd: number, bytes: Buffer): void {
  let offset = 0;
  while (offset < bytes.length) {
    const written = writeSync(fd, bytes, offset, bytes.length - offset);
    if (written === 0) throw new Error('会话记录写入未取得进展');
    offset += written;
  }
  fsyncSync(fd);
}

function parseCompleteRecords(bytes: Buffer): { rows: JournalRecord[]; end: number } {
  const end = bytes.lastIndexOf(10) + 1;
  const rows = bytes.subarray(0, end).toString('utf8').split('\n').slice(0, -1).map((line, index) => {
    const row = record.parse(JSON.parse(line));
    if (row.seq !== index + 1) throw new Error('会话记录序号不连续');
    return row;
  });
  return { rows, end };
}

/** 历史读取不取得写锁、不修复尾行，也不启动会话；只接受已完整落盘的记录。 */
export function readJournal(path: string): JournalRecord[] {
  return existsSync(path) ? parseCompleteRecords(readFileSync(path)).rows : [];
}

export class FileJournal implements Journal {
  private rows: JournalRecord[] = [];
  private fd: number;
  private failed = false;
  private closed = false;

  constructor(readonly path: string) {
    mkdirSync(dirname(path), { recursive: true });
    const existed = existsSync(path);
    this.fd = openSync(path, 'a+', 0o600);
    try {
      const bytes = readFileSync(path);
      const { rows, end } = parseCompleteRecords(bytes);
      this.rows = rows;
      if (end < bytes.length) {
        const backup = openSync(`${path}.partial-${randomUUID()}`, 'wx', 0o600);
        try { writeAll(backup, bytes.subarray(end)); } finally { closeSync(backup); }
        // 先让诊断副本的目录项落盘，再截断原文件。
        this.syncDirectory();
        ftruncateSync(this.fd, end);
      }
      fsyncSync(this.fd);
      if (!existed) this.syncDirectory();
    } catch (error) {
      closeSync(this.fd);
      throw new Error(`无法加载会话记录 ${path}：${String(error)}`, { cause: error });
    }
  }

  get records(): readonly JournalRecord[] { return this.rows; }

  append(data: JournalEvent): JournalRecord {
    if (this.closed || this.failed) throw new Error('会话记录已关闭或发生写入故障，必须重新打开');
    // 先编码再校验，内存副本与实际落盘内容保持一致，调用方不能修改已接收的数据。
    const row = record.parse(JSON.parse(JSON.stringify({ ...data, version: 1, seq: this.rows.length + 1, at: Date.now() })));
    try {
      writeAll(this.fd, Buffer.from(`${JSON.stringify(row)}\n`));
    } catch (error) {
      this.failed = true;
      throw error;
    }
    this.rows.push(row);
    return row;
  }

  close(): void {
    if (!this.closed) { this.closed = true; closeSync(this.fd); }
  }

  private syncDirectory(): void {
    const fd = openSync(dirname(this.path), 'r');
    try { fsyncSync(fd); } finally { closeSync(fd); }
  }
}
