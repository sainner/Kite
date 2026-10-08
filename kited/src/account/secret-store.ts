/** Git 授权与通用密钥共用存储；密文绑定用户、作用域和名称，查询列表不解密。 */
import type { Database } from 'bun:sqlite';
import { createCipheriv, createDecipheriv, hkdfSync, randomBytes } from 'node:crypto';
import type { SecretValue } from '../secrets.ts';

interface Entry { name: string; kind: SecretValue['kind']; label: string; updatedAt: number }

export class SecretStore {
  private readonly cipher: CredentialCipher;

  constructor(private db: Database, secret: string) {
    this.cipher = new CredentialCipher(secret);
    db.exec(`CREATE TABLE IF NOT EXISTS kite_credential (
      userId TEXT NOT NULL, scope TEXT NOT NULL, name TEXT NOT NULL,
      kind TEXT NOT NULL, label TEXT NOT NULL, secret TEXT NOT NULL, updatedAt INTEGER NOT NULL,
      PRIMARY KEY (userId, scope, name)
    )`);
  }

  list(user: string, scope: string): Entry[] {
    return this.db.query<Entry, [string, string]>(
      'SELECT name, kind, label, updatedAt FROM kite_credential WHERE userId = ? AND scope = ? ORDER BY name').all(user, scope);
  }

  get(user: string, scope: string, name: string): SecretValue | null {
    const row = this.db.query<{ kind: SecretValue['kind']; secret: string }, [string, string, string]>(
      'SELECT kind, secret FROM kite_credential WHERE userId = ? AND scope = ? AND name = ?').get(user, scope, name);
    return row ? { kind: row.kind, value: this.cipher.open(user, `${scope}\n${name}\n${row.kind}`, row.secret) } : null;
  }

  set(user: string, scope: string, name: string, value: SecretValue, updatedAt: number, label = ''): void {
    this.db.query(`INSERT INTO kite_credential VALUES (?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(userId, scope, name) DO UPDATE SET kind=excluded.kind, label=excluded.label, secret=excluded.secret, updatedAt=excluded.updatedAt`)
      .run(user, scope, name, value.kind, label, this.cipher.seal(user, `${scope}\n${name}\n${value.kind}`, value.value), updatedAt);
  }

  delete(user: string, scope: string, name: string): void {
    this.db.query('DELETE FROM kite_credential WHERE userId = ? AND scope = ? AND name = ?').run(user, scope, name);
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
