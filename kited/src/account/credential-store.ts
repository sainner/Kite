/** 各类凭据共用一张表：公开信息明文存放供列表使用，保密内容加密，密文绑定用户、凭据 ID 与类型。 */
import type { Database } from 'bun:sqlite';
import { createCipheriv, createDecipheriv, hkdfSync, randomBytes } from 'node:crypto';

export type CredentialType = 'secret' | 'git' | 'api';
export interface Credential {
  id: string;
  type: CredentialType;
  /** 空表示账号共享。 */
  projectId: string | null;
  name: string;
  meta: Record<string, unknown>;
  createdAt: number;
  updatedAt: number;
}
interface Row extends Omit<Credential, 'meta'> { meta: string; sealed: string }

export class CredentialConflictError extends Error {}

export class CredentialStore {
  private readonly cipher: CredentialCipher;

  constructor(private db: Database, secret: string) {
    this.cipher = new CredentialCipher(secret);
    // 旧表按作用域字符串混放三类凭据，在研期间不迁移，重新绑定即可。
    db.exec(`DROP TABLE IF EXISTS kite_credential;
      CREATE TABLE IF NOT EXISTS kite_credentials (
        id TEXT PRIMARY KEY, userId TEXT NOT NULL, type TEXT NOT NULL, projectId TEXT, name TEXT NOT NULL,
        meta TEXT NOT NULL, sealed TEXT NOT NULL, createdAt INTEGER NOT NULL, updatedAt INTEGER NOT NULL
      );
      CREATE UNIQUE INDEX IF NOT EXISTS kite_credentials_name ON kite_credentials (userId, type, coalesce(projectId, ''), name);`);
  }

  /** projectId 为 null 时只列账号共享。 */
  list(user: string, projectId: string | null, type?: CredentialType): Credential[] {
    return this.db.query<Row, [string, string, string | null]>(`SELECT * FROM kite_credentials
      WHERE userId = ?1 AND coalesce(projectId, '') = ?2 AND (?3 IS NULL OR type = ?3) ORDER BY type, name, createdAt`)
      .all(user, projectId ?? '', type ?? null).map(view);
  }

  get(user: string, id: string): Credential | null {
    const row = this.row(user, id);
    return row ? view(row) : null;
  }

  find(user: string, type: CredentialType, projectId: string | null, name: string): Credential | null {
    const row = this.db.query<Row, [string, string, string, string]>(
      `SELECT * FROM kite_credentials WHERE userId = ? AND type = ? AND coalesce(projectId, '') = ? AND name = ?`)
      .get(user, type, projectId ?? '', name);
    return row ? view(row) : null;
  }

  /** 解开保密内容；凭据不属于该用户时为 null。 */
  open<T>(user: string, id: string): T | null {
    const row = this.row(user, id);
    return row ? JSON.parse(this.cipher.open(user, `${row.id}\n${row.type}`, row.sealed)) as T : null;
  }

  create(user: string, entry: Omit<Credential, 'id' | 'createdAt' | 'updatedAt'>, secret: unknown, now: number): Credential {
    const id = crypto.randomUUID();
    uniqueName(() => this.db.query('INSERT INTO kite_credentials VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)').run(id, user, entry.type, entry.projectId,
      entry.name, JSON.stringify(entry.meta), this.cipher.seal(user, `${id}\n${entry.type}`, JSON.stringify(secret)), now, now));
    return this.get(user, id)!;
  }

  /** 保密内容为 undefined 时保留原值。 */
  update(user: string, id: string, change: { name: string; meta: Record<string, unknown>; secret?: unknown }, now: number): Credential {
    const row = this.row(user, id)!;
    const sealed = change.secret === undefined ? row.sealed : this.cipher.seal(user, `${row.id}\n${row.type}`, JSON.stringify(change.secret));
    uniqueName(() => this.db.query('UPDATE kite_credentials SET name = ?, meta = ?, sealed = ?, updatedAt = ? WHERE id = ? AND userId = ?')
      .run(change.name, JSON.stringify(change.meta), sealed, now, id, user));
    return this.get(user, id)!;
  }

  delete(user: string, id: string): void {
    this.db.query('DELETE FROM kite_credentials WHERE id = ? AND userId = ?').run(id, user);
  }

  private row(user: string, id: string): Row | null {
    return this.db.query<Row, [string, string]>('SELECT * FROM kite_credentials WHERE id = ? AND userId = ?').get(id, user);
  }
}

function view({ sealed: _sealed, meta, ...row }: Row): Credential {
  return { ...row, meta: JSON.parse(meta) as Record<string, unknown> };
}

/** 同一作用域内同类凭据重名时报 CredentialConflictError。 */
function uniqueName(write: () => void): void {
  try { write(); } catch (error) {
    if (error instanceof Error && /UNIQUE constraint failed/.test(error.message)) throw new CredentialConflictError();
    throw error;
  }
}

class CredentialCipher {
  private readonly key: Buffer;

  constructor(secret: string) {
    this.key = Buffer.from(hkdfSync('sha256', secret, 'kite-account', 'credentials', 32));
  }

  seal(userId: string, resource: string, plain: string): string {
    const iv = randomBytes(12);
    const cipher = createCipheriv('aes-256-gcm', this.key, iv);
    cipher.setAAD(Buffer.from(`${userId}\n${resource}`));
    const body = Buffer.concat([cipher.update(plain, 'utf8'), cipher.final()]);
    return Buffer.concat([iv, cipher.getAuthTag(), body]).toString('base64');
  }

  open(userId: string, resource: string, sealed: string): string {
    const raw = Buffer.from(sealed, 'base64');
    const decipher = createDecipheriv('aes-256-gcm', this.key, raw.subarray(0, 12));
    decipher.setAAD(Buffer.from(`${userId}\n${resource}`));
    decipher.setAuthTag(raw.subarray(12, 28));
    return Buffer.concat([decipher.update(raw.subarray(28)), decipher.final()]).toString('utf8');
  }
}
