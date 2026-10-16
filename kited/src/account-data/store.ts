/**
 * 账号级数据：资源库、项目登记与约束、凭据、各工作机的目录摘要和 Kite 的发布记录。所有工作机共有，任一台都能改，见 docs/分布式架构.md。
 *
 * 每条按 (kind, id) 只存最新版本。版本是 {at, by}：at 是写入时刻，至少比被替换的版本大 1；by 是写入的工作机。
 * 每次写入同时记下它见过的各工作机写入（seen，机器 ID 到 at 的版本向量）。收到的一份见过本机这份就替换，本机这份见过它就不要；
 * 互相都没见过是并发修改，版本大的为准，另一份另存成 conflict 条目，可以找回。只比上一个版本不够：对方在并发修改之后又改过一次时，
 * 它的上一个版本比本机的新，却同样没见过本机这份。conflict 条目的 ID 由被覆盖的版本决定，几台工作机各自发现同一处冲突也只留一条。
 * 删除也是一次写入，正文为空。
 *
 * 本机每次变化取一个递增序号，其他工作机按序号增量拉取；库重建过（epoch 变了）就从头拉。
 * 凭据的保密内容落地加密：库里存本机密钥封装的密文，发给其他工作机时解开，靠组网的 WireGuard 加密传输，对方用自己的密钥重新封装。
 */
import { Database } from 'bun:sqlite';
import { createCipheriv, createDecipheriv, createHash, randomBytes } from 'node:crypto';
import { KiteError } from '../errors.ts';

export type EntryKind = 'role' | 'template' | 'emblem' | 'plugin' | 'project' | 'constraints' | 'credential' | 'catalog' | 'release' | 'conflict';
type Body = Record<string, unknown>;

export interface Version { at: number; by: string }
/** 版本向量：这一版见过的各工作机的写入，机器 ID 到它写入的 at。 */
type Seen = Record<string, number>;
export interface Item { kind: EntryKind; id: string; body: Body; revision: string; at: number; by: string }
/** 在工作机之间传的形式：body 为 null 表示删除，凭据的保密内容是明文。 */
export interface WireEntry { kind: EntryKind; id: string; body: Body | null; at: number; by: string; seen: Seen }
export interface Changes { epoch: string; seq: number; entries: WireEntry[]; more: boolean }

interface Row { kind: EntryKind; id: string; body: string | null; revision: string | null; at: number; by: string; seen: string; seq: number }

/** 版本是内容的摘要：写入方按同一份 JSON 算出的版本一致，资源库缓存的期望版本也按它算。 */
export const revisionOf = (body: unknown) => createHash('sha256').update(JSON.stringify(body)).digest('hex');
const compare = (a: Version, b: Version) => a.at - b.at || (a.by < b.by ? -1 : a.by > b.by ? 1 : 0);
const conflictId = (kind: EntryKind, id: string, version: Version) => `${kind}:${id}:${version.at}:${version.by}`;
/** a 相对 b：after 是见过 b 的后续版本，before 是 b 见过的旧版本，concurrent 是互相没见过。 */
function relation(a: Seen, b: Seen): 'after' | 'before' | 'same' | 'concurrent' {
  let ahead = false;
  let behind = false;
  for (const machine of new Set([...Object.keys(a), ...Object.keys(b)])) {
    const x = a[machine] ?? 0;
    const y = b[machine] ?? 0;
    if (x > y) ahead = true;
    if (x < y) behind = true;
  }
  return ahead ? (behind ? 'concurrent' : 'after') : behind ? 'before' : 'same';
}
/** 一页最多带这么多正文字节；插件包可能有几 MB，单条超过时自己成一页。 */
const PAGE_BYTES = 4 * 1024 * 1024;

export class AccountData {
  private db: Database;
  readonly epoch: string;
  private listeners = new Set<(changed: Array<{ kind: EntryKind; id: string }>) => void>();
  private waiters = new Set<() => void>();
  private key?: Promise<Buffer>;
  private closed = false;

  /** loadKey 取凭据的封装密钥，第一次封装或解开时才调用。 */
  constructor(path: string, readonly machineId: string, private loadKey: () => Promise<Buffer>) {
    this.db = new Database(path, { create: true, strict: true });
    this.db.exec(`pragma journal_mode = wal;
      create table if not exists meta (key text primary key, value text not null);
      create table if not exists entries (
        kind text not null, id text not null, body text, revision text, at integer not null, by text not null,
        seen text not null, seq integer not null unique, primary key (kind, id)
      );
      create table if not exists cursors (machine text primary key, epoch text not null, seq integer not null);`);
    this.db.query("insert or ignore into meta values ('epoch', ?)").run(crypto.randomUUID());
    this.epoch = (this.db.query("select value from meta where key = 'epoch'").get() as { value: string }).value;
  }

  /** 先放掉挂着等变化的拉取，再关库；之后等待立即返回。 */
  close(): void {
    this.closed = true;
    for (const waiter of [...this.waiters]) waiter();
    this.db.close();
  }

  get seq(): number {
    return (this.db.query('select coalesce(max(seq), 0) as seq from entries').get() as { seq: number }).seq;
  }

  get(kind: EntryKind, id: string): Item | undefined {
    const row = this.row(kind, id);
    return row?.body == null ? undefined : item(row);
  }

  /** 删过的条目；从没收到过的不算，重建过的库从头拉取期间不会把还没拉到的当成删了。 */
  removed(kind: EntryKind, id: string): boolean {
    const row = this.row(kind, id);
    return !!row && row.body == null;
  }

  /** 现有的条目；omit 列出的顶层字段在 SQL 里去掉，例如插件包列表不带代码。 */
  list(kind: EntryKind, omit: string[] = []): Item[] {
    const body = omit.reduce((expression, key) => `json_remove(${expression}, '$.${key}')`, 'body');
    return (this.db.query(`select kind, id, ${body} as body, revision, at, by, seen, seq from entries
      where kind = ? and body is not null order by id`).all(kind) as Row[]).map(item);
  }

  /**
   * 本机写入。expectedRevision 为 null 表示看到的是没有这一项：同 ID 已有不同内容就冲突；字符串须等于现有的版本；
   * 省略不做校验，用于后写为准的内容。内容与现有的相同时不写。
   */
  put(kind: EntryKind, id: string, body: Body, expectedRevision?: string | null): Item {
    const revision = revisionOf(body);
    return this.write(kind, id, (current) => {
      const live = current?.body == null ? undefined : current;
      if (expectedRevision === null && live && live.revision !== revision) throw new KiteError('同 ID 已有其他内容，请另存为新的条目', 409);
      if (expectedRevision && live?.revision !== expectedRevision) throw new KiteError('内容已被其他设备修改，请刷新后重试', 409);
      return live?.revision === revision ? undefined : { body, revision };
    })!;
  }

  /** 本机删除，expectedRevision 含义同写入；期望的就是没有这一项时不做事。返回是否删了。 */
  remove(kind: EntryKind, id: string, expectedRevision?: string | null): boolean {
    let removed = false;
    this.write(kind, id, (current) => {
      const live = current?.body == null ? undefined : current;
      if (expectedRevision !== undefined && live?.revision !== (expectedRevision ?? undefined)) {
        throw new KiteError('内容已被其他设备修改，请刷新后重试', 409);
      }
      removed = !!live;
      return live ? { body: null, revision: null } : undefined;
    });
    return removed;
  }

  subscribe(listener: (changed: Array<{ kind: EntryKind; id: string }>) => void): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  /** 本机序号超过 seq，或等满 timeoutMs、signal 中止时返回。 */
  wait(seq: number, timeoutMs: number, signal?: AbortSignal): Promise<void> {
    if (this.closed || this.seq > seq || signal?.aborted) return Promise.resolve();
    return new Promise((resolve) => {
      // 到期由定时器本身判定，不比墙钟：系统时间往回调过时也照样放行。
      const finish = () => {
        clearTimeout(timer);
        this.waiters.delete(check);
        signal?.removeEventListener('abort', finish);
        resolve();
      };
      const check = () => { if (this.closed || this.seq > seq) finish(); };
      const timer = setTimeout(finish, timeoutMs);
      this.waiters.add(check);
      signal?.addEventListener('abort', finish);
    });
  }

  /** 给其他工作机的增量：epoch 与本机不同时从头给。 */
  async changes(epoch: string | undefined, since: number): Promise<Changes> {
    if (this.closed) throw new KiteError('工作机正在停止', 503);
    const from = epoch === this.epoch ? since : 0;
    // 先只读长度定这一页取哪些，正文按需再读；插件包这类几 MB 的正文不会被反复读出又丢掉。
    const heads = this.db.query('select kind, id, seq, coalesce(length(body), 0) as size from entries where seq > ? order by seq limit 500')
      .all(from) as Array<{ kind: EntryKind; id: string; seq: number; size: number }>;
    const entries: WireEntry[] = [];
    let bytes = 0;
    let seq = from;
    for (const head of heads) {
      if (entries.length && bytes + head.size > PAGE_BYTES) break;
      const row = this.row(head.kind, head.id)!;
      bytes += head.size;
      entries.push({ kind: row.kind, id: row.id, body: row.body == null ? null : await this.unseal(row.kind, JSON.parse(row.body)),
        at: row.at, by: row.by, seen: JSON.parse(row.seen) });
      seq = head.seq;
    }
    return { epoch: this.epoch, seq, entries, more: entries.length < heads.length || heads.length === 500 };
  }

  /** 从 machine 拉到上次以后的变化，与它的进度一起写入。 */
  cursor(machine: string): { epoch: string; seq: number } | undefined {
    return this.db.query('select epoch, seq from cursors where machine = ?').get(machine) as { epoch: string; seq: number } | null ?? undefined;
  }

  /** 应用其他工作机的一页变化：见过本机这份的替换它；互相没见过时版本大的为准，另一份另存为冲突。 */
  async apply(machine: string, page: Changes): Promise<void> {
    const sealed = await Promise.all(page.entries.map(async (entry) => ({
      ...entry, body: entry.body == null ? null : await this.seal(entry.kind, entry.body) })));
    const plain = new Map(page.entries.map((entry) => [`${entry.kind}\n${entry.id}`, entry.body]));
    // 判断两份内容是否相同要比明文，本机库里的凭据要先解开。
    const locals = new Map<string, Body | null>();
    for (const entry of page.entries) {
      const row = this.row(entry.kind, entry.id);
      if (row?.body != null && row.revision == null) locals.set(`${entry.kind}\n${entry.id}`, await this.unseal(row.kind, JSON.parse(row.body)));
    }
    const changed: Array<{ kind: EntryKind; id: string }> = [];
    this.db.transaction(() => {
      for (const entry of sealed) {
        const key = `${entry.kind}\n${entry.id}`;
        const current = this.row(entry.kind, entry.id);
        if (current && compare(entry, current) === 0) continue;
        const order = current ? relation(entry.seen, JSON.parse(current.seen)) : 'after';
        if (order === 'before' || order === 'same') continue;
        const concurrent = order === 'concurrent';
        const remote = { body: plain.get(key) ?? null, revision: entry.body == null || entry.kind === 'credential' ? null : revisionOf(entry.body) };
        const local = current && { body: current.revision == null ? locals.get(key) ?? null : null, revision: current.revision };
        const same = () => !!local && (local.revision != null ? local.revision === remote.revision : JSON.stringify(local.body) === JSON.stringify(remote.body));
        if (!concurrent || compare(entry, current!) > 0) {
          if (concurrent && current!.body != null && !same()) this.saveConflict(current!.kind, current!.id, current!, JSON.parse(current!.body), changed);
          this.insert(entry.kind, entry.id, entry.body == null ? null : JSON.stringify(entry.body), remote.revision, entry, entry.seen);
          changed.push({ kind: entry.kind, id: entry.id });
        } else if (entry.body != null && !same()) {
          this.saveConflict(entry.kind, entry.id, entry, entry.body, changed);
        }
      }
      this.db.query(`insert into cursors values (?, ?, ?) on conflict(machine) do update set epoch = excluded.epoch, seq = excluded.seq`)
        .run(machine, page.epoch, page.seq);
    })();
    this.notify(changed);
  }

  /** 凭据的保密内容用本机密钥封装；其他种类原样。 */
  async seal(kind: EntryKind, body: Body): Promise<Body> {
    if (kind === 'conflict' && body.kind === 'credential' && body.body) return { ...body, body: await this.seal('credential', body.body as Body) };
    if (kind !== 'credential' || body.secret === undefined) return body;
    const { secret, ...rest } = body;
    const key = await this.sealingKey();
    const iv = randomBytes(12);
    const cipher = createCipheriv('aes-256-gcm', key, iv);
    const data = Buffer.concat([cipher.update(JSON.stringify(secret), 'utf8'), cipher.final()]);
    return { ...rest, sealed: Buffer.concat([iv, cipher.getAuthTag(), data]).toString('base64') };
  }

  async unseal(kind: EntryKind, body: Body): Promise<Body> {
    if (kind === 'conflict' && body.kind === 'credential' && body.body) return { ...body, body: await this.unseal('credential', body.body as Body) };
    if (kind !== 'credential' || typeof body.sealed !== 'string') return body;
    const { sealed, ...rest } = body;
    const raw = Buffer.from(sealed, 'base64');
    const decipher = createDecipheriv('aes-256-gcm', await this.sealingKey(), raw.subarray(0, 12));
    decipher.setAuthTag(raw.subarray(12, 28));
    return { ...rest, secret: JSON.parse(Buffer.concat([decipher.update(raw.subarray(28)), decipher.final()]).toString('utf8')) };
  }

  /** 取过一次就留着；取失败（钥匙串锁着、被拒绝）不留，下次再取。 */
  private sealingKey(): Promise<Buffer> {
    return this.key ??= this.loadKey().catch((error: unknown) => { this.key = undefined; throw error; });
  }

  private row(kind: EntryKind, id: string): Row | undefined {
    return this.db.query('select * from entries where kind = ? and id = ?').get(kind, id) as Row | null ?? undefined;
  }

  /** decide 看现有的一行，给出新内容；undefined 表示不写。凭据的版本留空，比较时解开再比。 */
  private write(kind: EntryKind, id: string, decide: (current: Row | undefined) => { body: Body | null; revision: string | null } | undefined): Item | undefined {
    let wrote = false;
    const result = this.db.transaction(() => {
      const current = this.row(kind, id);
      const next = decide(current);
      if (!next) return current?.body == null ? undefined : item(current);
      const version = { at: Math.max(Date.now(), (current?.at ?? 0) + 1), by: this.machineId };
      const revision = next.body == null || kind === 'credential' ? null : next.revision;
      const seen = { ...(current ? JSON.parse(current.seen) as Seen : {}), [this.machineId]: version.at };
      this.insert(kind, id, next.body == null ? null : JSON.stringify(next.body), revision, version, seen);
      wrote = true;
      return next.body == null ? undefined : { kind, id, body: next.body, revision: revision ?? '', ...version };
    })();
    if (wrote) this.notify([{ kind, id }]);
    return result;
  }

  private insert(kind: EntryKind, id: string, body: string | null, revision: string | null, version: Version, seen: Seen): void {
    this.db.query(`insert into entries values (?, ?, ?, ?, ?, ?, ?, (select coalesce(max(seq), 0) + 1 from entries))
      on conflict(kind, id) do update set body = excluded.body, revision = excluded.revision, at = excluded.at, by = excluded.by,
        seen = excluded.seen, seq = excluded.seq`)
      .run(kind, id, body, revision, version.at, version.by, JSON.stringify(seen));
  }

  /** 冲突条目只在本机还没有时写；它自己不再产生冲突。目录摘要与发布记录只要最新的，被覆盖的不留。 */
  private saveConflict(kind: EntryKind, id: string, version: Version, body: Body, changed: Array<{ kind: EntryKind; id: string }>): void {
    if (kind === 'conflict' || kind === 'catalog' || kind === 'release') return;
    const conflict = conflictId(kind, id, version);
    if (this.row('conflict', conflict)) return;
    const value = { kind, id, at: version.at, by: version.by, body };
    const at = Date.now();
    this.insert('conflict', conflict, JSON.stringify(value), revisionOf(value), { at, by: this.machineId }, { [this.machineId]: at });
    changed.push({ kind: 'conflict', id: conflict });
  }

  private notify(changed: Array<{ kind: EntryKind; id: string }>): void {
    if (!changed.length) return;
    for (const waiter of [...this.waiters]) waiter();
    for (const listener of [...this.listeners]) {
      try { listener(changed); } catch (error) { console.error('[账号数据] 通知失败', (error as Error).message); }
    }
  }
}

function item(row: Row): Item {
  return { kind: row.kind, id: row.id, body: JSON.parse(row.body!), revision: row.revision ?? '', at: row.at, by: row.by };
}
