/**
 * 远程设备配对：本机生成一次性配对码，远程客户端用它换取每台设备独立的令牌。
 * 数据库只存令牌摘要；撤销设备同时断开它的事件流。
 */
import type { Database } from 'bun:sqlite';
import { createHash, randomBytes, randomInt, randomUUID } from 'node:crypto';
import { KiteError } from './errors.ts';

export interface Device { id: string; name: string; createdAt: number; lastSeenAt: number | null }
export interface Pairing { code: string; expiresAt: number }

/** 去掉容易混淆的 0/O/1/I/L，方便在手机上手输。 */
const ALPHABET = '23456789ABCDEFGHJKMNPQRSTUVWXYZ';
const CODE_TTL = 10 * 60_000;
/** 最近使用时间只用于设备列表，不必每个请求都写库。 */
const SEEN_PRECISION = 60_000;

const digest = (token: string) => createHash('sha256').update(token).digest('hex');
const normalize = (code: string) => code.toUpperCase().replace(/[^0-9A-Z]/g, '');
const deviceOf = (r: any): Device => ({ id: r.id, name: r.name, createdAt: r.created_at, lastSeenAt: r.last_seen_at });

export class Devices {
  private codes = new Map<string, number>();
  private streams = new Map<string, Set<() => void>>();

  constructor(private db: Database) {
    db.exec(`create table if not exists devices (
      id text primary key, name text not null, token_hash text not null unique, created_at integer not null, last_seen_at integer
    )`);
  }

  /** 配对码只在内存中保存，服务重启即失效。 */
  createPairing(now = Date.now()): Pairing {
    for (const [code, expiresAt] of this.codes) if (expiresAt <= now) this.codes.delete(code);
    const raw = Array.from({ length: 8 }, () => ALPHABET[randomInt(ALPHABET.length)]).join('');
    const expiresAt = now + CODE_TTL;
    this.codes.set(raw, expiresAt);
    return { code: `${raw.slice(0, 4)}-${raw.slice(4)}`, expiresAt };
  }

  pair(code: string, name: string, now = Date.now()): { device: Device; token: string } {
    const key = normalize(code);
    const expiresAt = this.codes.get(key);
    this.codes.delete(key); // 一次有效。
    if (expiresAt === undefined || expiresAt <= now) throw new KiteError('配对码无效或已过期，请在工作机上重新生成', 401);
    const token = randomBytes(32).toString('base64url');
    const device: Device = { id: randomUUID(), name: name.trim().slice(0, 80) || '未命名设备', createdAt: now, lastSeenAt: now };
    this.db.query('insert into devices values (?, ?, ?, ?, ?)').run(device.id, device.name, digest(token), device.createdAt, device.lastSeenAt);
    return { device, token };
  }

  authenticate(token: string, now = Date.now()): Device | undefined {
    const row = this.db.query('select * from devices where token_hash = ?').get(digest(token));
    if (!row) return undefined;
    const device = deviceOf(row);
    if (device.lastSeenAt === null || now - device.lastSeenAt >= SEEN_PRECISION) {
      this.db.query('update devices set last_seen_at = ? where id = ?').run(now, device.id);
      device.lastSeenAt = now;
    }
    return device;
  }

  list(): Device[] { return this.db.query('select * from devices order by created_at, id').all().map(deviceOf); }

  revoke(id: string): void {
    if (!this.db.query('delete from devices where id = ?').run(id).changes) throw new KiteError('没有这台设备', 404);
    for (const close of this.streams.get(id) ?? []) close();
    this.streams.delete(id);
  }

  /** 登记设备的长连接，撤销时由这里关闭；返回注销函数。 */
  watch(id: string, close: () => void): () => void {
    let set = this.streams.get(id);
    if (!set) this.streams.set(id, set = new Set());
    set.add(close);
    return () => { set.delete(close); if (!set.size && this.streams.get(id) === set) this.streams.delete(id); };
  }
}
