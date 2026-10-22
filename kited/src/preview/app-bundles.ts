/**
 * Mac App 的分发包（docs/成果查看与位置.md「原生 App」）：在另一台 Mac 上看 App 窗口时，可以把这个 App 装到那台 Mac 上直接用。
 * 工作机把 App 窗口里那个 App 的 .app 打成 zip（ditto）；看的那台 Mac 上的 App 下载下来交给本机的 kited 解开、打开。
 * 不由 App 自己解开：App 开着沙盒，它写出的文件带隔离标记，开发签名的 App 过不了 Gatekeeper；kited 写出的没有隔离标记。
 */
import { randomUUID } from 'node:crypto';
import { mkdirSync, readdirSync, rmSync } from 'node:fs';
import { join } from 'node:path';
import { KiteError } from '../errors.ts';
import { systemCommand } from '../system-command.ts';

const TOOLS_ENV = { PATH: '/usr/bin:/bin' };
const OPEN_TIMEOUT_MS = 2 * 60_000;

/** 把 .app 打成 zip 流式发出去；不是 .app（直接跑的可执行文件）的不能分发。 */
export function bundleResponse(path: string): Response {
  if (process.platform !== 'darwin') throw new KiteError('只有 Mac 工作机能打包 App', 503);
  if (!path.endsWith('.app')) throw new KiteError(`${path} 不是 .app，装不到别的 Mac 上：让预置脚本打出 .app 再跑它里面的可执行文件`, 409);
  const name = path.split('/').at(-1)!;
  const child = Bun.spawn(['/usr/bin/ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', path, '-'], { env: TOOLS_ENV, stdout: 'pipe', stderr: 'ignore' });
  return new Response(child.stdout, { headers: { 'content-type': 'application/zip', 'x-kite-app': encodeURIComponent(name) } });
}

/** 在这台 Mac 上解开 App 的 zip 并打开：放在 Kite 目录的 apps/ 下，同名的换成新的。返回解开后的 .app 路径。 */
export async function openBundle(home: string, name: string, zip: Blob): Promise<{ path: string }> {
  if (process.platform !== 'darwin') throw new KiteError('只有 Mac 能打开 App', 503);
  if (!/^[^/\0]+\.app$/.test(name) || name.startsWith('.')) throw new KiteError('App 名字无效', 400);
  const root = join(home, 'apps');
  const target = join(root, name.slice(0, -4));
  const staging = join(root, `.unpack-${randomUUID()}`);
  mkdirSync(staging, { recursive: true, mode: 0o700 });
  try {
    const archive = join(staging, 'app.zip');
    await Bun.write(archive, zip);
    const unpacked = join(staging, 'unpacked');
    if ((await systemCommand(['/usr/bin/ditto', '-x', '-k', archive, unpacked], { env: TOOLS_ENV, timeoutMs: OPEN_TIMEOUT_MS })).code !== 0) throw new KiteError('App 的包解不开', 400);
    const app = readdirSync(unpacked).find((entry) => entry.endsWith('.app'));
    if (!app) throw new KiteError('包里没有 .app', 400);
    rmSync(target, { recursive: true, force: true });
    mkdirSync(target, { recursive: true });
    const path = join(target, app);
    if ((await systemCommand(['/bin/mv', join(unpacked, app), path], { env: TOOLS_ENV })).code !== 0) throw new KiteError('App 没有放好', 500);
    if ((await systemCommand(['/usr/bin/open', '-n', path], { env: TOOLS_ENV, timeoutMs: OPEN_TIMEOUT_MS })).code !== 0) throw new KiteError('App 没有打开', 409);
    return { path };
  } finally {
    rmSync(staging, { recursive: true, force: true });
  }
}
