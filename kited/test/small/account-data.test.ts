/**
 * 账号级数据在工作机之间的合并（src/account-data/store.ts）：手动把一台的增量 changes 交给另一台 apply，
 * 看并发修改、只拉到最新的顺序修改、删除与修改相遇、经第三台中转时，各台最后是否一致、被覆盖的那份是否恰好留下一条冲突。
 * 并发时版本大的为准，用 setSystemTime 定下各台写入的先后。最后一条看本机密钥取不到时一页变化的部分写入与下次重试补齐。
 */
import { afterEach, expect, setSystemTime, test } from 'bun:test';
import { join } from 'node:path';
import { fileKey } from '../../src/account-data/key.ts';
import { AccountData } from '../../src/account-data/store.ts';
import { useTemp } from '../util.ts';

const temp = useTemp();
const opened: AccountData[] = [];
afterEach(() => {
  setSystemTime();
  for (const data of opened.splice(0)) data.close();
});

function open(root: string, machine: string): AccountData {
  const data = new AccountData(join(root, `${machine}.db`), machine, fileKey(join(root, `${machine}.key`)));
  opened.push(data);
  return data;
}

/** to 从 from 拉到上次以后的全部变化。 */
async function pull(to: AccountData, from: AccountData): Promise<void> {
  for (;;) {
    const cursor = to.cursor(from.machineId);
    const page = await from.changes(cursor?.epoch, cursor?.seq ?? 0);
    await to.apply(from.machineId, page);
    if (!page.more) return;
  }
}

/** b 先拉 a，a 再拉 b：b 发现的冲突条目也随这一轮传给 a。 */
async function exchange(a: AccountData, b: AccountData): Promise<void> {
  await pull(b, a);
  await pull(a, b);
}

/** 冲突条目的正文是被覆盖的那一版：原条目的种类、ID、版本与内容。 */
const conflicts = (data: AccountData) => data.list('conflict').map((item) => item.body);
const conflictIds = (data: AccountData) => data.list('conflict').map((item) => item.id);

test('两台工作机并发改同一条，互相同步后都以后写的为准，各留恰好一条被覆盖版本的冲突，再同步也不重复', async () => {
  const root = temp('account-data-');
  const a = open(root, 'machine-a');
  const b = open(root, 'machine-b');
  const start = Date.now();
  setSystemTime(start);
  a.put('role', 'shared', { text: '原始' });
  await exchange(a, b);
  expect(b.get('role', 'shared')?.body).toEqual({ text: '原始' });

  setSystemTime(start + 1_000);
  a.put('role', 'shared', { text: 'A 改的' });
  setSystemTime(start + 2_000);
  b.put('role', 'shared', { text: 'B 后改的' });
  setSystemTime();
  await exchange(a, b);
  for (const data of [a, b]) {
    expect(data.get('role', 'shared')).toMatchObject({ body: { text: 'B 后改的' }, by: 'machine-b' });
    expect(conflicts(data)).toEqual([expect.objectContaining({ kind: 'role', id: 'shared', by: 'machine-a', body: { text: 'A 改的' } })]);
  }
  expect(a.get('role', 'shared')!.revision).toBe(b.get('role', 'shared')!.revision);
  expect(conflicts(a)).toEqual(conflicts(b));
  expect(conflictIds(a)).toEqual(conflictIds(b));

  await exchange(a, b);
  await exchange(a, b);
  expect(conflictIds(a)).toHaveLength(1);
  expect(conflictIds(a)).toEqual(conflictIds(b));
});

test('只拉到最新版本时跳过的中间版本不算冲突；删除与另一台的并发修改相遇，以后写的删除为准，修改的那份两边各留一条冲突', async () => {
  const root = temp('account-data-');
  const a = open(root, 'machine-a');
  const b = open(root, 'machine-b');
  a.put('template', 'notes', { text: '第一版' });
  await exchange(a, b);
  a.put('template', 'notes', { text: '第二版' });
  a.put('template', 'notes', { text: '第三版' });
  await pull(b, a);
  expect(b.get('template', 'notes')?.body).toEqual({ text: '第三版' });
  b.put('template', 'notes', { text: 'B 在第三版上改' });
  await exchange(a, b);
  for (const data of [a, b]) {
    expect(data.get('template', 'notes')?.body).toEqual({ text: 'B 在第三版上改' });
    expect(conflicts(data)).toEqual([]);
  }

  const start = Date.now() + 10_000;
  setSystemTime(start);
  b.put('template', 'notes', { text: 'B 并发改的' });
  setSystemTime(start + 1_000);
  expect(a.remove('template', 'notes')).toBe(true);
  setSystemTime();
  await exchange(a, b);
  await exchange(a, b);
  for (const data of [a, b]) {
    expect(data.get('template', 'notes')).toBeUndefined();
    expect(conflicts(data)).toEqual([expect.objectContaining({ kind: 'template', id: 'notes', by: 'machine-b', body: { text: 'B 并发改的' } })]);
  }
});

/*
 * 跑起来才知道：几台之间拉取的先后下的因果判断（版本向量 seen）。
 * 真实 bug（旧实现只比对方的上一个版本）：B 在与 A 并发修改之后又改了一次，A 只拉到 B 的最新版，
 * 它的上一个版本比 A 这份新，被当成见过 A 这份，A 的修改没留冲突就被覆盖了。
 */
test('一台并发修改后又改了一次，另一台只拉到它的最新版时仍算冲突：以后写的为准，被覆盖的那份留一条冲突，双向同步后两边一致', async () => {
  const root = temp('account-data-');
  const a = open(root, 'machine-a');
  const b = open(root, 'machine-b');
  const start = Date.now();
  setSystemTime(start);
  a.put('role', 'shared', { text: '原始' });
  await exchange(a, b);

  setSystemTime(start + 1_000);
  a.put('role', 'shared', { text: 'A 改的' });
  setSystemTime(start + 2_000);
  b.put('role', 'shared', { text: 'B 第一次改' });
  setSystemTime(start + 3_000);
  b.put('role', 'shared', { text: 'B 第二次改' });
  setSystemTime();
  await pull(a, b);
  const overwritten = [expect.objectContaining({ kind: 'role', id: 'shared', by: 'machine-a', body: { text: 'A 改的' } })];
  expect(a.get('role', 'shared')).toMatchObject({ body: { text: 'B 第二次改' }, by: 'machine-b' });
  expect(conflicts(a)).toEqual(overwritten);

  await exchange(a, b);
  await exchange(a, b);
  for (const data of [a, b]) {
    expect(data.get('role', 'shared')).toMatchObject({ body: { text: 'B 第二次改' }, by: 'machine-b' });
    expect(conflicts(data)).toEqual(overwritten);
  }
  expect(conflictIds(a)).toEqual(conflictIds(b));
});

/*
 * 跑起来才知道：中转下的因果判断不误报。B 的写入经 C 转给 A（A 不直接从 B 拉），A 在它上面再改；
 * 这一版见过 B 那份，B、C 拉到后都是后续版本。seen 在中转时丢了或被换成转发方的，就会误报成并发修改。
 */
test('B 写的版本经 C 中转到 A，A 在它上面再改，B、C 拉到后都以 A 的为准，三台都不产生冲突', async () => {
  const root = temp('account-data-');
  const a = open(root, 'machine-a');
  const b = open(root, 'machine-b');
  const c = open(root, 'machine-c');
  a.put('template', 'notes', { text: '原始' });
  await pull(b, a);
  await pull(c, a);

  b.put('template', 'notes', { text: 'B 改的' });
  await pull(c, b);
  await pull(a, c);
  expect(a.get('template', 'notes')).toMatchObject({ body: { text: 'B 改的' }, by: 'machine-b' });
  a.put('template', 'notes', { text: 'A 在 B 的上面改' });
  await pull(b, a);
  await pull(c, a);
  for (const data of [b, c]) {
    expect(data.get('template', 'notes')).toMatchObject({ body: { text: 'A 在 B 的上面改' }, by: 'machine-a' });
    expect(conflicts(data)).toEqual([]);
  }

  // 各台再互相拉一遍：转发回来的同一版也不算并发修改。
  for (const [to, from] of [[a, b], [a, c], [b, c], [c, b], [b, a], [c, a]] as const) await pull(to, from);
  for (const data of [a, b, c]) {
    expect(data.get('template', 'notes')).toMatchObject({ body: { text: 'A 在 B 的上面改' }, by: 'machine-a' });
    expect(conflicts(data)).toEqual([]);
  }
});

/*
 * 几个部分的配合：取密钥失败不缓存、凭据封装与进度推进在同一页里的先后。本机密钥取不到（钥匙串锁着、等人允许超时）时，
 * 这一页里的发布记录也要写进来，进度却不能推进，凭据留给下次重试补齐；不然旧版工作机会因为钥匙串卡住永远收不到
 * 新版本的发布记录，多台工作机的自动更新互相卡死。
 */
test('本机密钥取不到时应用对端的一页：发布记录、目录摘要和项目照样写入，凭据与凭据冲突不写、进度不推进并抛出取密钥的错误；密钥能取到后再应用同一页，凭据补齐可解开、进度推进、发布记录不重复', async () => {
  const root = temp('account-data-');
  const a = open(root, 'machine-a');
  const c = open(root, 'machine-c');
  const credential = (token: string) => ({ type: 'git', name: 'git.example.test', meta: { username: 'kite-bot' }, secret: { token } });
  const start = Date.now();
  setSystemTime(start);
  a.put('credential', 'git', await a.seal('credential', credential('A 的令牌')));
  setSystemTime(start + 1_000);
  c.put('credential', 'git', await c.seal('credential', credential('C 后写的令牌')));
  setSystemTime();
  // A 拉到 C 的并发修改：凭据以 C 的为准，A 那份留成一条凭据的冲突。
  await pull(a, c);
  const release = { version: '2.0.0', url: 'https://example.test/kited-2.0.0.tar.gz' };
  a.put('release', '2.0.0', release);
  a.put('catalog', 'machine-a', { name: '工作机 A' });
  a.put('project', 'notes', { name: '笔记' });
  const page = await a.changes(undefined, 0);
  expect(page.more).toBe(false);
  expect(page.entries.map((entry) => entry.kind).sort()).toEqual(['catalog', 'conflict', 'credential', 'project', 'release']);

  const locked = new Error('钥匙串锁着，取不到凭据密钥');
  let keychainLocked = true;
  const key = fileKey(join(root, 'machine-b.key'));
  const b = new AccountData(join(root, 'machine-b.db'), 'machine-b', () => (keychainLocked ? Promise.reject(locked) : key()));
  opened.push(b);

  await expect(b.apply('machine-a', page)).rejects.toThrow(locked.message);
  expect(b.get('release', '2.0.0')?.body).toEqual(release);
  expect(b.get('catalog', 'machine-a')?.body).toEqual({ name: '工作机 A' });
  expect(b.get('project', 'notes')?.body).toEqual({ name: '笔记' });
  expect(b.get('credential', 'git')).toBeUndefined();
  expect(b.list('conflict')).toEqual([]);
  expect(b.cursor('machine-a')).toBeUndefined();

  keychainLocked = false;
  await b.apply('machine-a', page);
  const stored = b.get('credential', 'git')!;
  expect((await b.unseal('credential', stored.body)).secret).toEqual({ token: 'C 后写的令牌' });
  const kept = b.list('conflict');
  expect(kept).toHaveLength(1);
  expect(kept[0]!.body).toMatchObject({ kind: 'credential', id: 'git', by: 'machine-a' });
  expect(((await b.unseal('conflict', kept[0]!.body)).body as { secret: unknown }).secret).toEqual({ token: 'A 的令牌' });
  expect(b.cursor('machine-a')).toEqual({ epoch: page.epoch, seq: page.seq });
  expect(b.list('release').map((item) => item.body)).toEqual([release]);
});
