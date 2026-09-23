/**
 * bun test 的 preload（kited/bunfig.toml），在所有测试之前运行一次：
 * 把 process.env 换成一套最小的隔离环境，起一个整个测试进程共用的假端点。
 *
 * 必须清空：测试常在别的 Claude Code 会话里运行，环境里的 CLAUDECODE、CLAUDE_CODE_*、ANTHROPIC_BASE_URL
 * 漏进来会让子进程连到真实服务、读到真实设置。kited 在本进程里启动时，Claude Code 子进程和 SDK 的
 * resolveSettings、getSessionInfo 都读 process.env。
 *
 * 注意：Bun.spawn / Bun.spawnSync 不传 env 时继承的是进程启动时的环境，不是这里改过的 process.env。
 * 测试自己起子进程一律显式传 env（见 util.ts 的 ENV）。
 */
import { afterAll } from 'bun:test';
import { mkdirSync, mkdtempSync, realpathSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { startFakeApi } from './fake-api.ts';

const TMPDIR = realpathSync(tmpdir());
const root = realpathSync(mkdtempSync(join(TMPDIR, 'kited-test-env-')));
for (const d of ['home', 'claude']) mkdirSync(join(root, d));

/** 整个测试进程共用的假端点。 */
export const api = startFakeApi(join(root, 'bg'));

for (const k of Object.keys(process.env)) delete process.env[k];
Object.assign(process.env, {
  PATH: `${dirname(process.execPath)}:/usr/bin:/bin:/usr/sbin:/sbin`,
  HOME: join(root, 'home'),
  CLAUDE_CONFIG_DIR: join(root, 'claude'),
  TMPDIR,
  LANG: 'en_US.UTF-8',
  USER: 'kite-test',
  SHELL: '/bin/zsh',
  ANTHROPIC_API_KEY: 'sk-ant-fake',
  ANTHROPIC_BASE_URL: api.url,
  CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC: '1',
});

afterAll(async () => {
  api.releaseAll();
  await api.stop();
  rmSync(root, { recursive: true, force: true });
});
