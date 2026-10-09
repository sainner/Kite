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
