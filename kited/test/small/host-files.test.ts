/**
 * 添加项目时 App 选文件夹和环境变量文件用的 GET /host-files（docs/kited.md）：列这台工作机上的一个目录，只列名字不读内容。
 * 不起 Claude Code。
 */
import { afterEach, expect, test } from 'bun:test';
import { mkdirSync, symlinkSync } from 'node:fs';
import { join } from 'node:path';
import { hostDirectory } from '../../src/workspace/files.ts';
import { type Kited, startKited } from '../harness.ts';
import { writeFiles } from '../util.ts';

type Listing = Awaited<ReturnType<typeof hostDirectory>>;
type Entry = Listing['entries'][number];

let kited: Kited | undefined;
afterEach(async () => {
  await kited?.stop();
  kited = undefined;
});

/*
 * 运行时：Node 的 readdir 给的 Dirent 对符号链接只说它是链接，要跟随到目标才知道是目录还是文件；
 * 链接目标写的是相对路径，跟随时要相对链接所在的目录解析。不存在的路径 readdir 报 ENOENT，要映射成 404。
 * 不给路径时列主目录：Bun 的 os.homedir() 只在进程启动时读 HOME，不随运行中改过的 process.env.HOME 变化，
 * 测试的隔离环境（test/setup.ts）就是运行中改的 HOME。
 * 名字按字母排时文件 a-file.env 在子目录 b-dir 前面，目录在前要跑起来才看得出。
 */
test('列工作机上的目录：子目录与指向目录的链接归为 directory 排在前面，文件与指向文件的链接归为 file，路径都是绝对的；不存在的路径 404；不给路径时列 HOME', async () => {
  const k = kited = startKited();
  const dir = join(k.root, 'pick');
  mkdirSync(join(dir, 'b-dir'), { recursive: true });
  writeFiles(dir, { 'a-file.env': 'A=1\n', 'b-dir/inner.txt': 'x\n' });
  symlinkSync('b-dir', join(dir, 'c-dir-link'));
  symlinkSync('a-file.env', join(dir, 'd-file-link'));

  const listed = await k.call('GET', `/host-files?path=${encodeURIComponent(dir)}`);
  expect(listed.status).toBe(200);
  const listing = listed.body as Listing;
  expect(listing.path).toBe(dir);
  expect(listing.total).toBe(4);
  expect(listing.entries.map((e) => e.kind)).toEqual(['directory', 'directory', 'file', 'file']);
  const entry = (name: string, kind: Entry['kind']): Entry => ({ name, path: join(dir, name), kind });
  expect([...listing.entries].sort((a, b) => a.name.localeCompare(b.name))).toEqual([
    entry('a-file.env', 'file'), entry('b-dir', 'directory'), entry('c-dir-link', 'directory'), entry('d-file-link', 'file'),
  ]);

  expect((await k.call('GET', `/host-files?path=${encodeURIComponent(join(dir, 'missing'))}`)).status).toBe(404);

  const home = await k.call('GET', '/host-files');
  expect(home.status).toBe(200);
  expect(home.body.path).toBe(process.env.HOME);
}, 1000);
