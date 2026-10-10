/**
 * 快照引用、历史查找和工作树回退。
 */
import { expect, test } from 'bun:test';
import { renameSync, rmSync, utimesSync } from 'node:fs';
import { join } from 'node:path';
import { capture, changesBetween, findSnapshot, list, restore } from '../../src/workspace/snapshots.ts';
import { git, gitWorktree, lexists, listTree, newRepo, read, repoState, useTemp, writeFiles } from '../util.ts';

const temp = useTemp();

/*
 * 回归两个 bug：标签曾在第 80 个字处截断（这里用超过 80 字的标签）；快照曾挂在 refs/kite/<工作区>，
 * 和工作区分支 kite/<工作区> 的短名相同，git 优先把短名解析成快照。
 */
test('快照按文件内容去重，完整保存元数据且不干扰工作区和分支引用', async () => {
  const root = temp();
  const main = newRepo(root, 'main', { 'a.txt': 'a\n', 'b.txt': 'b\n' });
  writeFiles(main, { 'b.txt': 'main dirty\n', 'm.txt': 'm\n' });
  git(main, 'add', 'm.txt');
  const id = 's1';
  const wt = gitWorktree(main, join(root, 'wt'), `kite/${id}`);
  writeFiles(wt, { 'staged.txt': 'st\n' });
  git(wt, 'add', 'staged.txt');
  writeFiles(wt, { 'a.txt': 'a1\n' });
  const before = [repoState(main), repoState(wt)];

  const first = await capture(wt, id, '工作区开始');
  expect(first.created).toBe(true);
  expect(git(main, 'show', `${first.commit}:a.txt`)).toBe('a1');

  const same = await capture(wt, id, '没有变化');
  expect(same.created).toBe(false);
  expect(same.commit).toBe(first.commit);

  // 已改过的文件再改一次：工作区状态的样子不变，树变了
  writeFiles(wt, { 'a.txt': 'a2\n' });
  const label = `RUN echo 长标签 # ${'这是一条比较长的用户消息，'.repeat(8)}结尾`;
  const second = await capture(wt, id, label, ['toolu_a', 'toolu_b']);
  expect(second.created).toBe(true);
  // 快照是这个引用上的提交链：引用指向最新的一枚，list 沿它读回
  expect(git(main, 'rev-parse', `refs/kite/snapshots/${id}`)).toBe(second.commit);

  const snaps = await list(main, id);
  expect(snaps.map((s) => s.commit)).toEqual([second.commit, first.commit]);
  expect(snaps[0]!.label).toBe(label);
  expect(snaps[0]!.toolUseIds).toEqual(['toolu_a', 'toolu_b']);
  expect(snaps[1]!.label).toBe('工作区开始');
  expect(snaps[1]!.toolUseIds).toEqual([]);

  expect([repoState(main), repoState(wt)]).toEqual(before);
  const [short, branch] = git(main, 'rev-parse', `kite/${id}`, `refs/heads/kite/${id}`).split('\n');
  expect(short).toBe(branch);
});

test('回退恢复增删改名且保留忽略文件，自动快照能找回回退前内容', async () => {
  const root = temp();
  const main = newRepo(root, 'main', {
    '.gitignore': '.env\n',
    'keep.txt': 'v0\n',
    'del.txt': 'to be deleted\n',
    'ren.txt': 'to be renamed\n',
    'dir/inner.txt': 'inner\n',
  });
  const id = 's2';
  const wt = gitWorktree(main, join(root, 'wt'), `kite/${id}`);
  // Git 的 racy-clean 判定依赖 index 与工作文件的 mtime；复制 index 后再 add，
  // 同长度改写若保留旧 mtime，仍须把新内容纳入快照。
  const oldTime = new Date('2020-01-01T00:00:00Z');
  const keep = join(wt, 'keep.txt');
  utimesSync(keep, oldTime, oldTime);
  git(wt, 'add', '--', 'keep.txt');
  const worktreeIndex = git(wt, 'rev-parse', '--git-path', 'index');
  utimesSync(worktreeIndex, oldTime, oldTime);
  writeFiles(wt, { '.env': 'SECRET=1\n', 'keep.txt': 'v1\n' });
  utimesSync(keep, oldTime, oldTime);
  const s1 = await capture(wt, id, 'v1');
  expect(git(main, 'show', `${s1.commit}:keep.txt`)).toBe('v1');

  // 之后的改动，还没进任何快照
  rmSync(join(wt, 'del.txt'));
  renameSync(join(wt, 'ren.txt'), join(wt, 'renamed.txt'));
  rmSync(join(wt, 'dir'), { recursive: true });
  writeFiles(wt, { 'created.txt': 'new\n', 'newdir/deep/f.txt': 'nd\n', 'keep.txt': 'v2\n', '.env': 'SECRET=2\n' });

  const r = await restore(wt, id, s1.commit);
  expect(read(join(wt, 'keep.txt'))).toBe('v1\n');
  expect(read(join(wt, 'del.txt'))).toBe('to be deleted\n');
  expect(read(join(wt, 'ren.txt'))).toBe('to be renamed\n');
  expect(read(join(wt, 'dir/inner.txt'))).toBe('inner\n');
  expect(lexists(join(wt, 'renamed.txt'))).toBe(false);
  expect(lexists(join(wt, 'created.txt'))).toBe(false);
  expect(lexists(join(wt, 'newdir/deep/f.txt'))).toBe(false);
  expect(read(join(wt, '.env'))).toBe('SECRET=2\n');

  const auto = (await list(main, id)).find((s) => s.label === '回退前自动保存');
  expect(auto).toBeDefined();
  expect(r.safety.created).toBe(true);
  expect(r.safety.commit).toBe(auto!.commit);
  expect(git(main, 'show', `${auto!.commit}:created.txt`)).toBe('new');

  await restore(wt, id, auto!.commit);
  expect(read(join(wt, 'keep.txt'))).toBe('v2\n');
  expect(read(join(wt, 'created.txt'))).toBe('new\n');
  expect(read(join(wt, 'newdir/deep/f.txt'))).toBe('nd\n');
  expect(read(join(wt, 'renamed.txt'))).toBe('to be renamed\n');
  expect(lexists(join(wt, 'del.txt'))).toBe(false);
  expect(lexists(join(wt, 'ren.txt'))).toBe(false);
  expect(lexists(join(wt, 'dir/inner.txt'))).toBe(false);
  expect(read(join(wt, '.env'))).toBe('SECRET=2\n');
});

// 回归：旧快照中的文件曾覆盖当前同名的忽略文件，或删掉同名目录里的忽略内容；
// 这些内容不在回退前的安全快照里，依赖真实 Git 的索引、忽略规则和工作树更新共同保护。
// 不区分大小写的文件系统还会让 Config 文件与 config/ 目录指向同一路径。
// Git 对被忽略的嵌套仓库只列出目录，里面的文件和仓库也必须保留。
test('回退拒绝覆盖忽略文件或含忽略内容的目录，保留工作文件和 Git 状态', async () => {
  const root = temp();
  for (const fixture of [
    { name: 'file', path: '.env', ignored: '.env', captureDeletion: true },
    { name: 'directory', path: 'cache', ignored: 'cache/ignored.txt', captureDeletion: false },
    { name: 'case-directory', path: 'Config', ignored: 'config/ignored.txt', captureDeletion: false },
    { name: 'nested-repo', path: 'cache', ignored: 'cache/ignored.txt', captureDeletion: false },
  ]) {
    const main = newRepo(root, fixture.name, { 'keep.txt': '旧内容\n' });
    const id = `ignored-${fixture.name}`;
    const wt = gitWorktree(main, join(root, `wt-${fixture.name}`), `kite/${id}`);
    writeFiles(wt, { [fixture.path]: '快照中的文件\n' });
    if (fixture.name === 'case-directory' && !lexists(join(wt, 'config'))) continue;
    const target = await capture(wt, id, '原文件');
    rmSync(join(wt, fixture.path));
    writeFiles(wt, { '.gitignore': `${fixture.path}\n`, 'keep.txt': '回退前内容\n' });
    if (fixture.captureDeletion) await capture(wt, id, '删除原文件并忽略');
    writeFiles(wt, { [fixture.ignored]: '只保存在本地的内容\n' });
    if (fixture.name === 'nested-repo') newRepo(wt, fixture.path, {});
    expect(git(wt, 'check-ignore', '--', fixture.ignored)).toBe(fixture.ignored);
    const files = listTree(wt);
    const state = repoState(wt);

    const error = await restore(wt, id, target.commit).then(() => undefined, (error: unknown) => error);
    expect(listTree(wt)).toEqual(files);
    expect(repoState(wt)).toBe(state);
    expect(error).toBeInstanceOf(Error);
    expect((error as Error).message.toLowerCase()).toContain(fixture.path.toLowerCase());
  }
});

/*
 * 依赖 git：`git log -1 --format=%H%x1f%(trailers:key=Kite-Workspace,valueonly) <commit> --` 把缩写提交号解析成完整提交号，
 * 按 trailer 读出快照属于哪个工作区（另一个工作区的 id 以本工作区 id 开头，挡住按前缀比对）。分支名和修订表达式这里都让它们
 * 指向本工作区的快照，只有「只收十六进制」这一条能挡住；--output 会让 git log 往文件里写，挡住参数被当成选项。
 */
test('快照查找解析本工作区的提交号，拒绝外部快照、普通提交、引用和 Git 选项', async () => {
  const root = temp();
  const main = newRepo(root, 'main', { 'a.txt': 'a\n' });
  const id = 's3';
  const other = 's3-other';
  const wt = gitWorktree(main, join(root, 'wt'), `kite/${id}`);
  const otherWt = gitWorktree(main, join(root, 'wt-other'), `kite/${other}`);
  writeFiles(wt, { 'a.txt': 'a1\n' });
  const older = await capture(wt, id, '第一枚');
  writeFiles(wt, { 'a.txt': 'a2\n' });
  const newer = await capture(wt, id, '第二枚');
  writeFiles(otherWt, { 'a.txt': 'other\n' });
  const foreign = await capture(otherWt, other, '别的工作区');

  expect(await findSnapshot(main, id, older.commit.slice(0, 8))).toBe(older.commit);
  expect(await findSnapshot(wt, id, newer.commit)).toBe(newer.commit);

  expect(await findSnapshot(main, id, foreign.commit)).toBeNull();
  expect(await findSnapshot(main, id, foreign.commit.slice(0, 8))).toBeNull();
  expect(await findSnapshot(main, other, older.commit)).toBeNull();
  expect(await findSnapshot(main, id, git(main, 'rev-parse', 'HEAD'))).toBeNull();
  expect(await findSnapshot(main, id, 'deadbeef'.repeat(5))).toBeNull();

  // 让 HEAD 和 main 都指向本工作区的快照
  git(main, 'reset', '-q', '--hard', older.commit);
  for (const rev of ['HEAD', 'main', `refs/kite/snapshots/${id}`, `${older.commit}~0`, `${older.commit}^{commit}`]) {
    expect(await findSnapshot(main, id, rev)).toBeNull();
  }
  const leak = join(root, 'leak.txt');
  for (const arg of [`--output=${leak}`, '--all', '-1', `-${older.commit.slice(0, 8)}`]) {
    expect(await findSnapshot(main, id, arg)).toBeNull();
  }
  expect(lexists(leak)).toBe(false);
});

// 压缩的净文件变化依赖真实 git：两个时刻各自对应的快照（按 Kite-At 毫秒 trailer 定位）做 diff-tree，
// 改名检测、行数统计和删除文件的计数都来自 git 输出，看代码确认不了。
test('压缩起止时刻之间的净文件变化取各自最近的快照，列出新增修改删除与增删行数', async () => {
  const root = temp();
  const main = newRepo(root, 'main', { 'keep.txt': 'k\n', 'edit.txt': '一\n二\n三\n', 'gone.txt': 'x\ny\n' });
  const id = 'w1';
  await capture(main, id, '开始');
  writeFiles(main, { 'edit.txt': '一\n改\n三\n四\n', 'new.txt': 'a\nb\n' });
  rmSync(join(main, 'gone.txt'));
  await capture(main, id, '中间');
  writeFiles(main, { 'later.txt': '更晚的改动\n' });
  await capture(main, id, '之后');
  const [after, middle, start] = await list(main, id);
  expect(start!.at).toBeLessThan(middle!.at);
  expect(middle!.at + 1).toBeLessThan(after!.at);

  // 终点落在「中间」与「之后」两枚快照之间，取较早的「中间」；更晚的 later.txt 不应出现。
  const changes = await changesBetween(main, id, start!.at, middle!.at + 1);
  expect(changes?.split('\n').sort()).toEqual([
    '修改 edit.txt (+2 -1)',
    '删除 gone.txt (+0 -2)',
    '新增 new.txt (+2 -0)',
  ].sort());
});
