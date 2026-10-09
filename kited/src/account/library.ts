/**
 * 资源库：角色、上下文模板、点阵签名与插件包按账号保存，各工作机拉取后缓存使用。
 * 服务只做存储和版本校验，内容的格式由写入的工作机按自己的契约校验。
 */
import type { Database } from 'bun:sqlite';
import { createHash } from 'node:crypto';
import { z } from 'zod';

export const libraryKind = z.enum(['role', 'template', 'emblem', 'plugin']);
export type LibraryKind = z.infer<typeof libraryKind>;
export const libraryWrite = z.object({
  /** null 表示新建，同 ID 已有不同内容时冲突；省略表示不做版本校验，用于签名这类后写为准的内容。 */
  expectedRevision: z.string().min(1).nullable().optional(),
  body: z.record(z.string(), z.unknown()),
}).strict();

export interface LibraryItem { kind: LibraryKind; id: string; revision: string; updatedAt: number; body: Record<string, unknown> }
interface Row { kind: LibraryKind; id: string; revision: string; updatedAt: number; body: string }

export class LibraryConflict extends Error {}

/**
 * 在线工作机的资源库事件流。账号的资源库或项目约束变了就往它的各条流里发一条 changed，工作机收到后全量同步。
 * 连上先发一条 ready，工作机据此做重连后的同步；之后每 25 秒一次心跳，工作机靠它发现断线。
 */
export class LibraryEvents {
  private listeners = new Set<{ userId: string; send(text: string): void; close(): void }>();
  private encoder = new TextEncoder();

  notify(userId: string): void {
    for (const listener of this.listeners) if (listener.userId === userId) listener.send('data: changed\n\n');
  }

  open(userId: string, request: Request): Response {
    const { listeners, encoder } = this;
    let heartbeat: Timer | undefined;
    let listener: { userId: string; send(text: string): void; close(): void } | undefined;
    const stop = () => {
      clearInterval(heartbeat);
      if (listener) listeners.delete(listener);
    };
    const body = new ReadableStream<Uint8Array>({
      start(controller) {
        const current = listener = {
          userId,
          // 连接已断时写入会抛错，这时只把这条流摘掉。
          send: (text: string) => { try { controller.enqueue(encoder.encode(text)); } catch { stop(); } },
          close: () => { stop(); try { controller.close(); } catch {} },
        };
        listeners.add(current);
        current.send('data: ready\n\n');
        heartbeat = setInterval(() => current.send(': \n\n'), 25_000);
        request.signal.addEventListener('abort', current.close);
      },
      cancel: stop,
    });
    return new Response(body, { headers: { 'content-type': 'text/event-stream', 'cache-control': 'no-store', 'x-accel-buffering': 'no' } });
  }

  /** 停机前断开全部事件流，否则服务会一直等这些长连接结束。 */
  close(): void {
    for (const listener of [...this.listeners]) listener.close();
  }
}

/** 版本是内容的摘要，与工作机按同一份 JSON 算出的版本一致。 */
const revisionOf = (text: string) => createHash('sha256').update(text).digest('hex');

export class Library {
  constructor(private db: Database) {
    db.exec(`CREATE TABLE IF NOT EXISTS kite_library (
      userId TEXT NOT NULL, kind TEXT NOT NULL, id TEXT NOT NULL, body TEXT NOT NULL, revision TEXT NOT NULL, updatedAt INTEGER NOT NULL,
      PRIMARY KEY (userId, kind, id)
    )`);
  }

  /** 插件包的代码只在单独读取时给出，列表里只有元数据；代码在 SQL 里去掉，不解析整个包。 */
  list(userId: string): LibraryItem[] {
    return this.db.query<Row, [string]>(`SELECT kind, id, revision, updatedAt,
      CASE kind WHEN 'plugin' THEN json_remove(body, '$.bundle') ELSE body END AS body FROM kite_library WHERE userId = ? ORDER BY kind, id`).all(userId)
      .map((row) => ({ ...row, body: JSON.parse(row.body) }));
  }

  get(userId: string, kind: LibraryKind, id: string): LibraryItem | undefined {
    const row = this.db.query<Row, [string, string, string]>('SELECT kind, id, revision, updatedAt, body FROM kite_library WHERE userId = ? AND kind = ? AND id = ?')
      .get(userId, kind, id);
    return row ? { ...row, body: JSON.parse(row.body) } : undefined;
  }

  put(userId: string, kind: LibraryKind, id: string, write: z.infer<typeof libraryWrite>, now: number): LibraryItem {
    const text = JSON.stringify(write.body);
    const revision = revisionOf(text);
    return this.db.transaction(() => {
      const current = this.db.query<{ revision: string }, [string, string, string]>('SELECT revision FROM kite_library WHERE userId = ? AND kind = ? AND id = ?')
        .get(userId, kind, id);
      if (write.expectedRevision === null && current && current.revision !== revision) throw new LibraryConflict('同 ID 已有其他内容，请另存为新的条目');
      // 账号里还没有这一项时按新建处理：工作机上首次修改内置内容，没有其他设备的修改会被覆盖。
      if (write.expectedRevision && current && current.revision !== write.expectedRevision) throw new LibraryConflict('内容已被其他设备修改，请刷新后重试');
      this.db.query(`INSERT INTO kite_library VALUES (?, ?, ?, ?, ?, ?)
        ON CONFLICT(userId, kind, id) DO UPDATE SET body = excluded.body, revision = excluded.revision, updatedAt = excluded.updatedAt`)
        .run(userId, kind, id, text, revision, now);
      return { kind, id, revision, updatedAt: now, body: write.body };
    })();
  }
}
