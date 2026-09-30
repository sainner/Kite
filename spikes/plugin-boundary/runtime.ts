import { realpathSync } from 'node:fs';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';

export const denoBinary = join(import.meta.dir, 'node_modules/@deno/darwin-arm64/deno');

export function pluginLaunch(entry: string, cwd: string) {
  const bundle = realpathSync(entry);
  return {
    command: denoBinary,
    args: ['run', '--no-config', '--no-prompt', '--no-remote', '--no-npm', '--cached-only',
      `--allow-read=${bundle}`, '--deny-write', '--deny-net', '--deny-env', '--deny-run', '--deny-ffi', '--deny-sys',
      '--v8-flags=--max-old-space-size=128', join(import.meta.dir, 'launcher.js'), pathToFileURL(bundle).href],
    cwd,
    // 不继承宿主认证信息、Deno 配置或权限代理；缓存也按实例隔离。
    env: { HOME: cwd, PATH: '/usr/bin:/bin', TMPDIR: cwd, USER: 'kite-plugin', LOGNAME: 'kite-plugin', SHELL: '',
      DENO_DIR: join(cwd, 'cache'), DENO_NO_UPDATE_CHECK: '1', NO_COLOR: '1' },
  };
}

export function launchPlugin(entry: string, cwd: string) {
  const { command, args, env } = pluginLaunch(entry, cwd);
  return Bun.spawn([command, ...args], { cwd, env, stdin: 'pipe', stdout: 'pipe', stderr: 'pipe' });
}
