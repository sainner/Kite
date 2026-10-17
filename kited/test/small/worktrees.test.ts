/**
 * 沙箱里的 setup：检出是 Kite 数据目录里的裸仓库，工作树从它开出。
 */
import { expect, test } from 'bun:test';
import { chmodSync } from 'node:fs';
import { join } from 'node:path';
// setup 的沙箱宿主按路径起子进程，不在 import 链上；按文本引入，宿主改动时 .kite/check 才会选中这里。
import '../../src/execution/sandbox-callback-host.ts' with { type: 'text' };
import { checkoutPath, worktreePath } from '../../src/paths.ts';
import { addWorktree, runSetup } from '../../src/workspace/worktrees.ts';
import { commitAll, git, lexists, newRepo, read, useTemp, writeFiles } from '../util.ts';

const temp = useTemp();

/*
 * 依赖 macOS Seatbelt 的路径判定与 sh：setup 与模型的 shell 共用沙箱。检出与工作树照实际布局放在 KITE_HOME/repos、
 * KITE_HOME/worktrees 下，与登录凭据同在一个目录树里：工作树要能写、检出（Git 元数据）要能读，同时读不到 KITE_HOME/auth，
 * 写不了检出；环境只给约定的变量，kited 进程自己的变量不能带进去，也不再有 KITE_MAIN_DIR。
 * 网络依赖上游 @anthropic-ai/sandbox-runtime 的代理：名单外主机在 DNS 解析前交给宿主决定，setup 一律放行，
 * .invalid 放行后解析失败回 502，不靠外网；被拒回 403。回环一条挡住真实漏洞：setup 用的「名单外一律放行」宿主
 * 曾对 127.0.0.1 这类 IP 字面量和 localhost 直接放行（上游的解析地址检查只判主机名，IP 字面量原样放过，
 * localhost 也被认作该连回环），setup 能经代理连到 kited 只监听回环、信任回环客户端的本机接口。
 * 上游给命令的 NO_PROXY 含回环，curl 默认直连会先被 Seatbelt 挡住，要 --noproxy '' 强制走代理才测得到。
 */
test('setup 在沙箱里能读检出、写工作树，写不了检出、读不到 KITE_HOME 的登录凭据，也拿不到 kited 进程的环境变量和 KITE_MAIN_DIR；名单外主机放行，回环地址经代理也连不上', async () => {
  const root = temp();
  const home = join(root, 'kite');
  const auth = join(home, 'auth', 'chatgpt', 'auth.json');
  writeFiles(home, { 'auth/chatgpt/auth.json': '{"secret":"setup 不该读到"}\n' });
  const checkout = checkoutPath(home, 'project');
  let hits = 0;
  const server = Bun.serve({ hostname: '127.0.0.1', port: 0, fetch: () => { hits += 1; return new Response('reachable'); } });
  const curl = (url: string) => `$(curl --silent --output /dev/null --noproxy '' --max-time 1 --write-out '%{http_code}' ${url})`;
  const probe = [
    '#!/bin/sh',
    `if v=$(cat '${checkout}/HEAD' 2>/dev/null); then echo "checkout-read=$v"; else echo "checkout-read=denied"; fi`,
    `if (echo 来自 setup > '${checkout}/from-setup.txt') 2>/dev/null; then echo "checkout-write=ok"; else echo "checkout-write=denied"; fi`,
    'if (echo 来自 setup > ./from-setup.txt) 2>/dev/null; then echo "worktree-write=ok"; else echo "worktree-write=denied"; fi',
    `if cat '${auth}' >/dev/null 2>&1; then echo "auth-read=ok"; else echo "auth-read=denied"; fi`,
    'echo "process-only=${KITE_TEST_PROCESS_ONLY:-unset}"',
    'echo "main-dir=${KITE_MAIN_DIR:-unset}"',
    `echo "outside=${curl('http://kite-setup.invalid:8080/')}"`,
    `echo "loopback=${curl(`http://127.0.0.1:${server.port}/`)}"`,
    `echo "localhost=${curl(`http://localhost:${server.port}/`)}"`,
    `echo "numeric=${curl(`http://2130706433:${server.port}/`)}"`,
    '',
  ].join('\n');
  const source = newRepo(root, 'source', { '.kite/setup': probe }, null);
  chmodSync(join(source, '.kite/setup'), 0o755);
  commitAll(source, '可执行');
  git(root, 'clone', '-q', '--bare', source, checkout);
  const worktree = worktreePath(home, 'project', 'w1');
  await addWorktree(checkout, worktree, 'kite/w1', git(checkout, 'rev-parse', 'main'));

  process.env.KITE_TEST_PROCESS_ONLY = '只在 kited 进程里';
  let result: Awaited<ReturnType<typeof runSetup>>;
  try { result = await runSetup(checkout, worktree, join(home, 'logs', 'w1-setup.log'), home); }
  finally {
    delete process.env.KITE_TEST_PROCESS_ONLY;
    await server.stop(true);
  }

  expect(result?.exit).toBe(0);
  const seen = Object.fromEntries(result!.tail.trim().split('\n').map((line) => line.split(/=(.*)/s).slice(0, 2)));
  expect(seen).toEqual({
    'checkout-read': 'ref: refs/heads/main', 'checkout-write': 'denied', 'worktree-write': 'ok', 'auth-read': 'denied',
    'process-only': 'unset', 'main-dir': 'unset', outside: '502', loopback: '403', localhost: '403', numeric: '403',
  });
  expect(hits).toBe(0);
  expect(lexists(join(checkout, 'from-setup.txt'))).toBe(false);
  expect(read(join(worktree, 'from-setup.txt'))).toBe('来自 setup\n');
}, 1000);
