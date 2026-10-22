import { createHash, randomUUID } from 'node:crypto';
import { existsSync, mkdirSync, readFileSync, renameSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { KiteError } from './errors.ts';

/** 跑系统自带的小工具读它的输出：env 显式给出，不继承 kited 的环境；超时就杀掉。 */
export async function systemCommand(command: string[], options: { env?: Record<string, string>; timeoutMs?: number } = {}): Promise<{ code: number; stdout: string }> {
  const child = Bun.spawn(command, { env: options.env ?? { PATH: '/usr/bin:/bin' }, stdout: 'pipe', stderr: 'ignore' });
  const timer = setTimeout(() => child.kill(), options.timeoutMs ?? 5_000);
  try {
    const stdout = await new Response(child.stdout).text();
    return { code: await child.exited, stdout };
  } finally { clearTimeout(timer); }
}

const builds = new Map<string, Promise<string>>();

/**
 * 随 kited 带源码、首次使用时编译的小程序（kite-pdf、kite-sim）：按源码哈希编译到用户临时目录的 kite-<name>-<hash>/<name>，编过的直接用。
 * 先编到临时文件再改名，几处同时要时只编一次；编译失败时报 failure 加编译输出的最后几行。
 */
export function compiledHelper(helper: { source: string; name: string; compile: (output: string) => string[]; env: NodeJS.ProcessEnv; failure: string; status?: number }): Promise<string> {
  const key = `${helper.name}-${createHash('sha256').update(readFileSync(helper.source)).digest('hex').slice(0, 16)}`;
  let build = builds.get(key);
  if (!build) {
    build = (async () => {
      const directory = join(tmpdir(), `kite-${key}`);
      const binary = join(directory, helper.name);
      if (existsSync(binary)) return binary;
      mkdirSync(directory, { recursive: true, mode: 0o700 });
      const output = join(directory, `.build-${randomUUID()}`);
      const child = Bun.spawn(helper.compile(output), { env: helper.env, stdout: 'ignore', stderr: 'pipe' });
      const [log, code] = await Promise.all([new Response(child.stderr).text(), child.exited]);
      if (code !== 0) {
        rmSync(output, { force: true });
        throw new KiteError(`${helper.failure}：${log.trim().split('\n').slice(-3).join('\n')}`, helper.status);
      }
      renameSync(output, binary);
      return binary;
    })();
    builds.set(key, build);
    build.catch(() => builds.delete(key));
  }
  return build;
}
