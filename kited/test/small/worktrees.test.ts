/**
 * 工作树初始化时的忽略文件复制、上游设置加载和沙箱里的 setup。
 */
import { expect, test } from 'bun:test';
import { chmodSync, realpathSync, symlinkSync } from 'node:fs';
import { join } from 'node:path';
// setup 的沙箱宿主按路径起子进程，不在 import 链上；按文本引入，宿主改动时 .kite/check 才会选中这里。
import '../../src/execution/sandbox-callback-host.ts' with { type: 'text' };
import { addWorktree, runSetup } from '../../src/workspace/worktrees.ts';
import { commitAll, git, gitWorktree, isSymlink, lexists, newRepo, read, useTemp, writeFiles } from '../util.ts';

const temp = useTemp();

/*
 * 依赖代码之外的行为：哪些文件算匹配由 git 按忽略规则的语法判定；
 * 规则照 Claude Code 2.1.280 自己建工作树时的做法（匹配且被 .gitignore 忽略的才复制，符号链接不复制）。
 */
test('.worktreeinclude 按 Git 规则复制忽略文件，保留检出版本且不复制符号链接', async () => {
  const root = temp();
  const main = newRepo(root, 'main', {
    '.gitignore': '.env\nsecrets/\n*.local\n*.log\n*.secret\n',
    '.worktreeinclude': '.env\nsecrets/\n*.local\ntracked.txt\n/root.secret\n',
    'tracked.txt': 'committed\n',
  });
  writeFiles(main, {
    '.env': 'root\n',
    'app/.env': 'nested\n',
    'secrets/key.txt': 'key\n',
    'secrets/deep/more.txt': 'more\n',
    'config.local': 'local\n',
    'debug.log': 'not included\n',
    'root.secret': 'r\n',
    'app/root.secret': 'nested secret\n',
    'tracked.txt': 'dirty in main\n',
  });
  writeFiles(root, { 'outside/target.txt': 'target\n' });
  symlinkSync(join(root, 'outside/target.txt'), join(main, 'link.local'));
  symlinkSync(join(root, 'outside/target.txt'), join(main, 'secrets/link.txt'));
  symlinkSync(join(root, 'outside'), join(main, 'secrets/linkdir'));

  const wt = join(root, 'wts', 'w2');
  await addWorktree(main, wt, 'kite/w2', git(main, 'rev-parse', 'HEAD'));

  expect(read(join(wt, '.env'))).toBe('root\n');
  // 不带斜杠的模式匹配任意层级
  expect(read(join(wt, 'app/.env'))).toBe('nested\n');
  expect(read(join(wt, 'secrets/key.txt'))).toBe('key\n');
  expect(read(join(wt, 'secrets/deep/more.txt'))).toBe('more\n');
  expect(read(join(wt, 'config.local'))).toBe('local\n');
  // 前导斜杠只匹配根
  expect(read(join(wt, 'root.secret'))).toBe('r\n');
  expect(lexists(join(wt, 'app/root.secret'))).toBe(false);
  // 被忽略但没列在 .worktreeinclude 里
  expect(lexists(join(wt, 'debug.log'))).toBe(false);
  // 符号链接不复制
  expect(lexists(join(wt, 'link.local'))).toBe(false);
  expect(lexists(join(wt, 'secrets/link.txt'))).toBe(false);
  expect(lexists(join(wt, 'secrets/linkdir'))).toBe(false);
  // 匹配但未被忽略：检出的版本，不是主文件夹里改过的
  expect(read(join(wt, 'tracked.txt'))).toBe('committed\n');
  expect(git(wt, 'status', '--porcelain')).toBe('');
});

/* 依赖上游：SDK 的 resolveSettings 从项目设置里读出 worktree.symlinkDirectories。 */
test('工作树按项目的 worktree.symlinkDirectories 设置链接主文件夹目录', async () => {
  const root = temp();
  const main = newRepo(root, 'main', {
    '.gitignore': 'node_modules/\ndata/\n',
    '.claude/settings.json': JSON.stringify({ worktree: { symlinkDirectories: ['node_modules', 'data/big'] } }),
  });
  writeFiles(main, { 'node_modules/pkg/index.js': '1\n', 'data/big/blob.bin': 'blob\n' });

  const wt = join(root, 'wts', 'w3');
  await addWorktree(main, wt, 'kite/w3', git(main, 'rev-parse', 'HEAD'));

  expect(isSymlink(join(wt, 'node_modules'))).toBe(true);
  expect(realpathSync(join(wt, 'node_modules'))).toBe(join(main, 'node_modules'));
  expect(isSymlink(join(wt, 'data/big'))).toBe(true);
  expect(realpathSync(join(wt, 'data/big'))).toBe(join(main, 'data/big'));
});

/*
 * 依赖 macOS Seatbelt 的路径判定与 sh：setup 与模型的 shell 共用沙箱。工作树照实际布局放在 KITE_HOME/worktrees 下，
 * 与登录凭据同在一个目录树里：工作树要能写、检出里的忽略文件要能读，同时读不到 KITE_HOME/auth，写不了检出；
 * 环境只给约定的变量，kited 进程自己的变量不能带进去。
 * 网络依赖上游 @anthropic-ai/sandbox-runtime 的代理：名单外主机在 DNS 解析前交给宿主决定，setup 一律放行，
 * .invalid 放行后解析失败回 502，不靠外网；被拒回 403。回环一条挡住真实漏洞：setup 用的「名单外一律放行」宿主
 * 曾对 127.0.0.1 这类 IP 字面量和 localhost 直接放行（上游的解析地址检查只判主机名，IP 字面量原样放过，
 * localhost 也被认作该连回环），setup 能经代理连到 kited 只监听回环、信任回环客户端的本机接口。
 * 上游给命令的 NO_PROXY 含回环，curl 默认直连会先被 Seatbelt 挡住，要 --noproxy '' 强制走代理才测得到。
 */
test('setup 在沙箱里能读检出、写工作树，写不了检出、读不到 KITE_HOME 的登录凭据，也拿不到 kited 进程的环境变量；名单外主机放行，回环地址经代理也连不上', async () => {
  const root = temp();
  const home = join(root, 'kite');
  const auth = join(home, 'auth', 'chatgpt', 'auth.json');
  writeFiles(home, { 'auth/chatgpt/auth.json': '{"secret":"setup 不该读到"}\n' });
  let hits = 0;
  const server = Bun.serve({ hostname: '127.0.0.1', port: 0, fetch: () => { hits += 1; return new Response('reachable'); } });
  const curl = (url: string) => `$(curl --silent --output /dev/null --noproxy '' --max-time 1 --write-out '%{http_code}' ${url})`;
  const probe = [
    '#!/bin/sh',
    'if v=$(cat "$KITE_MAIN_DIR/local.env" 2>/dev/null); then echo "main-read=$v"; else echo "main-read=denied"; fi',
    'if (echo 来自 setup > "$KITE_MAIN_DIR/from-setup.txt") 2>/dev/null; then echo "main-write=ok"; else echo "main-write=denied"; fi',
    'if (echo 来自 setup > ./from-setup.txt) 2>/dev/null; then echo "worktree-write=ok"; else echo "worktree-write=denied"; fi',
    `if cat '${auth}' >/dev/null 2>&1; then echo "auth-read=ok"; else echo "auth-read=denied"; fi`,
    'echo "process-only=${KITE_TEST_PROCESS_ONLY:-unset}"',
    'echo "main=$KITE_MAIN_DIR"',
    `echo "outside=${curl('http://kite-setup.invalid:8080/')}"`,
    `echo "loopback=${curl(`http://127.0.0.1:${server.port}/`)}"`,
    `echo "localhost=${curl(`http://localhost:${server.port}/`)}"`,
    `echo "numeric=${curl(`http://2130706433:${server.port}/`)}"`,
    '',
  ].join('\n');
  const main = newRepo(root, 'main', { '.gitignore': 'local.env\n', '.kite/setup': probe });
  chmodSync(join(main, '.kite/setup'), 0o755);
  commitAll(main, '可执行');
  writeFiles(main, { 'local.env': '检出里的忽略文件' });
  const worktree = gitWorktree(main, join(home, 'worktrees', 'w1'), 'kite/w1');

  process.env.KITE_TEST_PROCESS_ONLY = '只在 kited 进程里';
  let result: Awaited<ReturnType<typeof runSetup>>;
  try { result = await runSetup(main, worktree, join(home, 'logs', 'w1-setup.log'), home); }
  finally {
    delete process.env.KITE_TEST_PROCESS_ONLY;
    await server.stop(true);
  }

  expect(result?.exit).toBe(0);
  const seen = Object.fromEntries(result!.tail.trim().split('\n').map((line) => line.split(/=(.*)/s).slice(0, 2)));
  expect(seen).toEqual({
    'main-read': '检出里的忽略文件', 'main-write': 'denied', 'worktree-write': 'ok', 'auth-read': 'denied',
    'process-only': 'unset', main, outside: '502', loopback: '403', localhost: '403', numeric: '403',
  });
  expect(hits).toBe(0);
  expect(lexists(join(main, 'from-setup.txt'))).toBe(false);
  expect(read(join(worktree, 'from-setup.txt'))).toBe('来自 setup\n');
}, 1000);
