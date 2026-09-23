/**
 * Kite 启动时的恢复（src/kite.ts）：K1。
 */
import { expect, test } from 'bun:test';
import { randomUUID } from 'node:crypto';
import { mkdirSync } from 'node:fs';
import { join } from 'node:path';
import { Bus } from '../../src/events.ts';
import { Kite } from '../../src/kite.ts';
import { Store } from '../../src/store.ts';
import { git, newRepo, until, useTemp } from '../util.ts';

const temp = useTemp();

test('在有 preparing 会话的数据库上构造 Kite（kited 重启），这个会话变成 prepare_failed', async () => {
  const root = temp();
  const home = join(root, 'kite');
  mkdirSync(home);
  const main = newRepo(root, 'proj', { 'a.txt': 'a\n' });
  const store = new Store(join(home, 'kite.db'));
  store.addProject({ id: 'proj', path: main, commits: 'user', createdAt: Date.now() });
  store.addSession({
    id: 'prep', projectId: 'proj', title: '你好', worktree: join(home, 'worktrees', 'proj', 'prep'), branch: 'kite/prep',
    base: git(main, 'rev-parse', 'HEAD'), runtime: 'claude', nativeId: randomUUID(), status: 'preparing', createdAt: Date.now(),
  });

  const kite = new Kite(store, home, new Bus());
  try {
    await until(() => store.session('prep')?.status !== 'preparing', '会话离开 preparing', 400).catch(() => undefined);
    expect(store.session('prep')?.status).toBe('prepare_failed');
  } finally {
    await kite.shutdown();
    store.close();
  }
});
